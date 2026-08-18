//
//  ModUpdateViewController.m
//  Amethyst
//
//  Multi-stage task flow page for mod updates/downgrades (Bento Grid + Material Design 3 style)
//

#import "ModUpdateViewController.h"
#import "ModUpdateService.h"
#import "ModVersion.h"
#import "PLPreferences.h"
#import "ModService.h"
#import "BackgroundManager.h"
#import <objc/runtime.h>

/// Associated object key: the ModDownloadTaskInfo for a download task
static void *kDownloadTaskInfoKey = &kDownloadTaskInfoKey;
/// Associated object key: the concurrency semaphore for a download task
static void *kDownloadSemaphoreKey = &kDownloadSemaphoreKey;

/// The stages of the multi-stage task flow
typedef NS_ENUM(NSInteger, ModUpdatePhase) {
    ModUpdatePhasePrepare  = 0, // Stage 0: preparation (filtering the mods)
    ModUpdatePhaseCheck    = 1, // Stage 1: check for updates concurrently (limited to 3)
    ModUpdatePhaseConfirm  = 2, // Stage 2: user confirmation (with checkboxes and a downgrade picker)
    ModUpdatePhaseDownload = 3, // Stage 3: download concurrently (limited to 16, with one retry on failure)
    ModUpdatePhaseReplace  = 4, // Stage 4: replace the files (honoring the modUpdateKeepOld preference)
    ModUpdatePhaseDone     = 5, // Stage 5: done (the result summary)
};

#pragma mark - Helper model: the items selected during the user confirmation stage

/// A selectable entry used in the stage 2 user confirmation step
@interface ModUpdateSelection : NSObject
@property (nonatomic, strong, nullable) ModUpdateResult *result;
@property (nonatomic, assign) BOOL selected;                       // Whether it is selected (YES by default)
@property (nonatomic, assign) BOOL expanded;                       // Whether the version list is expanded
@property (nonatomic, strong, nullable) ModVersion *chosenVersion; // The target version the user picked (candidateVersions.firstObject by default)
@end

@implementation ModUpdateSelection
@end

#pragma mark - Helper model: download task tracking

/// Task tracking for the concurrent downloads in stage 3
@interface ModDownloadTaskInfo : NSObject
@property (nonatomic, copy, nullable) NSString *fileName;
@property (nonatomic, strong, nullable) ModUpdateResult *result;
@property (nonatomic, strong, nullable) ModVersion *targetVersion;
@property (nonatomic, strong, nullable) NSProgress *progress;
@property (nonatomic, copy, nullable) NSString *tempFilePath; // Path of the temporary file once the download finishes
@property (nonatomic, assign) BOOL succeeded;
@property (nonatomic, assign) BOOL retried;                   // Whether it has already been retried once
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *task;
@end

@implementation ModDownloadTaskInfo
@end

#pragma mark - ModUpdateViewController class extension

@interface ModUpdateViewController () <UITableViewDataSource, UITableViewDelegate, NSURLSessionDownloadDelegate>

// Input parameters
@property (nonatomic, copy) NSArray<ModItem *> *inputMods;
@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, copy, nullable) NSString *loader;
@property (nonatomic, copy) NSString *projectType;

// Stage 0 output: the filtered mods (with entries lacking a filePath removed)
@property (nonatomic, copy) NSArray<ModItem *> *filteredMods;

// The current stage
@property (nonatomic, assign) ModUpdatePhase currentPhase;

// Stage 1: the check results
@property (nonatomic, copy) NSArray<ModUpdateResult *> *checkResults;
@property (nonatomic, assign) NSInteger checkCompleted;
@property (nonatomic, assign) NSInteger checkTotal;

// Stage 2: the entries selected during user confirmation
@property (nonatomic, strong) NSMutableArray<ModUpdateSelection *> *selections;

// Stage 3: the download task list
@property (nonatomic, strong) NSMutableArray<ModDownloadTaskInfo *> *downloadTasks;
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t callbackQueue;
@property (nonatomic, copy, nullable) NSString *tempDir;
@property (nonatomic, assign) NSInteger downloadCompleted;
@property (nonatomic, assign) NSInteger downloadTotal;

// Stages 4/5: the result statistics
@property (nonatomic, assign) NSInteger successCount;
@property (nonatomic, assign) NSInteger failureCount;
@property (nonatomic, copy) NSMutableArray<NSString *> *failedFileNames;

// UI: the Bento Grid container
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *bentoStack;

// UI: the header card at the top
@property (nonatomic, strong) UIView *headerCard;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeButton;

// UI: the stage status card
@property (nonatomic, strong) UIView *phaseCard;
@property (nonatomic, strong) UILabel *phaseTitleLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *currentFileLabel;

// UI: the content card (table / empty state)
@property (nonatomic, strong) UIView *contentCard;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UILabel *emptyLabel;

// UI: the action button card
@property (nonatomic, strong) UIView *actionCard;
@property (nonatomic, strong) UIButton *primaryButton;
@property (nonatomic, strong) UIButton *secondaryButton;

@end

@implementation ModUpdateViewController

#pragma mark - Initialization

