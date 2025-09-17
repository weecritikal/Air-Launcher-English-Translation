#import "AFNetworking.h"
#import "ForgeInstallViewController.h"
#import "LauncherNavigationController.h"
#import "WFWorkflowProgressView.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>

@interface ForgeInstallViewController()<NSXMLParserDelegate>
@property(atomic) AFURLSessionManager *afManager;
@property(nonatomic) WFWorkflowProgressView *progressView;

@property(nonatomic) NSDictionary *endpoints;
@property(nonatomic) NSMutableArray<NSNumber *> *visibilityList;
@property(nonatomic) NSMutableArray<NSString *> *versionList;
@property(nonatomic) NSMutableArray<NSMutableArray *> *forgeList;
@property(nonatomic, assign) BOOL isVersionElement;
@end

@implementation ForgeInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"Forge", @"NeoForge"]];
    segment.selectedSegmentIndex = 0;
    [segment addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = segment;

    // Load WFWorkflowProgressView
    dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL);
    self.progressView = [[NSClassFromString(@"WFWorkflowProgressView") alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    self.progressView.resolvedTintColor = self.view.tintColor;
    [self.progressView addTarget:self
        action:@selector(actionCancelDownload) forControlEvents:UIControlEventTouchUpInside];

    self.endpoints = @{
        @"Forge": @{
            @"installer": @"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar",
            @"metadata": @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
        },
        @"NeoForge": @{
            @"installer": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar",
            @"metadata": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
        }
    };
    self.visibilityList = [NSMutableArray new];
    self.versionList = [NSMutableArray new];
    self.forgeList = [NSMutableArray new];
    [self loadMetadataFromVendor:@"Forge"];
}

- (void)actionCancelDownload {
    [self.afManager invalidateSessionCancelingTasks:YES resetSession:NO];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)loadMetadataFromVendor:(NSString *)vendor {
    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *url = [[NSURL alloc] initWithString:self.endpoints[vendor][@"metadata"]];
        NSXMLParser *parser = [[NSXMLParser alloc] initWithContentsOfURL:url];
        parser.delegate = self;
        if (![parser parse]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                showDialog(localize(@"Error", nil), parser.parserError.localizedDescription);
                [self actionClose];
            });
        }
    });
}

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    [indicator startAnimating];
    self.navigationController.modalInPresentation = YES;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
}

- (void)segmentChanged:(UISegmentedControl *)segment {
    [self.visibilityList removeAllObjects];
    [self.versionList removeAllObjects];
    [self.forgeList removeAllObjects];
    [self.tableView reloadData];
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    [self loadMetadataFromVendor:vendor];
}

#pragma mark UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.versionList.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UITableViewHeaderFooterView *view = [self.tableView dequeueReusableHeaderFooterViewWithIdentifier:@"section"];
    if (!view) {
        view = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:@"section"];
        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tableViewDidSelectSection:)];
        [view addGestureRecognizer:tapGesture];
    }
    return view;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.versionList[section];
}

