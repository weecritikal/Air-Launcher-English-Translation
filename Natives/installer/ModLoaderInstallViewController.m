//
//  ModLoaderInstallViewController.m
//  Amethyst
//
//  参照 FCL (FoldCraftLauncher) 的模组加载器选择界面重构。
//
//  主要改进：
//  1. 加载器列表用 UITableView(UITableViewStyleGrouped) Grouped 风格，行卡片式选择
//     （与 FCL 的 InstallerItemGroup 行布局一致：图标 + 名称 + 状态 + 选择按钮）
//  2. 互斥逻辑与 FCL 完全一致：
//     - forge/fabric/quilt/neoforge 互斥
//     - optifine 与 fabric/quilt/neoforge 不兼容（与 forge 可共存）
//     - fabricApi 依赖 fabric，与 forge/optifine/neoforge 互斥
//  3. 版本列表 push 到独立的 ModLoaderVersionPickerViewController，
//     解决原实现"加载器列表固定 320pt + optionsContainer 50pt + 安装按钮"
//     在 iPhone 上挤压 versionTableView 到接近 0 高度的问题
//  4. 底部安装按钮钉在 safeAreaLayoutGuide.bottomAnchor，iPhone 上不会被 Home Indicator 遮挡
//  5. 顶部新增"版本名"输入框，自动生成 "游戏版本-加载器名"（参照 FCL VersionInstallInfoPage）
//

#import "ModLoaderInstallViewController.h"
#import "NeoForgeVersionFetcher.h"
#import "LauncherPreferences.h"

#pragma mark - Data Models

/// 加载器元数据
@interface ModLoaderRow : NSObject
@property (nonatomic, copy) NSString *identifier;   // "vanilla"/"fabric"/"forge"/"neoforge"/"quilt"/"optifine"
@property (nonatomic, copy) NSString *name;         // 显示名
@property (nonatomic, copy) NSString *desc;         // 描述
@property (nonatomic, copy) NSString *iconName;     // SF Symbol 名
@property (nonatomic, strong) UIColor *iconColor;   // 图标主色
@property (nonatomic, assign) BOOL compatible;      // 与当前游戏版本是否兼容
@property (nonatomic, copy, nullable) NSString *selectedVersion; // 选中版本（nil 表示未选）
@end
@implementation ModLoaderRow
@end

#pragma mark - Loader Cell (行卡片式)

@interface ModLoaderLoaderCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *statusLabel;   // 右侧状态：选中版本/不兼容/未选择
@property (nonatomic, strong) UIImageView *chevronView;
@property (nonatomic, strong) UIView *separator;
@end

@implementation ModLoaderLoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _iconView = [[UIImageView alloc] init];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.layer.cornerRadius = 10;
        _iconView.clipsToBounds = YES;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_iconView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _nameLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:_nameLabel];

        _descLabel = [[UILabel alloc] init];
        _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _descLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _descLabel.textColor = [UIColor secondaryLabelColor];
        _descLabel.numberOfLines = 2;
        [self.contentView addSubview:_descLabel];

        _statusLabel = [[UILabel alloc] init];
        _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _statusLabel.textColor = [UIColor secondaryLabelColor];
        _statusLabel.textAlignment = NSTextAlignmentRight;
        _statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_statusLabel];

        _chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        _chevronView.tintColor = [UIColor tertiaryLabelColor];
        _chevronView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_chevronView];

        _separator = [[UIView alloc] init];
        _separator.translatesAutoresizingMaskIntoConstraints = NO;
        _separator.backgroundColor = [UIColor separatorColor];
        [self.contentView addSubview:_separator];

        [NSLayoutConstraint activateConstraints:@[
            [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:40],
            [_iconView.heightAnchor constraintEqualToConstant:40],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_statusLabel.leadingAnchor constant:-8],

            [_descLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_descLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:3],
            [_descLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_statusLabel.leadingAnchor constant:-8],
            [_descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-12],

            [_statusLabel.trailingAnchor constraintEqualToAnchor:_chevronView.leadingAnchor constant:-4],
            [_statusLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_statusLabel.widthAnchor constraintLessThanOrEqualToConstant:140],

            [_chevronView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_chevronView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_chevronView.widthAnchor constraintEqualToConstant:14],
            [_chevronView.heightAnchor constraintEqualToConstant:14],

            [_separator.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [_separator.heightAnchor constraintEqualToConstant:0.5],
        ]];
    }
    return self;
}

- (void)setIncompatible:(BOOL)incompatible reason:(NSString *)reason {
    if (incompatible) {
        _statusLabel.hidden = NO;
        _statusLabel.text = reason ?: @"不兼容";
        _statusLabel.textColor = [UIColor systemRedColor];
        _nameLabel.textColor = [UIColor tertiaryLabelColor];
        _descLabel.textColor = [UIColor quaternaryLabelColor];
        _iconView.alpha = 0.5;
        _chevronView.hidden = YES;
        self.userInteractionEnabled = NO;
    } else {
        _nameLabel.textColor = [UIColor labelColor];
        _descLabel.textColor = [UIColor secondaryLabelColor];
        _iconView.alpha = 1.0;
        _chevronView.hidden = NO;
        self.userInteractionEnabled = YES;
    }
}