- (instancetype)initWithMods:(NSArray<ModItem *> *)mods
                gameVersion:(NSString *)gameVersion
                     loader:(nullable NSString *)loader
               projectType:(NSString *)projectType {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _inputMods = [mods copy] ?: @[];
        _gameVersion = [gameVersion copy] ?: @"";
        _loader = [loader copy];
        _projectType = [projectType copy] ?: @"mod";
        _currentPhase = ModUpdatePhasePrepare;
        _selections = [NSMutableArray array];
        _downloadTasks = [NSMutableArray array];
        _failedFileNames = [NSMutableArray array];
        _callbackQueue = dispatch_queue_create("com.amethyst.modupdate.callback", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    // Clean up the temporary directory
    if (self.tempDir) {
        [[NSFileManager defaultManager] removeItemAtPath:self.tempDir error:nil];
    }
    // Cancel and tear down the session
    [self.session invalidateAndCancel];
    self.session = nil;
    // Remove the background-effect notification observer so a notification after dealloc cannot crash on a dangling pointer
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - View loading

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // Adapt to the custom launcher background: make this VC transparent so the global background image/blur shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [self setupBentoLayout];
    // Make the tableView background transparent so it does not hide the global background
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    [self transitionToPhase:ModUpdatePhasePrepare];

    // Listen for background effect changes so transparency is re-applied when the background is switched
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)reapplyBackgroundEffect {
    // Re-apply transparency to this VC when the background effect changes
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // Reset the tableView background to transparent so the global background still shows after an effect switch
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

#pragma mark - Bento grid layout

/// Build the overall Bento Grid layout: a scroll container with a vertical stack of cards
- (void)setupBentoLayout {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.scrollView];

    self.bentoStack = [[UIStackView alloc] init];
    self.bentoStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.bentoStack.axis = UILayoutConstraintAxisVertical;
    self.bentoStack.spacing = 12;
    self.bentoStack.alignment = UIStackViewAlignmentFill;
    self.bentoStack.distribution = UIStackViewDistributionFill;
    [self.scrollView addSubview:self.bentoStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],

        [self.bentoStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:12],
        [self.bentoStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [self.bentoStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [self.bentoStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-12],

        [self.bentoStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    [self setupHeaderCard];
    [self setupPhaseCard];
    [self setupContentCard];
    [self setupActionCard];
}

/// Build one Bento-style card view (16pt corner radius, a light background, adapting to light/dark)
- (UIView *)makeBentoCard {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    return card;
}

/// Header card at the top: title + close button
- (void)setupHeaderCard {
    self.headerCard = [self makeBentoCard];
    [self.bentoStack addArrangedSubview:self.headerCard];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"Mod updates";
    self.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    self.titleLabel.adjustsFontForContentSizeCategory = YES;
    [self.headerCard addSubview:self.titleLabel];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    self.closeButton.tintColor = [UIColor secondaryLabelColor];
    self.closeButton.adjustsImageWhenDisabled = NO;
    [self.closeButton addTarget:self action:@selector(closeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.headerCard addSubview:self.closeButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerCard.heightAnchor constraintGreaterThanOrEqualToConstant:56],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.headerCard.leadingAnchor constant:16],
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.headerCard.centerYAnchor],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.closeButton.leadingAnchor constant:-8],

        [self.closeButton.trailingAnchor constraintEqualToAnchor:self.headerCard.trailingAnchor constant:-16],
        [self.closeButton.centerYAnchor constraintEqualToAnchor:self.headerCard.centerYAnchor],
        [self.closeButton.widthAnchor constraintEqualToConstant:30],
        [self.closeButton.heightAnchor constraintEqualToConstant:30],
    ]];
}

/// Stage status card: the stage name + a progress bar + the current file name
- (void)setupPhaseCard {
    self.phaseCard = [self makeBentoCard];
    [self.bentoStack addArrangedSubview:self.phaseCard];

    self.phaseTitleLabel = [[UILabel alloc] init];
    self.phaseTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.phaseTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.phaseTitleLabel.adjustsFontForContentSizeCategory = YES;
    self.phaseTitleLabel.numberOfLines = 0;
    [self.phaseCard addSubview:self.phaseTitleLabel];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progressTintColor = [UIColor systemBlueColor];
    [self.phaseCard addSubview:self.progressView];

    self.currentFileLabel = [[UILabel alloc] init];
    self.currentFileLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.currentFileLabel.font = [UIFont systemFontOfSize:13];
    self.currentFileLabel.adjustsFontForContentSizeCategory = YES;
    self.currentFileLabel.textColor = [UIColor secondaryLabelColor];
    self.currentFileLabel.numberOfLines = 1;
    self.currentFileLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.phaseCard addSubview:self.currentFileLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.phaseCard.heightAnchor constraintGreaterThanOrEqualToConstant:96],

        [self.phaseTitleLabel.topAnchor constraintEqualToAnchor:self.phaseCard.topAnchor constant:14],
        [self.phaseTitleLabel.leadingAnchor constraintEqualToAnchor:self.phaseCard.leadingAnchor constant:16],
        [self.phaseTitleLabel.trailingAnchor constraintEqualToAnchor:self.phaseCard.trailingAnchor constant:-16],

        [self.progressView.topAnchor constraintEqualToAnchor:self.phaseTitleLabel.bottomAnchor constant:10],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.phaseCard.leadingAnchor constant:16],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.phaseCard.trailingAnchor constant:-16],
        [self.progressView.heightAnchor constraintEqualToConstant:6],

        [self.currentFileLabel.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:8],
        [self.currentFileLabel.leadingAnchor constraintEqualToAnchor:self.phaseCard.leadingAnchor constant:16],
        [self.currentFileLabel.trailingAnchor constraintEqualToAnchor:self.phaseCard.trailingAnchor constant:-16],
        [self.currentFileLabel.bottomAnchor constraintEqualToAnchor:self.phaseCard.bottomAnchor constant:-14],
    ]];
}

