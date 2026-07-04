#import "DownloadTasksViewController.h"
#import "DownloadTaskManager.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import "UIKit+AFNetworking.h"
#pragma clang diagnostic pop

static const CGFloat kCellCornerRadius     = 12.0;
static const CGFloat kCellPadding          = 12.0;
static const CGFloat kIconSize             = 50.0;
static const CGFloat kTypeBadgeCornerRadius = 4.0;
static const CGFloat kFilterBarHeight      = 44.0;

#pragma mark - DownloadTaskTableViewCell

@interface DownloadTaskTableViewCell : UITableViewCell
@property (nonatomic, strong, readonly) UIView *cardView;
@property (nonatomic, strong, readonly) UIImageView *iconView;
@property (nonatomic, strong, readonly) UILabel *nameLabel;
@property (nonatomic, strong, readonly) UILabel *typeBadgeLabel;
@property (nonatomic, strong, readonly) UILabel *sourceLabel;
@property (nonatomic, strong, readonly) UILabel *speedLabel;
@property (nonatomic, strong, readonly) UILabel *percentLabel;
@property (nonatomic, strong, readonly) UIProgressView *progressView;
@property (nonatomic, strong, readonly) UILabel *statusLabel;

- (void)configureWithTask:(DownloadTaskItem *)task;
@end

@implementation DownloadTaskTableViewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        UIView *card = [[UIView alloc] init];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.layer.cornerRadius = kCellCornerRadius;
        card.layer.masksToBounds = YES;
        card.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.15];
        [self.contentView addSubview:card];
        _cardView = card;

        _iconView = [DownloadTaskTableViewCell makeIconView];
        _nameLabel = [DownloadTaskTableViewCell makeLabelWithFont:[UIFont boldSystemFontOfSize:16] textColor:[UIColor labelColor] numberOfLines:1];
        _typeBadgeLabel = [DownloadTaskTableViewCell makeLabelWithFont:[UIFont systemFontOfSize:10 weight:UIFontWeightMedium] textColor:[UIColor whiteColor] numberOfLines:1];
        _typeBadgeLabel.textAlignment = NSTextAlignmentCenter;
        _typeBadgeLabel.layer.cornerRadius = kTypeBadgeCornerRadius;
        _typeBadgeLabel.layer.masksToBounds = YES;
        _typeBadgeLabel.backgroundColor = [UIColor systemBlueColor];
        _sourceLabel = [DownloadTaskTableViewCell makeLabelWithFont:[UIFont systemFontOfSize:11] textColor:[UIColor secondaryLabelColor] numberOfLines:1];
        _speedLabel = [DownloadTaskTableViewCell makeLabelWithFont:[UIFont systemFontOfSize:11] textColor:[UIColor secondaryLabelColor] numberOfLines:1];
        _percentLabel = [DownloadTaskTableViewCell makeLabelWithFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] textColor:[UIColor labelColor] numberOfLines:1];
        _percentLabel.textAlignment = NSTextAlignmentRight;
        _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _progressView.translatesAutoresizingMaskIntoConstraints = NO;
        _progressView.trackTintColor = [UIColor colorWithWhite:0.5 alpha:0.2];
        _progressView.progressTintColor = [UIColor systemBlueColor];
        _statusLabel = [DownloadTaskTableViewCell makeLabelWithFont:[UIFont systemFontOfSize:11 weight:UIFontWeightMedium] textColor:[UIColor systemRedColor] numberOfLines:1];

        [card addSubview:_iconView];
        [card addSubview:_nameLabel];
        [card addSubview:_typeBadgeLabel];
        [card addSubview:_sourceLabel];
        [card addSubview:_speedLabel];
        [card addSubview:_percentLabel];
        [card addSubview:_progressView];
        [card addSubview:_statusLabel];

        [self setupConstraints];
    }
    return self;
}

- (UIView *)cardView {
    return _cardView;
}