- (void)setSelectedVersionText:(NSString *)text {
    if (text.length > 0) {
        _statusLabel.hidden = NO;
        _statusLabel.text = text;
        _statusLabel.textColor = [UIColor systemGreenColor];
    } else {
        _statusLabel.hidden = NO;
        _statusLabel.text = @"选择版本";
        _statusLabel.textColor = [UIColor secondaryLabelColor];
    }
}

/// 清空右侧状态文字（未选中加载器时使用）
- (void)clearStatusText {
    _statusLabel.hidden = YES;
    _statusLabel.text = nil;
}

@end

#pragma mark - Switch Cell (Fabric API / OptiFine 选项)

@interface ModLoaderSwitchCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UISwitch *switchControl;
@end

@implementation ModLoaderSwitchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:_titleLabel];

        _descLabel = [[UILabel alloc] init];
        _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _descLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _descLabel.textColor = [UIColor secondaryLabelColor];
        _descLabel.numberOfLines = 0;
        [self.contentView addSubview:_descLabel];

        _switchControl = [[UISwitch alloc] init];
        _switchControl.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_switchControl];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_switchControl.leadingAnchor constant:-12],

            [_descLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_descLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
            [_descLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_switchControl.leadingAnchor constant:-12],
            [_descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-10],

            [_switchControl.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_switchControl.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

@end

#pragma mark - Version Picker View Controller (版本选择子页面)

@interface ModLoaderVersionPickerViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, NSXMLParserDelegate>
@property (nonatomic, copy) NSString *loaderId;
@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, copy) NSString *selectedVersion;
@property (nonatomic, copy) void (^onSelected)(NSString *version);
@property (nonatomic, copy) void (^onCancelled)(void);
@end

@interface ModLoaderVersionPickerViewController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) NSArray *versions;
// Forge XML 解析
@property (nonatomic, strong) NSMutableArray *forgeVersionList;
@property (nonatomic, strong) NSMutableString *currentVersionValue;
@property (nonatomic, assign) BOOL isParsingForge;
// 网络任务
@property (nonatomic, strong) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong) NSURLSessionDataTask *bmclTask;
@end

@implementation ModLoaderVersionPickerViewController

- (void)dealloc {
    if (_currentTask) { [_currentTask cancel]; _currentTask = nil; }
    if (_bmclTask) { [_bmclTask cancel]; _bmclTask = nil; }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self pickerTitle];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(backTapped)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor labelColor];

    [self setupTableView];
    [self startLoading];
}

- (NSString *)pickerTitle {
    if ([_loaderId isEqualToString:@"fabric"])   return @"Fabric 版本";
    if ([_loaderId isEqualToString:@"forge"])    return @"Forge 版本";
    if ([_loaderId isEqualToString:@"neoforge"]) return @"NeoForge 版本";
    if ([_loaderId isEqualToString:@"quilt"])    return @"Quilt 版本";
    if ([_loaderId isEqualToString:@"optifine"]) return @"OptiFine 版本";
    return @"选择版本";
}

- (void)setupTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 50;
    [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"VersionCell"];
    [self.view addSubview:_tableView];

    _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:_loadingIndicator];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.text = @"暂无可用版本";
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.textColor = [UIColor secondaryLabelColor];
    _emptyLabel.font = [UIFont systemFontOfSize:15];
    _emptyLabel.hidden = YES;
    [self.view addSubview:_emptyLabel];

    _errorLabel = [[UILabel alloc] init];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.text = @"加载失败，请检查网络";
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.textColor = [UIColor systemRedColor];
    _errorLabel.font = [UIFont systemFontOfSize:15];
    _errorLabel.numberOfLines = 0;
    _errorLabel.hidden = YES;
    [self.view addSubview:_errorLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [_errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [_errorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
}

- (void)backTapped {
    if (_onCancelled) _onCancelled();
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)startLoading {
    _versions = nil;
    [_tableView reloadData];
    _emptyLabel.hidden = YES;
    _errorLabel.hidden = YES;
    [_loadingIndicator startAnimating];

    if ([_loaderId isEqualToString:@"fabric"] || [_loaderId isEqualToString:@"quilt"]) {
        [self loadFabricLikeVersions:_loaderId];
    } else if ([_loaderId isEqualToString:@"forge"]) {
        [self loadForgeVersions];
    } else if ([_loaderId isEqualToString:@"neoforge"]) {
        [self loadNeoForgeVersions];
    } else if ([_loaderId isEqualToString:@"optifine"]) {
        [self loadOptiFineVersions];
    } else {
        [self finishLoadingWithVersions:@[] error:nil];
    }
}

#pragma mark Fabric / Quilt

- (void)loadFabricLikeVersions:(NSString *)loaderType {
    NSString *metaBase = [loaderType isEqualToString:@"quilt"]
        ? @"https://meta.quiltmc.org/v3/versions/loader"
        : @"https://meta.fabricmc.net/v2/versions/loader";
    NSString *urlString = [NSString stringWithFormat:@"%@/%@", metaBase, _gameVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    __weak typeof(self) weakSelf = self;
    _currentTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error && error.code != NSURLErrorCancelled) {
                [strongSelf finishLoadingWithVersions:@[] error:error];
                return;
            }
            if (!data || error) {
                [strongSelf finishLoadingWithVersions:@[] error:nil];
                return;
            }
            NSError *jsonError;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!versions || jsonError) {
                [strongSelf finishLoadingWithVersions:@[] error:jsonError];
                return;
            }
            NSMutableArray *list = [NSMutableArray array];
            for (NSDictionary *ver in versions) {
                if (![ver isKindOfClass:[NSDictionary class]]) continue;
                NSString *loaderVersion = ver[@"loader"][@"version"];
                if (loaderVersion && ![list containsObject:loaderVersion]) {
                    [list addObject:loaderVersion];
                }
            }
            [strongSelf finishLoadingWithVersions:list error:nil];
        });
    }];
    [_currentTask resume];
}

