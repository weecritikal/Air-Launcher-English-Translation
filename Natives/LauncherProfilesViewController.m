#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherPrefGameDirViewController.h"
#import "LauncherPrefManageJREViewController.h"
#import "ProfileSettingsViewController.h"
#import "LauncherProfilesViewController.h"
#import "PLProfiles.h"
#import "VersionCardCell.h"  // New: import the standalone VersionCardCell
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import "UIKit+AFNetworking.h"
#pragma clang diagnostic pop
#import "UIKit+hook.h"
#import "installer/FabricInstallViewController.h"
#import "installer/ForgeInstallViewController.h"
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "installer/ModpackInstallViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"
#import "BackgroundManager.h"

// Version type
typedef NS_ENUM(NSInteger, VersionType) {
    VersionTypeRelease,
    VersionTypeSnapshot,
    VersionTypeOld,
    VersionTypeAll
};

@interface LauncherProfilesViewController () <UICollectionViewDataSource, UICollectionViewDelegate>
@property(nonatomic) UIBarButtonItem *createButtonItem;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic, strong) UISegmentedControl *filterSegment;
@property(nonatomic, strong) NSArray *versionList;
@property(nonatomic, strong) NSArray *filteredVersions;
@property(nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@end

@implementation LauncherProfilesViewController

- (id)init {
    self = [super init];
    self.title = @"Download";
    return self;
}

- (NSString *)imageName {
    return @"MenuProfiles";
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // Adapt to the custom launcher background: make this view controller transparent so the global background (image/video) shows through.
    // Called after view.backgroundColor is set, so an opaque background color cannot override the transparency.
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // Set up the navigation bar
    [self setupNavigationBar];

    // Set up the filters
    [self setupFilterSegment];

    // Set up the collection view
    [self setupCollectionView];
    // Make sure the collectionView background is transparent so the global background shows through
    // (UICollectionView has no backgroundView property, so clearing backgroundColor is enough)
    self.collectionView.backgroundColor = [UIColor clearColor];

    // Set up the loading indicator
    [self setupLoadingIndicator];

    // Load the version list
    [self loadVersionList];

    // Listen for background UI effect changes: when the user switches between frosted glass and translucent, or adjusts the opacity,
    // call makeViewControllerTransparent again to apply the latest look and keep the background showing correctly.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)setupNavigationBar {
    // Add button
    UIMenu *createMenu = [UIMenu menuWithTitle:@"New" image:nil identifier:nil
    options:UIMenuOptionsDisplayInline
    children:@[
        [UIAction actionWithTitle:@"Vanilla" image:nil identifier:@"vanilla" handler:^(UIAction *action) {
            [self actionCreateVanillaProfile];
        }],
        [UIAction actionWithTitle:@"Fabric/Quilt" image:nil identifier:@"fabric" handler:^(UIAction *action) {
            [self actionCreateFabricProfile];
        }],
        [UIAction actionWithTitle:@"Forge" image:nil identifier:@"forge" handler:^(UIAction *action) {
            [self actionCreateForgeProfile];
        }],
        [UIAction actionWithTitle:@"Modpack" image:nil identifier:@"modpack" handler:^(UIAction *action) {
            [self actionCreateModpackProfile];
        }]
    ]];
    
    self.createButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd menu:createMenu];
    self.navigationItem.rightBarButtonItem = self.createButtonItem;
}

- (void)setupFilterSegment {
    self.filterSegment = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Release", @"Snapshot", @"Ancient"]];
    self.filterSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterSegment.selectedSegmentIndex = 0;
    [self.filterSegment addTarget:self action:@selector(filterChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.filterSegment];
}

- (void)setupCollectionView {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    // Matching DownloadViewController: a single-column list of horizontal rows, 64pt tall
    // (VersionCardCell now uses the FCL/ZL2 horizontal row layout rather than 100x140 grid cards)
    layout.minimumInteritemSpacing = 0;
    layout.minimumLineSpacing = 4;
    layout.itemSize = CGSizeMake(self.view.bounds.size.width - 32, 64);
    layout.sectionInset = UIEdgeInsetsMake(8, 16, 8, 16);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerClass:[VersionCardCell class] forCellWithReuseIdentifier:@"VersionCard"];
    [self.view addSubview:self.collectionView];

    [NSLayoutConstraint activateConstraints:@[
        [self.filterSegment.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.filterSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.filterSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.collectionView.topAnchor constraintEqualToAnchor:self.filterSegment.bottomAnchor constant:8],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

// Update the itemSize width dynamically so it fills the collectionView (minus 16pt of sectionInset on each side).
// Matching viewDidLayoutSubviews in DownloadViewController, so the cell width does not lag behind on rotation.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.collectionView) return;
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
    if (![layout isKindOfClass:[UICollectionViewFlowLayout class]]) return;
    CGFloat horizInset = layout.sectionInset.left + layout.sectionInset.right;
    CGFloat availableWidth = MAX(0, self.collectionView.bounds.size.width - horizInset);
    CGSize target = CGSizeMake(availableWidth, 64);
    if (!CGSizeEqualToSize(layout.itemSize, target)) {
        layout.itemSize = target;
        [layout invalidateLayout];
    }
}

- (void)setupLoadingIndicator {
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    // Pick the download source from the settings
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL;
    
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        versionManifestURL = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        versionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    NSURL *url = [NSURL URLWithString:versionManifestURL];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && !jsonError) {
                    self.versionList = json[@"versions"];
                    [self applyFilter];
                }
            }
        });
    }];
    [task resume];
}