- (void)setupConstraints {
    UIView *card = _cardView;
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kCellPadding],
        [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kCellPadding],
        [card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],

        [_iconView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:kCellPadding],
        [_iconView.topAnchor constraintEqualToAnchor:card.topAnchor constant:kCellPadding],
        [_iconView.widthAnchor constraintEqualToConstant:kIconSize],
        [_iconView.heightAnchor constraintEqualToConstant:kIconSize],

        [_percentLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-kCellPadding],
        [_percentLabel.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],
        [_percentLabel.widthAnchor constraintGreaterThanOrEqualToConstant:36],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:10],
        [_nameLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:kCellPadding],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_percentLabel.leadingAnchor constant:-8],

        [_typeBadgeLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_typeBadgeLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:4],
        [_typeBadgeLabel.heightAnchor constraintEqualToConstant:16],
        [_typeBadgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:28],

        [_sourceLabel.leadingAnchor constraintEqualToAnchor:_typeBadgeLabel.trailingAnchor constant:6],
        [_sourceLabel.centerYAnchor constraintEqualToAnchor:_typeBadgeLabel.centerYAnchor],
        [_sourceLabel.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-kCellPadding],

        [_speedLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_speedLabel.topAnchor constraintEqualToAnchor:_typeBadgeLabel.bottomAnchor constant:4],
        [_speedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-kCellPadding],

        [_progressView.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_progressView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-kCellPadding],
        [_progressView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-kCellPadding],
        [_progressView.heightAnchor constraintEqualToConstant:4],

        [_statusLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:_speedLabel.centerYAnchor],
        [_statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-kCellPadding]
    ]];
}

+ (UIImageView *)makeIconView {
    UIImageView *iv = [[UIImageView alloc] init];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.layer.cornerRadius = 8;
    iv.layer.masksToBounds = YES;
    iv.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.15];
    iv.tintColor = [UIColor secondaryLabelColor];
    return iv;
}

+ (UILabel *)makeLabelWithFont:(UIFont *)font textColor:(UIColor *)color numberOfLines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    return label;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [_iconView cancelImageDownloadTask];
    _iconView.image = nil;
}

- (void)configureWithTask:(DownloadTaskItem *)task {
    self.nameLabel.text = task.displayName ?: task.resourceName ?: @"";
    self.sourceLabel.text = task.downloadSource ?: @"official";
    self.typeBadgeLabel.text = [DownloadTasksViewController localizedTypeNameForResourceType:task.resourceType];
    self.typeBadgeLabel.backgroundColor = [DownloadTasksViewController colorForResourceType:task.resourceType];

    // Icon
    UIImage *fallback = [DownloadTasksViewController systemImageForResourceType:task.resourceType];
    if (task.iconURL.length > 0) {
        [self.iconView setImageWithURL:[NSURL URLWithString:task.iconURL] placeholderImage:fallback];
    } else {
        self.iconView.image = fallback;
    }

    // State-specific UI
    switch (task.state) {
        case DownloadTaskStateCompleted:
            self.progressView.progress = 1.0;
            self.progressView.progressTintColor = [UIColor systemGreenColor];
            self.percentLabel.text = @"100%";
            self.speedLabel.hidden = YES;
            self.statusLabel.hidden = YES;
            break;
        case DownloadTaskStateFailed:
            self.progressView.progress = task.progress >= 0 ? (float)task.progress : 0.0f;
            self.progressView.progressTintColor = [UIColor systemRedColor];
            self.percentLabel.text = task.progress >= 0 ? [NSString stringWithFormat:@"%.0f%%", task.progress * 100] : @"--";
            self.speedLabel.hidden = YES;
            self.statusLabel.hidden = NO;
            self.statusLabel.textColor = [UIColor systemRedColor];
            self.statusLabel.text = task.errorInfo.localizedDescription ?: @"下载失败";
            break;
        case DownloadTaskStatePaused:
            self.progressView.progress = task.progress >= 0 ? (float)task.progress : 0.0f;
            self.progressView.progressTintColor = [UIColor systemOrangeColor];
            self.percentLabel.text = task.progress >= 0 ? [NSString stringWithFormat:@"%.0f%%", task.progress * 100] : @"--";
            self.speedLabel.hidden = YES;
            self.statusLabel.hidden = NO;
            self.statusLabel.textColor = [UIColor systemOrangeColor];
            self.statusLabel.text = @"已暂停";
            break;
        default: // Pending / Downloading / Cancelled
            self.progressView.progress = task.progress >= 0 ? (float)task.progress : 0.0f;
            self.progressView.progressTintColor = [UIColor systemBlueColor];
            self.percentLabel.text = task.progress >= 0 ? [NSString stringWithFormat:@"%.0f%%", task.progress * 100] : @"--";
            self.speedLabel.hidden = NO;
            self.speedLabel.text = [self speedTextForTask:task];
            self.statusLabel.hidden = YES;
            break;
    }
}