#pragma mark Forge (并发竞速，参照原 loadForgeVersionsReal)

- (void)loadForgeVersions {
    // 参照 FCL/HMCL：并发竞速同时发起官方源和 BMCLAPI 请求，谁先成功用谁
    NSString *bmclURL = @"https://bmclapi2.bangbang93.com/maven/net/minecraftforge/forge/maven-metadata.xml";
    NSString *officialURL = @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml";

    _forgeVersionList = [NSMutableArray array];
    _isParsingForge = YES;

    __weak typeof(self) weakSelf = self;
    __block BOOL settled = NO;

    NSString *userAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

    void (^processData)(NSData *) = ^(NSData *data) {
        @synchronized(weakSelf) {
            if (settled) return;
            settled = YES;
        }
        if (!data || data.length == 0) return;
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
        parser.delegate = weakSelf;
        [parser parse];
    };

    NSMutableURLRequest *bmclRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:bmclURL]];
    bmclRequest.timeoutInterval = 20.0;
    [bmclRequest setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    _bmclTask = [[NSURLSession sharedSession] dataTaskWithRequest:bmclRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            @synchronized(weakSelf) { if (settled) return; }
            return;
        }
        processData(data);
    }];

    NSMutableURLRequest *officialRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:officialURL]];
    officialRequest.timeoutInterval = 20.0;
    [officialRequest setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    _currentTask = [[NSURLSession sharedSession] dataTaskWithRequest:officialRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            @synchronized(weakSelf) { if (settled) return; }
            // 给 BMCLAPI 5s 宽限期
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @synchronized(weakSelf) {
                    if (settled) return;
                    settled = YES;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    [strongSelf finishLoadingWithVersions:@[] error:error];
                });
            });
            return;
        }
        processData(data);
    }];

    [_bmclTask resume];
    [_currentTask resume];
}

#pragma mark NeoForge

- (void)loadNeoForgeVersions {
    __weak typeof(self) weakSelf = self;
    [NeoForgeVersionFetcher fetchVersionsForGameVersion:_gameVersion completion:^(NSArray *versions, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf finishLoadingWithVersions:versions ?: @[] error:error];
        });
    }];
}

#pragma mark OptiFine (BMCLAPI 列表)

- (void)loadOptiFineVersions {
    NSString *urlString = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", _gameVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    __weak typeof(self) weakSelf = self;
    _currentTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error && error.code != NSURLErrorCancelled) {
                [strongSelf finishLoadingWithVersions:@[] error:error];
                return;
            }
            if (!data || error) {
                [strongSelf finishLoadingWithVersions:@[] error:nil];
                return;
            }
            NSError *jsonError;
            NSArray *list = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!list || jsonError || ![list isKindOfClass:[NSArray class]]) {
                [strongSelf finishLoadingWithVersions:@[] error:jsonError];
                return;
            }
            NSMutableArray *versions = [NSMutableArray array];
            for (NSDictionary *item in list) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *type = item[@"type"] ?: @"";
                NSString *patch = item[@"patch"] ?: @"";
                NSString *filename = item[@"filename"] ?: @"";
                if (patch.length == 0) continue;
                // 显示格式：HD_U_I6 (filename)
                NSString *display = [NSString stringWithFormat:@"%@_%@", type, patch];
                if (filename.length > 0) {
                    display = [NSString stringWithFormat:@"%@_%@ (%@)", type, patch, filename];
                }
                // 把完整信息打包进 version 字符串，用 \x1f 分隔（unit separator）
                NSString *packed = [NSString stringWithFormat:@"%@\x1f%@\x1f%@\x1f%@", type, patch, filename, display];
                [versions addObject:packed];
            }
            [strongSelf finishLoadingWithVersions:versions error:nil];
        });
    }];
    [_currentTask resume];
}

