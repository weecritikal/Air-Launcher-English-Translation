//
//  ModpackImportViewController.m
//  Amethyst
//
//  参照 FCL ModpackImportScreen / HMCL ModpackProviderPane / ZL2 ModpackImportScreen 重做
//
//  设计要点：
//    1. 顶部使用 UISegmentedControl 切换 "导入 / 导出"，导出切换时 push 到独立的 ModpackExportViewController
//    2. 导入流程：选择文件 → 解析（不确定模式进度卡片）→ 预览卡片（mod 信息）→ 导入进度卡片（支持取消）→ 完成提示
//    3. 真正的取消：通过 [self.importService setCancelled:YES] 触发，service 在检查点抛出错误并清理半成品目录
//    4. 已导入整合包列表使用现代化的卡片样式
//

#import "ModpackImportViewController.h"
#import "BackgroundManager.h"
#import "ModpackImportService.h"
#import "ModpackExportViewController.h"
#import "PLProfiles.h"
#import "UnzipKit.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ModpackImportViewController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UISegmentedControl *tabSegment;       // 顶部 "导入 | 导出" 切换
@property (nonatomic, strong) UIView *headerContainerView;          // 顶部说明 + 选择文件按钮
@property (nonatomic, strong) UILabel *hintLabel;                   // 支持格式说明
@property (nonatomic, strong) UIButton *importButton;               // 主导入按钮
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *importedModpacks;
@property (nonatomic, strong) ModpackImportService *importService;
@property (nonatomic, strong) NSDictionary *currentImportingModpack;

// FCL 风格进度卡片
@property (nonatomic, strong) UIView *progressOverlay;       // 半透明遮罩
@property (nonatomic, strong) UIView *progressCard;          // 居中卡片
@property (nonatomic, strong) UILabel *progressTitleLabel;   // 标题
@property (nonatomic, strong) UILabel *progressPercentLabel; // 百分比 (36pt 大字)
@property (nonatomic, strong) UIProgressView *progressBar;   // 进度条
@property (nonatomic, strong) UILabel *progressStageLabel;   // 阶段文案
@property (nonatomic, strong) UIActivityIndicatorView *progressSpinner; // 不确定模式转圈
@property (nonatomic, strong) UIButton *progressCancelButton; // 取消按钮
@end

@implementation ModpackImportViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景：将当前视图控制器透明化，使全局背景壁纸能够透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.title = @"整合包";

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
    // 回到导入页时，确保 tab 显示"导入"
    self.tabSegment.selectedSegmentIndex = 0;
}

#pragma mark - 顶部 Tab 切换（导入 / 导出）

- (void)setupNavigationTab {
    self.tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"导入", @"导出"]];
    self.tabSegment.selectedSegmentIndex = 0;
    [self.tabSegment addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];

    // 放置在 navigationItem.titleView，宽度自适应
    CGSize fittingSize = [self.tabSegment sizeThatFits:CGSizeMake(220, 30)];
    self.tabSegment.frame = CGRectMake(0, 0, MAX(180, fittingSize.width), 30);
    self.navigationItem.titleView = self.tabSegment;
}

- (void)tabChanged:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex == 1) {
        // 切换到导出：push 到 ModpackExportViewController
        ModpackExportViewController *exportVC = [[ModpackExportViewController alloc] init];
        exportVC.preselectedProfileName = PLProfiles.current.selectedProfileName;
        [self.navigationController pushViewController:exportVC animated:YES];
        // 立即把 tab 切回"导入"，因为返回时 viewWillAppear 会重置
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.selectedSegmentIndex = 0;
        });
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // 顶部说明 + 选择文件按钮容器
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
    self.hintLabel.text = @"支持格式：Modrinth (.mrpack)、CurseForge (.zip)、MMC (MultiMC/Prism)、Plain ZIP（直接含 .minecraft）";
    [self.headerContainerView addSubview:self.hintLabel];

    self.importButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.importButton setTitle:@"  选择整合包文件" forState:UIControlStateNormal];
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
    self.emptyLabel.text = @"还没有导入的整合包\n点击上方按钮导入";
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

#pragma mark - FCL 风格进度卡片

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
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
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

    // 初始不确定模式 (只显示转圈)
    [self setProgress:-1 stageMessage:@"正在准备..."];
}