- (void)filterChanged:(UISegmentedControl *)sender {
    [self applyFilter];
}

- (void)applyFilter {
    if (!self.versionList) return;
    
    VersionType filterType = (VersionType)self.filterSegment.selectedSegmentIndex;
    
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *version in self.versionList) {
        NSString *type = version[@"type"];
        
        switch (filterType) {
            case VersionTypeAll:
                [filtered addObject:version];
                break;
            case VersionTypeRelease:
                if ([type isEqualToString:@"release"]) {
                    [filtered addObject:version];
                }
                break;
            case VersionTypeSnapshot:
                if ([type isEqualToString:@"snapshot"]) {
                    [filtered addObject:version];
                }
                break;
            case VersionTypeOld:
                if ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"]) {
                    [filtered addObject:version];
                }
                break;
        }
    }
    
    self.filteredVersions = filtered;
    [self.collectionView reloadData];
}

#pragma mark - UICollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCard" forIndexPath:indexPath];
    
    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *versionId = version[@"id"];
    NSString *releaseTime = version[@"releaseTime"];
    NSString *versionType = version[@"type"];
    
    // Format the date
    NSString *formattedDate = [self formatDate:releaseTime];
    
    // Use the new configuration method
    [cell configureWithVersionId:versionId date:formattedDate type:versionType];
    
    return cell;
}

- (NSString *)formatDate:(NSString *)dateString {
    // Simplified date display
    if (dateString.length >= 10) {
        return [dateString substringToIndex:10];
    }
    return dateString;
}

#pragma mark - UICollectionView Delegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *versionId = version[@"id"];
    
    // Show the confirmation dialog
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:versionId
                                                                   message:@"Choose an action"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Download this version"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self downloadVersion:version];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    // iPad support
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        VersionCardCell *cell = (VersionCardCell *)[collectionView cellForItemAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)downloadVersion:(NSDictionary *)version {
    NSString *versionId = version[@"id"];
    
    // Create the new profile
    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"name"] = versionId;
    profile[@"lastVersionId"] = versionId;
    profile[@"type"] = @"custom";
    profile[@"created"] = [NSDate date].description;
    
    // Save the profile
    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;
    
    // Show the download progress
    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"Downloading"
                                                                           message:[NSString stringWithFormat:@"Downloading %@...", versionId]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progressAlert animated:YES completion:nil];
    
    // Simulate the download completing
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [progressAlert dismissViewControllerAnimated:YES completion:^{
            UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"Download complete"
                                                                                  message:[NSString stringWithFormat:@"%@ download complete", versionId]
                                                                           preferredStyle:UIAlertControllerStyleAlert];
            [successAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:successAlert animated:YES completion:nil];
        }];
    });
}

#pragma mark - Actions

- (void)actionCreateVanillaProfile {
    // Create the vanilla profile
    [self showVersionSelectorForType:@"vanilla"];
}

- (void)actionCreateFabricProfile {
    FabricInstallViewController *vc = [FabricInstallViewController new];
    [self presentNavigatedViewController:vc];
}