- (NSString *)speedTextForTask:(DownloadTaskItem *)task {
    if (task.state == DownloadTaskStatePending) {
        return @"等待中...";
    }
    if (task.speed <= 0) {
        if (task.progress < 0) return @"--";
        return @"正在计算速度...";
    }
    NSString *speed = [self formattedBytes:(int64_t)task.speed unit:@"/s"];
    if (task.estimatedTimeRemaining > 0) {
        NSString *remaining = [self formattedTime:task.estimatedTimeRemaining];
        return [NSString stringWithFormat:@"%@ · 剩余 %@", speed, remaining];
    }
    return speed;
}

- (NSString *)formattedBytes:(int64_t)bytes unit:(NSString *)unit {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld B%@", bytes, unit];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB%@", bytes / 1024.0, unit];
    if (bytes < 1024LL * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB%@", bytes / (1024.0 * 1024.0), unit];
    return [NSString stringWithFormat:@"%.2f GB%@", bytes / (1024.0 * 1024.0 * 1024.0), unit];
}

- (NSString *)formattedTime:(NSTimeInterval)seconds {
    if (seconds < 60) return @"少于 1 分钟";
    NSInteger minutes = (NSInteger)(seconds / 60);
    if (minutes < 60) return [NSString stringWithFormat:@"%ld 分钟", (long)minutes];
    NSInteger hours = minutes / 60;
    minutes = minutes % 60;
    return [NSString stringWithFormat:@"%ld 小时 %ld 分钟", (long)hours, (long)minutes];
}

@end

#pragma mark - DownloadTasksViewController

@interface DownloadTasksViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISegmentedControl *stateSegmentedControl;
@property (nonatomic, strong) UIScrollView *typeFilterScrollView;
@property (nonatomic, strong) UIStackView *typeFilterStackView;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) NSArray<DownloadTaskItem *> *filteredTasks;
@property (nonatomic, copy) NSArray<NSString *> *allResourceTypes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIButton *> *typeButtons;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *typeBadges;
@end

@implementation DownloadTasksViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"下载任务";

    [self setupNavigationBar];
    [self setupStateSegmentedControl];
    [self setupTypeFilterBar];
    [self setupTableView];
    [self setupEmptyStateView];

    [self applyFilter];
    [self registerNotifications];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Ensure type filter scroll indicators update after layout
    [self.typeFilterScrollView flashScrollIndicators];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Setup

- (void)setupNavigationBar {
    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                               target:self
                                                                               action:@selector(closeTapped:)];
    self.navigationItem.leftBarButtonItem = closeItem;

    UIBarButtonItem *clearItem = [[UIBarButtonItem alloc] initWithTitle:@"清空已完成"
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(clearCompletedTapped:)];
    self.navigationItem.rightBarButtonItem = clearItem;
}

- (void)setupStateSegmentedControl {
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"下载中", @"已下载"]];
    control.translatesAutoresizingMaskIntoConstraints = NO;
    control.selectedSegmentIndex = [self initialStateSegmentIndex];
    [control addTarget:self action:@selector(stateSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:control];
    self.stateSegmentedControl = control;
}