- (void)setProgress:(double)progress stageMessage:(NSString *)stageMessage {
    if (!self.progressCard) return;

    if (progress < 0) {
        // 不确定模式
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

/// 真正的取消：通过 service.cancelled 信号通知正在进行的导入流程
- (void)cancelImport {
    self.importService.cancelled = YES;
    if (self.progressCancelButton) {
        [self.progressCancelButton setTitle:@"正在取消..." forState:UIControlStateNormal];
        [self.progressCancelButton setEnabled:NO];
    }
    [self setProgress:-1 stageMessage:@"正在取消，请稍候..."];
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

#pragma mark - 文件选择

- (void)selectModpackFile {
    NSArray<UTType *> *contentTypes = @[
        [UTType typeWithFilenameExtension:@"mrpack"],
        [UTType typeWithFilenameExtension:@"zip"]
    ];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *fileURL = urls.firstObject;
    NSString *fileExtension = fileURL.pathExtension.lowercaseString;

    if (![fileExtension isEqualToString:@"mrpack"] && ![fileExtension isEqualToString:@"zip"]) {
        [self showAlertWithTitle:@"无效的文件" message:@"请选择 .mrpack 或 .zip 文件"];
        return;
    }

    BOOL accessGranted = [fileURL startAccessingSecurityScopedResource];
    if (!accessGranted) {
        [self showAlertWithTitle:@"访问被拒绝" message:@"无法访问选中的文件"];
        return;
    }

    // 解析阶段：显示不确定模式进度卡片
    [self showProgressCardWithTitle:@"正在解析整合包"];
    [self setProgress:-1 stageMessage:@"正在读取整合包信息..."];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        NSDictionary *modpackInfo = nil;

        @try {
            modpackInfo = [self.importService parseModpackAtURL:fileURL error:&error];
        } @catch (NSException *exception) {
            error = [NSError errorWithDomain:@"ModpackImportError" code:9999
                                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"解析异常: %@", exception.reason]}];
        }

        [fileURL stopAccessingSecurityScopedResource];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !modpackInfo) {
                [self hideProgressCard];
                [self showAlertWithTitle:@"解析失败" message:error.localizedDescription ?: @"无法解析整合包文件"];
                return;
            }
            self.currentImportingModpack = modpackInfo;
            [self hideProgressCard];
            [self showModpackPreview:modpackInfo fileURL:fileURL];
        });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {}

#pragma mark - 整合包预览卡片（参照 FCL ModpackPreviewSheet / HMCL ModpackInfoPage）

- (void)showModpackPreview:(NSDictionary *)modpackInfo fileURL:(NSURL *)fileURL {
    NSString *name = modpackInfo[@"name"] ?: @"未知";
    NSString *version = modpackInfo[@"version"] ?: @"未知";
    NSString *author = modpackInfo[@"author"] ?: @"";
    NSString *mcVersion = modpackInfo[@"minecraftVersion"] ?: @"未知";
    NSString *loader = modpackInfo[@"loader"] ?: @"Vanilla";
    NSString *loaderVersion = modpackInfo[@"loaderVersion"] ?: @"";
    NSString *format = modpackInfo[@"format"] ?: @"unknown";
    NSNumber *modCountNum = modpackInfo[@"modCount"];
    NSNumber *fileCountNum = modpackInfo[@"fileCount"];
    NSString *fileName = fileURL.lastPathComponent ?: @"";

    // 格式映射成中文
    NSDictionary *formatLabels = @{
        @"modrinth": @"Modrinth (.mrpack)",
        @"curseforge": @"CurseForge (.zip)",
        @"mmc": @"MMC (MultiMC/Prism)",
        @"plainzip": @"Plain ZIP (.minecraft)"
    };
    NSString *formatLabel = formatLabels[format] ?: format;

    NSMutableString *message = [NSMutableString string];
    [message appendFormat:@"文件: %@\n", fileName];
    [message appendFormat:@"格式: %@\n", formatLabel];
    [message appendFormat:@"名称: %@\n", name];
    [message appendFormat:@"版本: %@", version];
    if (author.length > 0) {
        [message appendFormat:@"   作者: %@", author];
    }
    [message appendString:@"\n"];
    [message appendFormat:@"Minecraft: %@\n", mcVersion];
    [message appendFormat:@"加载器: %@", loader];
    if (loaderVersion.length > 0) {
        [message appendFormat:@" %@", loaderVersion];
    }
    [message appendString:@"\n"];

    if (modCountNum && modCountNum.integerValue > 0) {
        [message appendFormat:@"需下载模组: %ld 个\n", (long)modCountNum.integerValue];
    }
    if (fileCountNum && fileCountNum.integerValue > 0) {
        [message appendFormat:@"需解压文件: %ld 个\n", (long)fileCountNum.integerValue];
    }

    // Forge/NeoForge 警告
    if ([loader isEqualToString:@"Forge"] || [loader isEqualToString:@"NeoForge"]) {
        [message appendFormat:@"\n⚠️ 注意: %@ %@ 加载器需通过下载界面手动安装，否则启动会失败。", loader, loaderVersion];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入整合包"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        self.currentImportingModpack = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startModpackImport:modpackInfo];
    }]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 导入流程

