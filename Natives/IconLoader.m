//
//  IconLoader.m
//  Amethyst
//
//  Implementation of the unified project icon loader (modelled on the best practices of FCL Glide + ZL2 Coil)
//
//  Key points:
//    1. Two-level cache:
//       - memory: NSCache (which responds to memory warnings automatically and is thread-safe), 20MB / 200 entries
//       - disk: Library/Caches/IconLoader/, named by the MD5 of url+size, capped at 256MB
//       (a compromise between the 250MB of FCL and the 512MB of ZL2; 256MB is more conservative for mobile)
//    2. Downsampling: CGImageSourceCreateThumbnailAtIndex decodes at the target size
//       (equivalent to ZL2 .size(pxSize), avoiding decoding a 1024x1024 original just to shrink it)
//    3. Async decoding: decoded on a dispatch_get_global_queue background thread, with the main thread only rendering
//    4. Concurrency cap: a dispatch_semaphore limits downloads to 6 at a time
//       (equivalent to the thread pool caps of Glide/Coil, avoiding dozens of concurrent requests while scrolling)
//    5. Same-URL coalescing: the inFlightRequests dictionary merges multiple callbacks for one URL
//       (equivalent to the RequestCoordinator of Glide and the shared flow of Coil)
//    6. CDN mirrors: cdn.modrinth.com / edge.forgecdn.net -> BMCLAPI mirrors
//       (equivalent to ZL2 MCIMirror)
//    7. Cancellation: each imageView is associated with a token, which is invalidated on cell reuse
//       (equivalent to Glide clear() and the composition cancellation of ZL2)
//    8. Prefetching: the prefetchIconWithURL: interface only downloads and caches, without binding an imageView
//       (equivalent to ZL2 imageLoader.enqueue)
//

#import "IconLoader.h"
#import "LauncherPreferences.h"
#import "MCIMMirror.h"
#import "utils.h"
#import <CommonCrypto/CommonCrypto.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>

/// Memory cache cap: 20MB (matching the ZL2 configuration)
static const NSUInteger kMemoryCacheCostLimit = 20 * 1024 * 1024;
static const NSUInteger kMemoryCacheCountLimit = 200;

/// Disk cache cap: 256MB (a compromise between the 250MB of FCL and the 512MB of ZL2)
static const unsigned long long kDiskCacheSizeLimit = 256ULL * 1024 * 1024;

/// Concurrent download cap (raised to 15 to load list icons faster)
/// Modelled on the thread pool cap of FCL Glide (4 by default, one per CPU core; list icons on mobile need more concurrency)
static const NSInteger kMaxConcurrentDownloads = 15;

/// Network request timeout (seconds) — shortened to 8 so failures are quick and queued requests get a slot sooner
static const NSTimeInterval kRequestTimeout = 8.0;

/// Singleton instance
static IconLoader *_sharedLoader = nil;

/// In-flight request dictionary: key = cacheKey (the MD5 of url+size), value = NSMutableArray<callback-block>
/// Used to coalesce identical URLs and avoid duplicate downloads (equivalent to the RequestCoordinator of Glide)
static NSMutableDictionary<NSString *, NSMutableArray<void(^)(UIImage * _Nullable)> *> *_inFlightRequests = nil;

/// Associated-object key mapping an imageView to the cacheKey of its current request
/// Used to cancel the old request on cell reuse (equivalent to Glide clear())
static const void *kIconLoaderImageViewKey = &kIconLoaderImageViewKey;

#pragma mark - Internal loading context

@interface IconLoader ()
/// Memory cache
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *memoryCache;
/// Set tracking the memory cache keys (NSCache exposes neither count nor enumeration,
/// so a separate NSMutableSet tracks the cached keys for the memoryCacheCount statistic)
@property (nonatomic, strong) NSMutableSet<NSString *> *memoryCacheKeys;
/// Concurrent download semaphore
@property (nonatomic, strong) dispatch_semaphore_t downloadSemaphore;
/// Serial queue guarding thread-safe access to the _inFlightRequests dictionary and memoryCacheKeys
@property (nonatomic, strong) dispatch_queue_t syncQueue;
/// Disk cache directory
@property (nonatomic, copy) NSString *diskCacheDirectory;
/// Whether CDN mirror substitution is enabled
@property (nonatomic, assign) BOOL mirrorEnabled;
/// NSURLSession (using an ephemeral configuration, so cookies are not shared with AFNetworking)
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation IconLoader