- (void)setupTypeFilterBar {
    self.allResourceTypes = @[
        @"",
        DownloadTaskResourceTypeMinecraft,
        DownloadTaskResourceTypeModloader,
        DownloadTaskResourceTypeMod,
        DownloadTaskResourceTypeShader,
        DownloadTaskResourceTypeResourcePack,
        DownloadTaskResourceTypeDataPack,
        DownloadTaskResourceTypeModpack
    ];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.alwaysBounceHorizontal = YES;
    scrollView.contentInset = UIEdgeInsetsMake(0, 12, 0, 12);

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentCenter;

    self.typeButtons = [NSMutableDictionary dictionary];
    self.typeBadges = [NSMutableDictionary dictionary];

    for (NSString *type in self.allResourceTypes) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [button setTitle:[self titleForTypeFilter:type] forState:UIControlStateNormal];
        [button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        button.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.15];
        button.layer.cornerRadius = 14;
        button.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
        button.tag = [self.allResourceTypes indexOfObject:type];
        [button addTarget:self action:@selector(typeFilterTapped:) forControlEvents:UIControlEventTouchUpInside];

        // Badge
        UILabel *badge = [[UILabel alloc] init];
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        badge.font = [UIFont boldSystemFontOfSize:10];
        badge.textColor = [UIColor whiteColor];
        badge.backgroundColor = [UIColor systemRedColor];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.layer.cornerRadius = 8;
        badge.layer.masksToBounds = YES;
        badge.hidden = YES;
        badge.text = @"0";
        [badge addConstraint:[badge.widthAnchor constraintGreaterThanOrEqualToConstant:16]];
        [badge addConstraint:[badge.heightAnchor constraintEqualToConstant:16]];

        [button addSubview:badge];
        [NSLayoutConstraint activateConstraints:@[
            [badge.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:4],
            [badge.topAnchor constraintEqualToAnchor:button.topAnchor constant:-4]
        ]];

        [stack addArrangedSubview:button];
        self.typeButtons[type] = button;
        self.typeBadges[type] = badge;
    }

    [scrollView addSubview:stack];
    [self.view addSubview:scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scrollView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor],
        [stack.heightAnchor constraintEqualToAnchor:scrollView.heightAnchor]
    ]];

    self.typeFilterScrollView = scrollView;
    self.typeFilterStackView = stack;

    [self updateTypeFilterSelection];
}

- (void)setupTableView {
    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.estimatedRowHeight = 100;
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.backgroundColor = [UIColor clearColor];
    [tableView registerClass:[DownloadTaskTableViewCell class] forCellReuseIdentifier:@"DownloadTaskCell"];
    [self.view addSubview:tableView];
    self.tableView = tableView;

    [NSLayoutConstraint activateConstraints:@[
        [self.stateSegmentedControl.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.stateSegmentedControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.stateSegmentedControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.typeFilterScrollView.topAnchor constraintEqualToAnchor:self.stateSegmentedControl.bottomAnchor constant:12],
        [self.typeFilterScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.typeFilterScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.typeFilterScrollView.heightAnchor constraintEqualToConstant:kFilterBarHeight],

        [self.tableView.topAnchor constraintEqualToAnchor:self.typeFilterScrollView.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)setupEmptyStateView {
    UIView *view = [[UIView alloc] init];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.hidden = YES;

    UIImageView *imageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle"]];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    imageView.tintColor = [UIColor tertiaryLabelColor];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"暂无下载任务";
    label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];

    [view addSubview:imageView];
    [view addSubview:label];
    [self.view addSubview:view];

    [NSLayoutConstraint activateConstraints:@[
        [imageView.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [imageView.centerYAnchor constraintEqualToAnchor:view.centerYAnchor constant:-20],
        [imageView.widthAnchor constraintEqualToConstant:64],
        [imageView.heightAnchor constraintEqualToConstant:64],

        [label.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [label.topAnchor constraintEqualToAnchor:imageView.bottomAnchor constant:12],

        [view.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [view.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],
        [view.widthAnchor constraintEqualToAnchor:self.tableView.widthAnchor],
        [view.heightAnchor constraintEqualToAnchor:self.tableView.heightAnchor]
    ]];

    self.emptyStateView = view;
}

#pragma mark - Notifications

- (void)registerNotifications {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(handleTaskUpdated:)
                   name:DownloadTaskManagerDidUpdateTaskNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleAggregateStateChanged:)
                   name:DownloadTaskManagerAggregateStateDidChangeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleTaskCompleted:)
                   name:DownloadTaskManagerTaskCompletedNotification
                 object:nil];
}

- (void)handleTaskUpdated:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyFilter];
    });
}

- (void)handleAggregateStateChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyFilter];
    });
}

