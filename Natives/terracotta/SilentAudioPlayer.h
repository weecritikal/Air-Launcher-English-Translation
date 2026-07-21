#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 后台保活：循环播放静音 WAV 让 iOS 给 App 后台运行配额。
 *
 * 用途：Terracotta 联机时 App 可能切到后台（如用户切到 MC），如果没有后台活动，
 * iOS 会很快挂起 App，导致 EasyTier P2P 连接断开。
 *
 * 实现：AVAudioSession category=playback + AVAudioPlayer 循环播放 200ms 静音 WAV。
 * Info.plist 需声明 UIBackgroundModes: audio。
 *
 * 用法：联机会话开始时调 startKeepingAlive，结束时调 stopKeepingAlive。
 * 多次调用 startKeepingAlive 是幂等的（只启动一次）。 */
@interface SilentAudioPlayer : NSObject

+ (instancetype)shared;

/* 开始后台保活（幂等，可多次调用） */
- (void)startKeepingAlive;

/* 停止后台保活（幂等） */
- (void)stopKeepingAlive;

@end

NS_ASSUME_NONNULL_END
