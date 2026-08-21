//
//  ModpackImportViewController.m
//  Flux
//
//  Reworked after FCL ModpackImportScreen / HMCL ModpackProviderPane / ZL2 ModpackImportScreen
//
//  Design points:
//    1. A UISegmentedControl at the top switches between "Import / Export", with Export pushing the separate ModpackExportViewController
//    2. The import flow: choose a file -> parse (an indeterminate progress card) -> preview card (mod information) -> import progress card (cancellable) -> completion message
//    3. Real cancellation: triggered by [self.importService setCancelled:YES]; the service throws at a checkpoint and cleans up the half-finished folder
//    4. The list of imported modpacks uses a modern card style
//

#import "ModpackImportViewController.h"
#import "BackgroundManager.h"
#import "ModpackImportService.h"
#import "ModpackExportViewController.h"
#import "PLProfiles.h"
#import "UnzipKit.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ModpackImportViewController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UISegmentedControl *tabSegment;       // The "Import | Export" switch at the top
@property (nonatomic, strong) UIView *headerContainerView;          // The header text + the choose file button
@property (nonatomic, strong) UILabel *hintLabel;                   // The supported formats note
@property (nonatomic, strong) UIButton *importButton;               // The main import button
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *importedModpacks;
@property (nonatomic, strong) ModpackImportService *importService;
@property (nonatomic, strong) NSDictionary *currentImportingModpack;

// FCL-style progress card
@property (nonatomic, strong) UIView *progressOverlay;       // Translucent scrim
@property (nonatomic, strong) UIView *progressCard;          // The centered card
@property (nonatomic, strong) UILabel *progressTitleLabel;   // Title
@property (nonatomic, strong) UILabel *progressPercentLabel; // Percentage (36pt, large)
@property (nonatomic, strong) UIProgressView *progressBar;   // Progress bar
@property (nonatomic, strong) UILabel *progressStageLabel;   // Stage text
@property (nonatomic, strong) UIActivityIndicatorView *progressSpinner; // The spinner for indeterminate mode
@property (nonatomic, strong) UIButton *progressCancelButton; // Cancel button
@end

@implementation ModpackImportViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Adapt to the custom launcher background: make this view controller transparent so the global wallpaper shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.title = @"Modpack";

    [[BackgroundManager sharedManager] applyEffectToView:self.view];

    self.importService = [[ModpackImportService alloc] init];
    self.importedModpacks = [NSMutableArray array];

    [self setupNavigationTab];
    [self setupUI];
    [self loadImportedModpacks];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // On returning to the import page, make sure the tab shows "Import"
    self.tabSegment.selectedSegmentIndex = 0;
}

#pragma mark - Top tab switching (import / export)

- (void)setupNavigationTab {
    self.tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"Import", @"Export"]];
    self.tabSegment.selectedSegmentIndex = 0;
    [self.tabSegment addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];

    // Placed in navigationItem.titleView, with a self-sizing width
    CGSize fittingSize = [self.tabSegment sizeThatFits:CGSizeMake(220, 30)];
    self.tabSegment.frame = CGRectMake(0, 0, MAX(180, fittingSize.width), 30);
    self.navigationItem.titleView = self.tabSegment;
}

- (void)tabChanged:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex == 1) {
        // Switching to Export: push ModpackExportViewController
        ModpackExportViewController *exportVC = [[ModpackExportViewController alloc] init];
        exportVC.preselectedProfileName = PLProfiles.current.selectedProfileName;
        [self.navigationController pushViewController:exportVC animated:YES];
        // Switch the tab straight back to "Import", since viewWillAppear resets it on return
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.selectedSegmentIndex = 0;
        });
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // Container for the header text and the choose file button
    self.headerContainerView = [[UIView alloc] init];
    self.headerContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerContainerView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.headerContainerView];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.text = @"Supported formats: Modrinth (.mrpack), CurseForge (.zip), MMC (MultiMC/Prism), Plain ZIP (containing .minecraft directly)";
    [self.headerContainerView addSubview:self.hintLabel];

    self.importButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.importButton setTitle:@"  Choose modpack file" forState:UIControlStateNormal];
    [self.importButton setImage:[UIImage systemImageNamed:@"doc.badge.plus"] forState:UIControlStateNormal];
    self.importButton.backgroundColor = [UIColor systemBlueColor];
    [self.importButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.importButton.tintColor = [UIColor whiteColor];
    self.importButton.layer.cornerRadius = 12;
    self.importButton.layer.masksToBounds = YES;
    self.importButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.importButton addTarget:self action:@selector(selectModpackFile) forControlEvents:UIControlEventTouchUpInside];
    [self.headerContainerView addSubview:self.importButton];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"ModpackCell"];
    self.tableView.rowHeight = 80;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.text = @"No modpacks imported yet\nTap the button above to import one";
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerContainerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.headerContainerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.headerContainerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.hintLabel.topAnchor constraintEqualToAnchor:self.headerContainerView.topAnchor],
        [self.hintLabel.leadingAnchor constraintEqualToAnchor:self.headerContainerView.leadingAnchor],
        [self.hintLabel.trailingAnchor constraintEqualToAnchor:self.headerContainerView.trailingAnchor],

        [self.importButton.topAnchor constraintEqualToAnchor:self.hintLabel.bottomAnchor constant:10],
        [self.importButton.leadingAnchor constraintEqualToAnchor:self.headerContainerView.leadingAnchor],
        [self.importButton.trailingAnchor constraintEqualToAnchor:self.headerContainerView.trailingAnchor],
        [self.importButton.heightAnchor constraintEqualToConstant:50],
        [self.importButton.bottomAnchor constraintEqualToAnchor:self.headerContainerView.bottomAnchor],

        [self.tableView.topAnchor constraintEqualToAnchor:self.headerContainerView.bottomAnchor constant:12],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

