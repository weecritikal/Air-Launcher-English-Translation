#import "AFNetworking.h"
#import "FabricInstallViewController.h"
#import "FabricUtils.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherProfileEditorViewController.h"
#import "PickTextField.h"
#import "PLProfiles.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <objc/runtime.h>

@interface FabricInstallViewController()
@property(nonatomic) NSDictionary *endpoints;
@property(nonatomic) NSMutableDictionary *localKVO;
// Loader metadata
@property(nonatomic) NSArray<NSDictionary *> *loaderMetadata;
@property(nonatomic) NSMutableArray<NSString *> *loaderList;
// Game metadata
@property(nonatomic) NSArray<NSDictionary *> *versionMetadata;
@property(nonatomic) NSMutableArray<NSString *> *versionList;
// Installation state
@property(nonatomic, assign) BOOL isInstalling;
@property(nonatomic, copy) NSString *installedProfileName;
@end

@implementation FabricInstallViewController

- (void)viewDidLoad {
    // Setup navigation bar
    self.title = localize(@"profile.title.install_fabric_quilt", nil);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone:)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];

    // Setup appearance
    self.prefSectionsVisible = YES;

    // Setup preference getter and setter
    __weak __typeof(self) weakSelf = self;
    
    // Use preset gameVersion if provided (from DownloadViewController)
    NSString *initialGameVersion = self.gameVersion ?: @"1.20.1";
    
    self.localKVO = @{
        @"gameVersion": initialGameVersion,
        @"loaderVendor": @"Fabric",
        @"loaderVersion": @"0.14.22"
    }.mutableCopy;
    self.getPreference = ^id(NSString *section, NSString *key){
        return weakSelf.localKVO[key];
    };
    self.setPreference = ^(NSString *section, NSString *key, NSString *value){
        weakSelf.localKVO[key] = value;
    };

    id typePickSegment = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        UISegmentedControl *view = [[UISegmentedControl alloc] initWithItems:item[@"pickList"]];
        [view addTarget:weakSelf action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
        if (view.selectedSegmentIndex == UISegmentedControlNoSegment) {
            view.selectedSegmentIndex = 0;
        }
        cell.accessoryView = view;
    };

    self.versionList = [NSMutableArray new];
    self.loaderList = [NSMutableArray new];
    self.prefContents = @[
        @[
            @{@"key": @"gameType",
              @"icon": @"ladybug",
              @"title": @"preference.profile.title.version_type",
              @"type": typePickSegment,
              @"pickList": @[localize(@"Release", nil), localize(@"Snapshot", nil)],
              @"action": ^(int type) {
                  [weakSelf changeVersionTypeTo:type];
              }
            },
            @{@"key": @"gameVersion",
              @"icon": @"archivebox",
              @"title": @"preference.profile.title.version",
              @"type": self.typePickField,
              @"pickKeys": self.versionList,
              @"pickList": self.versionList
            },
            @{@"key": @"loaderVendor",
              @"icon": @"folder.badge.gearshape",
              @"title": @"preference.profile.title.loader_vendor",
              @"type": typePickSegment,
              @"pickList": @[@"Fabric", @"Quilt"],
              @"action": ^(int vendor){
                  [weakSelf fetchVersionEndpoints:vendor];
              }
            },
            @{@"key": @"loaderType",
              @"icon": @"ladybug",
              @"title": @"preference.profile.title.loader_type",
              @"type": typePickSegment,
              @"pickList": @[localize(@"Release", nil), @"Unstable"],
              //localize(@"Unstable", nil)
              @"action": ^(int type) {
                  [weakSelf changeLoaderTypeTo:type];
              }
            },
            @{@"key": @"loaderVersion",
              @"icon": @"doc.badge.gearshape",
              @"title": @"preference.profile.title.loader_version",
              @"type": self.typePickField,
              @"pickKeys": self.loaderList,
              @"pickList": self.loaderList
            }
        ]
    ];

    // Ensure views are loaded here
    [super viewDidLoad];

    // Init endpoint info
    self.endpoints = FabricUtils.endpoints;
    [self fetchVersionEndpoints:0];
}

