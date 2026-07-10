#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"
#import "WFWorkflowProgressView.h"
#import "BackgroundManager.h"

static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

@interface DownloadProgressViewController ()
@property NSInteger fileListCount;
// 阶段12增强：表头摘要视图（总进度 + 速度 + ETA）
@property (nonatomic, strong) UIView *summaryHeaderView;
@property (nonatomic, strong) UILabel *summaryTitleLabel;
@property (nonatomic, strong) UILabel *summaryDetailLabel;
@property (nonatomic, strong) UIProgressView *summaryProgressBar;
@end

@implementation DownloadProgressViewController

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task {
    self = [super init];
    self.task = task;
    return self;
}

- (void)loadView {
    [super loadView];
    // 适配自定义启动器背景
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.tableView.allowsSelection = NO;

    // 阶段12增强：创建表头摘要视图（参照 FCL 下载页顶部的总进度摘要）
    [self setupSummaryHeader];

    // Load WFWorkflowProgressView
    dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL);
}

/// 创建表头摘要视图：总进度百分比 + 进度条 + 速度/ETA 信息
- (void)setupSummaryHeader {
    self.summaryHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 100)];
    self.summaryHeaderView.backgroundColor = [UIColor clearColor];

    UIView *cardView = [[UIView alloc] init];
    cardView.translatesAutoresizingMaskIntoConstraints = NO;
    cardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    cardView.layer.cornerRadius = 16;
    cardView.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:cardView];
    [self.summaryHeaderView addSubview:cardView];

    self.summaryTitleLabel = [[UILabel alloc] init];
    self.summaryTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryTitleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    self.summaryTitleLabel.textColor = [UIColor labelColor];
    self.summaryTitleLabel.text = @"正在下载...";
    [cardView addSubview:self.summaryTitleLabel];

    self.summaryDetailLabel = [[UILabel alloc] init];
    self.summaryDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryDetailLabel.font = [UIFont systemFontOfSize:12];
    self.summaryDetailLabel.textColor = [UIColor secondaryLabelColor];
    self.summaryDetailLabel.numberOfLines = 0;
    self.summaryDetailLabel.text = @"";
    [cardView addSubview:self.summaryDetailLabel];

    self.summaryProgressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.summaryProgressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryProgressBar.progress = 0.0;
    [cardView addSubview:self.summaryProgressBar];

    [NSLayoutConstraint activateConstraints:@[
        [cardView.topAnchor constraintEqualToAnchor:self.summaryHeaderView.topAnchor constant:8],
        [cardView.leadingAnchor constraintEqualToAnchor:self.summaryHeaderView.leadingAnchor constant:16],
        [cardView.trailingAnchor constraintEqualToAnchor:self.summaryHeaderView.trailingAnchor constant:-16],
        [cardView.bottomAnchor constraintEqualToAnchor:self.summaryHeaderView.bottomAnchor constant:-8],

        [self.summaryTitleLabel.topAnchor constraintEqualToAnchor:cardView.topAnchor constant:12],
        [self.summaryTitleLabel.leadingAnchor constraintEqualToAnchor:cardView.leadingAnchor constant:16],
        [self.summaryTitleLabel.trailingAnchor constraintEqualToAnchor:cardView.trailingAnchor constant:-16],

        [self.summaryProgressBar.topAnchor constraintEqualToAnchor:self.summaryTitleLabel.bottomAnchor constant:8],
        [self.summaryProgressBar.leadingAnchor constraintEqualToAnchor:cardView.leadingAnchor constant:16],
        [self.summaryProgressBar.trailingAnchor constraintEqualToAnchor:cardView.trailingAnchor constant:-16],

        [self.summaryDetailLabel.topAnchor constraintEqualToAnchor:self.summaryProgressBar.bottomAnchor constant:8],
        [self.summaryDetailLabel.leadingAnchor constraintEqualToAnchor:cardView.leadingAnchor constant:16],
        [self.summaryDetailLabel.trailingAnchor constraintEqualToAnchor:cardView.trailingAnchor constant:-16],
        [self.summaryDetailLabel.bottomAnchor constraintEqualToAnchor:cardView.bottomAnchor constant:-12]
    ]];

    self.tableView.tableHeaderView = self.summaryHeaderView;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

