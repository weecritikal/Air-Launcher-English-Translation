#import <UIKit/UIKit.h>

NSMutableArray<NSDictionary *> *localVersionList, *remoteVersionList;

@class MinecraftResourceDownloadTask;

@interface LauncherNavigationController : UINavigationController

@property(nonatomic) UIProgressView *progressViewMain, *progressViewSub;
@property(nonatomic) UILabel* progressText;
@property(nonatomic) UIButton* buttonInstall;

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter;
- (void)enterModpackImporter;
- (void)fetchLocalVersionList;
- (void)setInteractionEnabled:(BOOL)enable forDownloading:(BOOL)downloading;
- (void)showDownloadProgress:(MinecraftResourceDownloadTask *)downloader;

@end