- (void)tableViewDidSelectSection:(UITapGestureRecognizer *)sender {
    UITableViewHeaderFooterView *view = (id)sender.view;
    int section = [self.versionList indexOfObject:view.textLabel.text];
    self.visibilityList[section] = @(!self.visibilityList[section].boolValue);
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibilityList[section].boolValue ? self.forgeList[section].count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cell"];
    }

    UISegmentedControl *segment = (id)self.navigationItem.titleView;
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    NSString *rawVersion = self.forgeList[indexPath.section][indexPath.row];
    if ([vendor isEqualToString:@"NeoForge"]) {
        NSString *cleanVersion = [rawVersion stringByReplacingOccurrencesOfString:@"-beta" withString:@""];
        NSArray *components = [cleanVersion componentsSeparatedByString:@"."];
        if (components.count >= 2) {
            NSString *major = components[0];
            NSString *minor = components[1];
            NSString *gameVersion = [NSString stringWithFormat:@"1.%@.%@", major, minor];
            cell.textLabel.text = [NSString stringWithFormat:@"%@-%@", gameVersion, rawVersion];
        } else {
            cell.textLabel.text = rawVersion;
        }
    } else {
        cell.textLabel.text = rawVersion;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    tableView.allowsSelection = NO;

    [self switchToLoadingState];
    self.progressView.fractionCompleted = 0;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    cell.accessoryView = self.progressView;

    UISegmentedControl *segment = (id)self.navigationItem.titleView;
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    NSString *selectedRawVersion = self.forgeList[indexPath.section][indexPath.row];
    NSString *jarURL = [NSString stringWithFormat:self.endpoints[vendor][@"installer"], selectedRawVersion];
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tmp.jar"];
    NSDebugLog(@"[Forge Installer] Downloading %@", jarURL);

    self.afManager = [AFURLSessionManager new];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:jarURL]];
    NSURLSessionDownloadTask *downloadTask = [self.afManager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull progress){
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressView.fractionCompleted = progress.fractionCompleted;
        });
    } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
        return [NSURL fileURLWithPath:outPath];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            tableView.allowsSelection = YES;
            cell.accessoryView = nil;
            if (error) {
                if (error.code != NSURLErrorCancelled) {
                    NSDebugLog(@"Error: %@", error);
                    showDialog(localize(@"Error", nil), error.localizedDescription);
                }
                [self switchToReadyState];
                return;
            }
            LauncherNavigationController *navVC = (id)((UISplitViewController *)self.presentingViewController).viewControllers[1];
            [self dismissViewControllerAnimated:YES completion:^{
                [navVC enterModInstallerWithPath:outPath hitEnterAfterWindowShown:YES];
            }];
        });
    }];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [downloadTask resume];
    });
}

- (void)addVersionToList:(NSString *)version {
    // Get the current vendor to determine version format
    UISegmentedControl *segment = (id)self.navigationItem.titleView;
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    
    NSString *gameVersion;
    if ([vendor isEqualToString:@"Forge"]) {
        // Forge format: gameVersion-forgeVersion (e.g., "1.20.1-47.1.0")
        if (![version containsString:@"-"]) {
            return;
        }
        NSRange range = [version rangeOfString:@"-"];
        gameVersion = [version substringToIndex:range.location];
    } else if ([vendor isEqualToString:@"NeoForge"]) {
        // NeoForge format: major.minor.patch-beta (e.g., "20.2.3-beta")
        NSString *cleanVersion = [version stringByReplacingOccurrencesOfString:@"-beta" withString:@""];
        NSArray *components = [cleanVersion componentsSeparatedByString:@"."];
        if (components.count >= 2) {
            // Convert to full Minecraft version format (e.g., "20.2" -> "1.20.2")
            NSString *major = components[0];
            NSString *minor = components[1];
            gameVersion = [NSString stringWithFormat:@"1.%@.%@", major, minor];
        } else {
            gameVersion = version;
        }
    } else {
        return;
    }
    
    NSInteger gameVersionIndex = [self.versionList indexOfObject:gameVersion];
    if (gameVersionIndex == NSNotFound) {
        [self.visibilityList addObject:@(NO)];
        [self.versionList addObject:gameVersion];
        [self.forgeList addObject:[NSMutableArray new]];
        gameVersionIndex = self.versionList.count - 1;
    }
    [self.forgeList[gameVersionIndex] addObject:version];
}

#pragma mark NSXMLParser