#pragma mark - FCL style progress card

- (void)showProgressCardWithTitle:(NSString *)title {
    [self hideProgressCard];

    UIView *overlay = [[UIView alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    overlay.userInteractionEnabled = YES;
    [self.view addSubview:overlay];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    [overlay addSubview:card];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 2;
    [card addSubview:titleLabel];

    UILabel *percentLabel = [[UILabel alloc] init];
    percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    percentLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightHeavy];
    percentLabel.textAlignment = NSTextAlignmentCenter;
    percentLabel.text = @"0%";
    [card addSubview:percentLabel];

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.progressTintColor = [UIColor systemBlueColor];
    [card addSubview:bar];

    UILabel *stageLabel = [[UILabel alloc] init];
    stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    stageLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    stageLabel.textColor = [UIColor secondaryLabelColor];
    stageLabel.textAlignment = NSTextAlignmentCenter;
    stageLabel.numberOfLines = 0;
    [card addSubview:stageLabel];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.hidesWhenStopped = YES;
    [card addSubview:spinner];

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelBtn setTitle:@"Cancel" forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [cancelBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [cancelBtn addTarget:self action:@selector(cancelImport) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelBtn];

    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:300],

        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:24],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [percentLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:16],
        [percentLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [spinner.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:16],
        [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [bar.topAnchor constraintEqualToAnchor:percentLabel.bottomAnchor constant:12],
        [bar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [bar.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [bar.heightAnchor constraintEqualToConstant:8],

        [stageLabel.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:12],
        [stageLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [stageLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [cancelBtn.topAnchor constraintEqualToAnchor:stageLabel.bottomAnchor constant:16],
        [cancelBtn.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [cancelBtn.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20]
    ]];

    self.progressOverlay = overlay;
    self.progressCard = card;
    self.progressTitleLabel = titleLabel;
    self.progressPercentLabel = percentLabel;
    self.progressBar = bar;
    self.progressStageLabel = stageLabel;
    self.progressSpinner = spinner;
    self.progressCancelButton = cancelBtn;

    // Indeterminate at first (showing only the spinner)
    [self setProgress:-1 stageMessage:@"Preparing..."];
}

- (void)setProgress:(double)progress stageMessage:(NSString *)stageMessage {
    if (!self.progressCard) return;

    if (progress < 0) {
        // Indeterminate mode
        self.progressBar.hidden = YES;
        self.progressPercentLabel.hidden = YES;
        self.progressSpinner.hidden = NO;
        [self.progressSpinner startAnimating];
    } else {
        self.progressBar.hidden = NO;
        self.progressPercentLabel.hidden = NO;
        self.progressSpinner.hidden = YES;
        [self.progressSpinner stopAnimating];
        double clamped = MAX(0.0, MIN(1.0, progress));
        NSInteger percent = (NSInteger)(clamped * 100);
        self.progressPercentLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
        [self.progressBar setProgress:(float)clamped animated:YES];
    }
    self.progressStageLabel.text = stageMessage ?: @"";
}

- (void)hideProgressCard {
    if (self.progressOverlay) {
        [self.progressOverlay removeFromSuperview];
        self.progressOverlay = nil;
        self.progressCard = nil;
        self.progressTitleLabel = nil;
        self.progressPercentLabel = nil;
        self.progressBar = nil;
        self.progressStageLabel = nil;
        self.progressSpinner = nil;
        self.progressCancelButton = nil;
    }
}

/// Real cancellation: the service.cancelled signal tells the import in progress to stop
- (void)cancelImport {
    self.importService.cancelled = YES;
    if (self.progressCancelButton) {
        [self.progressCancelButton setTitle:@"Cancelling..." forState:UIControlStateNormal];
        [self.progressCancelButton setEnabled:NO];
    }
    [self setProgress:-1 stageMessage:@"Cancelling, please wait..."];
}

- (void)loadImportedModpacks {
    NSArray *modpacks = [self.importService getImportedModpacks];
    [self.importedModpacks removeAllObjects];
    [self.importedModpacks addObjectsFromArray:modpacks];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.emptyLabel.hidden = self.importedModpacks.count > 0;
        [self.tableView reloadData];
    });
}

#pragma mark - File selection

- (void)selectModpackFile {
    // A file is only tappable in the picker when its reported type conforms to one of
    // these. Listing only mrpack/zip made most files inert: .mrpack resolves to a
    // *dynamic* UTI that real .mrpack files on disk do not report (providers hand back
    // public.zip-archive or public.data), so tapping them did nothing at all.
    // Every other importer in the app already includes a catch-all; this one did not.
    // Accept broadly here and validate the extension after picking, so an unsupported
    // choice gets an explanatory message instead of silence.
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray new];
    for (NSString *ext in @[@"mrpack", @"zip", @"mcpack"]) {
        UTType *type = [UTType typeWithFilenameExtension:ext];
        if (type) [contentTypes addObject:type];
    }
    [contentTypes addObjectsFromArray:@[UTTypeZIP, UTTypeArchive, UTTypeData, UTTypeItem]];

    // asCopy:YES makes iOS copy the file into our sandbox and hand back a plain local
    // URL. The default (open-in-place) needs security-scoped access, which fails
    // intermittently on iCloud and third-party providers - the other half of the
    // "it just will not open" behaviour.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:contentTypes asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *fileURL = urls.firstObject;
    NSString *fileExtension = fileURL.pathExtension.lowercaseString;

    if (![fileExtension isEqualToString:@"mrpack"] && ![fileExtension isEqualToString:@"zip"]) {
        [self showAlertWithTitle:@"Unsupported file"
                         message:[NSString stringWithFormat:@"Modpacks must be .mrpack or .zip. You picked a .%@ file.", fileExtension.length ? fileExtension : @"(no extension)"]];
        return;
    }

    // With asCopy:YES the URL is already inside our sandbox, so security scoping is not
    // required. Ask for it anyway and carry on if it is refused, rather than aborting -
    // a refusal here used to block the import outright.
    BOOL accessGranted = [fileURL startAccessingSecurityScopedResource];
    if (!accessGranted && ![NSFileManager.defaultManager isReadableFileAtPath:fileURL.path]) {
        [self showAlertWithTitle:@"Access denied" message:@"Could not read the selected file"];
        return;
    }

    // Parse stage: show the indeterminate progress card
    [self showProgressCardWithTitle:@"Parsing the modpack"];
    [self setProgress:-1 stageMessage:@"Reading modpack information..."];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        NSDictionary *modpackInfo = nil;

        @try {
            modpackInfo = [self.importService parseModpackAtURL:fileURL error:&error];
        } @catch (NSException *exception) {
            error = [NSError errorWithDomain:@"ModpackImportError" code:9999
                                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Parse exception: %@", exception.reason]}];
        }

        [fileURL stopAccessingSecurityScopedResource];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !modpackInfo) {
                [self hideProgressCard];
                [self showAlertWithTitle:@"Parse failed" message:error.localizedDescription ?: @"Could not parse the modpack file"];
                return;
            }
            self.currentImportingModpack = modpackInfo;
            [self hideProgressCard];
            [self showModpackPreview:modpackInfo fileURL:fileURL];
        });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {}

#pragma mark - Modpack preview card (modeled on FCL ModpackPreviewSheet / HMCL ModpackInfoPage)

- (void)showModpackPreview:(NSDictionary *)modpackInfo fileURL:(NSURL *)fileURL {
    NSString *name = modpackInfo[@"name"] ?: @"Unknown";
    NSString *version = modpackInfo[@"version"] ?: @"Unknown";
    NSString *author = modpackInfo[@"author"] ?: @"";
    NSString *mcVersion = modpackInfo[@"minecraftVersion"] ?: @"Unknown";
    NSString *loader = modpackInfo[@"loader"] ?: @"Vanilla";
    NSString *loaderVersion = modpackInfo[@"loaderVersion"] ?: @"";
    NSString *format = modpackInfo[@"format"] ?: @"unknown";
    NSNumber *modCountNum = modpackInfo[@"modCount"];
    NSNumber *fileCountNum = modpackInfo[@"fileCount"];
    NSString *fileName = fileURL.lastPathComponent ?: @"";

    // Map the format to display text
    NSDictionary *formatLabels = @{
        @"modrinth": @"Modrinth (.mrpack)",
        @"curseforge": @"CurseForge (.zip)",
        @"mmc": @"MMC (MultiMC/Prism)",
        @"plainzip": @"Plain ZIP (.minecraft)"
    };
    NSString *formatLabel = formatLabels[format] ?: format;

    NSMutableString *message = [NSMutableString string];
    [message appendFormat:@"File: %@\n", fileName];
    [message appendFormat:@"Format: %@\n", formatLabel];
    [message appendFormat:@"Name: %@\n", name];
    [message appendFormat:@"Version: %@", version];
    if (author.length > 0) {
        [message appendFormat:@"   Author: %@", author];
    }
    [message appendString:@"\n"];
    [message appendFormat:@"Minecraft: %@\n", mcVersion];
    [message appendFormat:@"Loader: %@", loader];
    if (loaderVersion.length > 0) {
        [message appendFormat:@" %@", loaderVersion];
    }
    [message appendString:@"\n"];

    if (modCountNum && modCountNum.integerValue > 0) {
        [message appendFormat:@"Mods to download: %ld\n", (long)modCountNum.integerValue];
    }
    if (fileCountNum && fileCountNum.integerValue > 0) {
        [message appendFormat:@"Files to extract: %ld\n", (long)fileCountNum.integerValue];
    }

    // Forge/NeoForge warning
    if ([loader isEqualToString:@"Forge"] || [loader isEqualToString:@"NeoForge"]) {
        [message appendFormat:@"\n⚠️ Note: the %@ %@ loader must be installed manually from the download screen, or launching will fail.", loader, loaderVersion];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import modpack"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        self.currentImportingModpack = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startModpackImport:modpackInfo];
    }]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Import flow

- (void)startModpackImport:(NSDictionary *)modpackInfo {
    // Reset the cancellation state
    [self.importService resetCancelState];

    NSString *name = modpackInfo[@"name"] ?: @"Modpack";
    [self showProgressCardWithTitle:[NSString stringWithFormat:@"Importing %@", name]];
    [self setProgress:-1 stageMessage:@"Preparing..."];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __block NSError *error = nil;
        __block BOOL success = NO;

        @try {
            success = [self.importService importModpack:modpackInfo
                                               progress:^(double progress, NSString *stageMessage) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setProgress:progress stageMessage:stageMessage];
                });
            } error:&error];
        } @catch (NSException *exception) {
            error = [NSError errorWithDomain:@"ModpackImportError" code:9998
                                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Import exception: %@", exception.reason]}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            // Detect whether it was cancelled
            BOOL wasCancelled = [error.domain isEqualToString:@"ModpackImportError"] && error.code == 9999;
            NSString *localizedDesc = error.localizedDescription ?: @"";
            if (!wasCancelled && [localizedDesc localizedCaseInsensitiveContainsString:@"cancel"]) {
                wasCancelled = YES;
            }

            if (wasCancelled) {
                // Cancelled: hide the card without showing 100%
                [self hideProgressCard];
                self.currentImportingModpack = nil;
                [self showAlertWithTitle:@"Cancelled" message:@"Import cancelled"];
                return;
            }

            if (success) {
                // Show 100% on completion
                [self setProgress:1.0 stageMessage:@"Import complete"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self hideProgressCard];
                    self.currentImportingModpack = nil;
                    [self showImportSuccess:modpackInfo];
                });
            } else {
                // Phase 5 fix (following FCL): append the list of failed files to the error message (when there is one),
                // so the user knows exactly which mods failed instead of seeing one vague error.
                NSString *message = error.localizedDescription ?: @"Unknown error";
                NSArray<NSDictionary *> *failed = self.importService.failedFiles;
                if (failed.count > 0) {
                    NSMutableString *msg = [NSMutableString stringWithString:message];
                    [msg appendFormat:@"\n\nFailed files (%lu in total):", (unsigned long)failed.count];
                    NSUInteger showCount = MIN(failed.count, (NSUInteger)5);
                    for (NSUInteger k = 0; k < showCount; k++) {
                        NSString *n = failed[k][@"fileName"] ?: failed[k][@"name"];
                        [msg appendFormat:@"\n  • %@", n ?: @"(unknown)"];
                    }
                    if (failed.count > showCount) {
                        [msg appendFormat:@"\n  ...and %lu in total", (unsigned long)failed.count];
                    }
                    message = [msg copy];
                }
                [self hideProgressCard];
                self.currentImportingModpack = nil;
                [self showAlertWithTitle:@"Import failed" message:message];
            }
        });
    });
}

