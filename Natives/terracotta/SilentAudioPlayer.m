#import "SilentAudioPlayer.h"
#import <AVFoundation/AVFoundation.h>

@implementation SilentAudioPlayer {
    AVAudioPlayer *_player;
    BOOL _active;
}

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
        _player = [self buildSilentPlayer];
    }
    return self;
}

/* 生成 200ms 静音 WAV 数据（44100Hz, 16-bit, mono）。
 * 总字节 = 44(WAV头) + 44100*0.2*2 = 44 + 17640 = 17684 字节。
 * 不依赖外部资源文件，避免打包丢失。 */
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
    uint32_t byteRate = (uint32_t)(sampleRate * 2);  /* sr * channels * bytesPerSample */
    [wav appendBytes:&byteRate length:4];
    uint16_t blockAlign = 2;  /* channels * bytesPerSample */
    [wav appendBytes:&blockAlign length:2];
    uint16_t bitsPerSample = 16;
    [wav appendBytes:&bitsPerSample length:2];
    /* data chunk */
    [wav appendBytes:"data" length:4];
    uint32_t dataLen = (uint32_t)dataSize;
    [wav appendBytes:&dataLen length:4];
    /* 静音数据（全零，NSMutableData 已经 zero-fill） */
    [wav increaseLengthBy:dataSize];

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:wav error:&error];
    if (player == nil) {
        NSLog(@"[SilentAudioPlayer] init failed: %@", error);
        return nil;
    }
    player.numberOfLoops = -1;  /* 无限循环 */
    player.volume = 0.01f;       /* 极低音量（静音 0 会被 iOS 优化掉） */
    return player;
}

- (void)startKeepingAlive {
    @synchronized(self) {
        if (_active) return;
        if (_player == nil) {
            NSLog(@"[SilentAudioPlayer] player unavailable, keeping alive skipped");
            return;
        }

        /* 配置 AudioSession：playback 类别允许后台播放 */
        NSError *error = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback
                       mode:AVAudioSessionModeMoviePlayback
                    options:0
                      error:&error];
        if (error != nil) {
            NSLog(@"[SilentAudioPlayer] setCategory failed: %@", error);
        }
        [session setActive:YES error:&error];
        if (error != nil) {
            NSLog(@"[SilentAudioPlayer] activate session failed: %@", error);
        }

        if (![_player prepareToPlay]) {
            NSLog(@"[SilentAudioPlayer] prepareToPlay failed");
            return;
        }
        if (![_player play]) {
            NSLog(@"[SilentAudioPlayer] play failed");
            return;
        }
        _active = YES;
        NSLog(@"[SilentAudioPlayer] keeping alive started");
    }
}

- (void)stopKeepingAlive {
    @synchronized(self) {
        if (!_active) return;
        [_player stop];
        _active = NO;

        /* 释放 AudioSession，让其他 App（如 MC 自身的 OpenAL）能重新获取 */
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:&error];
        if (error != nil) {
            NSLog(@"[SilentAudioPlayer] deactivate session failed: %@", error);
        }
        NSLog(@"[SilentAudioPlayer] keeping alive stopped");
    }
}

@end
