#import "SilentAudioPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import "utils.h"

/// Background keep-alive audio player implementation
///
/// Design notes (rewritten version):
/// 1. Handles AVAudioSession interruption notifications (incoming calls, alarms, etc.) and resumes playback automatically after the interruption ends
/// 2. Handles AVAudioSession route changes (headphones plugged/unplugged, Bluetooth connected) to keep playback continuous
/// 3. Uses the mixWithOthers option to avoid interrupting music the user is currently playing
/// 4. The silent WAV is generated in memory, with no dependency on external resource files
/// 5. Singleton + NSLock guarantee thread safety
@implementation SilentAudioPlayer {
    AVAudioPlayer *_player;
    BOOL _active;
    NSLock *_lock;
    BOOL _interruptionPaused;  /* Paused by a system interruption, waiting to resume */
}

#pragma mark - Singleton

+ (instancetype)shared {
    static SilentAudioPlayer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SilentAudioPlayer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _player = [self buildSilentPlayer];
        [self registerNotifications];
    }
    return self;
}

#pragma mark - Public API

- (BOOL)isKeepingAlive {
    [_lock lock];
    BOOL active = _active;
    [_lock unlock];
    return active;
}

- (void)startKeepingAlive {
    [_lock lock];
    if (_active) {
        [_lock unlock];
        return;
    }
    if (_player == nil) {
        NSLog(@"[SilentAudioPlayer] player unavailable, keeping alive skipped");
        [_lock unlock];
        return;
    }

    /* Configure the AudioSession:
     * - playback: allows background playback
     * - mixWithOthers: mixes with other apps' audio instead of interrupting the user's music
     * - duckOthers: optional, not used here (ducking lowers other apps' volume and disturbs the user)
     * try/catch is used in case some options are unsupported on devices below iOS 13 */
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionMixWithOthers;
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:options
                        error:&error]) {
        NSLog(@"[SilentAudioPlayer] setCategory failed: %@", error);
        /* Fallback: try again without options (compatibility with some devices below iOS 14) */
        [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    }
    if (![session setActive:YES error:&error]) {
        NSLog(@"[SilentAudioPlayer] activate session failed: %@", error);
        /* Try to play even if activation failed; it still works in some scenarios */
    }

    _player.numberOfLoops = -1;  /* Infinite loop */
    _player.volume = 0.01f;       /* Extremely low volume (0 would be optimized away by iOS) */

    if (![_player prepareToPlay]) {
        NSLog(@"[SilentAudioPlayer] prepareToPlay failed");
        [_lock unlock];
        return;
    }
    if (![_player play]) {
        NSLog(@"[SilentAudioPlayer] play failed");
        [_lock unlock];
        return;
    }
    _active = YES;
    _interruptionPaused = NO;
    [_lock unlock];
    NSLog(@"[SilentAudioPlayer] keeping alive started");
}

- (void)stopKeepingAlive {
    [_lock lock];
    if (!_active) {
        [_lock unlock];
        return;
    }
    [_player stop];
    _active = NO;
    _interruptionPaused = NO;
    [_lock unlock];

    /* Release the AudioSession (done outside the lock to avoid blocking the main thread for too long)
     * NotifyOthersOnDeactivation lets other apps (such as MC's own OpenAL) reacquire the audio device */
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setActive:NO
                                        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                              error:&error]) {
        NSLog(@"[SilentAudioPlayer] deactivate session failed: %@", error);
    }
    NSLog(@"[SilentAudioPlayer] keeping alive stopped");
}

#pragma mark - Silent WAV Generation