- (void)finishLoadingWithVersions:(NSArray *)versions error:(NSError *)error {
    [_loadingIndicator stopAnimating];
    _isParsingForge = NO;

    if (error && versions.count == 0) {
        _versions = @[];
        _errorLabel.hidden = NO;
        _emptyLabel.hidden = YES;
        _errorLabel.text = [NSString stringWithFormat:@"加载失败：%@", error.localizedDescription ?: @"未知错误"];
    } else {
        _versions = versions ?: @[];
        _errorLabel.hidden = YES;
        _emptyLabel.hidden = (_versions.count > 0);
    }
    [_tableView reloadData];

    // 若当前已选中版本，滚动到选中行
    if (_selectedVersion.length > 0 && _versions.count > 0) {
        NSUInteger idx = [_versions indexOfObject:_selectedVersion];
        if (idx != NSNotFound) {
            [_tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:idx inSection:0]
                              atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        }
    }
}

#pragma mark NSXMLParserDelegate (Forge)

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"version"]) {
        _currentVersionValue = [NSMutableString new];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [_currentVersionValue appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if (!_isParsingForge) return;
    if ([elementName isEqualToString:@"version"]) {
        NSString *version = [_currentVersionValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (version.length > 0) {
            @synchronized (self) {
                NSString *prefix = [self.gameVersion stringByAppendingString:@"-"];
                if ([version hasPrefix:prefix]) {
                    [self.forgeVersionList addObject:version];
                }
            }
        }
    }
}

- (void)parserDidEndDocument:(NSXMLParser *)parser {
    _isParsingForge = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.forgeVersionList sortUsingComparator:^NSComparisonResult(NSString *v1, NSString *v2) {
            return [v2 compare:v1 options:NSNumericSearch];
        }];
        [self finishLoadingWithVersions:self.forgeVersionList error:nil];
    });
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError {
    _isParsingForge = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishLoadingWithVersions:@[] error:parseError];
    });
}

#pragma mark TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"VersionCell" forIndexPath:indexPath];
    NSString *raw = _versions[indexPath.row];

    // 处理 OptiFine packed 格式（type\x1fpatch\x1ffilename\x1fdisplay）
    NSString *display = raw;
    if ([raw containsString:@"\x1f"]) {
        NSArray *parts = [raw componentsSeparatedByString:@"\x1f"];
        if (parts.count >= 4) display = parts[3];
    }

    cell.textLabel.text = display;
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.backgroundColor = [UIColor clearColor];
    cell.accessoryType = [_selectedVersion isEqualToString:raw] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor systemGreenColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *raw = _versions[indexPath.row];
    _selectedVersion = raw;
    [tableView reloadData];

    // 短暂展示选中状态后 pop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.onSelected) self.onSelected(raw);
        if (self.navigationController.viewControllers.count > 1) {
            [self.navigationController popViewControllerAnimated:YES];
        } else {
            [self dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

@end

#pragma mark - Main Controller

@interface ModLoaderInstallViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UIButton *installButton;
@property (nonatomic, strong) UITextField *versionNameField;
@property (nonatomic, strong) UIView *nameBar;

// 数据
@property (nonatomic, strong) NSMutableArray<ModLoaderRow *> *loaders;
@property (nonatomic, copy) NSString *selectedLoaderId;       // "vanilla"/"fabric"/"forge"/"neoforge"/"quilt"/"optifine"
@property (nonatomic, copy) NSString *selectedFabricVersion;
@property (nonatomic, copy) NSString *selectedForgeVersion;
@property (nonatomic, copy) NSString *selectedNeoForgeVersion;
@property (nonatomic, copy) NSString *selectedQuiltVersion;
@property (nonatomic, copy) NSString *selectedOptiFineVersion;
@property (nonatomic, copy) NSString *selectedOptiFineType;     // HD_U 等
@property (nonatomic, copy) NSString *selectedOptiFinePatch;
@property (nonatomic, copy) NSString *selectedOptiFineFilename;

// 选项
@property (nonatomic, assign) BOOL installFabricAPI;
@property (nonatomic, assign) BOOL installOptiFine;  // 仅 forge 选中时显示

// 用户是否手动修改过版本名
@property (nonatomic, assign) BOOL nameManuallyModified;
@end

@implementation ModLoaderInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(backTapped)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor labelColor];

    _installFabricAPI = YES;  // Fabric 默认勾选 Fabric API（与 FCL 默认行为一致）

    [self setupLoaders];
    [self setupNameBar];
    [self setupBottomBar];    // 先创建底部按钮，setupTableView 才能引用 _bottomBar.topAnchor
    [self setupTableView];
    [self refreshIncompatibilities];
    [self refreshVersionName];
}

#pragma mark Setup

