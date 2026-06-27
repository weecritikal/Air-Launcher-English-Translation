//
//  ModUpdateViewController.m
//  Amethyst
//
//  Mod 更新/降级多阶段任务流页面（Bento Grid + Material Design 3 风格）
//

#import "ModUpdateViewController.h"
#import "ModUpdateService.h"
#import "ModVersion.h"
#import "PLPreferences.h"
#import "ModService.h"
#import <objc/runtime.h>

/// 关联对象 key：下载任务对应的 ModDownloadTaskInfo
static void *kDownloadTaskInfoKey = &kDownloadTaskInfoKey;
/// 关联对象 key：下载任务对应的并发信号量
static void *kDownloadSemaphoreKey = &kDownloadSemaphoreKey;

/// 多阶段任务流的阶段定义
typedef NS_ENUM(NSInteger, ModUpdatePhase) {
    ModUpdatePhasePrepare  = 0, // 阶段 0：准备（过滤 mods）
    ModUpdatePhaseCheck    = 1, // 阶段 1：并发检查更新（限流 3）
    ModUpdatePhaseConfirm  = 2, // 阶段 2：用户确认（可勾选 + 降级选择）
    ModUpdatePhaseDownload = 3, // 阶段 3：并发下载（限流 16，失败重试一次）
    ModUpdatePhaseReplace  = 4, // 阶段 4：替换文件（依据 modUpdateKeepOld 偏好）
    ModUpdatePhaseDone     = 5, // 阶段 5：完成（结果汇总）
};

#pragma mark - 辅助模型：用户确认阶段的选中项

/// 用于阶段 2 用户确认阶段的可勾选项
@interface ModUpdateSelection : NSObject
@property (nonatomic, strong, nullable) ModUpdateResult *result;
@property (nonatomic, assign) BOOL selected;                       // 是否选中（默认 YES）
@property (nonatomic, assign) BOOL expanded;                       // 是否展开版本列表
@property (nonatomic, strong, nullable) ModVersion *chosenVersion; // 用户选择的目标版本（默认 candidateVersions.firstObject）
@end

@implementation ModUpdateSelection
@end

#pragma mark - 辅助模型：下载任务跟踪

/// 用于阶段 3 并发下载的任务跟踪
@interface ModDownloadTaskInfo : NSObject
@property (nonatomic, copy, nullable) NSString *fileName;
@property (nonatomic, strong, nullable) ModUpdateResult *result;
@property (nonatomic, strong, nullable) ModVersion *targetVersion;
@property (nonatomic, strong, nullable) NSProgress *progress;
@property (nonatomic, copy, nullable) NSString *tempFilePath; // 下载完成后的临时文件路径
@property (nonatomic, assign) BOOL succeeded;
@property (nonatomic, assign) BOOL retried;                   // 是否已重试过一次
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *task;
@end

@implementation ModDownloadTaskInfo
@end

#pragma mark - ModUpdateViewController 类扩展

@interface ModUpdateViewController () <UITableViewDataSource, UITableViewDelegate, NSURLSessionDownloadDelegate>

// 输入参数
@property (nonatomic, copy) NSArray<ModItem *> *inputMods;
@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, copy, nullable) NSString *loader;
@property (nonatomic, copy) NSString *projectType;

// 阶段 0 产出：过滤后的 mods（去掉无 filePath 的项）
@property (nonatomic, copy) NSArray<ModItem *> *filteredMods;

// 当前阶段
@property (nonatomic, assign) ModUpdatePhase currentPhase;

// 阶段 1：检查结果
@property (nonatomic, copy) NSArray<ModUpdateResult *> *checkResults;

// 阶段 2：用户确认阶段的选中项
@property (nonatomic, strong) NSMutableArray<ModUpdateSelection *> *selections;

// 阶段 3：下载任务列表
@property (nonatomic, strong) NSMutableArray<ModDownloadTaskInfo *> *downloadTasks;
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t callbackQueue;
@property (nonatomic, copy, nullable) NSString *tempDir;
@property (nonatomic, assign) NSInteger downloadCompleted;
@property (nonatomic, assign) NSInteger downloadTotal;

// 阶段 1：检查更新进度跟踪
@property (nonatomic, assign) NSInteger checkCompleted;
@property (nonatomic, assign) NSInteger checkTotal;