/// Content card: holds the table and the empty state view
- (void)setupContentCard {
    self.contentCard = [self makeBentoCard];
    [self.bentoStack addArrangedSubview:self.contentCard];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"PlainCell"];
    [self.contentCard addSubview:self.tableView];

    self.emptyStateView = [[UIView alloc] init];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentCard addSubview:self.emptyStateView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.adjustsFontForContentSizeCategory = YES;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    [self.emptyStateView addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.contentCard.heightAnchor constraintGreaterThanOrEqualToConstant:240],

        [self.tableView.topAnchor constraintEqualToAnchor:self.contentCard.topAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.contentCard.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.contentCard.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.contentCard.bottomAnchor constant:-8],

        [self.emptyStateView.topAnchor constraintEqualToAnchor:self.contentCard.topAnchor],
        [self.emptyStateView.leadingAnchor constraintEqualToAnchor:self.contentCard.leadingAnchor],
        [self.emptyStateView.trailingAnchor constraintEqualToAnchor:self.contentCard.trailingAnchor],
        [self.emptyStateView.bottomAnchor constraintEqualToAnchor:self.contentCard.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.emptyStateView.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.emptyStateView.leadingAnchor constant:24],
        [self.emptyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.emptyStateView.trailingAnchor constant:-24],
    ]];
}

/// Action button card: a primary and a secondary button (Material Design 3 style)
- (void)setupActionCard {
    self.actionCard = [self makeBentoCard];
    [self.bentoStack addArrangedSubview:self.actionCard];

    self.primaryButton = [self makeFilledButtonWithTitle:@""];
    [self.primaryButton addTarget:self action:@selector(primaryButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.actionCard addSubview:self.primaryButton];

    self.secondaryButton = [self makeOutlinedButtonWithTitle:@""];
    [self.secondaryButton addTarget:self action:@selector(secondaryButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.actionCard addSubview:self.secondaryButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.actionCard.heightAnchor constraintGreaterThanOrEqualToConstant:60],

        [self.primaryButton.topAnchor constraintEqualToAnchor:self.actionCard.topAnchor constant:12],
        [self.primaryButton.leadingAnchor constraintEqualToAnchor:self.actionCard.leadingAnchor constant:16],
        [self.primaryButton.trailingAnchor constraintEqualToAnchor:self.actionCard.trailingAnchor constant:-16],
        [self.primaryButton.heightAnchor constraintEqualToConstant:46],

        [self.secondaryButton.topAnchor constraintEqualToAnchor:self.primaryButton.bottomAnchor constant:10],
        [self.secondaryButton.leadingAnchor constraintEqualToAnchor:self.actionCard.leadingAnchor constant:16],
        [self.secondaryButton.trailingAnchor constraintEqualToAnchor:self.actionCard.trailingAnchor constant:-16],
        [self.secondaryButton.heightAnchor constraintEqualToConstant:44],
        [self.secondaryButton.bottomAnchor constraintEqualToAnchor:self.actionCard.bottomAnchor constant:-12],
    ]];
}

/// Material Design 3 filled primary button
- (UIButton *)makeFilledButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.backgroundColor = [UIColor systemBlueColor];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.layer.cornerRadius = 12;
    button.layer.masksToBounds = YES;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
    return button;
}

/// Material Design 3 outlined secondary button
- (UIButton *)makeOutlinedButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.backgroundColor = [UIColor clearColor];
    [button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    button.layer.cornerRadius = 12;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor separatorColor].CGColor;
    button.layer.masksToBounds = YES;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
    return button;
}

#pragma mark - Stage transitions

/// Move to the given stage and refresh the UI
- (void)transitionToPhase:(ModUpdatePhase)phase {
    self.currentPhase = phase;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshUIForCurrentPhase];
    });

    switch (phase) {
        case ModUpdatePhasePrepare:
            [self startPhase0Prepare];
            break;
        case ModUpdatePhaseCheck:
            [self startPhase1Check];
            break;
        case ModUpdatePhaseConfirm:
            [self startPhase2Confirm];
            break;
        case ModUpdatePhaseDownload:
            [self startPhase3Download];
            break;
        case ModUpdatePhaseReplace:
            [self startPhase4Replace];
            break;
        case ModUpdatePhaseDone:
            [self startPhase5Done];
            break;
    }
}

/// Refresh the UI elements for the current stage
- (void)refreshUIForCurrentPhase {
    [self updatePhaseCardForCurrentPhase];
    [self updateActionCardForCurrentPhase];
    [self updateContentCardForCurrentPhase];
    [self.tableView reloadData];
}