#pragma mark - Singleton

+ (instancetype)sharedLoader {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedLoader = [[IconLoader alloc] init];
    });
    return _sharedLoader;
}

// Note: no +load method is implemented.
// Reason: +load runs before main(), when the preferences system (PLPreferences/LauncherPreferences) may not be initialized,
// so calling getPrefObject could return nil or crash. The mirror switch is instead initialized lazily in init (on the first sharedLoader call),
// by which point the app has finished basic startup and the preferences are ready.

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize the memory cache
        _memoryCache = [[NSCache alloc] init];
        _memoryCache.totalCostLimit = kMemoryCacheCostLimit;
        _memoryCache.countLimit = kMemoryCacheCountLimit;
        // NSCache clears itself on UIApplicationDidReceiveMemoryWarningNotification,
        // so observing it is not required (though observing it too is harmless and reacts faster)

        // Key tracking set (for the memoryCacheCount statistic, since NSCache does not expose count)
        _memoryCacheKeys = [NSMutableSet set];

        // Concurrent download semaphore
        _downloadSemaphore = dispatch_semaphore_create(kMaxConcurrentDownloads);

        // Synchronization queue (guarding _inFlightRequests)
        _syncQueue = dispatch_queue_create("com.angelaura.iconloader.sync", DISPATCH_QUEUE_SERIAL);

        // In-flight request dictionary
        _inFlightRequests = [NSMutableDictionary dictionary];

        // Disk cache directory
        NSString *cachesDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        _diskCacheDirectory = [cachesDir stringByAppendingPathComponent:@"IconLoader"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_diskCacheDirectory
                                  withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];

        // NSURLSession (ephemeral configuration, persisting no cookies or cache, so nothing is shared with AFNetworking)
        // Raise the concurrent connection count to 16, to load the many icons on a list page faster
        // Following the disk cache thread pool + active request queue of FCL Glide; scrolling a list can mean 20+ icon requests at once
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = kRequestTimeout;
        config.timeoutIntervalForResource = 15.0;
        config.HTTPMaximumConnectionsPerHost = 16;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        // Enable HTTP/2 multiplexing (supported by default on iOS 9+; set explicitly to be sure)
        config.HTTPShouldUsePipelining = YES;
        _session = [NSURLSession sessionWithConfiguration:config];

        // Listen for memory warnings: clear the memory cache
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];

        // Listen for the app entering the background: cancel every in-flight download (so the system does not kill them)
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];

        // Decide whether mirroring is enabled from the preferences by default
        _mirrorEnabled = [self shouldMirrorByDefault];

        NSDebugLog(@"[IconLoader] Initialization complete, disk cache directory: %@, mirror enabled: %@", _diskCacheDirectory, _mirrorEnabled ? @"YES" : @"NO");
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Public interface: loading icons