// 阶段 4/5：结果统计
@property (nonatomic, assign) NSInteger successCount;
@property (nonatomic, assign) NSInteger failureCount;
@property (nonatomic, copy) NSMutableArray<NSString *> *failedFileNames;

// UI：Bento Grid 容器
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *bentoStack;

// UI：顶部头卡片
@property (nonatomic, strong) UIView *headerCard;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeButton;

// UI：阶段状态卡片
@property (nonatomic, strong) UIView *phaseCard;
@property (nonatomic, strong) UILabel *phaseTitleLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *currentFileLabel;

// UI：内容卡片（表格 / 空态）
@property (nonatomic, strong) UIView *contentCard;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UILabel *emptyLabel;

// UI：操作按钮卡片
@property (nonatomic, strong) UIView *actionCard;
@property (nonatomic, strong) UIButton *primaryButton;
@property (nonatomic, strong) UIButton *secondaryButton;

@end

@implementation ModUpdateViewController

#pragma mark - 初始化

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
    // 清理临时目录
    if (self.tempDir) {
        [[NSFileManager defaultManager] removeItemAtPath:self.tempDir error:nil];
    }
    // 取消并销毁 session
    [self.session invalidateAndCancel];
    self.session = nil;
}

#pragma mark - 视图加载

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self setupBentoLayout];
    [self transitionToPhase:ModUpdatePhasePrepare];
}

#pragma mark - Bento Grid 布局

/// 搭建 Bento Grid 风格的整体布局：滚动容器 + 垂直卡片堆叠
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

/// 创建一个 Bento 风格的卡片视图（16pt 圆角，浅色背景，适配深浅色）
- (UIView *)makeBentoCard {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    return card;
}

