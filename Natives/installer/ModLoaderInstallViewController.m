//
//  ModLoaderInstallViewController.m
//  Amethyst
//
//  Rebuilt after FCL (FoldCraftLauncher) page_installer.xml + view_installer_item.xml.
//  - A compact toolbar at the top: the version name field + a download icon button in the top-right corner (replacing the old 72pt button at the bottom)
//  - The loader list uses flat UITableView InsetGrouped rows (about 54pt each, with no shadow and no card border)
//  - Each row: a 28pt icon on the left + a two-line name/status in the middle + a chevron/checkmark on the right
//  - Extra options (Fabric API / OptiFine coexistence) are switch rows in their own section
//  - The version selection subpage also uses flat UITableView rows
//  - The mutual exclusion rules match FCL exactly
//

#import "ModLoaderInstallViewController.h"
#import "NeoForgeVersionFetcher.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "ModLoaderIconHelper.h"
#import "ScreenUtils.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Data Models

/// Loader metadata
@interface ModLoaderRow : NSObject
@property (nonatomic, copy) NSString *identifier;   // "vanilla"/"fabric"/"forge"/"neoforge"/"quilt"/"optifine"
@property (nonatomic, copy) NSString *name;         // Display name
@property (nonatomic, copy) NSString *desc;         // Description
@property (nonatomic, copy) NSString *iconName;     // SF Symbol name (used as a fallback when the PNG is missing)
@property (nonatomic, strong) UIColor *iconColor;   // Primary icon color
@property (nonatomic, assign) BOOL compatible;      // Whether it is compatible with the current game version
@property (nonatomic, copy, nullable) NSString *selectedVersion; // The selected version (nil means none)
@end
@implementation ModLoaderRow
@end

#pragma mark - Loader Row Cell (扁平条目，参照 FCL view_installer_item.xml)

@interface ModLoaderRowCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation ModLoaderRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // Flat rows: no shadow and no border, relying solely on BackgroundManager.applyEffectToCell: for the frosted glass/translucency
    self.selectionStyle = UITableViewCellSelectionStyleDefault;
    self.accessoryType = UITableViewCellAccessoryNone;

    CGFloat iconSize = [ScreenUtils dp:28];
    CGFloat nameFont = [ScreenUtils sp:15];
    CGFloat stateFont = [ScreenUtils sp:12];

    _iconView = [[UIImageView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentView addSubview:_iconView];

    _nameLabel = [[UILabel alloc] init];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightMedium];
    _nameLabel.textColor = [UIColor labelColor];
    _nameLabel.numberOfLines = 1;
    _nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentView addSubview:_nameLabel];

    _stateLabel = [[UILabel alloc] init];
    _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stateLabel.font = [UIFont systemFontOfSize:stateFont];
    _stateLabel.textColor = [UIColor secondaryLabelColor];
    _stateLabel.numberOfLines = 1;
    _stateLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentView addSubview:_stateLabel];

    _selectedBadge = [[UIView alloc] init];
    _selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _selectedBadge.backgroundColor = [UIColor systemGreenColor];
    _selectedBadge.layer.cornerRadius = 10;
    _selectedBadge.hidden = YES;
    [self.contentView addSubview:_selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [_selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],

        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9],
        [self.nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.selectedBadge.leadingAnchor constant:-8],

        [self.stateLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.stateLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.stateLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.selectedBadge.leadingAnchor constant:-8],
        [self.stateLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-9],

        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.selectedBadge.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:20],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:20],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor],
    ]];
}

- (void)setIncompatible:(BOOL)incompatible reason:(NSString *)reason {
    if (incompatible) {
        self.stateLabel.hidden = NO;
        self.stateLabel.text = reason ?: @"Incompatible";
        self.stateLabel.textColor = [UIColor systemRedColor];
        self.nameLabel.textColor = [UIColor tertiaryLabelColor];
        self.iconView.alpha = 0.45;
        self.selectedBadge.hidden = YES;
        self.accessoryType = UITableViewCellAccessoryNone;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.contentView.userInteractionEnabled = NO;
    } else {
        self.nameLabel.textColor = [UIColor labelColor];
        self.stateLabel.textColor = [UIColor secondaryLabelColor];
        self.iconView.alpha = 1.0;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        self.contentView.userInteractionEnabled = YES;
    }
}