- (void)handleTaskCompleted:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyFilter];
    });
}

#pragma mark - Filtering

- (NSInteger)initialStateSegmentIndex {
    switch (self.filterState) {
        case DownloadTaskStateDownloading:
            return 1;
        case DownloadTaskStateCompleted:
        case DownloadTaskStateFailed:
            return 2;
        default:
            // Pending / Paused / Cancelled / default 0 -> "全部"
            return 0;
    }
}

- (void)stateSegmentChanged:(UISegmentedControl *)sender {
    switch (sender.selectedSegmentIndex) {
        case 0: self.filterState = DownloadTaskStatePending; break; // marker for "全部"
        case 1: self.filterState = DownloadTaskStateDownloading; break;
        case 2: self.filterState = DownloadTaskStateCompleted; break;
    }
    [self applyFilter];
}

- (void)typeFilterTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index >= 0 && index < self.allResourceTypes.count) {
        NSString *type = self.allResourceTypes[index];
        self.filterType = type.length > 0 ? type : nil;
        [self applyFilter];
        [self updateTypeFilterSelection];
    }
}

- (void)applyFilter {
    NSArray<DownloadTaskItem *> *all = [[DownloadTaskManager sharedManager] allTasks];

    // Primary filter by state
    NSArray<NSNumber *> *allowedStates;
    if (self.filterState == DownloadTaskStateDownloading) {
        allowedStates = @[@(DownloadTaskStateDownloading), @(DownloadTaskStatePending)];
    } else if (self.filterState == DownloadTaskStateCompleted) {
        allowedStates = @[@(DownloadTaskStateCompleted), @(DownloadTaskStateFailed)];
    } else {
        // "全部" segment: everything except Cancelled
        allowedStates = @[@(DownloadTaskStatePending),
                          @(DownloadTaskStateDownloading),
                          @(DownloadTaskStatePaused),
                          @(DownloadTaskStateCompleted),
                          @(DownloadTaskStateFailed)];
    }

    NSMutableArray<DownloadTaskItem *> *result = [NSMutableArray array];
    for (DownloadTaskItem *task in all) {
        if ([allowedStates containsObject:@(task.state)]) {
            if (!self.filterType || [task.resourceType isEqualToString:self.filterType]) {
                [result addObject:task];
            }
        }
    }

    // Sort: Downloading/Pending first, then Paused, Failed, Completed
    [result sortUsingComparator:^NSComparisonResult(DownloadTaskItem *a, DownloadTaskItem *b) {
        NSInteger orderA = [self sortOrderForState:a.state];
        NSInteger orderB = [self sortOrderForState:b.state];
        if (orderA != orderB) return orderA < orderB ? NSOrderedAscending : NSOrderedDescending;
        return [b.createdDate compare:a.createdDate];
    }];

    self.filteredTasks = [result copy];
    [self.tableView reloadData];
    [self updateEmptyState];
    [self updateTypeFilterBadges];
}

- (NSInteger)sortOrderForState:(DownloadTaskState)state {
    switch (state) {
        case DownloadTaskStateDownloading: return 0;
        case DownloadTaskStatePending:     return 1;
        case DownloadTaskStatePaused:      return 2;
        case DownloadTaskStateFailed:      return 3;
        case DownloadTaskStateCompleted:   return 4;
        default: return 5;
    }
}

- (void)updateEmptyState {
    BOOL empty = self.filteredTasks.count == 0;
    self.emptyStateView.hidden = !empty;
    self.tableView.hidden = empty;
}

- (void)updateTypeFilterSelection {
    NSString *selectedType = self.filterType ?: @"";
    for (NSString *type in self.allResourceTypes) {
        UIButton *button = self.typeButtons[type];
        BOOL selected = [type isEqualToString:selectedType];
        button.backgroundColor = selected ? [UIColor systemBlueColor] : [UIColor colorWithWhite:0.5 alpha:0.15];
        [button setTitleColor:selected ? [UIColor whiteColor] : [UIColor labelColor] forState:UIControlStateNormal];
    }
}