/// Update the stage status card
- (void)updatePhaseCardForCurrentPhase {
    switch (self.currentPhase) {
        case ModUpdatePhasePrepare:
            self.phaseTitleLabel.text = @"Preparing...";
            self.progressView.hidden = YES;
            self.currentFileLabel.text = @"";
            break;
        case ModUpdatePhaseCheck:
            self.phaseTitleLabel.text = [NSString stringWithFormat:@"Checking for updates (%ld/%ld)",
                                         (long)self.checkCompleted, (long)self.filteredMods.count];
            self.progressView.hidden = NO;
            self.currentFileLabel.text = @"Checking concurrently...";
            break;
        case ModUpdatePhaseConfirm:
            self.phaseTitleLabel.text = @"Confirm which mods to update";
            self.progressView.hidden = YES;
            self.currentFileLabel.text = @"";
            break;
        case ModUpdatePhaseDownload:
            self.phaseTitleLabel.text = [NSString stringWithFormat:@"Downloading (%ld/%ld)",
                                         (long)self.downloadCompleted, (long)self.downloadTotal];
            self.progressView.hidden = NO;
            break;
        case ModUpdatePhaseReplace:
            self.phaseTitleLabel.text = @"Replacing files...";
            self.progressView.hidden = YES;
            self.currentFileLabel.text = @"";
            break;
        case ModUpdatePhaseDone:
            self.phaseTitleLabel.text = [NSString stringWithFormat:@"Update finished (%ld succeeded, %ld failed)",
                                         (long)self.successCount, (long)self.failureCount];
            self.progressView.hidden = YES;
            self.currentFileLabel.text = @"";
            break;
    }
}

/// Update the action button card
- (void)updateActionCardForCurrentPhase {
    switch (self.currentPhase) {
        case ModUpdatePhasePrepare:
        case ModUpdatePhaseCheck:
        case ModUpdatePhaseDownload:
        case ModUpdatePhaseReplace:
            // An automatic stage, so hide the action buttons
            self.actionCard.hidden = YES;
            break;
        case ModUpdatePhaseConfirm: {
            self.actionCard.hidden = NO;
            if (self.selections.count == 0) {
                // No updates available
                [self.primaryButton setTitle:@"Close" forState:UIControlStateNormal];
                self.primaryButton.userInteractionEnabled = YES;
                self.secondaryButton.hidden = YES;
            } else {
                NSInteger selectedCount = [self selectedCount];
                [self.primaryButton setTitle:[NSString stringWithFormat:@"Update %ld selected", (long)selectedCount]
                                    forState:UIControlStateNormal];
                self.primaryButton.userInteractionEnabled = (selectedCount > 0);
                self.secondaryButton.hidden = NO;
                [self.secondaryButton setTitle:@"Cancel" forState:UIControlStateNormal];
            }
            break;
        }
        case ModUpdatePhaseDone:
            self.actionCard.hidden = NO;
            [self.primaryButton setTitle:@"Close" forState:UIControlStateNormal];
            self.primaryButton.userInteractionEnabled = YES;
            self.secondaryButton.hidden = YES;
            break;
    }
}

/// Update the content card display
- (void)updateContentCardForCurrentPhase {
    BOOL showEmpty = NO;
    NSString *emptyText = @"";

    switch (self.currentPhase) {
        case ModUpdatePhasePrepare:
            showEmpty = YES;
            emptyText = @"Preparing the mod list...";
            break;
        case ModUpdatePhaseCheck:
            if (self.filteredMods.count == 0) {
                showEmpty = YES;
                emptyText = @"No mods to check";
            }
            break;
        case ModUpdatePhaseConfirm:
            if (self.selections.count == 0) {
                showEmpty = YES;
                emptyText = @"All mods are up to date";
            }
            break;
        case ModUpdatePhaseDownload:
            if (self.downloadTasks.count == 0) {
                showEmpty = YES;
                emptyText = @"Nothing to download";
            }
            break;
        case ModUpdatePhaseReplace:
            showEmpty = YES;
            emptyText = @"Replacing files...";
            break;
        case ModUpdatePhaseDone:
            if (self.failureCount == 0) {
                showEmpty = YES;
                emptyText = [NSString stringWithFormat:@"Updated %ld mod(s) successfully", (long)self.successCount];
            }
            break;
    }

    self.emptyLabel.text = emptyText;
    self.emptyStateView.hidden = !showEmpty;
    self.tableView.hidden = showEmpty;
}

#pragma mark - Stage 0: preparation

- (void)startPhase0Prepare {
    // Filter out entries with no filePath
    NSMutableArray<ModItem *> *filtered = [NSMutableArray array];
    for (ModItem *mod in self.inputMods) {
        if (mod.filePath.length > 0) {
            [filtered addObject:mod];
        }
    }
    self.filteredMods = [filtered copy];
    self.checkCompleted = 0;

    // A brief delay so the user sees the preparation stage
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.filteredMods.count == 0) {
            // There are no mods to check, so go straight to the done stage
            self.successCount = 0;
            self.failureCount = 0;
            [self.failedFileNames removeAllObjects];
            [self transitionToPhase:ModUpdatePhaseDone];
        } else {
            [self transitionToPhase:ModUpdatePhaseCheck];
        }
    });
}

#pragma mark - Stage 1: concurrent update checks

