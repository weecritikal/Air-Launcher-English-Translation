#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Background keep-alive audio player
///
/// By looping an extremely quiet silent WAV, iOS is made to believe the app is playing audio,
/// which allows the app to keep running in the background for a long time (used to maintain the EasyTier P2P connection during Terracotta multiplayer).
///
/// Uses the AVAudioSession playback category, which mixes with other apps' audio (mixWithOthers),
/// so it does not interfere with the user listening to music. When multiplayer ends, stopKeepingAlive releases the AudioSession
/// so that MC's OpenAL can acquire the audio device normally.
///
/// Thread safety: all methods lock internally and may be called from any thread.
@interface SilentAudioPlayer : NSObject

+ (instancetype)shared;

/// Start background keep-alive. Idempotent, safe to call repeatedly.
- (void)startKeepingAlive;

/// Stop background keep-alive and release the AudioSession. Idempotent.
- (void)stopKeepingAlive;

/// Whether keep-alive is currently active.
@property(nonatomic, readonly, getter=isKeepingAlive) BOOL keepingAlive;

@end

NS_ASSUME_NONNULL_END