- (void)setupLoaders {
    _loaders = [NSMutableArray array];

    BOOL fabricCompatible = [self isFabricCompatible];
    BOOL quiltCompatible = [self isQuiltCompatible];
    BOOL forgeCompatible = [self isForgeCompatible];
    BOOL neoForgeCompatible = [self isNeoForgeCompatible];
    BOOL optiFineCompatible = [self isOptiFineCompatible];

    NSDictionary *iconFor = @{
        @"vanilla":  @"cube.fill",
        @"fabric":   @"bolt.fill",
        @"forge":    @"hammer.fill",
        @"neoforge": @"hammer.fill",
        @"quilt":    @"bolt.fill",
        @"optifine": @"eyeglasses",
    };

    NSArray *defs = @[
        @{ @"id": @"vanilla",  @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"color": @"gray",  @"compatible": @YES },
        @{ @"id": @"fabric",   @"name": @"Fabric",        @"desc": @"轻量级模组加载器，适合小型模组",      @"color": @"orange",@"compatible": @(fabricCompatible) },
        @{ @"id": @"forge",    @"name": @"Forge",         @"desc": @"经典模组加载器，模组生态丰富",        @"color": @"red",   @"compatible": @(forgeCompatible) },
        @{ @"id": @"neoforge", @"name": @"NeoForge",      @"desc": @"Forge 的分支，支持 1.20.1+",          @"color": @"brown", @"compatible": @(neoForgeCompatible) },
        @{ @"id": @"quilt",    @"name": @"Quilt",         @"desc": @"基于 Fabric 的新一代加载器",         @"color": @"purple",@"compatible": @(quiltCompatible) },
        @{ @"id": @"optifine", @"name": @"OptiFine",      @"desc": @"光影与画质优化（作为版本补丁安装）",  @"color": @"blue",  @"compatible": @(optiFineCompatible) },
    ];

    for (NSDictionary *d in defs) {
        ModLoaderRow *row = [ModLoaderRow new];
        row.identifier = d[@"id"];
        row.name = d[@"name"];
        row.desc = d[@"desc"];
        row.iconName = iconFor[d[@"id"]] ?: @"cube.fill";
        row.compatible = [d[@"compatible"] boolValue];
        NSString *colorKey = d[@"color"];
        if ([colorKey isEqualToString:@"gray"])   row.iconColor = [UIColor systemGrayColor];
        else if ([colorKey isEqualToString:@"orange"]) row.iconColor = [UIColor systemOrangeColor];
        else if ([colorKey isEqualToString:@"red"])    row.iconColor = [UIColor systemRedColor];
        else if ([colorKey isEqualToString:@"brown"])  row.iconColor = [UIColor systemBrownColor];
        else if ([colorKey isEqualToString:@"purple"]) row.iconColor = [UIColor systemPurpleColor];
        else if ([colorKey isEqualToString:@"blue"])   row.iconColor = [UIColor systemBlueColor];
        else row.iconColor = [UIColor systemGrayColor];
        [_loaders addObject:row];
    }
}

- (void)setupNameBar {
    _nameBar = [[UIView alloc] init];
    _nameBar.translatesAutoresizingMaskIntoConstraints = NO;
    _nameBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    [self.view addSubview:_nameBar];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"版本名";
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    [_nameBar addSubview:label];

    _versionNameField = [[UITextField alloc] init];
    _versionNameField.translatesAutoresizingMaskIntoConstraints = NO;
    _versionNameField.font = [UIFont systemFontOfSize:15];
    _versionNameField.textColor = [UIColor labelColor];
    _versionNameField.placeholder = @"输入版本名";
    _versionNameField.borderStyle = UITextBorderStyleNone;
    _versionNameField.returnKeyType = UIReturnKeyDone;
    _versionNameField.delegate = self;
    _versionNameField.autocorrectionType = UITextAutocorrectionTypeNo;
    _versionNameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [_nameBar addSubview:_versionNameField];

    [NSLayoutConstraint activateConstraints:@[
        [_nameBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [_nameBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_nameBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_nameBar.heightAnchor constraintEqualToConstant:48],

        [label.leadingAnchor constraintEqualToAnchor:_nameBar.leadingAnchor constant:12],
        [label.centerYAnchor constraintEqualToAnchor:_nameBar.centerYAnchor],

        [_versionNameField.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:12],
        [_versionNameField.trailingAnchor constraintEqualToAnchor:_nameBar.trailingAnchor constant:-12],
        [_versionNameField.centerYAnchor constraintEqualToAnchor:_nameBar.centerYAnchor],
        [_versionNameField.heightAnchor constraintEqualToAnchor:_nameBar.heightAnchor],
    ]];
}

- (void)setupTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.estimatedRowHeight = 76;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [_tableView registerClass:[ModLoaderLoaderCell class] forCellReuseIdentifier:@"LoaderCell"];
    [_tableView registerClass:[ModLoaderSwitchCell class] forCellReuseIdentifier:@"SwitchCell"];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:_nameBar.bottomAnchor constant:8],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:_bottomBar.topAnchor],
    ]];
}