- (void)setSelectedVersionText:(NSString *)text {
    if (text.length > 0) {
        self.stateLabel.hidden = NO;
        self.stateLabel.text = text;
        self.stateLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.stateLabel.hidden = NO;
        self.stateLabel.text = @"Tap to choose a version";
        self.stateLabel.textColor = [UIColor secondaryLabelColor];
    }
}

- (void)clearStatusText {
    self.stateLabel.hidden = NO;
    self.stateLabel.text = @"Not installed";
    self.stateLabel.textColor = [UIColor secondaryLabelColor];
}

- (void)configureWithRow:(ModLoaderRow *)row
            isSelected:(BOOL)isSelected
      selectedVersionDisplay:(NSString *)versionDisplay
                incompatible:(BOOL)incompatible
                     reason:(NSString *)reason {
    self.nameLabel.text = row.name;

    [ModLoaderIconHelper configureImageView:self.iconView
                                  forLoader:row.identifier
                             traitCollection:self.traitCollection];

    if (incompatible) {
        [self setIncompatible:YES reason:reason];
        return;
    }

    [self setIncompatible:NO reason:nil];

    if (isSelected) {
        if (versionDisplay.length > 0) {
            [self setSelectedVersionText:versionDisplay];
        } else if ([row.identifier isEqualToString:@"vanilla"]) {
            [self setSelectedVersionText:@"Selected"];
        } else {
            [self setSelectedVersionText:nil];
        }
        self.selectedBadge.hidden = NO;
        self.accessoryType = UITableViewCellAccessoryNone;
    } else {
        [self clearStatusText];
        self.selectedBadge.hidden = YES;
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
}

@end

#pragma mark - Switch Row Cell (Fabric API / OptiFine 选项开关行)

@interface ModLoaderSwitchCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UISwitch *switchControl;
@end

@implementation ModLoaderSwitchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    CGFloat titleFont = [ScreenUtils sp:15];
    CGFloat descFont = [ScreenUtils sp:12];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:titleFont weight:UIFontWeightMedium];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentView addSubview:_titleLabel];

    _descLabel = [[UILabel alloc] init];
    _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _descLabel.font = [UIFont systemFontOfSize:descFont];
    _descLabel.textColor = [UIColor secondaryLabelColor];
    _descLabel.numberOfLines = 0;
    _descLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _descLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentView addSubview:_descLabel];

    _switchControl = [[UISwitch alloc] init];
    _switchControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_switchControl];

    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.switchControl.leadingAnchor constant:-12],

        [self.descLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.descLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.descLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.switchControl.leadingAnchor constant:-12],
        [self.descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-9],

        [self.switchControl.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.switchControl.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];
}

@end

#pragma mark - Version Row Cell (版本选择子页面扁平条目)

@interface ModLoaderVersionCell : UITableViewCell
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation ModLoaderVersionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    self.selectionStyle = UITableViewCellSelectionStyleDefault;

    CGFloat versionFont = [ScreenUtils sp:15];

    _versionLabel = [[UILabel alloc] init];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.font = [UIFont systemFontOfSize:versionFont weight:UIFontWeightRegular];
    _versionLabel.textColor = [UIColor labelColor];
    _versionLabel.numberOfLines = 1;
    _versionLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentView addSubview:_versionLabel];

    _selectedBadge = [[UIView alloc] init];
    _selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _selectedBadge.backgroundColor = [UIColor systemGreenColor];
    _selectedBadge.layer.cornerRadius = 10;
    _selectedBadge.hidden = YES;
    [self.contentView addSubview:_selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [_selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.versionLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.versionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.selectedBadge.leadingAnchor constant:-8],

        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.selectedBadge.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:20],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:20],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor],
    ]];
}

- (void)configureWithVersion:(NSString *)version isSelected:(BOOL)isSelected {
    // OptiFine packed format: type\x1fpatch\x1ffilename\x1fdisplay
    NSString *display = version;
    if ([version containsString:@"\x1f"]) {
        NSArray *parts = [version componentsSeparatedByString:@"\x1f"];
        if (parts.count >= 4) display = parts[3];
        else if (parts.count >= 1) display = parts[0];
    }
    self.versionLabel.text = display;
    self.selectedBadge.hidden = !isSelected;
    self.accessoryType = isSelected ? UITableViewCellAccessoryNone : UITableViewCellAccessoryNone;
}

@end