- (void)actionCreateForgeProfile {
    ForgeInstallViewController *vc = [ForgeInstallViewController new];
    __weak typeof(self) weakSelf = self;
    vc.completionHandler = ^(BOOL success, NSString *profileName, id resultOrError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // User cancelled: stay silent for ForgeInstallerFlowErrorDomain/Cancelled
        if (!success) {
            if ([resultOrError isKindOfClass:[NSError class]]) {
                NSError *err = (NSError *)resultOrError;
                if ([err.domain isEqualToString:ForgeInstallerFlowErrorDomain] && err.code == ForgeInstallerFlowErrorCodeCancelled) {
                    return;
                }
                showDialog(localize(@"Error", nil), err.localizedDescription);
            }
            return;
        }

        // Parse the result packed by ForgeInstallVC
        NSInteger selectedScheme = 0;
        NSString *filePath = nil;
        if ([resultOrError isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = (NSDictionary *)resultOrError;
            filePath = result[@"filePath"];
            selectedScheme = [result[@"selectedScheme"] integerValue];
        } else if ([resultOrError isKindOfClass:[NSString class]]) {
            filePath = (NSString *)resultOrError;
        }

        BOOL isNeoForge = vc.isNeoForge;

        if (selectedScheme == 1 && filePath.length > 0) {
            // Direct install: pure file operations, with no dependency on LauncherNavigationController
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSError *directError = nil;
                BOOL installed = NO;
                if (isNeoForge) {
                    installed = [NeoForgeDirectInstaller installNeoForgeFromInstaller:filePath versionId:profileName error:&directError];
                } else {
                    installed = [ForgeDirectInstaller installForgeFromInstaller:filePath versionId:profileName error:&directError];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (installed) {
                        showDialog(localize(@"Success", nil), [NSString stringWithFormat:@"%@ installed successfully", isNeoForge ? @"NeoForge" : @"Forge"]);
                    } else {
                        showDialog(localize(@"Error", nil), directError.localizedDescription ?: @"Unknown error");
                    }
                });
            });
            return;
        }

        // Vanilla method: walk down from keyWindow.rootViewController to find LauncherNavigationController and start the AWT installer
        LauncherNavigationController *launcherNav = [strongSelf findLauncherNavigationController];
        if (launcherNav && filePath.length > 0) {
            [launcherNav enterModInstallerWithPath:filePath hitEnterAfterWindowShown:YES];
            showDialog(localize(@"Info", nil), [NSString stringWithFormat:@"%@ installer started", isNeoForge ? @"NeoForge" : @"Forge"]);
        } else if (filePath.length > 0) {
            showDialog(localize(@"Error", nil), @"Could not start the installer: the main launcher navigation controller was not found");
        }
    };
    [self presentNavigatedViewController:vc];
}

// Recursively find LauncherNavigationController from keyWindow.rootViewController
- (LauncherNavigationController *)findLauncherNavigationController {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [[UIApplication sharedApplication] windows].firstObject;
    }
    UIViewController *rootVC = keyWindow.rootViewController;
    return [self findLauncherNavIn:rootVC];
}

- (LauncherNavigationController *)findLauncherNavIn:(UIViewController *)vc {
    if (!vc) return nil;
    if ([vc isKindOfClass:[LauncherNavigationController class]]) {
        return (LauncherNavigationController *)vc;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavIn:child];
            if (found) return found;
        }
    }
    if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *child in ((UISplitViewController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavIn:child];
            if (found) return found;
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in ((UITabBarController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavIn:child];
            if (found) return found;
        }
    }
    if (vc.presentedViewController) {
        LauncherNavigationController *found = [self findLauncherNavIn:vc.presentedViewController];
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        LauncherNavigationController *found = [self findLauncherNavIn:child];
        if (found) return found;
    }
    return nil;
}

- (void)actionCreateModpackProfile {
    ModpackInstallViewController *vc = [ModpackInstallViewController new];
    [self presentNavigatedViewController:vc];
}

- (void)showVersionSelectorForType:(NSString *)type {
    // Show the version picker
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select version"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Latest release"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self createProfileWithVersion:@"latest-release" type:type];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Latest snapshot"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self createProfileWithVersion:@"latest-snapshot" type:type];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createProfileWithVersion:(NSString *)versionId type:(NSString *)type {
    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"name"] = versionId;
    profile[@"lastVersionId"] = versionId;
    profile[@"type"] = type;
    
    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Created"
                                                                   message:[NSString stringWithFormat:@"Created the %@ profile", versionId]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentNavigatedViewController:(UIViewController *)vc {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

/// Re-apply the background effect: called when the BackgroundUIEffectChanged notification arrives.
/// Re-applies the opacity/frosted-glass effect to this view controller via BackgroundManager,
/// and set the collectionView background to transparent, so the global background shows through.
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.collectionView.backgroundColor = [UIColor clearColor];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