/// 顶部头卡片：标题 + 关闭按钮
- (void)setupHeaderCard {
    self.headerCard = [self makeBentoCard];
    [self.bentoStack addArrangedSubview:self.headerCard];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"Mod 更新";
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

/// 阶段状态卡片：阶段名称 + 进度条 + 当前文件名
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

/// 内容卡片：包含表格和空态视图
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

/// 操作按钮卡片：主按钮 + 次按钮（Material Design 3 风格）
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

/// Material Design 3 填充主按钮
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

/// Material Design 3 描边次按钮
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

#pragma mark - 阶段流转

/// 切换到指定阶段并刷新 UI
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

/// 根据当前阶段刷新 UI 元素
- (void)refreshUIForCurrentPhase {
    [self updatePhaseCardForCurrentPhase];
    [self updateActionCardForCurrentPhase];
    [self updateContentCardForCurrentPhase];
    [self.tableView reloadData];
}

/// 更新阶段状态卡片
- (void)updatePhaseCardForCurrentPhase {
    switch (self.currentPhase) {
        case ModUpdatePhasePrepare:
            self.phaseTitleLabel.text = @"正在准备...";
            self.progressView.hidden = YES;
            self.currentFileLabel.text = @"";
            break;
        case ModUpdatePhaseCheck:
            self.phaseTitleLabel.text = [NSString stringWithFormat:@"正在检查更新 (%ld/%ld)",
                                         (long)self.checkCompleted, (long)self.filteredMods.count];
            self.progressView.hidden = NO;
            self.currentFileLabel.text = @"并发检查中...";
            break;
        case ModUpdatePhaseConfirm:
            self.phaseTitleLabel.text = @"请确认需要更新的 Mod";
            self.progressView.hidden = YES;
            self.currentFileLabel.text = @"";
            break;
        case ModUpdatePhaseDownload:
            self.phaseTitleLabel.text = [NSString stringWithFormat:@"正在下载 (%ld/%ld)",
                                         (long)self.downloadCompleted, (long)self.downloadTotal];
            self.progressView.hidden = NO;
            break;
        case ModUpdatePhaseReplace:
            self.phaseTitleLabel.text = @"正在替换文件...";
            self.progressView.hidden = YES;
            self.currentFileLabel.text = @"";
            break;
        case ModUpdatePhaseDone:
            self.phaseTitleLabel.text = [NSString stringWithFormat:@"更新完成（成功 %ld，失败 %ld）",
                                         (long)self.successCount, (long)self.failureCount];
            self.progressView.hidden = YES;
            self.currentFileLabel.text = @"";
            break;
    }
}

/// 更新操作按钮卡片
- (void)updateActionCardForCurrentPhase {
    switch (self.currentPhase) {
        case ModUpdatePhasePrepare:
        case ModUpdatePhaseCheck:
        case ModUpdatePhaseDownload:
        case ModUpdatePhaseReplace:
            // 自动执行阶段，隐藏操作按钮
            self.actionCard.hidden = YES;
            break;
        case ModUpdatePhaseConfirm: {
            self.actionCard.hidden = NO;
            if (self.selections.count == 0) {
                // 无可用更新
                [self.primaryButton setTitle:@"关闭" forState:UIControlStateNormal];
                self.primaryButton.userInteractionEnabled = YES;
                self.secondaryButton.hidden = YES;
            } else {
                NSInteger selectedCount = [self selectedCount];
                [self.primaryButton setTitle:[NSString stringWithFormat:@"更新选中的 %ld 项", (long)selectedCount]
                                    forState:UIControlStateNormal];
                self.primaryButton.userInteractionEnabled = (selectedCount > 0);
                self.secondaryButton.hidden = NO;
                [self.secondaryButton setTitle:@"取消" forState:UIControlStateNormal];
            }
            break;
        }
        case ModUpdatePhaseDone:
            self.actionCard.hidden = NO;
            [self.primaryButton setTitle:@"关闭" forState:UIControlStateNormal];
            self.primaryButton.userInteractionEnabled = YES;
            self.secondaryButton.hidden = YES;
            break;
    }
}

/// 更新内容卡片显示
- (void)updateContentCardForCurrentPhase {
    BOOL showEmpty = NO;
    NSString *emptyText = @"";

    switch (self.currentPhase) {
        case ModUpdatePhasePrepare:
            showEmpty = YES;
            emptyText = @"正在准备 Mod 列表...";
            break;
        case ModUpdatePhaseCheck:
            if (self.filteredMods.count == 0) {
                showEmpty = YES;
                emptyText = @"没有可检查的 Mod";
            }
            break;
        case ModUpdatePhaseConfirm:
            if (self.selections.count == 0) {
                showEmpty = YES;
                emptyText = @"所有 Mod 均为最新版本";
            }
            break;
        case ModUpdatePhaseDownload:
            if (self.downloadTasks.count == 0) {
                showEmpty = YES;
                emptyText = @"没有需要下载的项";
            }
            break;
        case ModUpdatePhaseReplace:
            showEmpty = YES;
            emptyText = @"正在替换文件...";
            break;
        case ModUpdatePhaseDone:
            if (self.failureCount == 0) {
                showEmpty = YES;
                emptyText = [NSString stringWithFormat:@"成功更新 %ld 个 Mod", (long)self.successCount];
            }
            break;
    }

    self.emptyLabel.text = emptyText;
    self.emptyStateView.hidden = !showEmpty;
    self.tableView.hidden = showEmpty;
}

#pragma mark - 阶段 0：准备

- (void)startPhase0Prepare {
    // 过滤掉无 filePath 的项
    NSMutableArray<ModItem *> *filtered = [NSMutableArray array];
    for (ModItem *mod in self.inputMods) {
        if (mod.filePath.length > 0) {
            [filtered addObject:mod];
        }
    }
    self.filteredMods = [filtered copy];
    self.checkCompleted = 0;

    // 短暂延时，让用户看到准备阶段
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.filteredMods.count == 0) {
            // 没有可检查的 Mod，直接进入完成阶段
            self.successCount = 0;
            self.failureCount = 0;
            [self.failedFileNames removeAllObjects];
            [self transitionToPhase:ModUpdatePhaseDone];
        } else {
            [self transitionToPhase:ModUpdatePhaseCheck];
        }
    });
}

#pragma mark - 阶段 1：并发检查更新

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

#pragma mark - 阶段 2：用户确认