#pragma mark - Version Picker View Controller (版本选择子页面，扁平 UITableView)

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
// Forge XML parsing
@property (nonatomic, strong) NSMutableArray *forgeVersionList;
@property (nonatomic, strong) NSMutableString *currentVersionValue;
@property (nonatomic, assign) BOOL isParsingForge;
// Network task
@property (nonatomic, strong) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong) NSURLSessionDataTask *bmclTask;
@end

@implementation ModLoaderVersionPickerViewController

- (void)dealloc {
    if (_currentTask) { [_currentTask cancel]; _currentTask = nil; }
    if (_bmclTask) { [_bmclTask cancel]; _bmclTask = nil; }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self pickerTitle];
    self.view.backgroundColor = [UIColor clearColor];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(backTapped)];

    [self setupTableView];
    [self startLoading];
}

- (void)refreshBackgroundEffect {
    // Refresh the cells' frosted glass appearance when the background effect changes
    [_tableView reloadData];
}

- (NSString *)pickerTitle {
    if ([_loaderId isEqualToString:@"fabric"])   return @"Fabric version";
    if ([_loaderId isEqualToString:@"forge"])    return @"Forge version";
    if ([_loaderId isEqualToString:@"neoforge"]) return @"NeoForge version";
    if ([_loaderId isEqualToString:@"quilt"])    return @"Quilt version";
    if ([_loaderId isEqualToString:@"optifine"]) return @"OptiFine version";
    return @"Select version";
}

- (void)setupTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 50;
    _tableView.estimatedRowHeight = 50;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    // extendedLayoutIncludesOpaqueBars / edgesForExtendedLayout are UIViewController properties
    // and cannot be set on a UITableView, or the compiler reports "property not found on object of type 'UITableView *'"
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;
    [_tableView registerClass:[ModLoaderVersionCell class] forCellReuseIdentifier:@"VersionCell"];
    [self.view addSubview:_tableView];

    _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:_loadingIndicator];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.text = @"No versions available";
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.textColor = [UIColor secondaryLabelColor];
    _emptyLabel.font = [UIFont systemFontOfSize:15];
    _emptyLabel.hidden = YES;
    [self.view addSubview:_emptyLabel];

    _errorLabel = [[UILabel alloc] init];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.text = @"Load failed, check your network";
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.textColor = [UIColor systemRedColor];
    _errorLabel.font = [UIFont systemFontOfSize:15];
    _errorLabel.numberOfLines = 0;
    _errorLabel.hidden = YES;
    [self.view addSubview:_errorLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [self.errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.errorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
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
    // Modeled on FCL/HMCL: race the official source and the BMCL API concurrently and use whichever succeeds first
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
            // Give BMCLAPI a 5s grace period
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
                // Display format: HD_U_I6 (filename)
                NSString *display = [NSString stringWithFormat:@"%@_%@", type, patch];
                if (filename.length > 0) {
                    display = [NSString stringWithFormat:@"%@_%@ (%@)", type, patch, filename];
                }
                // Pack the full information into the version string, separated by \x1f (unit separator)
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
        _errorLabel.text = [NSString stringWithFormat:@"Load failed: %@", error.localizedDescription ?: @"Unknown error"];
    } else {
        _versions = versions ?: @[];
        _errorLabel.hidden = YES;
        _emptyLabel.hidden = (_versions.count > 0);
    }
    [_tableView reloadData];

    // If a version is already selected, scroll to the selected row
    if (_selectedVersion.length > 0 && _versions.count > 0) {
        NSUInteger idx = [_versions indexOfObject:_selectedVersion];
        if (idx != NSNotFound) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:idx inSection:0];
            [_tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
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
        NSString *raw = [_currentVersionValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (raw.length > 0 && [_forgeVersionList indexOfObject:raw] == NSNotFound) {
            // Forge version format: <mcver>-<forgever>, for example "1.20.1-47.2.0"
            // Following FCL/HMCL: keep only the versions matching the current gameVersion
            NSString *prefix = [NSString stringWithFormat:@"%@-", _gameVersion];
            if ([raw hasPrefix:prefix]) {
                NSString *forgeVer = [raw substringFromIndex:prefix.length];
                if (forgeVer.length > 0 && ![_forgeVersionList containsObject:forgeVer]) {
                    [_forgeVersionList addObject:forgeVer];
                }
            } else if ([raw hasPrefix:_gameVersion] && [raw isEqualToString:_gameVersion]) {
                // A very rare case: the version number is gameVersion itself
                if (![_forgeVersionList containsObject:raw]) {
                    [_forgeVersionList addObject:raw];
                }
            }
        }
        _currentVersionValue = nil;
    } else if ([elementName isEqualToString:@"metadata"]) {
        _isParsingForge = NO;
        // Parsing finished
        NSArray *sorted = [_forgeVersionList sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            // A simple descending sort, so the newest version comes first
            return [b compare:a options:NSNumericSearch];
        }];
        // NSXMLParser runs synchronously on a background thread (the NSURLSession completionHandler),
        // and finishLoadingWithVersions: performs UI operations such as reloadData / stopAnimating internally,
        // so it must switch back to the main thread, otherwise AutoLayout crashes on background-thread mutation.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishLoadingWithVersions:sorted error:nil];
        });
    }
}