- (void)showImportSuccess:(NSDictionary *)modpackInfo {
    NSString *loader = modpackInfo[@"loader"];
    NSString *name = modpackInfo[@"name"];
    NSString *msg = [NSString stringWithFormat:@"The modpack '%@' was imported successfully.", name];
    if ([loader isEqualToString:@"Forge"] || [loader isEqualToString:@"NeoForge"]) {
        msg = [msg stringByAppendingFormat:@"\n\nNote: this modpack uses the %@ %@ loader. Install that loader version manually from the download screen first, or launching will fail.", loader, modpackInfo[@"loaderVersion"]];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import successful"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [self loadImportedModpacks];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Launch now" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self loadImportedModpacks];
        [self launchModpack:modpackInfo];
    }]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.importedModpacks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackCell" forIndexPath:indexPath];
    // Reset the cell style
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    // Reset the cell style: remove the old blurView and shadowView (cell reuse)
    for (UIView *subview in cell.contentView.subviews) {
        if ([subview isKindOfClass:[UIVisualEffectView class]] ||
            (subview.layer.shadowOpacity > 0.0f)) {
            [subview removeFromSuperview];
        }
    }

    NSDictionary *modpack = self.importedModpacks[indexPath.row];
    NSString *name = modpack[@"name"] ?: @"Unknown";
    NSString *mcVersion = modpack[@"minecraftVersion"] ?: @"Unknown";
    NSString *loader = modpack[@"loader"] ?: @"Unknown";

    cell.textLabel.text = name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Minecraft %@ - %@", mcVersion, loader];
    cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = [UIColor clearColor];

    // Phase 6 visual alignment: following the card spec of ModernAssetCell / ModVersionTableViewCell / VersionCardCell
    // （cornerRadius 12 + cornerCurve continuous + shadow offset 2/opacity 0.10/radius 4 + leading/trailing 10）
    // Since masksToBounds=YES on a UIVisualEffectView clips both the blur and the shadow, a separate shadowView is needed
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
    return cell;
}