+ (void)loadIconForImageView:(nullable UIImageView *)imageView
                         URL:(nullable NSString *)url
                 placeholder:(nullable UIImage *)placeholder
                    fallback:(nullable UIImage *)fallback
                   targetSize:(CGSize)targetSize
                      options:(IconLoaderOptions)options
                   completion:(nullable IconLoaderCompletion)completion {
    IconLoader *loader = [self sharedLoader];

    // 1. Cancel the earlier request on this imageView (the cell reuse case)
    if (imageView) {
        [self cancelLoadingForImageView:imageView];
    }

    // 2. Set the placeholder
    if (imageView) {
        if (placeholder) {
            imageView.image = placeholder;
        } else if (!imageView.image) {
            // With no placeholder and no current image, use a transparent background so a stale image does not linger
            imageView.image = nil;
        }
    }

    // 3. Empty URL: call back with nil straight away (so the caller shows the fallback)
    if (!url || url.length == 0) {
        if (fallback && imageView) {
            imageView.image = fallback;
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil);
            });
        }
        return;
    }

    // 4. Apply CDN mirror substitution
    NSString *finalURL = url;
    if (!(options & IconLoaderOptionsNoMirror)) {
        finalURL = [self applyMirrorToURL:url];
    }

    // 5. Compute the cache key
    NSString *cacheKey = [loader cacheKeyForURL:finalURL targetSize:targetSize options:options];

    // 6. Bind the imageView to the cacheKey (used for cancellation)
    if (imageView) {
        objc_setAssociatedObject(imageView, kIconLoaderImageViewKey, cacheKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 7. Try the memory cache first
    UIImage *cached = [loader.memoryCache objectForKey:cacheKey];
    if (cached) {
        if (imageView) {
            imageView.image = cached;
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cached);
            });
        }
        return;
    }

    // 8. Add to the in-flight request dictionary (coalescing identical URLs)
    __weak UIImageView *weakImageView = imageView;
    void (^wrappedCallback)(UIImage * _Nullable) = ^(UIImage * _Nullable image) {
        // Check: after cell reuse the imageView may be bound to a new cacheKey, so an old request must not overwrite the new image
        // (equivalent to Glide not setting the Drawable after clear())
        if (weakImageView) {
            NSString *currentKey = objc_getAssociatedObject(weakImageView, kIconLoaderImageViewKey);
            if (![currentKey isEqualToString:cacheKey]) {
                // This imageView has already started a new request, so the old callback gives up on updating it
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(nil);
                    });
                }
                return;
            }
            if (image) {
                weakImageView.image = image;
            } else if (fallback) {
                weakImageView.image = fallback;
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(image);
            });
        }
    };

    BOOL isNewRequest = [loader addCallback:wrappedCallback forCacheKey:cacheKey];
    if (!isNewRequest) {
        // A request for the same URL is already in flight; the callback has been queued and will be delivered with it
        return;
    }

    // 9. Start the download (on a background thread)
    // Pass in the original (pre-mirror) URL so it can be retried:
    // if the mirror URL fails (HTTP 4xx/5xx, a timeout, a non-image Content-Type, or a decode failure),
    // the original URL is retried once automatically. This is the key fix for icons never loading at all —
    // the MCIM mirror path of BMCLAPI (/mcim/modrinth/) may not serve the static icon assets of cdn.modrinth.com,
    // so every mirrored icon request returns 404/HTML while the original CDN works fine.
    [loader startDownloadForURL:finalURL
                  originalURL:url
                      cacheKey:cacheKey
                     targetSize:targetSize
                        options:options];
}

+ (void)loadIconForImageView:(nullable UIImageView *)imageView
                         URL:(nullable NSString *)url
                 placeholder:(nullable UIImage *)placeholder
                    fallback:(nullable UIImage *)fallback
                   targetSize:(CGSize)targetSize {
    [self loadIconForImageView:imageView
                           URL:url
                   placeholder:placeholder
                      fallback:fallback
                     targetSize:targetSize
                        options:IconLoaderOptionsDefault
                     completion:nil];
}

#pragma mark - Public interface: prefetching

+ (void)prefetchIconWithURL:(NSString *)url targetSize:(CGSize)targetSize {
    if (!url || url.length == 0) return;

    IconLoader *loader = [self sharedLoader];
    NSString *finalURL = [self applyMirrorToURL:url];
    NSString *cacheKey = [loader cacheKeyForURL:finalURL targetSize:targetSize options:IconLoaderOptionsDefault];

    // Memory cache hit: no prefetch needed
    if ([loader.memoryCache objectForKey:cacheKey]) {
        return;
    }

    // Disk cache hit: load it straight into the memory cache
    NSString *diskPath = [loader diskPathForCacheKey:cacheKey];
    if ([[NSFileManager defaultManager] fileExistsAtPath:diskPath]) {
        [loader loadDiskImageToMemoryCacheAtPath:diskPath cacheKey:cacheKey];
        return;
    }

    // The same request is already in flight: no need to prefetch it again
    __block BOOL alreadyInFlight = NO;
    dispatch_sync(loader.syncQueue, ^{
        if (_inFlightRequests[cacheKey]) {
            alreadyInFlight = YES;
        }
    });
    if (alreadyInFlight) return;

    // Start the prefetch request (with an empty callback, so it only fills the cache)
    [loader addCallback:^(UIImage * _Nullable image) {
        // A prefetch does not update the UI; it just relies on the download flow writing to the cache
    } forCacheKey:cacheKey];

    [loader startDownloadForURL:finalURL
                  originalURL:url
                      cacheKey:cacheKey
                     targetSize:targetSize
                        options:IconLoaderOptionsDefault];
}

#pragma mark - Public interface: cancellation