/// Generate 200ms of silent WAV data (44100Hz, 16-bit, mono).
/// Total bytes = 44 (WAV header) + 44100*0.2*2 = 44 + 17640 = 17684 bytes.
/// Does not depend on external resource files, avoiding packaging loss.
- (AVAudioPlayer *)buildSilentPlayer {
    NSUInteger sampleRate = 44100;
    NSUInteger durationMs = 200;
    NSUInteger numSamples = (sampleRate * durationMs) / 1000;  /* 8820 samples */
    NSUInteger dataSize = numSamples * 2;  /* 16-bit = 2 bytes/sample */
    NSUInteger fileSize = 36 + dataSize;   /* RIFF chunk size */

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
    /* RIFF header */
    [wav appendBytes:"RIFF" length:4];
    uint32_t riffSize = (uint32_t)fileSize;
    [wav appendBytes:&riffSize length:4];
    [wav appendBytes:"WAVE" length:4];
    /* fmt chunk */
    [wav appendBytes:"fmt " length:4];
    uint32_t fmtSize = 16;
    [wav appendBytes:&fmtSize length:4];
    uint16_t audioFormat = 1;  /* PCM */
    [wav appendBytes:&audioFormat length:2];
    uint16_t numChannels = 1;
    [wav appendBytes:&numChannels length:2];
    uint32_t sr = (uint32_t)sampleRate;
    [wav appendBytes:&sr length:4];
    uint32_t byteRate = (uint32_t)(sampleRate * 2);
    [wav appendBytes:&byteRate length:4];
    uint16_t blockAlign = 2;
    [wav appendBytes:&blockAlign length:2];
    uint16_t bitsPerSample = 16;
    [wav appendBytes:&bitsPerSample length:2];
    /* data chunk */
    [wav appendBytes:"data" length:4];
    uint32_t dataLen = (uint32_t)dataSize;
    [wav appendBytes:&dataLen length:4];
    /* Silent data (all zeros; NSMutableData is already zero-filled) */
    [wav increaseLengthBy:dataSize];

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:wav error:&error];
    if (player == nil) {
        NSLog(@"[SilentAudioPlayer] init failed: %@", error);
        return nil;
    }
    return player;
}

#pragma mark - AVAudioSession Notifications

/// Listen for audio interruption and route change notifications so background keep-alive can recover after system events.
- (void)registerNotifications {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    /* Audio interruptions (incoming calls, alarms, Siri, etc.) */
    [nc addObserver:self
           selector:@selector(handleInterruption:)
               name:AVAudioSessionInterruptionNotification
             object:nil];
    /* Route changes (headphones plugged/unplugged, Bluetooth connected) */
    [nc addObserver:self
           selector:@selector(handleRouteChange:)
               name:AVAudioSessionRouteChangeNotification
             object:nil];
}

- (void)handleInterruption:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    NSUInteger type = [info[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];

    [_lock lock];
    switch (type) {
        case AVAudioSessionInterruptionTypeBegan: {
            /* The system began an interruption (e.g. an incoming call) and audio was forcibly paused */
            if (_active) {
                _interruptionPaused = YES;
                NSLog(@"[SilentAudioPlayer] interruption began");
            }
            break;
        }
        case AVAudioSessionInterruptionTypeEnded: {
            /* Interruption ended, try to resume playback */
            if (_active && _interruptionPaused) {
                NSUInteger options = [info[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
                NSError *error = nil;
                [[AVAudioSession sharedInstance] setActive:YES error:&error];
                if (error != nil) {
                    NSLog(@"[SilentAudioPlayer] resume activate failed: %@", error);
                }
                if (options & AVAudioSessionInterruptionOptionShouldResume) {
                    [_player prepareToPlay];
                    [_player play];
                    NSLog(@"[SilentAudioPlayer] resumed after interruption");
                } else {
                    NSLog(@"[SilentAudioPlayer] interruption ended but should not resume");
                }
                _interruptionPaused = NO;
            }
            break;
        }
    }
    [_lock unlock];
}

- (void)handleRouteChange:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    NSUInteger reason = [info[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];

    [_lock lock];
    /* When an old device disconnects (e.g. headphones unplugged), the system automatically pauses playback; resume here after the new device connects */
    if (reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable
        || reason == AVAudioSessionRouteChangeReasonOverride) {
        if (_active && !_player.playing) {
            [_player prepareToPlay];
            [_player play];
            NSLog(@"[SilentAudioPlayer] resumed after route change (reason=%lu)", (unsigned long)reason);
        }
    }
    [_lock unlock];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