#pragma mark - UITableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *modpack = self.importedModpacks[indexPath.row];
    [self showModpackOptions:modpack];
}

- (void)showModpackOptions:(NSDictionary *)modpack {
    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:modpack[@"name"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"Launch modpack" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self launchModpack:modpack];
    }]];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteModpack:modpack];
    }]];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        actionSheet.popoverPresentationController.sourceView = self.view;
        actionSheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:actionSheet animated:YES completion:nil];
}

- (void)launchModpack:(NSDictionary *)modpack {
    NSString *profileName = modpack[@"profileName"];
    if (profileName && PLProfiles.current.profiles[profileName]) {
        PLProfiles.current.selectedProfileName = profileName;
        [self showAlertWithTitle:@"Profile selected" message:[NSString stringWithFormat:@"Switched to the modpack profile: %@", profileName]];
    } else {
        [self showAlertWithTitle:@"Error" message:@"The modpack profile was not found"];
    }
}

- (void)deleteModpack:(NSDictionary *)modpack {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Confirm delete" message:[NSString stringWithFormat:@"Delete the modpack '%@'? This cannot be undone.", modpack[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self showProgressCardWithTitle:@"Deleting"];
        [self setProgress:-1 stageMessage:@"Deleting modpack files..."];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error = nil;
            BOOL success = [self.importService deleteModpack:modpack error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideProgressCard];
                if (success) {
                    [self loadImportedModpacks];
                } else {
                    [self showAlertWithTitle:@"Delete failed" message:error.localizedDescription];
                }
            });
        });
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

#pragma mark - Helper methods

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    [self showAlertWithTitle:title message:message completion:nil];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message completion:(void (^ _Nullable)(void))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (completion) completion();
    }]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Re-apply transparency, so the view still shows the global background after an effect switch
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        [[BackgroundManager sharedManager] applyEffectToView:self.view];
        [self.tableView reloadData];
    });
}

@end