+ (void)cancelLoadingForImageView:(UIImageView *)imageView {
    if (!imageView) return;
    NSString *cacheKey = objc_getAssociatedObject(imageView, kIconLoaderImageViewKey);
    if (!cacheKey) return;
    // Clear the association, so an in-flight callback no longer updates this imageView
    objc_setAssociatedObject(imageView, kIconLoaderImageViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Note: the download task itself is not cancelled, because other imageViews may be waiting on the same URL
    // (equivalent to Glide clear(), which only drops the binding for that ImageView and does not cancel the shared request)
}

+ (void)cancelAllLoadings {
    IconLoader *loader = [self sharedLoader];
    dispatch_sync(loader.syncQueue, ^{
        [_inFlightRequests removeAllObjects];
    });
    // Cancel every NSURLSession task
    [loader.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *dataTasks, NSArray<NSURLSessionUploadTask *> *uploadTasks, NSArray<NSURLSessionDownloadTask *> *downloadTasks) {
        for (NSURLSessionTask *task in dataTasks) {
            [task cancel];
        }
    }];
}

#pragma mark - Public interface: cache management

+ (void)clearMemoryCache {
    IconLoader *loader = [self sharedLoader];
    [loader clearMemoryCacheInternal];
}

+ (void)clearDiskCacheWithCompletion:(nullable dispatch_block_t)completion {
    IconLoader *loader = [self sharedLoader];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error;
        if ([fm fileExistsAtPath:loader.diskCacheDirectory]) {
            [fm removeItemAtPath:loader.diskCacheDirectory error:&error];
            if (error) {
                NSDebugLog(@"[IconLoader] Failed to clear disk cache: %@", error);
            } else {
                // Recreate the empty directory
                [fm createDirectoryAtPath:loader.diskCacheDirectory
                      withIntermediateDirectories:YES
                                      attributes:nil
                                           error:nil];
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    });
}

+ (unsigned long long)diskCacheSize {
    IconLoader *loader = [self sharedLoader];
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long totalSize = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:loader.diskCacheDirectory];
    NSString *fileName;
    while ((fileName = [enumerator nextObject])) {
        NSString *filePath = [loader.diskCacheDirectory stringByAppendingPathComponent:fileName];
        NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
        if (attrs) {
            totalSize += [attrs fileSize];
        }
    }
    return totalSize;
}

+ (NSUInteger)memoryCacheCount {
    IconLoader *loader = [self sharedLoader];
    // NSCache exposes no count property and does not support enumerateKeysAndObjectsUsingBlock: (that is an NSDictionary method).
    // A separate memoryCacheKeys set is used to count the cached entries.
    // Note: NSCache may evict entries silently under memory pressure without notifying us, so memoryCacheKeys can be slightly higher than reality,
    // but this method only feeds a statistic on the settings page and is not on a hot path, so a small overestimate is acceptable.
    __block NSUInteger count = 0;
    dispatch_sync(loader.syncQueue, ^{
        count = loader.memoryCacheKeys.count;
    });
    return count;
}

#pragma mark - Public interface: CDN mirror

+ (void)setMirrorEnabled:(BOOL)enabled {
    IconLoader *loader = [self sharedLoader];
    loader.mirrorEnabled = enabled;
}

+ (NSString *)applyMirrorToURL:(NSString *)url {
    if (!url || url.length == 0) return url;

    // Apply the MCIM mirror first (the mod mirror source setting)
    // The MCIM mirror serves both the API and the CDN icon assets of Modrinth/CurseForge,
    // so enabling it rewrites cdn.modrinth.com / edge.forgecdn.net / media.forgecdn.net
    // to mod.mcimirror.top, speeding up icon loading in mainland China.
    NSString *mcimURL = [MCIMMirror rewriteURL:url];
    if (mcimURL) return mcimURL;

    IconLoader *loader = [self sharedLoader];
    // The preference is read live every time, so switching download source in settings takes effect immediately
    // (it deliberately does not use the cached mirrorEnabled, which could go out of sync after a preference change)
    if (![loader shouldMirrorByDefault]) return url;

    // ⚠️ Key fix: do NOT apply BMCLAPI mirror substitution to icon assets on the Modrinth/CurseForge CDNs.
    //
    // Reason: the MCIM mirror paths of BMCLAPI (/mcim/modrinth/, /mcim/curseforge/) only cache
    // API responses and file downloads, not the project icon assets on the CDN. In testing, every
    // cdn.modrinth.com / edge.forgecdn.net / media.forgecdn.net icon URL
    // returned HTTP 404 (Content-Type: text/plain) through the BMCLAPI mirror.
    //
    // The earlier "mirror 404 -> fall back to the original URL" mechanism did restore loading, but caused two problems:
    //   1. every icon went through twice the work (a BMCLAPI 404 taking ~0.1s + the original URL taking ~2-4s),
    //      doubling how long list icons took and making users feel "the icons will not load".
    //   2. some of the 15 concurrency permits were held by requests that had already 404ed and were about to fall back,
    //      blocking new requests and making icon loading on other tabs even slower.
    //
    // In testing the original CDNs are directly reachable from mainland China:
    //   - cdn.modrinth.com 307-redirects to cdn-alt.modrinth.com and returns image/png|webp
    //   - edge.forgecdn.net / media.forgecdn.net are reachable directly
    // Using the original CDN is therefore the better choice, avoiding the extra cost of a mirror 404 plus a fallback retry.
    //
    // The method is kept (other callers such as prefetchIconWithURL: still use it) but no longer mirrors any CDN
    // icon. If BMCLAPI ever supports CDN icons, mirroring can be restored selectively here.
    return url;
}

