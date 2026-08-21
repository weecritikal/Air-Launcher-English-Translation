//
//  MurmurHash2.h
//  Flux
//
//  MurmurHash2 streaming incremental hash helper (the variant CurseForge uses for file fingerprints)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// MurmurHash2 streaming incremental hash helper
/// Used for CurseForge file fingerprint lookups, filtering out the four whitespace bytes 0x09/0x0a/0x0d/0x20
@interface MurmurHash2 : NSObject

/// Compute the MurmurHash2 fingerprint of a file (the CurseForge format)
/// @param filePath The file path
/// @param error Error output
/// @return The unsigned 32-bit hash, or 0 with error set on failure
+ (uint32_t)hashOfFile:(NSString *)filePath error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