#pragma mark UITableViewDataSource / UITableViewDelegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModLoaderVersionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"VersionCell" forIndexPath:indexPath];
    NSString *version = _versions[indexPath.row];
    BOOL isSelected = [_selectedVersion isEqualToString:version];
    [cell configureWithVersion:version isSelected:isSelected];
    // Adapt to the custom launcher background: apply the frosted glass/translucent effect to the cell
    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *raw = _versions[indexPath.row];

    // Update the selection visual feedback immediately
    _selectedVersion = raw;
    [tableView reloadData];

    // Pop after briefly showing the selected state
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
@property (nonatomic, strong) UITextField *versionNameField;
@property (nonatomic, strong) UIView *nameBar;

// Data
@property (nonatomic, strong) NSMutableArray<ModLoaderRow *> *loaders;
@property (nonatomic, copy) NSString *selectedLoaderId;       // "vanilla"/"fabric"/"forge"/"neoforge"/"quilt"/"optifine"
@property (nonatomic, copy) NSString *selectedFabricVersion;
@property (nonatomic, copy) NSString *selectedForgeVersion;
@property (nonatomic, copy) NSString *selectedNeoForgeVersion;
@property (nonatomic, copy) NSString *selectedQuiltVersion;
@property (nonatomic, copy) NSString *selectedOptiFineVersion;
@property (nonatomic, copy) NSString *selectedOptiFineType;     // HD_U and the like
@property (nonatomic, copy) NSString *selectedOptiFinePatch;
@property (nonatomic, copy) NSString *selectedOptiFineFilename;

// Options
@property (nonatomic, assign) BOOL installFabricAPI;
@property (nonatomic, assign) BOOL installOptiFine;  // Shown only when forge is selected

// Whether the user has edited the version name manually
@property (nonatomic, assign) BOOL nameManuallyModified;
@end

@implementation ModLoaderInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Choose installation method";
    self.view.backgroundColor = [UIColor clearColor];
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(backTapped)];

    // FCL style: a download icon button in the top-right corner (replacing the old 72pt button at the bottom)
    UIBarButtonItem *installItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"]
                                                                      style:UIBarButtonItemStyleDone
                                                                     target:self
                                                                     action:@selector(installTapped)];
    installItem.tintColor = [UIColor systemGreenColor];
    self.navigationItem.rightBarButtonItem = installItem;

    _installFabricAPI = YES;  // Fabric ticks Fabric API by default (matching FCL's default behavior)

    [self setupLoaders];
    [self setupNameBar];
    [self setupTableView];
    [self refreshIncompatibilities];
    [self refreshVersionName];
}

- (void)refreshBackgroundEffect {
    // Refresh the frosted glass appearance of the cells and the nameBar when the background effect changes
    [_tableView reloadData];
}

#pragma mark Setup