/// Decide automatically whether mirroring is enabled, based on the download source preference
+ (void)refreshMirrorEnabledFromPreference {
    IconLoader *loader = [self sharedLoader];
    loader.mirrorEnabled = [loader shouldMirrorByDefault];
}

/// Default rule: mirroring is on for bmclapi / auto (mainland China defaults to BMCLAPI)
/// Handles a nil preference safely (returning NO when the preference system is not initialized, so an early +load call cannot crash)
- (BOOL)shouldMirrorByDefault {
    NSString *source = getPrefObject(@"general.download_source");
    if (!source) return NO;
    if ([source isEqualToString:@"bmclapi"]) return YES;
    if ([source isEqualToString:@"auto"]) return YES;
    // The official sources (mojang/official) do not use mirroring
    return NO;
}

#pragma mark - Internal: cache keys and disk paths

/// Build the cache key: MD5(url + targetSize + options)
- (NSString *)cacheKeyForURL:(NSString *)url targetSize:(CGSize)targetSize options:(IconLoaderOptions)options {
    NSString *keyString = [NSString stringWithFormat:@"%@|%.0fx%.0f|%lu",
                           url,
                           targetSize.width, targetSize.height,
                           (unsigned long)options];
    return [self md5OfString:keyString];
}

/// Disk cache file path
- (NSString *)diskPathForCacheKey:(NSString *)cacheKey {
    return [self.diskCacheDirectory stringByAppendingPathComponent:cacheKey];
}

- (NSString *)md5OfString:(NSString *)string {
    const char *cStr = [string UTF8String];
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), result);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            result[0], result[1], result[2], result[3],
            result[4], result[5], result[6], result[7],
            result[8], result[9], result[10], result[11],
            result[12], result[13], result[14], result[15]];
}

#pragma mark - Internal: in-flight request management (deduplicating identical URLs)

/// Add a callback to the in-flight request dictionary
/// @return YES if this is the first request for that URL (so a download must start), NO if one is already in flight (the callback is merely merged in)
- (BOOL)addCallback:(void(^)(UIImage * _Nullable))callback forCacheKey:(NSString *)cacheKey {
    __block BOOL isNew = NO;
    dispatch_sync(self.syncQueue, ^{
        NSMutableArray *callbacks = _inFlightRequests[cacheKey];
        if (!callbacks) {
            callbacks = [NSMutableArray array];
            _inFlightRequests[cacheKey] = callbacks;
            isNew = YES;
        }
        if (callback) {
            [callbacks addObject:[callback copy]];
        }
    });
    return isNew;
}

/// Remove and return every callback for this cacheKey
- (NSArray<void(^)(UIImage * _Nullable)> *)popCallbacksForCacheKey:(NSString *)cacheKey {
    __block NSArray *result = nil;
    dispatch_sync(self.syncQueue, ^{
        result = [_inFlightRequests[cacheKey] copy];
        [_inFlightRequests removeObjectForKey:cacheKey];
    });
    return result;
}

#pragma mark - Internal: downloading and decoding