- (void)startPhase2Confirm {
    // 根据 checkResults 构建选中项列表，默认全选
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

/// 当前选中的项数
- (NSInteger)selectedCount {
    NSInteger count = 0;
    for (ModUpdateSelection *sel in self.selections) {
        if (sel.selected) count++;
    }
    return count;
}

#pragma mark - 阶段 3：并发下载（限流 16，失败重试一次）

- (void)startPhase3Download {
    // 收集选中的项
    NSArray<ModUpdateSelection *> *selected = [self.selections filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(ModUpdateSelection *sel, NSDictionary *_) {
            return sel.selected && sel.result && sel.chosenVersion;
        }]];

    if (selected.count == 0) {
        // 没有选中的项，直接进入完成阶段
        self.successCount = 0;
        self.failureCount = 0;
        [self.failedFileNames removeAllObjects];
        [self transitionToPhase:ModUpdatePhaseDone];
        return;
    }

    // 创建临时目录
    self.tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ModUpdate_%@", [[NSUUID UUID] UUIDString]]];
    NSError *mkError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.tempDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&mkError];
    if (mkError) {
        // 临时目录创建失败，全部标记为失败
        self.successCount = 0;
        self.failureCount = (NSInteger)selected.count;
        [self.failedFileNames removeAllObjects];
        for (ModUpdateSelection *sel in selected) {
            [self.failedFileNames addObject:[self fileNameForSelection:sel]];
        }
        [self transitionToPhase:ModUpdatePhaseDone];
        return;
    }

    // 创建 NSURLSession（由本控制器作为 delegate）
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.HTTPMaximumConnectionsPerHost = 16;
    config.timeoutIntervalForRequest = 60;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];

    // 初始化下载任务列表
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

    // 并发限流 16，使用信号量控制
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(16);
    dispatch_queue_t workQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __weak typeof(self) weakSelf = self;

    for (ModDownloadTaskInfo *info in self.downloadTasks) {
        dispatch_async(workQueue, ^{
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
            // 在主线程创建并启动下载任务
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

/// 为指定 info 创建并启动下载任务
- (void)createAndStartDownloadTaskForInfo:(ModDownloadTaskInfo *)info
                                semaphore:(dispatch_semaphore_t)semaphore {
    NSString *urlString = [self downloadURLStringForVersion:info.targetVersion];
    if (urlString.length == 0) {
        // 无效下载链接，标记为失败
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
    // 通过关联对象把 info 绑定到 task，便于在 delegate 回调中取回
    objc_setAssociatedObject(task, &kDownloadTaskInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(task, &kDownloadSemaphoreKey, semaphore, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [task resume];

    // 更新当前文件名显示
    self.currentFileLabel.text = info.fileName;
}

/// 单个下载任务结束（成功或失败）的统一处理
/// 注意：本方法可能从 NSURLSession 的后台 delegate 队列调用，UI 更新必须派发到主线程
- (void)onDownloadTaskFinished:(ModDownloadTaskInfo *)info
                     semaphore:(dispatch_semaphore_t)semaphore {
    self.downloadCompleted += 1;
    NSInteger completed = self.downloadCompleted;
    NSInteger total = self.downloadTotal;

    // UI 更新派发到主线程
    dispatch_async(dispatch_get_main_queue(), ^{
        if (total > 0) {
            self.progressView.progress = (float)completed / (float)total;
        }
        [self updatePhaseCardForCurrentPhase];
        [self.tableView reloadData];
    });

    // 释放信号量，允许下一个任务进入
    dispatch_semaphore_signal(semaphore);

    // 全部完成则进入替换阶段
    if (completed >= total) {
        [self transitionToPhase:ModUpdatePhaseReplace];
    }
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    // 下载完成，把文件移动到我们的临时目录
    ModDownloadTaskInfo *info = objc_getAssociatedObject(downloadTask, &kDownloadTaskInfoKey);
    if (!info) return;

    NSString *destName = info.fileName.length > 0 ? info.fileName :
        [NSString stringWithFormat:@"%@.jar", [[NSUUID UUID] UUIDString]];
    NSString *destPath = [self.tempDir stringByAppendingPathComponent:destName];

    // 若目标已存在则先移除（同名时覆盖）
    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];

    NSError *moveError = nil;
    [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destPath] error:&moveError];
    if (moveError) {
        // 移动失败，标记为未成功
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
    // 节流地刷新表格（在串行队列上派发到主线程）
    dispatch_async(self.callbackQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            // 仅更新可见行，避免频繁全量刷新
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
        // 成功（tempFilePath 已在 didFinishDownloadingToURL 中设置）
        if (!info.succeeded) {
            // 极少数情况下 didFinish 未设置成功状态，这里兜底判定为失败
            info.succeeded = NO;
        }
        [self onDownloadTaskFinished:info semaphore:semaphore];
        return;
    }

    // 失败：若未重试过，则自动重试一次
    if (!info.retried) {
        info.retried = YES;
        info.succeeded = NO;
        info.tempFilePath = nil;
        // 重新创建并启动下载任务（重试不重新获取信号量，复用原有的并发槽位）
        dispatch_async(dispatch_get_main_queue(), ^{
            [self createAndStartDownloadTaskForInfo:info semaphore:semaphore];
        });
        return;
    }

    // 已重试过仍失败，标记为失败
    info.succeeded = NO;
    [self onDownloadTaskFinished:info semaphore:semaphore];
}

#pragma mark - 阶段 4：替换文件

- (void)startPhase4Replace {
    // 根据 modUpdateKeepOld 偏好决定旧文件处理方式
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
            // 处理旧文件
            if ([fm fileExistsAtPath:oldPath]) {
                if (keepOld) {
                    // 保留旧文件：重命名为 <原名>.old
                    NSString *oldBackupPath = [oldPath stringByAppendingString:@".old"];
                    // 若 .old 已存在则先删除
                    [fm removeItemAtPath:oldBackupPath error:nil];
                    NSError *renameError = nil;
                    [fm moveItemAtPath:oldPath toPath:oldBackupPath error:&renameError];
                    if (renameError) {
                        // 重命名失败则尝试删除
                        [fm removeItemAtPath:oldPath error:nil];
                    }
                } else {
                    // 不保留：直接删除旧文件
                    [fm removeItemAtPath:oldPath error:nil];
                }
            }

            // 若目标路径已存在同名文件（与旧文件不同名的情况），先移除
            if (![newPath isEqualToString:oldPath] && [fm fileExistsAtPath:newPath]) {
                [fm removeItemAtPath:newPath error:nil];
            }

            // 把临时目录的新文件移动到 mods 目录
            NSError *moveError = nil;
            [fm moveItemAtPath:info.tempFilePath toPath:newPath error:&moveError];
            if (moveError) {
                self.failureCount += 1;
                [self.failedFileNames addObject:fileName];
            } else {
                self.successCount += 1;
                info.tempFilePath = nil; // 已移走，清空避免后续误删
            }
        } @catch (NSException *exception) {
            self.failureCount += 1;
            [self.failedFileNames addObject:fileName];
        }
    }

    // 进入完成阶段
    [self transitionToPhase:ModUpdatePhaseDone];
}

#pragma mark - 阶段 5：完成

- (void)startPhase5Done {
    // 无额外操作；UI 刷新由 transitionToPhase: 派发到主线程执行
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

/// 阶段 1：检查中的文件列表 cell
- (UITableViewCell *)checkCellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"PlainCell" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
    cell.imageView.image = nil;

    if (indexPath.row >= (NSInteger)self.filteredMods.count) return cell;
    ModItem *mod = self.filteredMods[indexPath.row];

    // 使用真实动画指示器作为 accessoryView
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

/// 阶段 2：用户确认 cell（首行摘要 / 后续行为版本选项）
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
        // 摘要行：勾选开关 + 文件名 + 版本变化 + 来源 + 展开指示
        NSString *fileName = result.localFilePath.lastPathComponent ?: @"未知文件";
        NSString *currentVer = result.currentVersion.versionNumber ?: @"未知版本";
        NSString *targetVer = sel.chosenVersion.versionNumber ?: @"最新版本";
        NSString *source = [self sourceNameForResult:result];

        // 使用 UISwitch 作为 accessoryView
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = sel.selected;
        sw.tag = indexPath.section;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;

        // 展开指示图标
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

    // 版本选项行：单选指示 + 版本号 + 发布日期
    NSInteger versionIndex = indexPath.row - 1;
    if (versionIndex >= (NSInteger)result.allVersions.count) return cell;
    ModVersion *version = result.allVersions[versionIndex];

    BOOL isChosen = (sel.chosenVersion == version);
    UIImage *radio = [UIImage systemImageNamed:isChosen ? @"largecircle.fill.circle" : @"circle"];
    cell.imageView.image = radio;
    cell.imageView.tintColor = [UIColor systemBlueColor];

    cell.textLabel.text = version.versionNumber ?: version.name ?: @"未知版本";
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.textColor = isChosen ? [UIColor labelColor] : [UIColor secondaryLabelColor];

    NSString *dateText = version.datePublished.length > 0 ? version.datePublished : @"";
    cell.detailTextLabel.text = dateText;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];

    return cell;
}

/// 阶段 3：下载进度列表 cell
- (UITableViewCell *)downloadCellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"PlainCell" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.row >= (NSInteger)self.downloadTasks.count) return cell;
    ModDownloadTaskInfo *info = self.downloadTasks[indexPath.row];

    // 判定任务是否已经结束（成功或最终失败）
    BOOL finished = info.succeeded || (info.retried && !info.succeeded && info.task == nil);
    if (info.succeeded) {
        cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        cell.imageView.tintColor = [UIColor systemGreenColor];
        cell.accessoryView = nil;
    } else if (finished) {
        // 已结束但未成功
        cell.imageView.image = [UIImage systemImageNamed:@"xmark.circle.fill"];
        cell.imageView.tintColor = [UIColor systemRedColor];
        cell.accessoryView = nil;
    } else {
        // 进行中：使用真实动画指示器
        cell.imageView.image = nil;
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    }

    cell.textLabel.text = info.fileName ?: @"未知文件";
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.numberOfLines = 1;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    // 进度文本
    int64_t completed = info.progress.completedUnitCount;
    int64_t total = info.progress.totalUnitCount;
    NSString *progressText = nil;
    if (info.succeeded) {
        progressText = @"已完成";
    } else if (finished) {
        progressText = @"失败";
    } else if (total > 0) {
        float ratio = (float)completed / (float)total;
        progressText = [NSString stringWithFormat:@"%d%%", (int)(ratio * 100)];
    } else if (info.retried) {
        progressText = @"重试中...";
    } else {
        progressText = @"下载中...";
    }
    cell.detailTextLabel.text = progressText;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    return cell;
}

