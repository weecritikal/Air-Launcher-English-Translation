//
//  MurmurHash2.m
//  Amethyst
//
//  MurmurHash2 streaming incremental hash helper (the variant CurseForge uses for file fingerprints)
//  Reference implementation: MurmurHash2Incremental.kt in ZalithLauncher2
//

#import "MurmurHash2.h"

// The MurmurHash2 algorithm constants
static const uint32_t kMurmurHash2_M = 0x5bd1e995u;
static const uint32_t kMurmurHash2_R = 24u;
static const uint32_t kMurmurHash2_Seed = 1u;

// The streaming read buffer size
static const NSUInteger kMurmurHash2_BufferSize = 8192;

// The whitespace bytes CurseForge filters out: 0x09 (tab), 0x0a (LF), 0x0d (CR), 0x20 (space)
static const uint8_t kMurmurHash2_SkipBytes[] = {0x09, 0x0a, 0x0d, 0x20};

/// Whether a byte is one of the whitespace bytes to skip
static inline BOOL MurmurHash2_ShouldSkipByte(uint8_t b) {
    for (size_t i = 0; i < sizeof(kMurmurHash2_SkipBytes); i++) {
        if (b == kMurmurHash2_SkipBytes[i]) {
            return YES;
        }
    }
    return NO;
}

@interface MurmurHash2 ()
/// First pass: compute the total length once the whitespace bytes are filtered out
+ (uint32_t)_filteredLengthOfFile:(NSString *)filePath error:(NSError *_Nullable *_Nullable)error;
/// Second pass: compute the MurmurHash2 hash in a stream
+ (uint32_t)_computeHashOfFile:(NSString *)filePath
                filteredLength:(uint32_t)totalLen
                        error:(NSError *_Nullable *_Nullable)error;
@end

@implementation MurmurHash2

+ (uint32_t)hashOfFile:(NSString *)filePath error:(NSError *_Nullable *_Nullable)error {
    // Parameter check: the path is not empty
    if (filePath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileNoSuchFileError
                                     userInfo:@{NSLocalizedDescriptionKey: @"The file path is empty"}];
        }
        return 0;
    }

    // Check that the file exists and is not a directory
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:filePath isDirectory:&isDirectory] || isDirectory) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileNoSuchFileError
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The file does not exist or is a directory: %@", filePath]}];
        }
        return 0;
    }

    // First pass: compute the filtered total length
    // The initial hash h = seed ^ totalLen needs the filtered total length up front, hence the extra pass
    NSError *lengthError = nil;
    uint32_t totalLen = [self _filteredLengthOfFile:filePath error:&lengthError];
    if (lengthError) {
        if (error) { *error = lengthError; }
        return 0;
    }

    // Second pass: compute the hash in a stream
    NSError *hashError = nil;
    uint32_t hash = [self _computeHashOfFile:filePath filteredLength:totalLen error:&hashError];
    if (hashError) {
        if (error) { *error = hashError; }
        return 0;
    }

    return hash;
}

#pragma mark - 内部辅助方法

+ (uint32_t)_filteredLengthOfFile:(NSString *)filePath error:(NSError *_Nullable *_Nullable)error {
    uint32_t totalLen = 0;
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:filePath];
    if (!stream) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadUnknownError
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not create an input stream"}];
        }
        return 0;
    }

    [stream open];
    if ([stream streamStatus] == NSStreamStatusError) {
        if (error) { *error = [stream streamError]; }
        [stream close];
        return 0;
    }

    uint8_t readBuffer[kMurmurHash2_BufferSize];
    NSInteger bytesRead;
    while ((bytesRead = [stream read:readBuffer maxLength:sizeof(readBuffer)]) > 0) {
        for (NSInteger i = 0; i < bytesRead; i++) {
            if (!MurmurHash2_ShouldSkipByte(readBuffer[i])) {
                totalLen++;
            }
        }
    }

    NSError *streamError = [stream streamError];
    [stream close];

    if (streamError) {
        if (error) { *error = streamError; }
        return 0;
    }

    return totalLen;
}

+ (uint32_t)_computeHashOfFile:(NSString *)filePath
                filteredLength:(uint32_t)totalLen
                        error:(NSError *_Nullable *_Nullable)error {
    // The initial hash: h = seed ^ totalLen
    uint32_t h = kMurmurHash2_Seed ^ totalLen;

    // tail: the buffer for a trailing chunk shorter than 4 bytes; tailLen: how many trailing bytes have accumulated
    uint8_t tail[4];
    uint32_t tailLen = 0;

    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:filePath];
    if (!stream) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadUnknownError
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not create an input stream"}];
        }
        return 0;
    }

    [stream open];
    if ([stream streamStatus] == NSStreamStatusError) {
        if (error) { *error = [stream streamError]; }
        [stream close];
        return 0;
    }

    uint8_t readBuffer[kMurmurHash2_BufferSize];
    NSInteger bytesRead;
    while ((bytesRead = [stream read:readBuffer maxLength:sizeof(readBuffer)]) > 0) {
        for (NSInteger i = 0; i < bytesRead; i++) {
            uint8_t b = readBuffer[i];

            // Skip whitespace bytes
            if (MurmurHash2_ShouldSkipByte(b)) {
                continue;
            }

            // Accumulate into the tail buffer
            tail[tailLen++] = b;

            // Run the MurmurHash2 mix once 4 bytes have accumulated
            if (tailLen == 4) {
                // Assemble them into a 32-bit integer in little-endian order
                uint32_t k = ((uint32_t)tail[0])
                           | ((uint32_t)tail[1] << 8)
                           | ((uint32_t)tail[2] << 16)
                           | ((uint32_t)tail[3] << 24);

                // The MurmurHash2 core mix
                // The & 0xFFFFFFFFu mask makes the uint32_t overflow semantics explicit (equivalent to & 0xFFFFFFFFL in Kotlin)
                k = (k * kMurmurHash2_M) & 0xFFFFFFFFu;
                k ^= (k >> kMurmurHash2_R);
                k = (k * kMurmurHash2_M) & 0xFFFFFFFFu;

                h = (h * kMurmurHash2_M) & 0xFFFFFFFFu;
                h ^= k;

                tailLen = 0;
            }
        }
    }

    NSError *streamError = [stream streamError];
    [stream close];

    if (streamError) {
        if (error) { *error = streamError; }
        return 0;
    }

    // Handle the trailing bytes when fewer than 4 remain (the switch falls through deliberately, matching the Kotlin branches)
    switch (tailLen) {
        case 3:
            h ^= ((uint32_t)tail[2] << 16);
            // fall through
        case 2:
            h ^= ((uint32_t)tail[1] << 8);
            // fall through
        case 1:
            h ^= (uint32_t)tail[0];
            h = (h * kMurmurHash2_M) & 0xFFFFFFFFu;
            break;
        default:
            break;
    }

    // The final mix (finalizer)
    h ^= (h >> 13);
    h = (h * kMurmurHash2_M) & 0xFFFFFFFFu;
    h ^= (h >> 15);

    return h;
}

@end