- (void)startPhase1Check {
    self.progressView.progress = 0;
    self.progressView.hidden = NO;

    __weak typeof(self) weakSelf = self;
    [[ModUpdateService sharedService] checkUpdatesForMods:self.filteredMods
                                            gameVersion:self.gameVersion
                                                 loader:self.loader
                                            projectType:self.projectType
                                               progress:^(NSInteger completed, NSInteger total) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.checkCompleted = completed;
            if (total > 0) {
                strongSelf.progressView.progress = (float)completed / (float)total;
            }
            [strongSelf updatePhaseCardForCurrentPhase];
            [strongSelf.tableView reloadData];
        });
    } completion:^(NSArray<ModUpdateResult *> *results) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.checkResults = [results copy] ?: @[];
            strongSelf.progressView.progress = 1.0;
            [strongSelf transitionToPhase:ModUpdatePhaseConfirm];
        });
    }];
}

#pragma mark - Stage 2: user confirmation

- (void)startPhase2Confirm {
    // Build the selection list from checkResults, with everything selected by default
    [self.selections removeAllObjects];
    for (ModUpdateResult *result in self.checkResults) {
        if (![result hasUpdate]) continue;
        ModUpdateSelection *sel = [[ModUpdateSelection alloc] init];
        sel.result = result;
        sel.selected = YES;
        sel.expanded = NO;
        sel.chosenVersion = result.candidateVersions.firstObject;
        [self.selections addObject:sel];
    }
    [self refreshUIForCurrentPhase];
}

/// The number of entries currently selected
- (NSInteger)selectedCount {
    NSInteger count = 0;
    for (ModUpdateSelection *sel in self.selections) {
        if (sel.selected) count++;
    }
    return count;
}

#pragma mark - Stage 3: concurrent downloads (limited to 16, with one retry on failure)

- (void)startPhase3Download {
    // Collect the selected entries
    NSArray<ModUpdateSelection *> *selected = [self.selections filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(ModUpdateSelection *sel, NSDictionary *_) {
            return sel.selected && sel.result && sel.chosenVersion;
        }]];

    if (selected.count == 0) {
        // Nothing is selected, so go straight to the done stage
        self.successCount = 0;
        self.failureCount = 0;
        [self.failedFileNames removeAllObjects];
        [self transitionToPhase:ModUpdatePhaseDone];
        return;
    }

    // Create a temporary directory
    self.tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ModUpdate_%@", [[NSUUID UUID] UUIDString]]];
    NSError *mkError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.tempDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&mkError];
    if (mkError) {
        // The temporary directory could not be created, so mark everything as failed
        self.successCount = 0;
        self.failureCount = (NSInteger)selected.count;
        [self.failedFileNames removeAllObjects];
        for (ModUpdateSelection *sel in selected) {
            [self.failedFileNames addObject:[self fileNameForSelection:sel]];
        }
        [self transitionToPhase:ModUpdatePhaseDone];
        return;
    }

    // Create the NSURLSession (with this controller as its delegate)
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.HTTPMaximumConnectionsPerHost = 16;
    config.timeoutIntervalForRequest = 60;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];

    // Initialize the download task list
    [self.downloadTasks removeAllObjects];
    for (ModUpdateSelection *sel in selected) {
        ModDownloadTaskInfo *info = [[ModDownloadTaskInfo alloc] init];
        info.result = sel.result;
        info.targetVersion = sel.chosenVersion;
        info.fileName = [self fileNameForSelection:sel];
        info.progress = [NSProgress progressWithTotalUnitCount:-1];
        info.succeeded = NO;
        info.retried = NO;
        [self.downloadTasks addObject:info];
    }

    self.downloadCompleted = 0;
    self.downloadTotal = (NSInteger)self.downloadTasks.count;
    self.progressView.progress = 0;
    [self refreshUIForCurrentPhase];

    // Concurrency limited to 16, controlled by a semaphore
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(16);
    dispatch_queue_t workQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __weak typeof(self) weakSelf = self;

    for (ModDownloadTaskInfo *info in self.downloadTasks) {
        dispatch_async(workQueue, ^{
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
            // Create and start the download task on the main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) {
                    dispatch_semaphore_signal(semaphore);
                    return;
                }
                [strongSelf createAndStartDownloadTaskForInfo:info semaphore:semaphore];
            });
        });
    }
}