- (void)updateTypeFilterBadges {
    NSArray<DownloadTaskItem *> *all = [[DownloadTaskManager sharedManager] allTasks];

    // Determine primary state filter for badge counting
    NSArray<NSNumber *> *allowedStates;
    if (self.filterState == DownloadTaskStateDownloading) {
        allowedStates = @[@(DownloadTaskStateDownloading), @(DownloadTaskStatePending)];
    } else if (self.filterState == DownloadTaskStateCompleted) {
        allowedStates = @[@(DownloadTaskStateCompleted), @(DownloadTaskStateFailed)];
    } else {
        allowedStates = @[@(DownloadTaskStatePending),
                          @(DownloadTaskStateDownloading),
                          @(DownloadTaskStatePaused),
                          @(DownloadTaskStateCompleted),
                          @(DownloadTaskStateFailed)];
    }

    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (DownloadTaskItem *task in all) {
        if (![allowedStates containsObject:@(task.state)]) continue;
        NSString *type = task.resourceType ?: @"";
        counts[type] = @([counts[type] integerValue] + 1);
    }

    for (NSString *type in self.allResourceTypes) {
        UILabel *badge = self.typeBadges[type];
        NSInteger count = [counts[type] integerValue];
        if (count > 0) {
            badge.hidden = NO;
            badge.text = [NSString stringWithFormat:@"%ld", (long)count];
        } else {
            badge.hidden = YES;
        }
    }
}

#pragma mark - Actions

- (void)closeTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)clearCompletedTapped:(id)sender {
    NSArray<DownloadTaskItem *> *all = [[DownloadTaskManager sharedManager] allTasks];
    for (DownloadTaskItem *task in all) {
        if (task.state == DownloadTaskStateCompleted || task.state == DownloadTaskStateFailed || task.state == DownloadTaskStateCancelled) {
            [[DownloadTaskManager sharedManager] removeTaskWithId:task.taskId];
        }
    }
    [self applyFilter];
}

#pragma mark - Long press actions

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    CGPoint point = [gesture locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath) return;

    DownloadTaskItem *task = self.filteredTasks[indexPath.row];
    [self showActionSheetForTask:task];
}

- (void)showActionSheetForTask:(DownloadTaskItem *)task {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:task.displayName
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    BOOL canPause = (task.state == DownloadTaskStateDownloading || task.state == DownloadTaskStatePending);
    BOOL canResume = (task.state == DownloadTaskStatePaused);
    BOOL canCancel = !(task.state == DownloadTaskStateCompleted || task.state == DownloadTaskStateCancelled || task.state == DownloadTaskStateFailed);

    if (canPause) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"暂停" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[DownloadTaskManager sharedManager] pauseTaskWithId:task.taskId];
        }]];
    }

    if (canResume) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[DownloadTaskManager sharedManager] resumeTaskWithId:task.taskId];
        }]];
    }

    if (canCancel) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[DownloadTaskManager sharedManager] cancelTaskWithId:task.taskId];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"切换下载源" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showSwitchSourceAlertForTask:task];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        sheet.popoverPresentationController.permittedArrowDirections = 0;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showSwitchSourceAlertForTask:(DownloadTaskItem *)task {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"切换下载源"
                                                                   message:[NSString stringWithFormat:@"当前源：%@", task.downloadSource ?: @"official"]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"输入新的下载源地址或标识";
        textField.text = task.downloadSource;
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        UITextField *textField = alert.textFields.firstObject;
        NSString *newSource = textField.text ?: @"";
        if (newSource.length == 0) return;

        [[DownloadTaskManager sharedManager] switchDownloadSourceForTaskId:task.taskId
                                                                  toSource:newSource
                                                                completion:^(BOOL shouldRecreate, BOOL supportsResume, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    [strongSelf showAlertWithTitle:@"切换失败" message:error.localizedDescription];
                    return;
                }
                if (shouldRecreate && !supportsResume) {
                    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"提示"
                                                                                     message:@"该源不支持断点续传，确认后将重新从头下载。"
                                                                              preferredStyle:UIAlertControllerStyleAlert];
                    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                    [confirm addAction:[UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                        [[DownloadTaskManager sharedManager] cancelTaskWithId:task.taskId];
                        [strongSelf showAlertWithTitle:@"已取消" message:@"请手动重新触发下载以使用新的下载源。"];
                    }]];
                    [strongSelf presentViewController:confirm animated:YES completion:nil];
                } else {
                    [strongSelf showAlertWithTitle:@"切换成功" message:@"下载源已更新。"];
                }
            });
        }];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.filteredTasks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DownloadTaskTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DownloadTaskCell" forIndexPath:indexPath];
    DownloadTaskItem *task = self.filteredTasks[indexPath.row];
    [cell configureWithTask:task];

    // Attach long press gesture if not already attached
    BOOL hasGesture = NO;
    for (UIGestureRecognizer *g in cell.contentView.gestureRecognizers) {
        if ([g isKindOfClass:[UILongPressGestureRecognizer class]]) {
            hasGesture = YES;
            break;
        }
    }
    if (!hasGesture) {
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 0.5;
        [cell.contentView addGestureRecognizer:longPress];
    }

    return cell;
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell isKindOfClass:[DownloadTaskTableViewCell class]]) {
        DownloadTaskTableViewCell *taskCell = (DownloadTaskTableViewCell *)cell;
        UIView *card = taskCell.cardView;
        if (card) {
            card.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.15];
        }
    }
}

