#import "ModpackInstallViewController.h"
#import "BackgroundManager.h"
#import "InlineMessageView.h"
#import "modpack/ModrinthAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
// Note: UIKit+AFNetworking has been replaced by the unified IconLoader
// (AFNetworking only caches in memory and does not downsample; IconLoader adds a two-level cache, downsampling, CDN mirrors and concurrency control)
#import "IconLoader.h"
#import "WFWorkflowProgressView.h"
#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import <dlfcn.h>

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6

@interface ModpackInstallViewController()<UIContextMenuInteractionDelegate>
@property(nonatomic) UISearchController *searchController;
@property(nonatomic) UIMenu *currentMenu;
@property(nonatomic) NSMutableArray *list;
@property(nonatomic) NSMutableDictionary *filters;
@property ModrinthAPI *modrinth;
@property(nonatomic, strong) InlineMessageView *currentMessageView;
@property(nonatomic) NSIndexPath *loadingIndexPath;  // The indexPath whose version is currently loading
@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // Adapt to the custom launcher background: make this VC transparent so the global background image/blur shows through
    // This controller is a UITableViewController subclass, and makeViewControllerTransparent makes the tableView background transparent internally
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // Apply the frosted glass effect to the root view
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    self.modrinth = [ModrinthAPI new];
    self.filters = @{
        @"isModpack": @(YES),
        @"projectType": @"modpack",
        @"name": @" "
    }.mutableCopy;
    [self updateSearchResults];
    
    // Set the table style
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    // Phase 6 visual unification: match the list row height of ModpackImportViewController / DownloadViewController (80pt)
    self.tableView.rowHeight = 80;
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

// Override the tableView getter to change the background (avoiding duplicated code)
- (UITableView *)tableView {
    UITableView *tv = [super tableView];
    if (!tv) {
        tv = [super tableView];
    }
    return tv;
}

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text;
    if (!prevList && [self.filters[@"name"] isEqualToString:name]) {
        return;
    }

    [self switchToLoadingState];
    // Show the inline loading indicator (on the first load)
    if (!prevList) {
        self.currentMessageView = [InlineMessageView showInViewController:self
                                                                    title:@"Loading"
                                                                 message:nil
                                                                    type:InlineMessageTypeLoading];
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.filters[@"name"] = name;
        self.list = [self.modrinth searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.currentMessageView dismiss];
            self.currentMessageView = nil;
            if (self.list) {
                [self switchToReadyState];
                [self.tableView reloadData];
            } else {
                // Show the error in the content area rather than in a dialog
                self.currentMessageView = [InlineMessageView showInViewController:self
                                                                            title:localize(@"Error", nil)
                                                                         message:self.modrinth.lastError.localizedDescription
                                                                            type:InlineMessageTypeError];
                [self switchToReadyState];
            }
        });
    });
}

- (void)updateSearchResults {
    [self loadSearchResultsWithPrevList:NO];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    [indicator startAnimating];
    self.navigationController.modalInPresentation = YES;
    self.tableView.allowsSelection = NO;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
    self.tableView.allowsSelection = YES;
}