/// Create and start the download task for the given info
- (void)createAndStartDownloadTaskForInfo:(ModDownloadTaskInfo *)info
                                semaphore:(dispatch_semaphore_t)semaphore {
    NSString *urlString = [self downloadURLStringForVersion:info.targetVersion];
    if (urlString.length == 0) {
        // An invalid download link, so mark it as failed
        info.succeeded = NO;
        [self onDownloadTaskFinished:info semaphore:semaphore];
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        info.succeeded = NO;
        [self onDownloadTaskFinished:info semaphore:semaphore];
        return;
    }

    NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:url];
    info.task = task;
    // Bind info to the task through an associated object, so it can be read back in the delegate callbacks
    objc_setAssociatedObject(task, &kDownloadTaskInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(task, &kDownloadSemaphoreKey, semaphore, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [task resume];

    // Update the current file name display
    self.currentFileLabel.text = info.fileName;
}

/// Shared handling for one download task finishing (successfully or not)
/// Note: this may be called from the background delegate queue of NSURLSession, so UI updates must be dispatched to the main thread
- (void)onDownloadTaskFinished:(ModDownloadTaskInfo *)info
                     semaphore:(dispatch_semaphore_t)semaphore {
    self.downloadCompleted += 1;
    NSInteger completed = self.downloadCompleted;
    NSInteger total = self.downloadTotal;

    // Dispatch the UI update to the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        if (total > 0) {
            self.progressView.progress = (float)completed / (float)total;
        }
        [self updatePhaseCardForCurrentPhase];
        [self.tableView reloadData];
    });

    // Release the semaphore so the next task can start
    dispatch_semaphore_signal(semaphore);

    // Move to the replace stage once everything is done
    if (completed >= total) {
        [self transitionToPhase:ModUpdatePhaseReplace];
    }
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    // The download finished, so move the file into our temporary directory
    ModDownloadTaskInfo *info = objc_getAssociatedObject(downloadTask, &kDownloadTaskInfoKey);
    if (!info) return;

    NSString *destName = info.fileName.length > 0 ? info.fileName :
        [NSString stringWithFormat:@"%@.jar", [[NSUUID UUID] UUIDString]];
    NSString *destPath = [self.tempDir stringByAppendingPathComponent:destName];

    // Remove the destination first if it already exists (overwriting a same-named file)
    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];

    NSError *moveError = nil;
    [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destPath] error:&moveError];
    if (moveError) {
        // The move failed, so mark it as unsuccessful
        info.succeeded = NO;
        info.tempFilePath = nil;
        return;
    }

    info.tempFilePath = destPath;
    info.succeeded = YES;
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    ModDownloadTaskInfo *info = objc_getAssociatedObject(downloadTask, &kDownloadTaskInfoKey);
    if (!info) return;
    if (totalBytesExpectedToWrite > 0) {
        info.progress.totalUnitCount = totalBytesExpectedToWrite;
        info.progress.completedUnitCount = totalBytesWritten;
    }
    // Refresh the table with throttling (dispatched to the main thread from the serial queue)
    dispatch_async(self.callbackQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            // Only update the visible rows, to avoid frequent full reloads
            if (self.currentPhase == ModUpdatePhaseDownload) {
                [self.tableView reloadData];
            }
        });
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (![task isKindOfClass:[NSURLSessionDownloadTask class]]) return;
    NSURLSessionDownloadTask *downloadTask = (NSURLSessionDownloadTask *)task;
    ModDownloadTaskInfo *info = objc_getAssociatedObject(downloadTask, &kDownloadTaskInfoKey);
    dispatch_semaphore_t semaphore = objc_getAssociatedObject(downloadTask, &kDownloadSemaphoreKey);

    if (!info) return;

    if (error == nil) {
        // Success (tempFilePath was set in didFinishDownloadingToURL)
        if (!info.succeeded) {
            // In the rare case where didFinish did not set the success state, treat it as a failure here
            info.succeeded = NO;
        }
        [self onDownloadTaskFinished:info semaphore:semaphore];
        return;
    }

    // Failure: retry once automatically if it has not been retried yet
    if (!info.retried) {
        info.retried = YES;
        info.succeeded = NO;
        info.tempFilePath = nil;
        // Recreate and start the download task (a retry does not take a new semaphore slot; it reuses the existing one)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self createAndStartDownloadTaskForInfo:info semaphore:semaphore];
        });
        return;
    }

    // Already retried and still failing, so mark it as failed
    info.succeeded = NO;
    [self onDownloadTaskFinished:info semaphore:semaphore];
}

#pragma mark - Stage 4: replacing the files

- (void)startPhase4Replace {
    // Decide what to do with the old file from the modUpdateKeepOld preference
    BOOL keepOld = [PLPreferences modUpdateKeepOld];

    self.successCount = 0;
    self.failureCount = 0;
    [self.failedFileNames removeAllObjects];

    NSFileManager *fm = [NSFileManager defaultManager];

    for (ModDownloadTaskInfo *info in self.downloadTasks) {
        NSString *fileName = info.fileName.length > 0 ? info.fileName : [info.result.localFilePath lastPathComponent];

        if (!info.succeeded || info.tempFilePath.length == 0 || !info.result.localFilePath) {
            self.failureCount += 1;
            [self.failedFileNames addObject:fileName];
            continue;
        }

        NSString *oldPath = info.result.localFilePath;
        NSString *oldDir = [oldPath stringByDeletingLastPathComponent];
        NSString *newPath = [oldDir stringByAppendingPathComponent:fileName];

        @try {
            // Handle the old file
            if ([fm fileExistsAtPath:oldPath]) {
                if (keepOld) {
                    // Keep the old file: rename it to <original name>.old
                    NSString *oldBackupPath = [oldPath stringByAppendingString:@".old"];
                    // If the .old file already exists, delete it first
                    [fm removeItemAtPath:oldBackupPath error:nil];
                    NSError *renameError = nil;
                    [fm moveItemAtPath:oldPath toPath:oldBackupPath error:&renameError];
                    if (renameError) {
                        // If renaming fails, try deleting instead
                        [fm removeItemAtPath:oldPath error:nil];
                    }
                } else {
                    // Do not keep it: delete the old file outright
                    [fm removeItemAtPath:oldPath error:nil];
                }
            }

            // If a file with the same name already exists at the destination (when it differs from the old file name), remove it first
            if (![newPath isEqualToString:oldPath] && [fm fileExistsAtPath:newPath]) {
                [fm removeItemAtPath:newPath error:nil];
            }

            // Move the new file from the temporary directory into the mods folder
            NSError *moveError = nil;
            [fm moveItemAtPath:info.tempFilePath toPath:newPath error:&moveError];
            if (moveError) {
                self.failureCount += 1;
                [self.failedFileNames addObject:fileName];
            } else {
                self.successCount += 1;
                info.tempFilePath = nil; // Already moved, so clear it to avoid deleting it by mistake later
            }
        } @catch (NSException *exception) {
            self.failureCount += 1;
            [self.failedFileNames addObject:fileName];
        }
    }

    // Move to the done stage
    [self transitionToPhase:ModUpdatePhaseDone];
}