- (void)setupLoaders {
    _loaders = [NSMutableArray array];

    BOOL fabricCompatible = [self isFabricCompatible];
    BOOL quiltCompatible = [self isQuiltCompatible];
    BOOL forgeCompatible = [self isForgeCompatible];
    BOOL neoForgeCompatible = [self isNeoForgeCompatible];
    BOOL optiFineCompatible = [self isOptiFineCompatible];

    // Get the loader icon and brand color uniformly through ModLoaderIconHelper (PNG first, falling back to an SF Symbol)
    NSArray *defs = @[
        @{ @"id": @"vanilla",  @"name": @"Vanilla", @"desc": @"Pure Minecraft, without any mod loader", @"compatible": @YES },
        @{ @"id": @"fabric",   @"name": @"Fabric",        @"desc": @"A lightweight mod loader, good for smaller mods",      @"compatible": @(fabricCompatible) },
        @{ @"id": @"forge",    @"name": @"Forge",         @"desc": @"The classic mod loader, with a large mod ecosystem",        @"compatible": @(forgeCompatible) },
        @{ @"id": @"neoforge", @"name": @"NeoForge",      @"desc": @"A fork of Forge, supports 1.20.1+",          @"compatible": @(neoForgeCompatible) },
        @{ @"id": @"quilt",    @"name": @"Quilt",         @"desc": @"A next-generation loader based on Fabric",         @"compatible": @(quiltCompatible) },
        @{ @"id": @"optifine", @"name": @"OptiFine",      @"desc": @"Shaders and visual tuning (installed as a version patch)",  @"compatible": @(optiFineCompatible) },
    ];

    for (NSDictionary *d in defs) {
        ModLoaderRow *row = [ModLoaderRow new];
        row.identifier = d[@"id"];
        row.name = d[@"name"];
        row.desc = d[@"desc"];
        // Get the icon symbol name and brand color uniformly through ModLoaderIconHelper (used as a fallback when the PNG is missing)
        row.iconName = [ModLoaderIconHelper symbolNameForLoader:d[@"id"]];
        row.compatible = [d[@"compatible"] boolValue];
        row.iconColor = [ModLoaderIconHelper brandColorForLoader:d[@"id"]];
        [_loaders addObject:row];
    }
}

- (void)setupNameBar {
    // FCL style name_bar: a compact horizontal row ("Version name" label + text field), 40pt tall
    _nameBar = [[UIView alloc] init];
    _nameBar.translatesAutoresizingMaskIntoConstraints = NO;
    // Adapt to the custom launcher background: use frosted glass when a global background is set, otherwise the default solid color
    if ([[BackgroundManager sharedManager] hasBackground]) {
        _nameBar.backgroundColor = [UIColor clearColor];
        [[BackgroundManager sharedManager] applyEffectToView:_nameBar];
        _nameBar.layer.cornerRadius = 10;
        _nameBar.layer.masksToBounds = YES;
    } else {
        _nameBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        _nameBar.layer.cornerRadius = 10;
        _nameBar.layer.masksToBounds = YES;
    }
    [self.view addSubview:_nameBar];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Version name";
    label.font = [UIFont systemFontOfSize:[ScreenUtils sp:13] weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.adjustsFontForContentSizeCategory = NO;
    [_nameBar addSubview:label];

    _versionNameField = [[UITextField alloc] init];
    _versionNameField.translatesAutoresizingMaskIntoConstraints = NO;
    _versionNameField.font = [UIFont systemFontOfSize:[ScreenUtils sp:14]];
    _versionNameField.textColor = [UIColor labelColor];
    _versionNameField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Enter a version name"
                                                                             attributes:@{
        NSForegroundColorAttributeName: [UIColor placeholderTextColor]
    }];
    _versionNameField.borderStyle = UITextBorderStyleNone;
    _versionNameField.returnKeyType = UIReturnKeyDone;
    _versionNameField.delegate = self;
    _versionNameField.autocorrectionType = UITextAutocorrectionTypeNo;
    _versionNameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _versionNameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [_nameBar addSubview:_versionNameField];

    [NSLayoutConstraint activateConstraints:@[
        [_nameBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [_nameBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_nameBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_nameBar.heightAnchor constraintEqualToConstant:40],

        [label.leadingAnchor constraintEqualToAnchor:_nameBar.leadingAnchor constant:12],
        [label.centerYAnchor constraintEqualToAnchor:_nameBar.centerYAnchor],

        [_versionNameField.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:10],
        [_versionNameField.trailingAnchor constraintEqualToAnchor:_nameBar.trailingAnchor constant:-12],
        [_versionNameField.centerYAnchor constraintEqualToAnchor:_nameBar.centerYAnchor],
        [_versionNameField.heightAnchor constraintEqualToAnchor:_nameBar.heightAnchor],
    ]];
}

- (void)setupTableView {
    // FCL style: a flat UITableView InsetGrouped with a loader list section and an extra options section
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 54;
    _tableView.estimatedRowHeight = 54;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    // extendedLayoutIncludesOpaqueBars / edgesForExtendedLayout are UIViewController properties
    // and cannot be set on a UITableView, or the compiler reports "property not found on object of type 'UITableView *'"
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;
    _tableView.sectionHeaderTopPadding = 0;
    [_tableView registerClass:[ModLoaderRowCell class] forCellReuseIdentifier:@"LoaderRowCell"];
    [_tableView registerClass:[ModLoaderSwitchCell class] forCellReuseIdentifier:@"SwitchCell"];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:_nameBar.bottomAnchor constant:8],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
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
    // OptiFine 1.14+ is compatible with Forge; 1.13 and earlier are installed separately as a version patch
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
    // fabricApi excludes forge/optifine/neoforge
    // optifine excludes fabric/quilt/neoforge (but can coexist with forge)
    // forge/fabric/quilt/neoforge are mutually exclusive

    if ([loaderId isEqualToString:@"vanilla"]) return nil;

    BOOL fabricSelected  = [_selectedLoaderId isEqualToString:@"fabric"];
    BOOL forgeSelected   = [_selectedLoaderId isEqualToString:@"forge"];
    BOOL neoSelected     = [_selectedLoaderId isEqualToString:@"neoforge"];
    BOOL quiltSelected   = [_selectedLoaderId isEqualToString:@"quilt"];
    BOOL optiSelected    = [_selectedLoaderId isEqualToString:@"optifine"];

    if ([loaderId isEqualToString:@"fabric"] || [loaderId isEqualToString:@"forge"] ||
        [loaderId isEqualToString:@"neoforge"] || [loaderId isEqualToString:@"quilt"]) {
        // Loader group mutual exclusion
        if (fabricSelected  && ![loaderId isEqualToString:@"fabric"])  return @"Conflicts with Fabric";
        if (forgeSelected   && ![loaderId isEqualToString:@"forge"])   return @"Conflicts with Forge";
        if (neoSelected     && ![loaderId isEqualToString:@"neoforge"]) return @"Conflicts with NeoForge";
        if (quiltSelected   && ![loaderId isEqualToString:@"quilt"])   return @"Conflicts with Quilt";
        // optifine excludes fabric/quilt/neoforge
        if (optiSelected) {
            if ([loaderId isEqualToString:@"fabric"])  return @"Conflicts with OptiFine";
            if ([loaderId isEqualToString:@"quilt"])   return @"Conflicts with OptiFine";
            if ([loaderId isEqualToString:@"neoforge"]) return @"Conflicts with OptiFine";
        }
    }

    if ([loaderId isEqualToString:@"optifine"]) {
        if (fabricSelected)  return @"Conflicts with Fabric";
        if (quiltSelected)   return @"Conflicts with Quilt";
        if (neoSelected)     return @"Conflicts with NeoForge";
    }

    return nil;
}