/// 阶段 5：完成阶段失败项 cell
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
    cell.detailTextLabel.text = @"更新失败";
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
        // 点击摘要行：切换展开/收起
        sel.expanded = !sel.expanded;
        NSIndexSet *indexSet = [NSIndexSet indexSetWithIndex:indexPath.section];
        [tableView reloadSections:indexSet withRowAnimation:UITableViewRowAnimationAutomatic];
    } else {
        // 点击版本行：选择降级目标版本
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

#pragma mark - 交互事件

/// 勾选开关变化
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

#pragma mark - 工具方法

/// 从 ModVersion 中提取下载 URL
- (nullable NSString *)downloadURLStringForVersion:(ModVersion *)version {
    if (!version) return nil;
    NSDictionary *pf = version.primaryFile;
    if (![pf isKindOfClass:[NSDictionary class]]) return nil;
    NSString *url = [pf[@"url"] isKindOfClass:[NSString class]] ? pf[@"url"] : nil;
    return url.length > 0 ? url : nil;
}

/// 从 ModVersion 中提取文件名
- (nullable NSString *)fileNameForVersion:(ModVersion *)version {
    if (!version) return nil;
    NSDictionary *pf = version.primaryFile;
    if (![pf isKindOfClass:[NSDictionary class]]) return nil;
    NSString *name = [pf[@"filename"] isKindOfClass:[NSString class]] ? pf[@"filename"] : nil;
    return name.length > 0 ? name : nil;
}

/// 选中项的显示文件名
- (NSString *)fileNameForSelection:(ModUpdateSelection *)sel {
    NSString *name = [self fileNameForVersion:sel.chosenVersion];
    if (name.length > 0) return name;
    return sel.result.localFilePath.lastPathComponent ?: @"未知文件";
}

/// 返回来源名称
- (NSString *)sourceNameForResult:(ModUpdateResult *)result {
    NSNumber *src = result.apiSource;
    if (src && [src isKindOfClass:[NSNumber class]] && [src integerValue] == 2) {
        return @"CurseForge";
    }
    return @"Modrinth";
}

@end