#pragma mark - Stage 5: completion

- (void)startPhase5Done {
    // Nothing extra to do; the UI refresh is dispatched to the main thread by transitionToPhase:
}

#pragma mark - UITableViewDataSource / UITableViewDelegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    switch (self.currentPhase) {
        case ModUpdatePhaseCheck:
            return 1;
        case ModUpdatePhaseConfirm:
            return (NSInteger)self.selections.count;
        case ModUpdatePhaseDownload:
            return 1;
        case ModUpdatePhaseDone:
            return (self.failureCount > 0) ? 1 : 0;
        default:
            return 0;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (self.currentPhase) {
        case ModUpdatePhaseCheck:
            return (NSInteger)self.filteredMods.count;
        case ModUpdatePhaseConfirm: {
            if (section >= (NSInteger)self.selections.count) return 0;
            ModUpdateSelection *sel = self.selections[section];
            return sel.expanded ? (1 + (NSInteger)sel.result.allVersions.count) : 1;
        }
        case ModUpdatePhaseDownload:
            return (NSInteger)self.downloadTasks.count;
        case ModUpdatePhaseDone:
            return (NSInteger)self.failedFileNames.count;
        default:
            return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (self.currentPhase) {
        case ModUpdatePhaseCheck:
            return [self checkCellForRowAtIndexPath:indexPath];
        case ModUpdatePhaseConfirm:
            return [self confirmCellForRowAtIndexPath:indexPath];
        case ModUpdatePhaseDownload:
            return [self downloadCellForRowAtIndexPath:indexPath];
        case ModUpdatePhaseDone:
            return [self doneCellForRowAtIndexPath:indexPath];
        default:
            return [[UITableViewCell alloc] init];
    }
}

/// Stage 1: the cell for the list of files being checked
- (UITableViewCell *)checkCellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"PlainCell" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
    cell.imageView.image = nil;

    if (indexPath.row >= (NSInteger)self.filteredMods.count) return cell;
    ModItem *mod = self.filteredMods[indexPath.row];

    // Use a real animated indicator as the accessoryView
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    cell.accessoryView = spinner;

    cell.textLabel.text = mod.fileName ?: mod.displayName ?: mod.basename ?: mod.filePath.lastPathComponent;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    cell.detailTextLabel.text = nil;
    return cell;
}

/// Stage 2: the user confirmation cell (a summary on the first row, version options on the rest)
- (UITableViewCell *)confirmCellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"PlainCell" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;

    if (indexPath.section >= (NSInteger)self.selections.count) return cell;
    ModUpdateSelection *sel = self.selections[indexPath.section];
    ModUpdateResult *result = sel.result;

    if (indexPath.row == 0) {
        // Summary row: the checkbox + file name + version change + source + expand indicator
        NSString *fileName = result.localFilePath.lastPathComponent ?: @"Unknown file";
        NSString *currentVer = result.currentVersion.versionNumber ?: @"Unknown version";
        NSString *targetVer = sel.chosenVersion.versionNumber ?: @"Latest version";
        NSString *source = [self sourceNameForResult:result];

        // Use a UISwitch as the accessoryView
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = sel.selected;
        sw.tag = indexPath.section;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;

        // Expand indicator icon
        UIImage *chevron = [UIImage systemImageNamed:sel.expanded ? @"chevron.up" : @"chevron.down"];
        cell.imageView.image = chevron;
        cell.imageView.tintColor = [UIColor secondaryLabelColor];

        cell.textLabel.text = fileName;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.textLabel.numberOfLines = 1;
        cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ → %@  ·  %@", currentVer, targetVer, source];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 1;
        return cell;
    }

    // Version option row: the selection indicator + version number + publication date
    NSInteger versionIndex = indexPath.row - 1;
    if (versionIndex >= (NSInteger)result.allVersions.count) return cell;
    ModVersion *version = result.allVersions[versionIndex];

    BOOL isChosen = (sel.chosenVersion == version);
    UIImage *radio = [UIImage systemImageNamed:isChosen ? @"largecircle.fill.circle" : @"circle"];
    cell.imageView.image = radio;
    cell.imageView.tintColor = [UIColor systemBlueColor];

    cell.textLabel.text = version.versionNumber ?: version.name ?: @"Unknown version";
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.textColor = isChosen ? [UIColor labelColor] : [UIColor secondaryLabelColor];

    NSString *dateText = version.datePublished.length > 0 ? version.datePublished : @"";
    cell.detailTextLabel.text = dateText;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];

    return cell;
}