[self.task.textProgress addObserver:self
        forKeyPath:@"fractionCompleted"
        options:NSKeyValueObservingOptionInitial
        context:TotalProgressObserverContext];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];

[self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    NSProgress *progress = object;
    if (context == CellProgressObserverContext) {
        UITableViewCell *cell = objc_getAssociatedObject(progress, @"cell");
        if (!cell) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            cell.detailTextLabel.text = progress.localizedAdditionalDescription;
            WFWorkflowProgressView *progressView = (id)cell.accessoryView;
            progressView.fractionCompleted = progress.fractionCompleted;
            if (progress.finished) {
                [progressView transitionCompletedLayerToVisible:YES animated:YES haptic:NO];
            }
        });
    } else if (context == TotalProgressObserverContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.title = progress.localizedDescription;
            // 阶段12增强：更新表头摘要
            double fraction = progress.fractionCompleted;
            self.summaryTitleLabel.text = [NSString stringWithFormat:@"正在下载... %.0f%%", fraction * 100.0];
            [self.summaryProgressBar setProgress:(float)fraction animated:YES];

            // 构建详情文本：已下载/总大小 + 速度 + ETA
            NSMutableString *detail = [NSMutableString string];
            if (progress.totalUnitCount > 0) {
                NSInteger completed = progress.totalUnitCount * fraction;
                [detail appendFormat:@"%@ / %@",
                    [NSByteCountFormatter stringFromByteCount:completed countStyle:NSByteCountFormatterCountStyleFile],
                    [NSByteCountFormatter stringFromByteCount:progress.totalUnitCount countStyle:NSByteCountFormatterCountStyleFile]];
            }
            if (progress.throughput) {
                NSInteger speed = [progress.throughput integerValue];
                if (speed > 1024 * 1024) {
                    [detail appendFormat:@" • %.1f MB/s", speed / (1024.0 * 1024.0)];
                } else if (speed > 1024) {
                    [detail appendFormat:@" • %.1f KB/s", speed / 1024.0];
                } else if (speed > 0) {
                    [detail appendFormat:@" • %ld B/s", (long)speed];
                }
            }
            if (progress.estimatedTimeRemaining) {
                NSInteger eta = [progress.estimatedTimeRemaining integerValue];
                if (eta > 60) {
                    [detail appendFormat:@" • 剩余 %ld分%ld秒", (long)(eta / 60), (long)(eta % 60)];
                } else if (eta > 0) {
                    [detail appendFormat:@" • 剩余 %ld秒", (long)eta];
                }
            }
            self.summaryDetailLabel.text = detail.length > 0 ? detail : @"";

            if (self.fileListCount != self.task.fileList.count) {
                [self.tableView reloadData];
            }
            self.fileListCount = self.task.fileList.count;
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.task.fileList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        WFWorkflowProgressView *progressView = [[NSClassFromString(@"WFWorkflowProgressView") alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        progressView.resolvedTintColor = self.view.tintColor;
        progressView.stopSize = 0;
        cell.accessoryView = progressView;
    }

    // Unset the last cell displaying the progress
    NSProgress *lastProgress = objc_getAssociatedObject(cell, @"progress");
    if (lastProgress) {
        objc_setAssociatedObject(lastProgress, @"cell", nil, OBJC_ASSOCIATION_ASSIGN);
        @try {
            [lastProgress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch(id anException) {}
    }

    NSProgress *progress = self.task.progressList[indexPath.row];
    objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [progress addObserver:self
        forKeyPath:@"fractionCompleted"
        options:NSKeyValueObservingOptionInitial
        context:CellProgressObserverContext];

    WFWorkflowProgressView *progressView = (id)cell.accessoryView;
    if (lastProgress && lastProgress.finished) {
        [progressView reset];
    }
    progressView.fractionCompleted = progress.fractionCompleted;
    [progressView transitionCompletedLayerToVisible:progress.finished animated:NO haptic:NO];
    [progressView transitionRunningLayerToVisible:!progress.finished animated:NO];

    cell.textLabel.text = self.task.fileList[indexPath.row];
    cell.detailTextLabel.text = progress.localizedAdditionalDescription;
    return cell;
}

@end