- (void)startDownloadForURL:(NSString *)urlString
               originalURL:(NSString *)originalURLString
                   cacheKey:(NSString *)cacheKey
                 targetSize:(CGSize)targetSize
                    options:(IconLoaderOptions)options {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self completeRequestWithCacheKey:cacheKey image:nil];
        return;
    }

    // Check the disk cache first (on a background thread)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *diskPath = [self diskPathForCacheKey:cacheKey];
        if ([[NSFileManager defaultManager] fileExistsAtPath:diskPath]) {
            // Disk cache hit: load it into memory and return
            UIImage *image = [self loadDiskImageToMemoryCacheAtPath:diskPath cacheKey:cacheKey];
            if (image) {
                [self completeRequestWithCacheKey:cacheKey image:image];
                return;
            }
            // The disk cache file is corrupt: delete it and carry on to the network download
            [[NSFileManager defaultManager] removeItemAtPath:diskPath error:nil];
        }

        // Network download (passing the original URL so it can be retried if the mirror fails)
        [self downloadFromURL:url
                originalURLString:originalURLString
                      cacheKey:cacheKey
                     targetSize:targetSize
                        options:options];
    });
}

/// Load an image from disk into the memory cache
- (nullable UIImage *)loadDiskImageToMemoryCacheAtPath:(NSString *)path cacheKey:(NSString *)cacheKey {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return nil;
    UIImage *image = [UIImage imageWithData:data];
    if (image) {
        [self storeInMemoryCache:image forKey:cacheKey];
    }
    return image;
}

- (void)downloadFromURL:(NSURL *)url
       originalURLString:(NSString *)originalURLString
               cacheKey:(NSString *)cacheKey
             targetSize:(CGSize)targetSize
                options:(IconLoaderOptions)options {
    // Semaphore throttling: wait for a free slot (equivalent to the thread pool cap of Glide)
    dispatch_semaphore_wait(self.downloadSemaphore, DISPATCH_TIME_FOREVER);

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            // Defensive: a singleton will never hit this, but the semaphore is still released to avoid a leak
            dispatch_semaphore_signal(weakSelf.downloadSemaphore);
            return;
        }

        // Release the semaphore slot
        dispatch_semaphore_signal(strongSelf.downloadSemaphore);

        // -- HTTP response validation (key fix: stop 404/HTML error pages being treated as image data) --
        //
        // The earlier bug: statusCode and Content-Type were not validated at all,
        // so when the mirror URL returned 404 the error was nil and data was non-empty (an HTML error page),
        // none of the three if checks matched, the HTML went into the decoder,
        // CGImageSourceCreateWithData failed and returned nil, which was swallowed silently,
        // leaving only the fallback puzzle-piece placeholder icon.
        NSInteger statusCode = 0;
        NSString *contentType = nil;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            statusCode = httpResponse.statusCode;
            contentType = httpResponse.allHeaderFields[@"Content-Type"];
        }

        BOOL isNetworkError = (error != nil);
        BOOL isEmptyData = (!data || data.length == 0);
        BOOL isHTTPError = (statusCode >= 400);
        BOOL isNonImageContentType = NO;
        if (contentType && contentType.length > 0) {
            NSString *lowerCT = [contentType lowercaseString];
            // Strict Content-Type validation: only image/* is accepted
            // HTML error pages usually have Content-Type text/html, which must be rejected
            if (![lowerCT hasPrefix:@"image/"]) {
                isNonImageContentType = YES;
            }
        }

        BOOL shouldFallbackToOriginal = NO;

        if (isNetworkError) {
            NSLog(@"[IconLoader] Network error: %@ - %@", url, error.localizedDescription);
            shouldFallbackToOriginal = YES;
        } else if (isEmptyData) {
            NSLog(@"[IconLoader] Response data is empty: %@ (HTTP %ld)", url, (long)statusCode);
            shouldFallbackToOriginal = YES;
        } else if (isHTTPError) {
            NSLog(@"[IconLoader] HTTP error: %@ (status=%ld, Content-Type=%@)", url, (long)statusCode, contentType);
            shouldFallbackToOriginal = YES;
        } else if (isNonImageContentType) {
            NSLog(@"[IconLoader] Content-Type is not image: %@ (Content-Type=%@)", url, contentType);
            shouldFallbackToOriginal = YES;
        }

        // -- Fall back to the original URL when the mirror fails (key fix) --
        //
        // If the current request used a mirror URL (different from the original) and failed,
        // retry once with the original URL. This is the core fix for icons never loading —
        // the MCIM mirror path of BMCLAPI (/mcim/modrinth/) may not serve the static icon assets of cdn.modrinth.com,
        // while the original CDN works fine.
        //
        // Even from mainland China, the small icon assets on cdn.modrinth.com and edge.forgecdn.net
        // are usually reachable (with slightly higher latency but without failing), so falling back to the original URL is safe.
        if (shouldFallbackToOriginal && originalURLString && originalURLString.length > 0) {
            NSString *currentURLString = url.absoluteString;
            // Only fall back when the current URL differs from the original (to avoid retrying forever)
            if (![currentURLString isEqualToString:originalURLString]) {
                NSLog(@"[IconLoader] Falling back to original URL: %@", originalURLString);
                NSURL *originalURL = [NSURL URLWithString:originalURLString];
                if (originalURL) {
                    // Call ourselves recursively, passing nil as originalURLString so it cannot fall back again
                    [strongSelf downloadFromURL:originalURL
                              originalURLString:nil
                                      cacheKey:cacheKey
                                     targetSize:targetSize
                                        options:options];
                    return;
                }
            }
        }

        if (shouldFallbackToOriginal) {
            // Every retry is exhausted, so this is the final failure
            NSLog(@"[IconLoader] Icon loading ultimately failed (all URLs unavailable): %@", url);
            [strongSelf completeRequestWithCacheKey:cacheKey image:nil];
            return;
        }

        // -- Background-thread decoding + downsampling --
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            UIImage *decodedImage = [strongSelf decodeImageData:data
                                                     targetSize:targetSize
                                                        options:options];
            if (decodedImage) {
                // Write to both cache levels
                [strongSelf storeInMemoryCache:decodedImage forKey:cacheKey];

                // Write to the disk cache (unless MemoryCacheOnly was specified)
                if (!(options & IconLoaderOptionsMemoryCacheOnly)) {
                    [strongSelf writeDataToDisk:data cacheKey:cacheKey];
                }
            } else {
                // Decoding failed: the data may be corrupt, or non-image data disguised with an image Content-Type
                // Try falling back to the original URL (if that has not been tried yet)
                NSLog(@"[IconLoader] Image decoding failed, data may be corrupted or not an image: %@ (data.length=%lu)", url, (unsigned long)data.length);
                if (originalURLString && originalURLString.length > 0) {
                    NSString *currentURLString = url.absoluteString;
                    if (![currentURLString isEqualToString:originalURLString]) {
                        NSLog(@"[IconLoader] Decode failure, falling back to original URL: %@", originalURLString);
                        NSURL *originalURL = [NSURL URLWithString:originalURLString];
                        if (originalURL) {
                            [strongSelf downloadFromURL:originalURL
                                      originalURLString:nil
                                              cacheKey:cacheKey
                                             targetSize:targetSize
                                                options:options];
                            return;
                        }
                    }
                }
            }
            [strongSelf completeRequestWithCacheKey:cacheKey image:decodedImage];
        });
    }];
    [task resume];
}