/// Stage 3: the download progress list cell
- (UITableViewCell *)downloadCellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"PlainCell" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.row >= (NSInteger)self.downloadTasks.count) return cell;
    ModDownloadTaskInfo *info = self.downloadTasks[indexPath.row];

    // Work out whether the task has finished (successfully or with a final failure)
    BOOL finished = info.succeeded || (info.retried && !info.succeeded && info.task == nil);
    if (info.succeeded) {
        cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        cell.imageView.tintColor = [UIColor systemGreenColor];
        cell.accessoryView = nil;
    } else if (finished) {
        // Finished but unsuccessful
        cell.imageView.image = [UIImage systemImageNamed:@"xmark.circle.fill"];
        cell.imageView.tintColor = [UIColor systemRedColor];
        cell.accessoryView = nil;
    } else {
        // In progress: use a real animated indicator
        cell.imageView.image = nil;
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    }

    cell.textLabel.text = info.fileName ?: @"Unknown file";
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    // Progress text
    int64_t completed = info.progress.completedUnitCount;
    int64_t total = info.progress.totalUnitCount;
    NSString *progressText = nil;
    if (info.succeeded) {
        progressText = @"Completed";
    } else if (finished) {
        progressText = @"Failed";
    } else if (total > 0) {
        float ratio = (float)completed / (float)total;
        progressText = [NSString stringWithFormat:@"%d%%", (int)(ratio * 100)];
    } else if (info.retried) {
        progressText = @"Retrying...";
    } else {
        progressText = @"Downloading...";
    }
    cell.detailTextLabel.text = progressText;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    return cell;
}

/// Stage 5: the cell for a failed entry in the done stage
- (UITableViewCell *)doneCellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"PlainCell" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.row >= (NSInteger)self.failedFileNames.count) return cell;
    cell.imageView.image = [UIImage systemImageNamed:@"xmark.circle.fill"];
    cell.imageView.tintColor = [UIColor systemRedColor];
    cell.textLabel.text = self.failedFileNames[indexPath.row];
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    cell.detailTextLabel.text = @"Update failed";
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.currentPhase != ModUpdatePhaseConfirm) return;
    if (indexPath.section >= (NSInteger)self.selections.count) return;
    ModUpdateSelection *sel = self.selections[indexPath.section];

    if (indexPath.row == 0) {
        // Tapping the summary row toggles expanded/collapsed
        sel.expanded = !sel.expanded;
        NSIndexSet *indexSet = [NSIndexSet indexSetWithIndex:indexPath.section];
        [tableView reloadSections:indexSet withRowAnimation:UITableViewRowAnimationAutomatic];
    } else {
        // Tapping a version row picks that downgrade target
        NSInteger versionIndex = indexPath.row - 1;
        if (versionIndex < (NSInteger)sel.result.allVersions.count) {
            sel.chosenVersion = sel.result.allVersions[versionIndex];
            sel.expanded = NO;
            NSIndexSet *indexSet = [NSIndexSet indexSetWithIndex:indexPath.section];
            [tableView reloadSections:indexSet withRowAnimation:UITableViewRowAnimationAutomatic];
            [self updateActionCardForCurrentPhase];
        }
    }
}

#pragma mark - Interaction events

/// The checkbox switch changed
- (void)switchChanged:(UISwitch *)sw {
    if (sw.tag >= (NSInteger)self.selections.count) return;
    ModUpdateSelection *sel = self.selections[sw.tag];
    sel.selected = sw.on;
    [self updateActionCardForCurrentPhase];
}

- (void)closeButtonTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)primaryButtonTapped {
    switch (self.currentPhase) {
        case ModUpdatePhaseConfirm:
            if (self.selections.count == 0) {
                [self dismissViewControllerAnimated:YES completion:nil];
            } else {
                [self transitionToPhase:ModUpdatePhaseDownload];
            }
            break;
        case ModUpdatePhaseDone:
            [self dismissViewControllerAnimated:YES completion:nil];
            break;
        default:
            break;
    }
}

- (void)secondaryButtonTapped {
    if (self.currentPhase == ModUpdatePhaseConfirm) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - Utility methods

/// Extract the download URL from a ModVersion
- (nullable NSString *)downloadURLStringForVersion:(ModVersion *)version {
    if (!version) return nil;
    NSDictionary *pf = version.primaryFile;
    if (![pf isKindOfClass:[NSDictionary class]]) return nil;
    NSString *url = [pf[@"url"] isKindOfClass:[NSString class]] ? pf[@"url"] : nil;
    return url.length > 0 ? url : nil;
}

/// Extract the file name from a ModVersion
- (nullable NSString *)fileNameForVersion:(ModVersion *)version {
    if (!version) return nil;
    NSDictionary *pf = version.primaryFile;
    if (![pf isKindOfClass:[NSDictionary class]]) return nil;
    NSString *name = [pf[@"filename"] isKindOfClass:[NSString class]] ? pf[@"filename"] : nil;
    return name.length > 0 ? name : nil;
}

/// The display file name of a selected entry
- (NSString *)fileNameForSelection:(ModUpdateSelection *)sel {
    NSString *name = [self fileNameForVersion:sel.chosenVersion];
    if (name.length > 0) return name;
    return sel.result.localFilePath.lastPathComponent ?: @"Unknown file";
}

/// Return the source name
- (NSString *)sourceNameForResult:(ModUpdateResult *)result {
    NSNumber *src = result.apiSource;
    if (src && [src isKindOfClass:[NSNumber class]] && [src integerValue] == 2) {
        return @"CurseForge";
    }
    return @"Modrinth";
}

@end