#pragma mark - Helpers

- (NSString *)titleForTypeFilter:(NSString *)type {
    if (type.length == 0) return @"全部";
    return [DownloadTasksViewController localizedTypeNameForResourceType:type];
}

+ (NSString *)localizedTypeNameForResourceType:(NSString *)type {
    if ([type isEqualToString:DownloadTaskResourceTypeMinecraft])    return @"MC 本体";
    if ([type isEqualToString:DownloadTaskResourceTypeModloader])    return @"Mod 加载器";
    if ([type isEqualToString:DownloadTaskResourceTypeMod])          return @"Mod";
    if ([type isEqualToString:DownloadTaskResourceTypeShader])       return @"光影包";
    if ([type isEqualToString:DownloadTaskResourceTypeResourcePack]) return @"资源包";
    if ([type isEqualToString:DownloadTaskResourceTypeDataPack])     return @"数据包";
    if ([type isEqualToString:DownloadTaskResourceTypeModpack])      return @"整合包";
    return type ?: @"其他";
}

+ (UIColor *)colorForResourceType:(NSString *)type {
    if ([type isEqualToString:DownloadTaskResourceTypeMinecraft])    return [UIColor systemIndigoColor];
    if ([type isEqualToString:DownloadTaskResourceTypeModloader])    return [UIColor systemOrangeColor];
    if ([type isEqualToString:DownloadTaskResourceTypeMod])          return [UIColor systemBlueColor];
    if ([type isEqualToString:DownloadTaskResourceTypeShader])       return [UIColor systemYellowColor];
    if ([type isEqualToString:DownloadTaskResourceTypeResourcePack]) return [UIColor systemPinkColor];
    if ([type isEqualToString:DownloadTaskResourceTypeDataPack])     return [UIColor systemTealColor];
    if ([type isEqualToString:DownloadTaskResourceTypeModpack])      return [UIColor systemPurpleColor];
    return [UIColor systemGrayColor];
}

+ (UIImage *)systemImageForResourceType:(NSString *)type {
    NSString *name = @"doc";
    if ([type isEqualToString:DownloadTaskResourceTypeMinecraft])    name = @"cube";
    else if ([type isEqualToString:DownloadTaskResourceTypeModloader])    name = @"gearshape.2";
    else if ([type isEqualToString:DownloadTaskResourceTypeMod])          name = @"puzzlepiece.extension";
    else if ([type isEqualToString:DownloadTaskResourceTypeShader])       name = @"sun.max";
    else if ([type isEqualToString:DownloadTaskResourceTypeResourcePack]) name = @"paintpalette";
    else if ([type isEqualToString:DownloadTaskResourceTypeDataPack])     name = @"archivebox";
    else if ([type isEqualToString:DownloadTaskResourceTypeModpack])      name = @"cube.box";

    UIImage *image = [UIImage systemImageNamed:name];
    if (!image) image = [UIImage systemImageNamed:@"doc"];
    return image;
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