#pragma mark - Internal: downsampled decoding (the equivalent of ZL2 .size(pxSize))

/// Decode the image data, downsampling to the target size
/// Uses CGImageSourceCreateThumbnailAtIndex to decode on demand, so the full-resolution original never has to be loaded into memory
- (nullable UIImage *)decodeImageData:(NSData *)data
                           targetSize:(CGSize)targetSize
                              options:(IconLoaderOptions)options {
    if (!data || data.length == 0) return nil;

    // Skip downsampling: decode the original directly
    if (options & IconLoaderOptionsNoDownsample || CGSizeEqualToSize(targetSize, CGSizeZero)) {
        UIImage *directImage = [UIImage imageWithData:data];
        if (!directImage) {
            NSLog(@"[IconLoader] decodeImageData: UIImage imageWithData: returned nil (data.length=%lu)", (unsigned long)data.length);
        }
        return directImage;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nil);
    if (!source) {
        NSLog(@"[IconLoader] decodeImageData: CGImageSourceCreateWithData failed (data.length=%lu)", (unsigned long)data.length);
        return nil;
    }

    CFIndex imageCount = CGImageSourceGetCount(source);
    if (imageCount == 0) {
        NSLog(@"[IconLoader] decodeImageData: CGImageSourceGetCount returned 0 (data.length=%lu)", (unsigned long)data.length);
        CFRelease(source);
        return nil;
    }

    // Work out the target size (taking the screen scale into account)
    CGFloat scale = [UIScreen mainScreen].scale;
    NSInteger maxPixelSize = MAX(targetSize.width, targetSize.height) * scale;
    // Leave a little headroom so it does not look blurry after scaling (equivalent to the 1.1x tolerance of Coil)
    maxPixelSize = (NSInteger)(maxPixelSize * 1.1);

    NSDictionary *optionsDict = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceShouldCache: @YES,                    // Cache in memory as soon as it is decoded
        (id)kCGImageSourceShouldCacheImmediately: @YES,         // Force immediate decoding (so deferred decoding does not cause hitches)
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,   // Apply the EXIF orientation
        (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize)
    };

    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)optionsDict);
    CFRelease(source);

    if (!thumbnail) {
        // Downsampling failed, so fall back to a plain decode (the data may be fine even though the thumbnail could not be created)
        UIImage *fallbackImage = [UIImage imageWithData:data];
        if (!fallbackImage) {
            NSLog(@"[IconLoader] decodeImageData: both downsampling and direct decode failed (data.length=%lu)", (unsigned long)data.length);
        }
        return fallbackImage;
    }

    UIImage *result = [UIImage imageWithCGImage:thumbnail scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(thumbnail);

    return result;
}