- (void)fetchVersionEndpoints:(int)type {
    // Fetch version
    __block BOOL errorShown = NO;
    id errorCallback = ^(NSURLSessionTask *operation, NSError *error) {
        if (!errorShown) {
            errorShown = YES;
            NSDebugLog(@"Error: %@", error);
            showDialog(localize(@"Error", nil), error.localizedDescription);
            [self actionClose];
        }
    };
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    NSDictionary *endpoint = self.endpoints[self.localKVO[@"loaderVendor"]];
    [manager GET:endpoint[@"game"] parameters:nil headers:nil progress:nil  success:^(NSURLSessionTask *task, NSArray *response) {
        NSDebugLog(@"[%@ Installer] Got %d game versions", self.localKVO[@"loaderVendor"], response.count);
        self.versionMetadata = response;
        [self changeVersionTypeTo:[self.localKVO[@"gameType_index"] intValue]];
    } failure:errorCallback];
    [manager GET:endpoint[@"loader"] parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSArray *response) {
        NSDebugLog(@"[%@ Installer] Got %d loader versions", self.localKVO[@"loaderVendor"], response.count);
        self.loaderMetadata = response;
        [self changeLoaderTypeTo:[self.localKVO[@"loaderType_index"] intValue]];
    } failure:errorCallback];
}

- (void)actionClose {
    // If there's a completion handler, call it with cancelled status
    if (self.completionHandler) {
        self.completionHandler(NO, nil, nil);
    }
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionDone:(UIBarButtonItem *)sender {
    if (self.isInstalling) return;
    self.isInstalling = YES;
    sender.enabled = NO;

    NSDictionary *endpoint = self.endpoints[self.localKVO[@"loaderVendor"]];
    NSString *path = [NSString stringWithFormat:endpoint[@"json"], self.localKVO[@"gameVersion"], self.localKVO[@"loaderVersion"]];
    NSDebugLog(@"[%@ Installer] Downloading %@", self.localKVO[@"loaderVendor"], path);

    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    __weak typeof(self) weakSelf = self;
    [manager GET:path parameters:nil headers:nil progress:nil  success:^(NSURLSessionTask *task, NSDictionary *response) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        strongSelf.isInstalling = NO;
        sender.enabled = YES;

        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), response[@"id"]];
        [NSFileManager.defaultManager createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *error = saveJSONToFile(response, jsonPath);
        if (error) {
            showDialog(localize(@"Error", nil), error.localizedDescription);
            if (strongSelf.completionHandler) {
                strongSelf.completionHandler(NO, nil, error);
            }
            return;
        }
        
        [localVersionList addObject:@{
            @"id": response[@"id"],
            @"type": @"custom"}];
        
        strongSelf.installedProfileName = response[@"id"];
        
        // If Fabric API installation is requested
        if (strongSelf.shouldInstallAPI && [strongSelf.localKVO[@"loaderVendor"] isEqualToString:@"Fabric"]) {
            [strongSelf installFabricAPIWithCompletion:^(BOOL success, NSError *apiError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf handleInstallationComplete:response[@"id"] endpoint:endpoint error:apiError];
                });
            }];
        } else {
            [strongSelf handleInstallationComplete:response[@"id"] endpoint:endpoint error:nil];
        }
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.isInstalling = NO;
            sender.enabled = YES;
        }
        NSDebugLog(@"Error: %@", error);
        showDialog(localize(@"Error", nil), error.localizedDescription);
        if (strongSelf.completionHandler) {
            strongSelf.completionHandler(NO, nil, error);
        }
    }];
}

