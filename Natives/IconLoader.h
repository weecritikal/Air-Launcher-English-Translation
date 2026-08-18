//
//  IconLoader.h
//  Amethyst
//
//  Unified project icon loader (modelled on the best practices of FCL Glide + ZL2 Coil)
//
//  Design goals:
//    1. Fixes the fact that AFNetworking's UIImageView+AFNetworking only caches in memory, so every icon has to be
//       re-downloaded after an app restart (the root cause of icons loading very slowly on the download page after each cold start).
//    2. Fixes AFNetworking not downsampling icons and decoding them at full resolution, which pushes memory peaks high and
//       makes decoding slow (typical Modrinth/CurseForge project icons are 200~800KB and may be 1024x1024,
//       yet they are only displayed at 56x56 / 72x72).
//    3. Unified placeholder and fallback: following the ShimmerBox + ic_unknown_icon of ZL2, a placeholder
//       SF Symbol is shown while loading and a fallback SF Symbol on failure, so there are never blank squares.
//    4. CDN mirror substitution: following ZL2 MCIMirror, cdn.modrinth.com /
//       edge.forgecdn.net are rewritten to mirror domains reachable from mainland China (BMCLAPI), a big improvement for those users.
//    5. Concurrency cap + same-URL coalescing: following the thread pools and request merging of Glide/Coil, so scrolling a list
//       does not fire dozens of simultaneous requests and cause network congestion and CPU spikes.
//    6. Prefetching: following ZL2 imageLoader.enqueue, prefetchIconWithURL: fetches and stores an icon
//       just before the user scrolls to that cell.
//
//  Benchmark notes (compared side by side with FCL/ZL2):
//    ┌──────────────────┬─────────────────────────┬──────────────────────────┐
//    | Aspect            | FCL (Glide 4.16)        | ZL2 (Coil 3.5)           |
//    ├──────────────────┼─────────────────────────┼──────────────────────────┤
//    | Memory cache      | default LRU + largeHeap | 20MB LRU + weak refs     |
//    | Disk cache        | default 250MB RESULT    | 512MB explicit directory |
//    | Downsampling      | implicit (via ImageView)| explicit .size(pxSize)   |
//    | Async decoding    | Glide default pool      | Dispatchers.IO           |
//    | Prefetching       | none                    | lightweight enqueue      |
//    | Placeholder/fallback | no icon placeholder  | ShimmerBox + fallback    |
//    | CDN mirror        | none (official CDN)     | MCIM mirror substitution |
//    | Concurrency cap   | default (CPU cores)     | default                  |
//    └──────────────────┴─────────────────────────┴──────────────────────────┘
//
//  This implementation combines the strengths of both: explicit downsampling (ZL2) + a two-level cache (ZL2 capacities) + enqueue prefetching (ZL2)
//  + CDN mirror substitution (ZL2) + placeholder/fallback SF Symbols (the project's own SF Symbol set) + a concurrency cap (added here)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Load completion callback (always fired on the main thread)
/// A nil image means loading failed (the caller should show the fallback icon)
typedef void(^IconLoaderCompletion)(UIImage * _Nullable image);

/// Icon loading options (bit flags, so they are easy to extend later)
typedef NS_OPTIONS(NSUInteger, IconLoaderOptions) {
    /// Default behavior: placeholder + fallback + downsampling + CDN mirror substitution + memory and disk cache
    IconLoaderOptionsDefault = 0,
    /// Skip CDN mirror substitution (forcing the original URL, e.g. server icons should not go through the Modrinth mirror)
    IconLoaderOptionsNoMirror = 1 << 0,
    /// Memory cache only (nothing written to disk, e.g. a temporary avatar)
    IconLoaderOptionsMemoryCacheOnly = 1 << 1,
    /// Skip downsampling (decode at full resolution; only for cases that need the original, such as a screenshot detail view)
    IconLoaderOptionsNoDownsample = 1 << 2,
};

@interface IconLoader : NSObject

/// Singleton accessor
+ (instancetype)sharedLoader;

#pragma mark - 核心加载接口

/// Load an icon into the given UIImageView (mirroring the unified interface of ZL2 AssetsIcon)
///
/// @param imageView   Target image view (held weakly to avoid a retain cycle; when nil this only prefetches)
/// @param url         Icon URL (nil or empty just sets the placeholder)
/// @param placeholder Placeholder shown while loading (nil keeps the current imageView image)
/// @param fallback    Fallback shown if loading fails (nil keeps the placeholder)
/// @param targetSize  Target display size (in pixels) used for downsampling; pass CGSizeZero for the original size
/// @param options     Loading options
/// @param completion  Load completion callback (main thread, may be nil)
///
/// This method automatically:
///   1. cancels any earlier request on this imageView (so an old request cannot overwrite a new image after cell reuse)
///   2. sets the placeholder
///   3. shows the image straight away on a memory cache hit
///   4. otherwise starts a background download (coalescing identical URLs), then downsamples, decodes and writes to both cache levels
///   5. shows the fallback on failure
+ (void)loadIconForImageView:(nullable UIImageView *)imageView
                         URL:(nullable NSString *)url
                 placeholder:(nullable UIImage *)placeholder
                    fallback:(nullable UIImage *)fallback
                   targetSize:(CGSize)targetSize
                      options:(IconLoaderOptions)options
                   completion:(nullable IconLoaderCompletion)completion;

/// Convenience interface: load an icon with the default options
+ (void)loadIconForImageView:(nullable UIImageView *)imageView
                         URL:(nullable NSString *)url
                 placeholder:(nullable UIImage *)placeholder
                    fallback:(nullable UIImage *)fallback
                   targetSize:(CGSize)targetSize;

#pragma mark - 预取（参照 ZL2 imageLoader.enqueue）

/// Prefetch an icon into the cache (without binding an imageView; it only downloads, decodes and caches)
/// Used to fetch icons just before they scroll into view, so they hit the cache and appear instantly when the user gets there.
+ (void)prefetchIconWithURL:(NSString *)url targetSize:(CGSize)targetSize;

#pragma mark - 取消

/// Cancel the icon load in flight on the given imageView
/// Call this in cell prepareForReuse or viewController dealloc, so pointless requests do not hold the network
+ (void)cancelLoadingForImageView:(UIImageView *)imageView;

/// Cancel every in-flight request (called when the app goes to the background or on a memory warning)
+ (void)cancelAllLoadings;

#pragma mark - 缓存管理

/// Clear the memory cache (called on a memory warning)
+ (void)clearMemoryCache;

/// Clear the disk cache (called when the user taps "Clear icon cache" in settings)
+ (void)clearDiskCacheWithCompletion:(nullable dispatch_block_t)completion;

/// Current disk cache size in bytes, for display on the settings page
+ (unsigned long long)diskCacheSize;

/// Number of icons currently cached (in memory)
+ (NSUInteger)memoryCacheCount;

#pragma mark - CDN 镜像（参照 ZL2 MCIMirror）

/// Enable or disable CDN mirror substitution (decided automatically from the general.download_source preference by default)
/// When enabled, cdn.modrinth.com / edge.forgecdn.net are rewritten to mirror domains reachable from mainland China
+ (void)setMirrorEnabled:(BOOL)enabled;

/// Apply URL mirror substitution (public, so other networking layers can reuse it)
/// Takes the original URL and returns the rewritten one (returned unchanged when mirroring is off or nothing matches)
+ (NSString *)applyMirrorToURL:(NSString *)url;

@end

NS_ASSUME_NONNULL_END