#pragma mark - Internal: dispatching completed requests

- (void)completeRequestWithCacheKey:(NSString *)cacheKey image:(nullable UIImage *)image {
    NSArray<void(^)(UIImage * _Nullable)> *callbacks = [self popCallbacksForCacheKey:cacheKey];
    if (!callbacks || callbacks.count == 0) return;
    for (void(^cb)(UIImage * _Nullable) in callbacks) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(image);
        });
    }
}

#pragma mark - Internal: disk cache writes and LRU eviction

- (void)writeDataToDisk:(NSData *)data cacheKey:(NSString *)cacheKey {
    if (!data || data.length == 0) return;

    NSString *path = [self diskPathForCacheKey:cacheKey];
    [data writeToFile:path atomically:YES];

    // Trigger the LRU cleanup asynchronously (so it is not checked synchronously on every write)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [self trimDiskCacheIfNeeded];
    });
}

/// LRU cleanup: when the total disk cache size exceeds the cap, delete the oldest files by last access time
- (void)trimDiskCacheIfNeeded {
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long totalSize = 0;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:self.diskCacheDirectory];
    NSString *fileName;
    while ((fileName = [enumerator nextObject])) {
        NSString *filePath = [self.diskCacheDirectory stringByAppendingPathComponent:fileName];
        NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
        if (!attrs) continue;
        unsigned long long fileSize = [attrs fileSize];
        NSDate *modDate = attrs[NSFileModificationDate] ?: [NSDate distantPast];
        totalSize += fileSize;
        [entries addObject:@{
            @"path": filePath,
            @"size": @(fileSize),
            @"date": modDate
        }];
    }

    if (totalSize <= kDiskCacheSizeLimit) return;

    // Sort by modification time ascending (oldest first)
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"date"] compare:b[@"date"]];
    }];

    // Delete from the oldest until the total size is under the cap
    unsigned long long targetSize = (unsigned long long)(kDiskCacheSizeLimit * 0.8); // Delete down to 80%
    for (NSDictionary *entry in entries) {
        if (totalSize <= targetSize) break;
        NSString *path = entry[@"path"];
        unsigned long long size = [entry[@"size"] unsignedLongLongValue];
        [fm removeItemAtPath:path error:nil];
        totalSize -= size;
    }
}

#pragma mark - Internal: helpers

- (NSUInteger)costForImage:(UIImage *)image {
    // Estimate the memory footprint: width * height * 4 bytes (RGBA)
    return (NSUInteger)(image.size.width * image.scale * image.size.height * image.scale * 4);
}

/// Store an image in the memory cache and update the key tracking set alongside it
- (void)storeInMemoryCache:(UIImage *)image forKey:(NSString *)cacheKey {
    [self.memoryCache setObject:image
                       forKey:cacheKey
                         cost:[self costForImage:image]];
    dispatch_async(self.syncQueue, ^{
        [self.memoryCacheKeys addObject:cacheKey];
    });
}

/// Clear the memory cache and its key tracking set
- (void)clearMemoryCacheInternal {
    [self.memoryCache removeAllObjects];
    dispatch_async(self.syncQueue, ^{
        [self.memoryCacheKeys removeAllObjects];
    });
}

#pragma mark - Notification handling

- (void)handleMemoryWarning {
    [self clearMemoryCacheInternal];
    NSDebugLog(@"[IconLoader] Memory warning: cleared memory cache");
}

- (void)handleEnterBackground {
    // The app went to the background: cancel every in-flight download (so the system does not kill them)
    [IconLoader cancelAllLoadings];
    NSDebugLog(@"[IconLoader] App entered background: cancelled all ongoing downloads");
}

@end