- (void)handleInstallationComplete:(NSString *)profileId endpoint:(NSDictionary *)endpoint error:(NSError *)error {
    if (error) {
        if (self.completionHandler) {
            self.completionHandler(NO, nil, error);
        }
        return;
    }
    
    if (self.completionHandler) {
        // New mode: callback to caller (DownloadViewController)
        self.completionHandler(YES, profileId, nil);
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    } else {
        // Legacy mode: jump to profile editor
        LauncherProfileEditorViewController *vc = [LauncherProfileEditorViewController new];
        vc.profile = @{
            @"icon": endpoint[@"icon"],
            @"name": profileId,
            @"lastVersionId": profileId
        }.mutableCopy;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)installFabricAPIWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    NSString *gameVersion = self.localKVO[@"gameVersion"];
    NSString *fabricVersion = self.localKVO[@"loaderVersion"];
    
    // Fabric API download URL from Modrinth
    NSString *apiUrl = [NSString stringWithFormat:@"https://api.modrinth.com/v2/project/fabric-api/version?game_versions=[\"%@\"]&loaders=[\"fabric\"]", gameVersion];
    
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:apiUrl parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSArray *response) {
        if (response.count == 0) {
            NSDebugLog(@"[Fabric Installer] No Fabric API version found for game version %@", gameVersion);
            if (completion) completion(YES, nil); // Not an error, just no API available
            return;
        }
        
        // Get the latest version
        NSDictionary *latestVersion = response.firstObject;
        NSArray *files = latestVersion[@"files"];
        NSDictionary *primaryFile = nil;
        for (NSDictionary *file in files) {
            if ([file[@"primary"] boolValue]) {
                primaryFile = file;
                break;
            }
        }
        
        if (!primaryFile) {
            primaryFile = files.firstObject;
        }
        
        NSString *downloadUrl = primaryFile[@"url"];
        NSString *fileName = primaryFile[@"filename"];
        NSString *modsPath = [NSString stringWithFormat:@"%1$s/mods", getenv("POJAV_GAME_DIR")];
        
        // Ensure mods directory exists
        [[NSFileManager defaultManager] createDirectoryAtPath:modsPath withIntermediateDirectories:YES attributes:nil error:nil];
        
        NSURL *url = [NSURL URLWithString:downloadUrl];
        NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                NSDebugLog(@"[Fabric Installer] Failed to download Fabric API: %@", error);
                if (completion) completion(NO, error);
                return;
            }
            
            NSString *destPath = [modsPath stringByAppendingPathComponent:fileName];
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destPath] error:nil];
            NSDebugLog(@"[Fabric Installer] Fabric API installed: %@", destPath);
            if (completion) completion(YES, nil);
        }];
        
        [downloadTask resume];
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        NSDebugLog(@"[Fabric Installer] Failed to fetch Fabric API versions: %@", error);
        // Not a critical error, continue with installation
        if (completion) completion(YES, nil);
    }];
}

- (void)changeTypeToStable:(BOOL)stable forList:(NSMutableArray *)list fromMetadata:(NSArray *)metadata atRow:(int)row key:(NSString *)key {
    [list removeAllObjects];

    for (NSDictionary *version in metadata) {
        if (version[@"stable"]) {
            // Fabric: has stable key
            if ([version[@"stable"] boolValue] != stable) continue;
        } else {
            // Quilt: has beta in the version name
            if ([version[@"version"] containsString:@"beta"] == stable) continue;
        }
        [list addObject:version[@"version"]];
    }
    self.localKVO[key] = list.firstObject;
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)changeLoaderTypeTo:(int)type {
    [self changeTypeToStable:type==0 forList:self.loaderList fromMetadata:self.loaderMetadata atRow:4 key:@"loaderVersion"];
}
- (void)changeVersionTypeTo:(int)type {
    [self changeTypeToStable:type==0 forList:self.versionList fromMetadata:self.versionMetadata atRow:1 key:@"gameVersion"];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, @"item");
    self.localKVO[item[@"key"]] = [sender titleForSegmentAtIndex:sender.selectedSegmentIndex];
    self.localKVO[[item[@"key"] stringByAppendingString:@"_index"]] = @(sender.selectedSegmentIndex);
    void(^invokeAction)(int selected) = item[@"action"];
    if (invokeAction) {
        invokeAction(sender.selectedSegmentIndex);
    }
}

@end