- (void)setupBottomBar {
    _bottomBar = [[UIView alloc] init];
    _bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    _bottomBar.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_bottomBar];

    _installButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _installButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_installButton setTitle:@"安装" forState:UIControlStateNormal];
    _installButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _installButton.backgroundColor = [UIColor systemGreenColor];
    [_installButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _installButton.layer.cornerRadius = 12;
    [_installButton addTarget:self action:@selector(installTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_installButton];

    [NSLayoutConstraint activateConstraints:@[
        [_bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_bottomBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [_bottomBar.heightAnchor constraintEqualToConstant:72],

        [_installButton.leadingAnchor constraintEqualToAnchor:_bottomBar.leadingAnchor constant:16],
        [_installButton.trailingAnchor constraintEqualToAnchor:_bottomBar.trailingAnchor constant:-16],
        [_installButton.centerYAnchor constraintEqualToAnchor:_bottomBar.centerYAnchor],
        [_installButton.heightAnchor constraintEqualToConstant:50],
    ]];
}

#pragma mark Compatibility checks (与原 LoaderSelectionViewController 一致)

- (BOOL)isFabricCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 14) return YES;
    return NO;
}

- (BOOL)isQuiltCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 18) return YES;
    return NO;
}

- (BOOL)isForgeCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major == 1 && minor >= 1) return YES;
    if (major > 1) return YES;
    return NO;
}

- (BOOL)isNeoForgeCompatible {
    if (!_gameVersion) return NO;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return NO;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    NSInteger patch = (c.count > 2) ? [c[2] integerValue] : 0;
    if (major > 1) return YES;
    if (major == 1 && minor == 20 && patch >= 1) return YES;
    if (major == 1 && minor > 20) return YES;
    return NO;
}

- (BOOL)isOptiFineCompatible {
    // OptiFine 1.14+ 与 Forge 兼容，1.13 及以下独立装为版本补丁
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 8) return YES;
    return NO;
}

#pragma mark Compatibility (互斥逻辑，参照 FCL InstallerItemGroup)

- (NSString *)incompatibleReasonForLoaderId:(NSString *)loaderId {
    // fabricApi 与 forge/optifine/neoforge 互斥
    // optifine 与 fabric/quilt/neoforge 互斥（与 forge 可共存）
    // forge/fabric/quilt/neoforge 互斥

    if ([loaderId isEqualToString:@"vanilla"]) return nil;

    BOOL fabricSelected  = [_selectedLoaderId isEqualToString:@"fabric"];
    BOOL forgeSelected   = [_selectedLoaderId isEqualToString:@"forge"];
    BOOL neoSelected     = [_selectedLoaderId isEqualToString:@"neoforge"];
    BOOL quiltSelected   = [_selectedLoaderId isEqualToString:@"quilt"];
    BOOL optiSelected    = [_selectedLoaderId isEqualToString:@"optifine"];

    if ([loaderId isEqualToString:@"fabric"] || [loaderId isEqualToString:@"forge"] ||
        [loaderId isEqualToString:@"neoforge"] || [loaderId isEqualToString:@"quilt"]) {
        // 加载器组互斥
        if (fabricSelected  && ![loaderId isEqualToString:@"fabric"])  return @"与 Fabric 冲突";
        if (forgeSelected   && ![loaderId isEqualToString:@"forge"])   return @"与 Forge 冲突";
        if (neoSelected     && ![loaderId isEqualToString:@"neoforge"]) return @"与 NeoForge 冲突";
        if (quiltSelected   && ![loaderId isEqualToString:@"quilt"])   return @"与 Quilt 冲突";
        // optifine 与 fabric/quilt/neoforge 互斥
        if (optiSelected) {
            if ([loaderId isEqualToString:@"fabric"])  return @"与 OptiFine 冲突";
            if ([loaderId isEqualToString:@"quilt"])   return @"与 OptiFine 冲突";
            if ([loaderId isEqualToString:@"neoforge"]) return @"与 OptiFine 冲突";
        }
    }

    if ([loaderId isEqualToString:@"optifine"]) {
        if (fabricSelected)  return @"与 Fabric 冲突";
        if (quiltSelected)   return @"与 Quilt 冲突";
        if (neoSelected)     return @"与 NeoForge 冲突";
    }

    return nil;
}

- (void)refreshIncompatibilities {
    for (ModLoaderRow *row in _loaders) {
        // 不在 cell 上记录 reason，渲染时计算
    }
    [_tableView reloadData];
}

#pragma mark Version name (参照 FCL VersionInstallInfoPage.generateVersionName)

- (NSString *)generateVersionName {
    if (!_gameVersion) return @"";
    NSMutableString *name = [NSMutableString stringWithString:_gameVersion];

    // 已选加载器追加 -loaderName
    NSString *loaderId = _selectedLoaderId;
    if (loaderId.length > 0 && ![loaderId isEqualToString:@"vanilla"]) {
        NSString *loaderName = nil;
        if ([loaderId isEqualToString:@"fabric"])   loaderName = @"fabric";
        else if ([loaderId isEqualToString:@"forge"])    loaderName = @"forge";
        else if ([loaderId isEqualToString:@"neoforge"]) loaderName = @"neoforge";
        else if ([loaderId isEqualToString:@"quilt"])    loaderName = @"quilt";
        else if ([loaderId isEqualToString:@"optifine"]) loaderName = @"OptiFine";
        if (loaderName) [name appendFormat:@"-%@", loaderName];
    }

    // 若同时勾选了 OptiFine（与 Forge 共存），追加 -OptiFine
    if (_installOptiFine && [loaderId isEqualToString:@"forge"]) {
        if (![_selectedLoaderId isEqualToString:@"optifine"]) {
            [name appendString:@"-OptiFine"];
        }
    }

    return [name copy];
}