- (void)startModpackImport:(NSDictionary *)modpackInfo {
    // 重置取消状态
    [self.importService resetCancelState];

    NSString *name = modpackInfo[@"name"] ?: @"整合包";
    [self showProgressCardWithTitle:[NSString stringWithFormat:@"正在导入 %@", name]];
    [self setProgress:-1 stageMessage:@"正在准备..."];

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
                                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"导入异常: %@", exception.reason]}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            // 检测是否被取消
            BOOL wasCancelled = [error.domain isEqualToString:@"ModpackImportError"] && error.code == 9999;
            NSString *localizedDesc = error.localizedDescription ?: @"";
            if (!wasCancelled && [localizedDesc containsString:@"取消"]) {
                wasCancelled = YES;
            }

            if (wasCancelled) {
                // 取消：直接隐藏卡片，不显示 100%
                [self hideProgressCard];
                self.currentImportingModpack = nil;
                [self showAlertWithTitle:@"已取消" message:@"导入已取消"];
                return;
            }

            if (success) {
                // 完成时显示 100%
                [self setProgress:1.0 stageMessage:@"导入完成"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self hideProgressCard];
                    self.currentImportingModpack = nil;
                    [self showImportSuccess:modpackInfo];
                });
            } else {
                // 阶段5修复（参照 FCL）：错误消息中追加失败文件列表（如有），
                // 让用户清楚知道是哪些 mod 下载失败，而不是只看到一个笼统的错误。
                NSString *message = error.localizedDescription ?: @"未知错误";
                NSArray<NSDictionary *> *failed = self.importService.failedFiles;
                if (failed.count > 0) {
                    NSMutableString *msg = [NSMutableString stringWithString:message];
                    [msg appendFormat:@"\n\n失败文件（共 %lu 个）：", (unsigned long)failed.count];
                    NSUInteger showCount = MIN(failed.count, (NSUInteger)5);
                    for (NSUInteger k = 0; k < showCount; k++) {
                        NSString *n = failed[k][@"fileName"] ?: failed[k][@"name"];
                        [msg appendFormat:@"\n  • %@", n ?: @"(unknown)"];
                    }
                    if (failed.count > showCount) {
                        [msg appendFormat:@"\n  ...等共 %lu 个", (unsigned long)failed.count];
                    }
                    message = [msg copy];
                }
                [self hideProgressCard];
                self.currentImportingModpack = nil;
                [self showAlertWithTitle:@"导入失败" message:message];
            }
        });
    });
}

- (void)showImportSuccess:(NSDictionary *)modpackInfo {
    NSString *loader = modpackInfo[@"loader"];
    NSString *name = modpackInfo[@"name"];
    NSString *msg = [NSString stringWithFormat:@"整合包 '%@' 已成功导入。", name];
    if ([loader isEqualToString:@"Forge"] || [loader isEqualToString:@"NeoForge"]) {
        msg = [msg stringByAppendingFormat:@"\n\n注意: 此整合包使用 %@ %@ 加载器，请先通过下载界面手动安装该加载器版本，否则启动会失败。", loader, modpackInfo[@"loaderVersion"]];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入成功"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [self loadImportedModpacks];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"立即启动" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
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
    // 重置 cell 样式
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    // 重置 cell 样式：移除旧的 blurView 和 shadowView（cell 复用）
    for (UIView *subview in cell.contentView.subviews) {
        if ([subview isKindOfClass:[UIVisualEffectView class]] ||
            (subview.layer.shadowOpacity > 0.0f)) {
            [subview removeFromSuperview];
        }
    }

    NSDictionary *modpack = self.importedModpacks[indexPath.row];
    NSString *name = modpack[@"name"] ?: @"未知";
    NSString *mcVersion = modpack[@"minecraftVersion"] ?: @"未知";
    NSString *loader = modpack[@"loader"] ?: @"未知";

    cell.textLabel.text = name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Minecraft %@ - %@", mcVersion, loader];
    cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = [UIColor clearColor];

    // 阶段6视觉统一：参照 ModernAssetCell / ModVersionTableViewCell / VersionCardCell 的卡片规范
    // （cornerRadius 12 + cornerCurve continuous + shadow offset 2/opacity 0.10/radius 4 + leading/trailing 10）
    // 由于 UIVisualEffectView 的 masksToBounds=YES 会同时裁剪 blur 和 shadow，需要单独的 shadowView
    // 提供阴影（与 blurView 同 frame），blurView 在上层提供毛玻璃效果。
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
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"启动整合包" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self launchModpack:modpack];
    }]];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteModpack:modpack];
    }]];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

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
        [self showAlertWithTitle:@"配置文件已选择" message:[NSString stringWithFormat:@"已切换到整合包配置文件: %@", profileName]];
    } else {
        [self showAlertWithTitle:@"错误" message:@"找不到整合包配置文件"];
    }
}

- (void)deleteModpack:(NSDictionary *)modpack {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认删除" message:[NSString stringWithFormat:@"删除整合包 '%@'？此操作无法撤销。", modpack[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self showProgressCardWithTitle:@"正在删除"];
        [self setProgress:-1 stageMessage:@"正在删除整合包文件..."];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error = nil;
            BOOL success = [self.importService deleteModpack:modpack error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideProgressCard];
                if (success) {
                    [self loadImportedModpacks];
                } else {
                    [self showAlertWithTitle:@"删除失败" message:error.localizedDescription];
                }
            });
        });
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

#pragma mark - 辅助方法

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    [self showAlertWithTitle:title message:message completion:nil];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message completion:(void (^ _Nullable)(void))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
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
        // 重新应用透明化，确保背景效果切换后视图仍能透出全局背景
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        [[BackgroundManager sharedManager] applyEffectToView:self.view];
        [self.tableView reloadData];
    });
}

@end
