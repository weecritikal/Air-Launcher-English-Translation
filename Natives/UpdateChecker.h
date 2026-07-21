#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 更新信息数据模型
@interface UpdateInfo : NSObject
@property(nonatomic, copy, nullable) NSString *latestVersion;    /* 最新版本号（去掉 v 前缀） */
@property(nonatomic, copy, nullable) NSString *currentVersion;   /* 当前 App 版本号 */
@property(nonatomic, assign) BOOL hasUpdate;                     /* 是否有新版本 */
@property(nonatomic, copy, nullable) NSString *releaseName;      /* release 标题 */
@property(nonatomic, copy, nullable) NSString *releaseNotes;     /* 更新日志（markdown） */
@property(nonatomic, copy, nullable) NSString *htmlURL;          /* release 页面链接 */
@property(nonatomic, copy, nullable) NSString *publishedAt;      /* 发布时间（ISO8601） */
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *assets; /* 下载资源列表 */
@end

/// 更新检查器（参考 FCL/ZL2，使用 GitHub Releases API）
///
/// 正式版检查：访问 /releases/latest 接口，GitHub 自动返回最新的非 pre-release。
/// 项目地址：https://github.com/herbrine8403/Amethyst-iOS-MyRemastered
@interface UpdateChecker : NSObject

/// 仓库所有者
@property(nonatomic, class, readonly) NSString *repoOwner;
/// 仓库名称
@property(nonatomic, class, readonly) NSString *repoName;
/// 正式版 releases API URL
@property(nonatomic, class, readonly) NSString *latestReleaseURL;

/// 检查更新（正式版）。网络请求在后台线程，回调在主线程。
/// @param completion 回调，info 为 nil 表示请求失败（error 不为 nil）或解析失败
+ (void)checkForUpdateWithCompletion:(void(^)(UpdateInfo *_Nullable info, NSError *_Nullable error))completion;

/// 打开 release 页面（跳转 Safari）
+ (void)openReleasePage;

/// 版本比较：v1 < v2 返回 NSOrderedAscending
+ (NSComparisonResult)compareVersion:(NSString *)v1 withVersion:(NSString *)v2;

/// 获取当前 App 版本号（CFBundleShortVersionString）
+ (NSString *)currentVersion;

@end

NS_ASSUME_NONNULL_END