- (void)parserDidEndDocument:(NSXMLParser *)unused {
        dispatch_async(dispatch_get_main_queue(), ^{
        // Determine current vendor to apply proper sorting
        UISegmentedControl *segment = (id)self.navigationItem.titleView;
        NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];

        NSMutableArray<NSNumber *> *indices = [NSMutableArray new];
        for (NSInteger i = 0; i < self.versionList.count; i++) {
            [indices addObject:@(i)];
        }
        [indices sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            NSString *va = self.versionList[a.integerValue];
            NSString *vb = self.versionList[b.integerValue];
            // Expect format "1.minor.patch"
            NSArray *pa = [va componentsSeparatedByString:@"."];
            NSArray *pb = [vb componentsSeparatedByString:@"."];
            NSInteger aMinor = pa.count > 1 ? [pa[1] integerValue] : 0;
            NSInteger bMinor = pb.count > 1 ? [pb[1] integerValue] : 0;
            if (aMinor != bMinor) return aMinor < bMinor ? NSOrderedDescending : NSOrderedAscending;
            NSInteger aPatch = pa.count > 2 ? [pa[2] integerValue] : 0;
            NSInteger bPatch = pb.count > 2 ? [pb[2] integerValue] : 0;
            if (aPatch != bPatch) return aPatch < bPatch ? NSOrderedDescending : NSOrderedAscending;
            return NSOrderedSame;
        }];

        NSMutableArray *newVisibility = [NSMutableArray new];
        NSMutableArray *newVersionList = [NSMutableArray new];
        NSMutableArray *newForgeList = [NSMutableArray new];
        for (NSNumber *idx in indices) {
            [newVisibility addObject:self.visibilityList[idx.integerValue]];
            [newVersionList addObject:self.versionList[idx.integerValue]];
            [newForgeList addObject:self.forgeList[idx.integerValue]];
        }
        self.visibilityList = newVisibility;
        self.versionList = newVersionList;
        self.forgeList = newForgeList;

        for (NSMutableArray<NSString *> *versions in self.forgeList) {
            [versions sortUsingComparator:^NSComparisonResult(NSString *lhs, NSString *rhs) {
                if ([vendor isEqualToString:@"Forge"]) {
                    // Format: 1.x.y-A.B.C -> compare A, then B, then C (descending)
                    NSRange dashL = [lhs rangeOfString:@"-"];
                    NSRange dashR = [rhs rangeOfString:@"-"];
                    NSString *lv = dashL.location != NSNotFound ? [lhs substringFromIndex:dashL.location + 1] : lhs;
                    NSString *rv = dashR.location != NSNotFound ? [rhs substringFromIndex:dashR.location + 1] : rhs;
                    NSArray *lp = [lv componentsSeparatedByString:@"."];
                    NSArray *rp = [rv componentsSeparatedByString:@"."];
                    NSInteger lA = lp.count > 0 ? [lp[0] integerValue] : 0;
                    NSInteger rA = rp.count > 0 ? [rp[0] integerValue] : 0;
                    if (lA != rA) return lA < rA ? NSOrderedDescending : NSOrderedAscending;
                    NSInteger lB = lp.count > 1 ? [lp[1] integerValue] : 0;
                    NSInteger rB = rp.count > 1 ? [rp[1] integerValue] : 0;
                    if (lB != rB) return lB < rB ? NSOrderedDescending : NSOrderedAscending;
                    NSInteger lC = lp.count > 2 ? [lp[2] integerValue] : 0;
                    NSInteger rC = rp.count > 2 ? [rp[2] integerValue] : 0;
                    if (lC != rC) return lC < rC ? NSOrderedDescending : NSOrderedAscending;
                    return NSOrderedSame;
                } else {
                    // NeoForge: X.Y.Z[-beta] where X.Y is stream; compare Z (build) descending; release before beta
                    BOOL lBeta = [lhs containsString:@"-beta"];
                    BOOL rBeta = [rhs containsString:@"-beta"];
                    NSString *lClean = [lhs stringByReplacingOccurrencesOfString:@"-beta" withString:@""];
                    NSString *rClean = [rhs stringByReplacingOccurrencesOfString:@"-beta" withString:@""];
                    NSArray *lc = [lClean componentsSeparatedByString:@"."];
                    NSArray *rc = [rClean componentsSeparatedByString:@"."];
                    NSInteger lBuild = lc.count > 2 ? [lc[2] integerValue] : 0;
                    NSInteger rBuild = rc.count > 2 ? [rc[2] integerValue] : 0;
                    if (lBuild != rBuild) return lBuild < rBuild ? NSOrderedDescending : NSOrderedAscending;
                    if (lBeta != rBeta) return lBeta ? NSOrderedDescending : NSOrderedAscending; // release first
                    return NSOrderedSame;
                }
            }];
        }

        [self switchToReadyState];
        [self.tableView reloadData];
    });
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary *)attributeDict {
    self.isVersionElement = [elementName isEqualToString:@"version"];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)version {
    if (self.isVersionElement) {
        [self addVersionToList:version];
    }
}

@end
