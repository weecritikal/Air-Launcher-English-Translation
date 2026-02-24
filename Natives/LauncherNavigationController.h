#import <UIKit/UIKit.h>

NSMutableArray<NSDictionary *> *localVersionList, *remoteVersionList;

@interface LauncherNavigationController : UINavigationController

@property(nonatomic) UIProgressView *progressViewMain, *progressViewSub;
@property(nonatomic) UILabel* progressText;
@property(nonatomic) UIButton* buttonInstall;

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter;

- (void)fetchLocalVersionList;
- (void)fetchRemoteVersionListForce:(BOOL)force;
- (void)setInteractionEnabled:(BOOL)enable forDownloading:(BOOL)downloading;

// 版本列表缓存相关
+ (BOOL)isVersionListCacheValid;
+ (void)invalidateVersionListCache;
+ (NSArray *)getCachedVersionList;

@end