- (void)refreshVersionName {
    if (_nameManuallyModified) return;
    NSString *auto = [self generateVersionName];
    if (![auto isEqualToString:_versionNameField.text]) {
        // programmatic edit, ignore text change notification
        _versionNameField.text = auto;
    }
}

#pragma mark Actions

- (void)backTapped {
    if (_cancelled) _cancelled();
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)installTapped {
    if (_selectedLoaderId.length == 0) {
        [self showAlert:@"请选择安装方式" message:nil];
        return;
    }

    if (![_selectedLoaderId isEqualToString:@"vanilla"] && ![_selectedLoaderId isEqualToString:@"optifine"]) {
        NSString *selectedVersion = [self selectedVersionForLoader:_selectedLoaderId];
        if (selectedVersion.length == 0) {
            [self showAlert:@"请选择版本" message:@"请先选择加载器的版本号"];
            return;
        }
    }

    // OptiFine 单独安装时必须有选中版本
    if ([_selectedLoaderId isEqualToString:@"optifine"] && _selectedOptiFineVersion.length == 0) {
        [self showAlert:@"请选择 OptiFine 版本" message:nil];
        return;
    }

    BOOL installFabricAPI = NO;
    BOOL installOptiFine = NO;
    NSString *loaderVersion = [self selectedVersionForLoader:_selectedLoaderId];

    if ([_selectedLoaderId isEqualToString:@"fabric"]) {
        installFabricAPI = _installFabricAPI;
    } else if ([_selectedLoaderId isEqualToString:@"forge"]) {
        installOptiFine = _installOptiFine;
    } else if ([_selectedLoaderId isEqualToString:@"optifine"]) {
        // 单独安装 OptiFine：作为版本补丁
        installOptiFine = YES;
        // 单独 optifine 时 loaderVersion 为 OptiFine 完整描述（type\x1fpatch\x1ffilename\x1fdisplay）
        loaderVersion = _selectedOptiFineVersion;
    }

    if (_completion) {
        _completion(_selectedLoaderId, installFabricAPI, installOptiFine, loaderVersion);
    }
}

- (NSString *)selectedVersionForLoader:(NSString *)loaderId {
    if ([loaderId isEqualToString:@"fabric"])   return _selectedFabricVersion;
    if ([loaderId isEqualToString:@"forge"])    return _selectedForgeVersion;
    if ([loaderId isEqualToString:@"neoforge"]) return _selectedNeoForgeVersion;
    if ([loaderId isEqualToString:@"quilt"])    return _selectedQuiltVersion;
    if ([loaderId isEqualToString:@"optifine"]) return _selectedOptiFineVersion;
    return nil;
}

- (void)setSelectedVersion:(NSString *)version forLoader:(NSString *)loaderId {
    if ([loaderId isEqualToString:@"fabric"])   self.selectedFabricVersion = version;
    else if ([loaderId isEqualToString:@"forge"])    self.selectedForgeVersion = version;
    else if ([loaderId isEqualToString:@"neoforge"]) self.selectedNeoForgeVersion = version;
    else if ([loaderId isEqualToString:@"quilt"])    self.selectedQuiltVersion = version;
    else if ([loaderId isEqualToString:@"optifine"]) {
        self.selectedOptiFineVersion = version;
        // 解析 packed 格式：type\x1fpatch\x1ffilename\x1fdisplay
        if ([version containsString:@"\x1f"]) {
            NSArray *parts = [version componentsSeparatedByString:@"\x1f"];
            if (parts.count >= 3) {
                self.selectedOptiFineType = parts[0];
                self.selectedOptiFinePatch = parts[1];
                self.selectedOptiFineFilename = parts[2];
            }
        }
    }
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TextField

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    // 用户开始手动编辑
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    NSString *auto = [self generateVersionName];
    if (textField.text.length == 0) {
        _nameManuallyModified = NO;
        textField.text = auto;
    } else if (![textField.text isEqualToString:auto]) {
        _nameManuallyModified = YES;
    }
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;  // 0: 加载器列表, 1: 选项
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        return _loaders.count;
    }
    // section 1: 选项
    NSMutableArray *opts = [self currentOptions];
    return opts.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"模组加载器";
    return [self currentOptions].count > 0 ? @"附加选项" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        if ([_selectedLoaderId isEqualToString:@"forge"] && _installOptiFine) {
            return @"已勾选 OptiFine：将与 Forge 共存，自动安装到 mods 目录";
        }
        if ([_selectedLoaderId isEqualToString:@"optifine"]) {
            return @"OptiFine 将作为版本补丁独立安装（不依赖 Forge）";
        }
        return nil;
    }
    return nil;
}