- (void)refreshIncompatibilities {
    // Re-render every row; the exclusion/compatibility state is computed in cellForRowAtIndexPath
    [_tableView reloadData];
}

#pragma mark Version name (参照 FCL VersionInstallInfoPage.generateVersionName)

- (NSString *)generateVersionName {
    if (!_gameVersion) return @"";
    NSMutableString *name = [NSMutableString stringWithString:_gameVersion];

    // Append -loaderName for the selected loader
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

    // If OptiFine is also ticked (coexisting with Forge), append -OptiFine
    if (_installOptiFine && [loaderId isEqualToString:@"forge"]) {
        if (![_selectedLoaderId isEqualToString:@"optifine"]) {
            [name appendString:@"-OptiFine"];
        }
    }

    return [name copy];
}

- (void)refreshVersionName {
    if (_nameManuallyModified) return;
    // Note: the variable cannot be named "auto", because auto is a reserved keyword in C/C++/Objective-C
    // (a storage class specifier), and using it as an identifier causes an "expected identifier or '('" compile error.
    // autoGeneratedName is used instead, to avoid clashing with the keyword.
    NSString *autoGeneratedName = [self generateVersionName];
    if (![autoGeneratedName isEqualToString:_versionNameField.text]) {
        // programmatic edit, ignore text change notification
        _versionNameField.text = autoGeneratedName;
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
        [self showAlert:@"Please choose an installation method" message:nil];
        return;
    }

    if (![_selectedLoaderId isEqualToString:@"vanilla"] && ![_selectedLoaderId isEqualToString:@"optifine"]) {
        NSString *selectedVersion = [self selectedVersionForLoader:_selectedLoaderId];
        if (selectedVersion.length == 0) {
            [self showAlert:@"Please choose a version" message:@"Choose a loader version first"];
            return;
        }
    }

    // A version must be selected when installing OptiFine on its own
    if ([_selectedLoaderId isEqualToString:@"optifine"] && _selectedOptiFineVersion.length == 0) {
        [self showAlert:@"Please choose an OptiFine version" message:nil];
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
        // Installing OptiFine on its own: as a version patch
        installOptiFine = YES;
        // For a standalone optifine install, loaderVersion is the full OptiFine description (type\x1fpatch\x1ffilename\x1fdisplay)
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
        // Parse the packed format: type\x1fpatch\x1ffilename\x1fdisplay
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
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TextField

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    // The user has started editing manually
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    // Note: the variable cannot be named "auto", because auto is a reserved keyword in C/C++/Objective-C
    // (a storage class specifier), and using it as an identifier causes an "expected identifier or '('" compile error.
    // autoGeneratedName is used instead, to avoid clashing with the keyword.
    NSString *autoGeneratedName = [self generateVersionName];
    if (textField.text.length == 0) {
        _nameManuallyModified = NO;
        textField.text = autoGeneratedName;
    } else if (![textField.text isEqualToString:autoGeneratedName]) {
        _nameManuallyModified = YES;
    }
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;  // 0: loader list, 1: extra options
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        return _loaders.count;
    }
    // section 1: extra options
    return [self currentOptions].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Mod loader";
    return [self currentOptions].count > 0 ? @"Additional options" : nil;
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
        ModLoaderRowCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderRowCell" forIndexPath:indexPath];
        ModLoaderRow *row = _loaders[indexPath.row];

        BOOL isSelected = [_selectedLoaderId isEqualToString:row.identifier];

        // Compute the display text of the selected version (extracting display from the OptiFine packed format)
        NSString *versionDisplay = nil;
        if (isSelected && ![row.identifier isEqualToString:@"vanilla"]) {
            NSString *selVer = [self selectedVersionForLoader:row.identifier];
            if (selVer.length > 0) {
                versionDisplay = selVer;
                if ([selVer containsString:@"\x1f"]) {
                    NSArray *parts = [selVer componentsSeparatedByString:@"\x1f"];
                    if (parts.count >= 4) versionDisplay = parts[3];
                    else if (parts.count >= 1) versionDisplay = parts[0];
                }
            }
        }

        // Compatibility + mutual exclusion checks
        BOOL incompatible = NO;
        NSString *reason = nil;
        if (!row.compatible) {
            incompatible = YES;
            reason = @"Not supported on this version";
        } else {
            reason = [self incompatibleReasonForLoaderId:row.identifier];
            if (reason) incompatible = YES;
        }

        [cell configureWithRow:row
                    isSelected:isSelected
          selectedVersionDisplay:versionDisplay
                    incompatible:incompatible
                         reason:reason];
        // Adapt to the custom launcher background: apply the frosted glass/translucent effect to the cell
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    } else {
        // section 1: extra options (the Fabric API / OptiFine coexistence switches)
        ModLoaderSwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell" forIndexPath:indexPath];
        NSMutableArray *opts = [self currentOptions];
        NSDictionary *opt = opts[indexPath.row];
        NSString *type = opt[@"type"];

        if ([type isEqualToString:@"fabric_api"]) {
            cell.titleLabel.text = @"Also install Fabric API";
            cell.descLabel.text = @"The core library for Fabric mods; leaving this on is recommended";
            cell.switchControl.on = _installFabricAPI;
            cell.switchControl.tag = 1001;
        } else if ([type isEqualToString:@"optifine_mod"]) {
            cell.titleLabel.text = @"Also install OptiFine";
            cell.descLabel.text = @"Installed as a mod in the mods folder, alongside Forge";
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
        // Adapt to the custom launcher background: apply the frosted glass/translucent effect to the cell
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
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
    // Reload section 0 so the row selection and mutual exclusion states refresh together
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
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
        // Clear the loader version (vanilla needs no version number)
        _installOptiFine = NO;
        _installFabricAPI = NO;
        [self refreshVersionName];
        [tableView reloadData];
        return;
    }

    // Switch the loader
    _selectedLoaderId = row.identifier;
    // Reset the mutually exclusive options
    if (![row.identifier isEqualToString:@"fabric"])  _installFabricAPI = NO;
    if (![row.identifier isEqualToString:@"forge"])   _installOptiFine = NO;
    if ([row.identifier isEqualToString:@"fabric"])   _installFabricAPI = YES;

    [self refreshVersionName];

    // Push the version selection page directly
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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