#pragma mark UIContextMenu

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location
{
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

// Fix: removed the private _UIContextMenuStyle method, since no custom style is needed and the system default is fine

#pragma mark UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.list.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Use a custom card-style cell (ModernAssetCell if it exists, otherwise a fallback)
    static NSString *cellIdentifier = @"ModpackCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        // Try to use ModernAssetCell (if it exists)
        Class modernCellClass = NSClassFromString(@"ModernAssetCell");
        if (modernCellClass) {
            cell = [[modernCellClass alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
        } else {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
        }
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        // Phase 6 visual unification: follow the card conventions of ModernAssetCell / ModVersionTableViewCell / VersionCardCell
        // （cornerRadius 12 + cornerCurve continuous + shadow offset 2/opacity 0.10/radius 4 + leading/trailing 10）
        // Because UIVisualEffectView's masksToBounds=YES clips both the blur and the shadow, a separate shadowView is needed
        // to provide the shadow (with the same frame as blurView), while blurView provides the frosted glass on top.
        UIView *shadowView = [[UIView alloc] init];
        shadowView.translatesAutoresizingMaskIntoConstraints = NO;
        shadowView.layer.cornerRadius = 12;
        shadowView.layer.cornerCurve = kCACornerCurveContinuous;
        shadowView.layer.shadowColor = [UIColor blackColor].CGColor;
        shadowView.layer.shadowOffset = CGSizeMake(0, 2);
        shadowView.layer.shadowOpacity = 0.10;
        shadowView.layer.shadowRadius = 4;
        shadowView.layer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08].CGColor;
        [cell.contentView insertSubview:shadowView atIndex:0];

        // Add the frosted glass card
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        blurView.translatesAutoresizingMaskIntoConstraints = NO;
        blurView.layer.cornerRadius = 12;
        blurView.layer.cornerCurve = kCACornerCurveContinuous;
        blurView.layer.masksToBounds = YES;
        [cell.contentView insertSubview:blurView atIndex:1];
        [NSLayoutConstraint activateConstraints:@[
            [shadowView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
            [shadowView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:10],
            [shadowView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-10],
            [shadowView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
            [blurView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
            [blurView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:10],
            [blurView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-10],
            [blurView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]
        ]];
        cell.backgroundView = nil;
    }

    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"description"];
    cell.detailTextLabel.numberOfLines = 2;
    UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    // Modpack list icons: loaded uniformly through IconLoader (two-level cache + downsampling + CDN mirror + concurrency control)
    // Modpack icons are displayed quite small (about 38x38, the default UITableViewCell icon size), so they are downsampled to that size instead of being decoded at full resolution
    [IconLoader loadIconForImageView:cell.imageView
                                 URL:item[@"imageUrl"]
                         placeholder:fallbackImage
                            fallback:fallbackImage
                           targetSize:CGSizeMake(38, 38)];
    cell.imageView.layer.cornerRadius = 8;
    cell.imageView.clipsToBounds = YES;

    if (!self.modrinth.reachedLastPage && indexPath.row == self.list.count-1) {
        [self loadSearchResultsWithPrevList:YES];
    }

    return cell;
}

- (void)showDetails:(NSDictionary *)details atIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];

    NSMutableArray<UIAction *> *menuItems = [[NSMutableArray alloc] init];
    [details[@"versionNames"] enumerateObjectsUsingBlock:
    ^(NSString *name, NSUInteger i, BOOL *stop) {
        NSString *nameWithVersion = name;
        NSString *mcVersion = details[@"mcVersionNames"][i];
        if (![name hasSuffix:mcVersion]) {
            nameWithVersion = [NSString stringWithFormat:@"%@ - %@", name, mcVersion];
        }
        [menuItems addObject:[UIAction
            actionWithTitle:nameWithVersion
            image:nil identifier:nil
            handler:^(UIAction *action) {
            [self actionClose];
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
            
            // Fix: replaced the private method _imageWithSize: with a public scaling implementation
            UIImage *originalImage = cell.imageView.image;
            if (originalImage) {
                CGSize targetSize = CGSizeMake(40, 40);
                UIGraphicsBeginImageContextWithOptions(targetSize, NO, 0.0);
                [originalImage drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
                UIImage *scaledImage = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                [UIImagePNGRepresentation(scaledImage) writeToFile:tmpIconPath atomically:YES];
            } else {
                // If there is no image, write empty data or ignore it
                [[NSData data] writeToFile:tmpIconPath atomically:YES];
            }
            
            [self.modrinth installModpackFromDetail:self.list[indexPath.row] atIndex:i];
        }]];
    }];

    self.currentMenu = [UIMenu menuWithTitle:@"" children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    cell.detailTextLabel.interactions = @[interaction];
    // Fix: removed the private method _presentMenuAtLocation:; the system shows the menu automatically on user interaction
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.list[indexPath.row];
    if ([item[@"versionDetailsLoaded"] boolValue]) {
        [self showDetails:item atIndexPath:indexPath];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    // Prevent repeated taps
    if (self.loadingIndexPath) return;
    self.loadingIndexPath = indexPath;

    // Show the loading indicator in the middle of the content area (instead of the spinner in the nav bar, so nothing is blocked)
    NSString *loadingTitle = [NSString stringWithFormat:@"\"%@\"", item[@"title"]];
    self.currentMessageView = [InlineMessageView showInViewController:self
                                                                title:loadingTitle
                                                             message:@"Loading the version list"
                                                                type:InlineMessageTypeLoading];

    // Load asynchronously, avoiding the synchronous dispatch_group_wait (which made the list load too slowly)
    NSMutableDictionary *mutableItem = self.list[indexPath.row];
    __weak typeof(self) weakSelf = self;
    [self.modrinth loadDetailsOfModAsync:mutableItem completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.loadingIndexPath = nil;
            [strongSelf.currentMessageView dismiss];
            strongSelf.currentMessageView = nil;

            if (success && [mutableItem[@"versionDetailsLoaded"] boolValue]) {
                [strongSelf showDetails:mutableItem atIndexPath:indexPath];
            } else {
                // Show the error in the content area rather than in a dialog
                NSString *errMsg = error.localizedDescription ?: strongSelf.modrinth.lastError.localizedDescription;
                strongSelf.currentMessageView = [InlineMessageView showInViewController:strongSelf
                                                                                  title:localize(@"Error", nil)
                                                                               message:errMsg
                                                                                  type:InlineMessageTypeError];
            }
        });
    }];
}

/// Reapply the transparency treatment and the frosted glass effect when the background effect changes, so the global background still shows through after a background switch
- (void)reapplyBackgroundEffect {
    // Make the current VC transparent again (it is a UITableViewController subclass, which handles the tableView background transparency internally)
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // Reapply the frosted glass effect to the root view
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    // As a fallback, set the tableView background to transparent again, so the global background still shows through after a background effect switch
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reapplyBackgroundEffect];
        [self.tableView reloadData];
    });
}

@end