- (NSMutableArray *)currentOptions {
    NSMutableArray *opts = [NSMutableArray array];
    if ([_selectedLoaderId isEqualToString:@"fabric"]) {
        [opts addObject:@{ @"type": @"fabric_api" }];
    }
    if ([_selectedLoaderId isEqualToString:@"forge"]) {
        [opts addObject:@{ @"type": @"optifine_mod" }];
    }
    return opts;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        ModLoaderLoaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderCell" forIndexPath:indexPath];
        ModLoaderRow *row = _loaders[indexPath.row];

        cell.nameLabel.text = row.name;
        cell.descLabel.text = row.desc;
        cell.iconView.image = [UIImage systemImageNamed:row.iconName];
        cell.iconView.tintColor = row.iconColor;
        cell.iconView.backgroundColor = [row.iconColor colorWithAlphaComponent:0.15];

        if (!row.compatible) {
            [cell setIncompatible:YES reason:@"当前版本不支持"];
        } else {
            NSString *incompatReason = [self incompatibleReasonForLoaderId:row.identifier];
            if (incompatReason) {
                [cell setIncompatible:YES reason:incompatReason];
            } else {
                [cell setIncompatible:NO reason:nil];
                if ([_selectedLoaderId isEqualToString:row.identifier]) {
                    NSString *selVer = [self selectedVersionForLoader:row.identifier];
                    if ([row.identifier isEqualToString:@"vanilla"]) {
                        [cell setSelectedVersionText:@"已选择"];
                    } else if (selVer.length > 0) {
                        // OptiFine packed 格式提取 display
                        NSString *display = selVer;
                        if ([selVer containsString:@"\x1f"]) {
                            NSArray *parts = [selVer componentsSeparatedByString:@"\x1f"];
                            if (parts.count >= 4) display = parts[3];
                            else if (parts.count >= 1) display = parts[0];
                        }
                        [cell setSelectedVersionText:display];
                    } else {
                        [cell setSelectedVersionText:nil];
                    }
                } else {
                    // 未选中加载器：不显示状态文字（避免误导）
                    [cell clearStatusText];
                }
            }
        }
        return cell;
    } else {
        // section 1: 选项
        ModLoaderSwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell" forIndexPath:indexPath];
        NSMutableArray *opts = [self currentOptions];
        NSDictionary *opt = opts[indexPath.row];
        NSString *type = opt[@"type"];

        if ([type isEqualToString:@"fabric_api"]) {
            cell.titleLabel.text = @"同时安装 Fabric API";
            cell.descLabel.text = @"Fabric 模组的核心依赖库，建议保持开启";
            cell.switchControl.on = _installFabricAPI;
            cell.switchControl.tag = 1001;
        } else if ([type isEqualToString:@"optifine_mod"]) {
            cell.titleLabel.text = @"同时安装 OptiFine";
            cell.descLabel.text = @"作为 mod 安装到 mods 目录，与 Forge 共存";
            cell.switchControl.on = _installOptiFine;
            cell.switchControl.tag = 1002;
        } else {
            cell.titleLabel.text = @"";
            cell.descLabel.text = @"";
            cell.switchControl.on = NO;
            cell.switchControl.tag = 0;
        }
        [cell.switchControl removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.switchControl addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
}

- (void)switchChanged:(UISwitch *)sender {
    if (sender.tag == 1001) {
        _installFabricAPI = sender.on;
    } else if (sender.tag == 1002) {
        _installOptiFine = sender.on;
    }
    [self refreshVersionName];
    // 重新加载 footer 文案
    [_tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;

    ModLoaderRow *row = _loaders[indexPath.row];
    if (!row.compatible) return;

    NSString *reason = [self incompatibleReasonForLoaderId:row.identifier];
    if (reason) {
        [self showAlert:reason message:nil];
        return;
    }

    if ([row.identifier isEqualToString:@"vanilla"]) {
        _selectedLoaderId = @"vanilla";
        // 清空加载器版本（vanilla 无需版本号）
        _installOptiFine = NO;
        _installFabricAPI = NO;
        [self refreshVersionName];
        [tableView reloadData];
        return;
    }

    // 切换加载器
    _selectedLoaderId = row.identifier;
    // 重置互斥选项
    if (![row.identifier isEqualToString:@"fabric"])  _installFabricAPI = NO;
    if (![row.identifier isEqualToString:@"forge"])   _installOptiFine = NO;
    if ([row.identifier isEqualToString:@"fabric"])   _installFabricAPI = YES;

    [self refreshVersionName];

    // 直接 push 版本选择页
    [self pushVersionPickerForLoader:row.identifier];
    [tableView reloadData];
}

- (void)pushVersionPickerForLoader:(NSString *)loaderId {
    ModLoaderVersionPickerViewController *picker = [[ModLoaderVersionPickerViewController alloc] init];
    picker.loaderId = loaderId;
    picker.gameVersion = _gameVersion;
    picker.selectedVersion = [self selectedVersionForLoader:loaderId];

    __weak typeof(self) weakSelf = self;
    picker.onSelected = ^(NSString *version) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setSelectedVersion:version forLoader:loaderId];
        [strongSelf refreshVersionName];
        [strongSelf.tableView reloadData];
    };
    picker.onCancelled = nil;

    [self.navigationController pushViewController:picker animated:YES];
}

@end
