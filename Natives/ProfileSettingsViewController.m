#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ResourcePacksManagerViewController.h"
#import "DataPacksManagerViewController.h"
#import "WorldsManagerViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "LauncherNavigationController.h" // for localVersionList/remoteVersionList
#import "MinecraftResourceUtils.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModVersion.h"
#import "ios_uikit_bridge.h" // for showDialog
#import "utils.h"
#import "BackgroundManager.h"
#import "DownloadProgressCardView.h"
#import "ModpackExportService.h" // for parseVersionId:

@interface ProfileSettingsViewController () <UITextFieldDelegate, UIPickerViewDataSource, UIPickerViewDelegate>

@property (nonatomic, strong) NSArray<NSArray *> *sections;
@property (nonatomic, strong) NSString *selectedRenderer;
@property (nonatomic, strong) NSString *selectedGraphicsApi;  // MC 26.2+ 图形 API: default/prefer_vulkan/prefer_opengl
@property (nonatomic, strong) NSString *selectedJavaVersion;
@property (nonatomic, assign) NSInteger allocatedMemory;
@property (nonatomic, assign) NSInteger maxMemory;
// 服务器地址（FCL 风格：留空则不自动加入）
@property (nonatomic, strong) NSString *serverIp;
// JVM 启动参数（如 -Dfoo=bar -Xnoclassgc 等；Xms/Xmx/d32/d64 由内存分配控制会被过滤）
@property (nonatomic, strong) NSString *javaArgs;
// JVM 参数输入框
@property (nonatomic, strong) UITextField *javaArgsTextField;
// 版本选择器
@property (nonatomic, strong) UITextField *versionTextField;
@property (nonatomic, strong) UITextField *nameTextField;
@property (nonatomic, strong) UISegmentedControl *versionTypeControl;
@property (nonatomic, strong) UIPickerView *versionPickerView;
@property (nonatomic, strong) UIToolbar *versionPickerToolbar;
@property (nonatomic, strong) NSArray *versionList;
@property (nonatomic, assign) NSInteger versionSelectedAt;
// 原始名称，用于重命名检测
@property (nonatomic, copy) NSString *originalName;

@end

@implementation ProfileSettingsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    // 如果只传了 profileName 没传 profile，从 PLProfiles 加载
    if (!self.profile && self.profileName) {
        self.profile = [PLProfiles.current.profiles[self.profileName] mutableCopy];
        if (!self.profile) {
            self.profile = [NSMutableDictionary dictionary];
            self.profile[@"name"] = self.profileName;
        }
    }
    // 安全网：如果调用方既没传 profileName 也没传 profile，创建空字典避免后续 nil 写入
    if (!self.profile) {
        self.profile = [NSMutableDictionary dictionary];
    }

    // 确保 profile 有 name 字段
    self.originalName = self.profile[@"name"];
    if ([self.originalName length] == 0) {
        self.originalName = self.profileName ?: @"New Profile";
        self.profile[@"name"] = self.originalName;
    }

    self.title = [NSString stringWithFormat:@"%@ 设置", self.originalName];

    // 导航栏按钮
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];

    // 设置表格
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    // 适配自定义启动器背景：透明背景让底层背景毛玻璃透出。
    // 之前用 systemBackgroundColor 遮挡底层 VersionManagerViewController 的 collection view，
    // 但现在 VersionManagerViewController 已适配背景透明（viewDidLoad 调用
    // makeViewControllerTransparent + applyEffectToNavigationBar），不再需要遮挡。
    // 两条进入路径（push 和 showProfileEditor modal）都使用 clearColor，
    // 统一由 BackgroundManager 管理背景效果。
    self.tableView.backgroundColor = [UIColor clearColor];
    // 适配自定义启动器背景：导航栏毛玻璃 + 视图透明
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;

    // 计算最大内存
    [self calculateMaxMemory];

    // 加载设置
    [self loadSettings];

    // 设置版本选择器
    [self setupVersionPicker];

    // 设置分区
    [self setupSections];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadVersionList)
                                                 name:@"ReloadProfileList"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadVersionList {
    self.versionList = nil;
    self.versionSelectedAt = -1;
    if (self.versionPickerView && self.versionPickerView.window) {
        [self changeVersionType:nil];
    }
}

#pragma mark - Memory

- (void)calculateMaxMemory {
    long long totalMemory = [NSProcessInfo processInfo].physicalMemory;
    self.maxMemory = (NSInteger)(totalMemory / (1024 * 1024));
    self.maxMemory = (NSInteger)(self.maxMemory * 0.8);
    if (self.maxMemory < 1024) {
        self.maxMemory = 1024;
    }
}

#pragma mark - Load Settings

- (void)loadSettings {
    // 渲染器
    self.selectedRenderer = self.profile[@"renderer"] ?: @"auto";

    // 图形 API（MC 26.2+ 游戏内 OpenGL/Vulkan 切换）
    self.selectedGraphicsApi = self.profile[@"graphicsApi"] ?: @"default";

    // Java版本（兼容旧版直装器写入的 NSDictionary 格式）
    id javaVerRaw = self.profile[@"javaVersion"];
    if ([javaVerRaw isKindOfClass:[NSDictionary class]]) {
        id major = javaVerRaw[@"majorVersion"];
        self.selectedJavaVersion = major ? [major description] : @"0";
    } else {
        self.selectedJavaVersion = [javaVerRaw isKindOfClass:[NSString class]] ? javaVerRaw : @"0";
    }

    // 内存分配 (MB)
    self.allocatedMemory = [self.profile[@"allocatedMemory"] integerValue];
    if (self.allocatedMemory == 0) {
        self.allocatedMemory = MIN(self.maxMemory / 2, 2048);
    }
    if (self.allocatedMemory > self.maxMemory) {
        self.allocatedMemory = self.maxMemory;
    }

    // 服务器地址（默认空字符串，留空不自动加入）
    NSString *profName = self.profile[@"name"] ?: self.profileName;
    self.serverIp = [PLProfiles.current serverIpForProfile:profName] ?: @"";

    // JVM 启动参数：参照 main 分支，仅读取 profile 自身字段；
    // 为空时 UI 显示 "(default)" placeholder，实际启动时由 PLProfiles.resolveKeyForCurrentProfile
    // 回退到全局 java.java_args（见 JavaLauncher.init_loadCustomJvmFlags）。
    id rawArgs = self.profile[@"javaArgs"];
    if ([rawArgs isKindOfClass:[NSString class]]) {
        self.javaArgs = rawArgs;
    } else {
        self.javaArgs = @"";
    }
}

#pragma mark - Sections

- (void)setupSections {
    // 高级设置 section：渲染器 + 图形 API（仅 MC 26.2+）+ Java/内存/JVM
    NSMutableArray *advancedRows = [NSMutableArray arrayWithArray:@[@"渲染器"]];
    if ([self isCurrentProfileModernVersion]) {
        [advancedRows addObject:@"图形 API"];
    }
    [advancedRows addObjectsFromArray:@[@"Java版本", @"内存分配", @"JVM 启动参数", @"清除JVM参数"]];

    self.sections = @[
        @[@"名称", @"游戏版本", @"游戏目录"],
        @[@"模组管理"],
        @[@"光影管理"],
        [advancedRows copy],
        @[@"服务器地址"],
        @[@"Fabric API", @"OptiFine"],
        @[@"资源包管理"],
        @[@"数据包管理"],
        @[@"世界管理"]
    ];
}

#pragma mark - Save

- (void)saveSettings {
    // 仅保存渲染器/Java/内存/服务器等设置项，不处理重命名
    // 重命名逻辑在 actionDone 中处理
    // 注意：必须使用 originalName 作为 key，且不能把用户正在编辑的 name 写入 PLProfiles
    // 否则用户改名后关闭（不点 Done），PLProfiles 中的 profile.name 会变成新名但 key 仍是旧名
    NSString *profName = self.originalName ?: self.profile[@"name"];
    if (!profName) return;

    // 保存用户正在编辑的字段（name 和 lastVersionId 可能在编辑中，尚未确认）
    NSString *userInputName = self.profile[@"name"];
    NSString *userInputVersion = self.profile[@"lastVersionId"];

    NSMutableDictionary *existing = [PLProfiles.current.profiles[profName] mutableCopy];
    if (!existing) {
        existing = [NSMutableDictionary dictionary];
    }
    existing[@"renderer"] = self.selectedRenderer;
    existing[@"graphicsApi"] = self.selectedGraphicsApi;
    existing[@"javaVersion"] = self.selectedJavaVersion;
    existing[@"allocatedMemory"] = @(self.allocatedMemory);
    existing[@"serverIp"] = self.serverIp ?: @"";
    // 参照 main 分支：javaArgs 为空时移除 key，让 profile 回退到全局 java.java_args
    if (self.javaArgs.length > 0) {
        existing[@"javaArgs"] = self.javaArgs;
    } else {
        [existing removeObjectForKey:@"javaArgs"];
    }
    // 保存游戏目录（版本隔离用）：gameDir 为 nil 时默认 "."，与 main 分支行为一致
    existing[@"gameDir"] = self.profile[@"gameDir"] ?: @".";
    // existing 中的 name 和 lastVersionId 字段保持原始值不变
    PLProfiles.current.profiles[profName] = existing;
    [PLProfiles.current save];

    // 同步到 working copy（深拷贝，避免与 PLProfiles 共享对象）
    // 恢复用户正在编辑的 name 和 lastVersionId，这样 actionDone 仍能拿到用户改的值
    self.profile = [existing mutableCopy];
    if (userInputName.length > 0) {
        self.profile[@"name"] = userInputName;
    }
    if (userInputVersion.length > 0) {
        self.profile[@"lastVersionId"] = userInputVersion;
    }
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"版本信息";
        case 1: return @"模组";
        case 2: return @"光影";
        case 3: return @"高级设置";
        case 4: return @"服务器";
        case 5: return @"组件安装";
        case 6: return @"资源包";
        case 7: return @"数据包";
        case 8: return @"世界";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 4) {
        return @"启动游戏后自动加入此服务器（参照 FCL）\n格式：host 或 host:port（IPv6 为 [host]:port），留空则不自动加入";
    }
    if (section == 0) {
        return @"游戏目录决定存档/模组/配置文件的隔离位置\n\".\" = 使用当前游戏目录切换选中的实例\n点击可修改为相对/绝对路径实现版本隔离";
    }
    if (section == 5) {
        return @"Fabric API：Fabric 模组的依赖库（仅 Fabric 加载器有效）\nOptiFine：OptiFine 优化模组（仅原版/Forge 有效）";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"SettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellIdentifier];
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
    }

    // 重置复用 cell 的状态
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;

    NSString *title = self.sections[indexPath.section][indexPath.row];
    cell.textLabel.text = title;

    switch (indexPath.section) {
        case 0: // 版本信息
            if ([title isEqualToString:@"名称"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"tag"];
                cell.accessoryView = [self buildNameTextField];
            } else if ([title isEqualToString:@"游戏版本"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.accessoryView = [self buildVersionTextField];
                cell.detailTextLabel.text = nil;
            } else if ([title isEqualToString:@"游戏目录"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"folder"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                NSString *gameDir = self.profile[@"gameDir"] ?: @".";
                cell.detailTextLabel.text = gameDir;
            }
            break;

        case 1: // 模组管理
            cell.imageView.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;

        case 2: // 光影管理
            cell.imageView.image = [UIImage systemImageNamed:@"paintbrush.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;

        case 3: // 高级设置
            if ([title isEqualToString:@"渲染器"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"cpu"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self rendererDisplayName:self.selectedRenderer];
            } else if ([title isEqualToString:@"图形 API"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"rectangle.dashed"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self graphicsApiDisplayName:self.selectedGraphicsApi];
            } else if ([title isEqualToString:@"Java版本"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"j.square"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self.selectedJavaVersion isEqualToString:@"0"] ? @"自动" : [NSString stringWithFormat:@"Java %@", self.selectedJavaVersion];
            } else if ([title isEqualToString:@"内存分配"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB / %ld MB", (long)self.allocatedMemory, (long)self.maxMemory];
            } else if ([title isEqualToString:@"JVM 启动参数"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"slider.vertical.3"];
                cell.accessoryView = [self buildJavaArgsTextField];
                cell.detailTextLabel.text = nil;
            } else if ([title isEqualToString:@"清除JVM参数"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"trash"];
                cell.imageView.tintColor = [UIColor systemRedColor];
                cell.textLabel.textColor = [UIColor systemRedColor];
                cell.detailTextLabel.text = self.javaArgs.length > 0 ? @"点击清除" : @"(无参数)";
            }
            break;

        case 4: // 服务器地址（FCL 风格）
            cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            cell.accessoryView = [self buildServerIpTextField];
            break;

        case 5: // 组件安装
            if ([title isEqualToString:@"Fabric API"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"bolt.fill"];
                cell.imageView.tintColor = [UIColor systemOrangeColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self isFabricProfile] ? @"点击安装" : @"仅 Fabric 有效";
            } else if ([title isEqualToString:@"OptiFine"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"speedometer"];
                cell.imageView.tintColor = [UIColor systemRedColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self isOptiFineCompatibleProfile] ? @"点击安装" : @"仅原版/Forge 有效";
            }
            break;

        case 6: // 资源包管理
            cell.imageView.image = [UIImage systemImageNamed:@"rectangle.stack.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;

        case 7: // 数据包管理
            cell.imageView.image = [UIImage systemImageNamed:@"shippingbox.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;

        case 8: // 世界管理
            cell.imageView.image = [UIImage systemImageNamed:@"globe.asia.australia.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
    }

    return cell;
}

#pragma mark - 名称输入框

- (UITextField *)buildNameTextField {
    // 复用已有 textField
    if (self.nameTextField) {
        // 检查是否已被其他 cell 持有（复用机制下需要重新添加）
        if (!self.nameTextField.superview || self.nameTextField.superview == self.view) {
            return self.nameTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    textField.placeholder = @"版本名称";
    textField.text = self.profile[@"name"];
    textField.font = [UIFont systemFontOfSize:14];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 10;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.textAlignment = NSTextAlignmentRight;
    textField.tag = 1001;
    textField.delegate = self;
    [textField addTarget:self action:@selector(nameTextFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(nameTextFieldDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.nameTextField = textField;
    return textField;
}

- (void)nameTextFieldChanged:(UITextField *)textField {
    self.profile[@"name"] = textField.text ?: @"";
}

- (void)nameTextFieldDidEnd:(UITextField *)textField {
    NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    self.profile[@"name"] = trimmed;
    textField.text = trimmed;
}

#pragma mark - 版本选择器

- (void)setupVersionPicker {
    self.versionPickerView = [[UIPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;

    self.versionPickerToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 44)];
    self.versionTypeControl = [[UISegmentedControl alloc] initWithItems:@[
        @"已安装", @"正式版", @"快照", @"Old-beta", @"Old-alpha"
    ]];
    [self.versionTypeControl addTarget:self action:@selector(changeVersionType:) forControlEvents:UIControlEventValueChanged];
    self.versionPickerToolbar.items = @[
        [[UIBarButtonItem alloc] initWithCustomView:self.versionTypeControl],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(versionClosePicker)]
    ];

    // 自动选择版本类型
    NSString *currentVersion = self.profile[@"lastVersionId"];
    if (currentVersion) {
        if ([MinecraftResourceUtils findVersion:currentVersion inList:localVersionList]) {
            self.versionTypeControl.selectedSegmentIndex = 0;
        } else {
            NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:currentVersion inList:remoteVersionList];
            if (selected) {
                NSArray *types = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"];
                NSString *type = selected[@"type"];
                self.versionTypeControl.selectedSegmentIndex = [types indexOfObject:type];
                if (self.versionTypeControl.selectedSegmentIndex == NSNotFound) {
                    self.versionTypeControl.selectedSegmentIndex = 0;
                }
            } else {
                self.versionTypeControl.selectedSegmentIndex = 0;
            }
        }
    } else {
        self.versionTypeControl.selectedSegmentIndex = 0;
    }
    self.versionSelectedAt = -1;
}

- (UITextField *)buildVersionTextField {
    if (self.versionTextField) {
        if (!self.versionTextField.superview || self.versionTextField.superview == self.view) {
            return self.versionTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    textField.text = self.profile[@"lastVersionId"] ?: @"";
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.textAlignment = NSTextAlignmentRight;
    textField.tag = 1002;
    textField.delegate = self;
    textField.inputView = self.versionPickerView;
    textField.inputAccessoryView = self.versionPickerToolbar;
    [textField addTarget:self action:@selector(versionTextFieldDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.versionTextField = textField;

    // 初始化版本列表
    [self changeVersionType:nil];
    return textField;
}

- (void)versionTextFieldDidEnd:(UITextField *)textField {
    // 更新 profile 中的版本
    self.profile[@"lastVersionId"] = textField.text ?: @"";
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

- (void)changeVersionType:(UISegmentedControl *)sender {
    NSArray *newVersionList = self.versionList;
    if (sender || !self.versionList) {
        if (self.versionTypeControl.selectedSegmentIndex == 0) {
            // nil 安全：启动器刚启动时 localVersionList 可能尚未加载
            newVersionList = localVersionList ?: @[];
        } else {
            NSString *type = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"][self.versionTypeControl.selectedSegmentIndex];
            // nil 安全：remoteVersionList 为 nil 时用空数组，避免 filteredArrayUsingPredicate 崩溃
            NSArray *remote = remoteVersionList ?: @[];
            newVersionList = [remote filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(type == %@)", type]];
        }
    }

    if (self.versionSelectedAt == -1) {
        NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:self.versionTextField.text inList:newVersionList];
        self.versionSelectedAt = [newVersionList indexOfObject:selected];
    } else {
        NSObject *lastSelected = nil;
        if (self.versionList.count > self.versionSelectedAt) {
            lastSelected = self.versionList[self.versionSelectedAt];
        }
        if (lastSelected != nil) {
            NSObject *nearest = [MinecraftResourceUtils findNearestVersion:lastSelected expectedType:self.versionTypeControl.selectedSegmentIndex];
            if (nearest != nil) {
                self.versionSelectedAt = [newVersionList indexOfObject:(id)nearest];
            }
        }
        self.versionSelectedAt = MIN(abs(self.versionSelectedAt), (NSInteger)newVersionList.count - 1);
    }

    self.versionList = newVersionList;
    [self.versionPickerView reloadAllComponents];
    if (self.versionSelectedAt != -1 && self.versionSelectedAt < (NSInteger)newVersionList.count) {
        [self.versionPickerView selectRow:self.versionSelectedAt inComponent:0 animated:NO];
        [self pickerView:self.versionPickerView didSelectRow:self.versionSelectedAt inComponent:0];
    }
}

#pragma mark - UIPickerView DataSource/Delegate

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return self.versionList.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    if (self.versionList.count <= row) return nil;
    NSObject *object = self.versionList[row];
    if ([object isKindOfClass:[NSString class]]) {
        return (NSString *)object;
    } else {
        return [object valueForKey:@"id"];
    }
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    if (self.versionList.count == 0) {
        self.versionTextField.text = @"";
        return;
    }
    self.versionSelectedAt = row;
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
    self.profile[@"lastVersionId"] = self.versionTextField.text;
}

#pragma mark - 服务器地址输入框

- (UITextField *)buildServerIpTextField {
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
    textField.placeholder = @"如 example.com:25565（留空则不自动加入）";
    textField.text = self.serverIp;
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.keyboardType = UIKeyboardTypeURL;
    textField.tag = 9527;
    textField.delegate = self;
    [textField addTarget:self action:@selector(serverIpTextFieldEditingChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(serverIpTextFieldEditingDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    return textField;
}

#pragma mark - JVM 启动参数输入框

- (UITextField *)buildJavaArgsTextField {
    if (self.javaArgsTextField) {
        if (!self.javaArgsTextField.superview || self.javaArgsTextField.superview == self.view) {
            return self.javaArgsTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    // 参照 main 分支 LauncherProfileEditorViewController：placeholder 为 "(default)"，
    // 表示未设置时回退到全局 java.java_args。
    textField.placeholder = @"(default)";
    // 仅当 profile 显式设置了 javaArgs 时才显示，否则留空显示 placeholder
    textField.text = self.profile[@"javaArgs"] ?: @"";
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.tag = 1003;
    textField.delegate = self;
    [textField addTarget:self action:@selector(javaArgsTextFieldEditingChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(javaArgsTextFieldEditingDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.javaArgsTextField = textField;
    return textField;
}

- (void)javaArgsTextFieldEditingChanged:(UITextField *)textField {
    self.javaArgs = textField.text ?: @"";
}

- (void)javaArgsTextFieldEditingDidEnd:(UITextField *)textField {
    // 参照 main 分支：空串或 "(default)" 视为未设置，保存时移除 key 以回退全局 java.java_args
    NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (trimmed.length == 0 || [trimmed isEqualToString:@"(default)"]) {
        self.javaArgs = @"";
        textField.text = @"";
    } else {
        self.javaArgs = trimmed;
        textField.text = trimmed;
    }
    [self saveSettings];
}

/// 一键清除当前版本已设置的 JVM 启动参数
- (void)clearJavaArgs {
    if (self.javaArgs.length == 0) {
        UIAlertController *tip = [UIAlertController alertControllerWithTitle:@"提示"
                                                                     message:@"当前没有已设置的 JVM 启动参数"
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [tip addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:tip animated:YES completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清除 JVM 启动参数"
                                                                   message:@"确定要清除当前版本的 JVM 启动参数吗？此操作不可撤销。"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        self.javaArgs = @"";
        self.javaArgsTextField.text = @"";
        [self saveSettings];
        [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)serverIpTextFieldEditingChanged:(UITextField *)textField {
    self.serverIp = textField.text ?: @"";
}

- (void)serverIpTextFieldEditingDidEnd:(UITextField *)textField {
    self.serverIp = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    textField.text = self.serverIp;
    [self saveSettings];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Helpers

- (NSString *)rendererDisplayName:(NSString *)renderer {
    NSArray *keys = getRendererKeys(NO);
    NSArray *names = getRendererNames(NO);
    NSUInteger idx = [keys indexOfObject:renderer];
    if (idx != NSNotFound && idx < names.count) {
        return names[idx];
    }
    return renderer ?: @"auto";
}

- (NSString *)currentProfileName {
    return self.profile[@"name"] ?: self.profileName;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *title = self.sections[indexPath.section][indexPath.row];

    switch (indexPath.section) {
        case 0: // 版本信息
            if ([title isEqualToString:@"名称"]) {
                // 聚焦名称输入框
                if (self.nameTextField) [self.nameTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"游戏版本"]) {
                // 聚焦版本选择器
                if (self.versionTextField) [self.versionTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"游戏目录"]) {
                [self editGameDir];
            }
            break;

        case 1: // 模组管理
            [self openModsManager];
            break;

        case 2: // 光影管理
            [self openShadersManager];
            break;

        case 3: // 高级设置
            if ([title isEqualToString:@"渲染器"]) {
                [self showRendererSelector];
            } else if ([title isEqualToString:@"图形 API"]) {
                [self showGraphicsApiSelector];
            } else if ([title isEqualToString:@"Java版本"]) {
                [self showJavaVersionSelector];
            } else if ([title isEqualToString:@"内存分配"]) {
                [self showMemoryAllocator];
            } else if ([title isEqualToString:@"JVM 启动参数"]) {
                if (self.javaArgsTextField) [self.javaArgsTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"清除JVM参数"]) {
                [self clearJavaArgs];
            }
            break;

        case 4: // 服务器地址
            [self focusTextFieldInCellAtIndexPath:indexPath];
            break;

        case 5: // 组件安装
            if ([title isEqualToString:@"Fabric API"]) {
                [self installFabricAPIStandalone];
            } else if ([title isEqualToString:@"OptiFine"]) {
                [self installOptiFineStandalone];
            }
            break;

        case 6: // 资源包管理
            [self openResourcePacksManager];
            break;

        case 7: // 数据包管理
            [self openDataPacksManager];
            break;

        case 8: // 世界管理
            [self openWorldsManager];
            break;
    }
}

- (void)focusTextFieldInCellAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    if (!cell) return;
    UITextField *textField = [self findTextFieldInView:cell.contentView];
    if ([textField canBecomeFirstResponder]) {
        [textField becomeFirstResponder];
    }
}

- (UITextField *)findTextFieldInView:(UIView *)view {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UITextField class]]) {
            return (UITextField *)sub;
        }
        UITextField *found = [self findTextFieldInView:sub];
        if (found) return found;
    }
    return nil;
}

#pragma mark - Actions

/// 编辑游戏目录（仿 main 分支 LauncherProfileEditorViewController 的 gameDir 文本框）
/// gameDir="." 表示使用当前 POJAV_GAME_DIR（即"游戏目录切换"选中的实例目录）
/// 也可以输入相对路径（相对于 POJAV_GAME_DIR）或绝对路径来实现版本隔离
- (void)editGameDir {
    NSString *currentGameDir = self.profile[@"gameDir"] ?: @".";
    NSString *currentInstance = getPrefObject(@"general.game_directory") ?: @"default";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"游戏目录"
                         message:[NSString stringWithFormat:
                                  @"设定此版本使用的游戏目录。\n\n"
                                   "\".\" = 使用当前游戏目录切换选中的实例（%@）\n"
                                   "相对路径 = 相对于当前游戏目录的子目录（用于版本隔离）\n"
                                   "绝对路径 = 使用指定路径",
                                  currentInstance]
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = currentGameDir;
        textField.placeholder = [NSString stringWithFormat:@". -> /Documents/instances/%@", currentInstance];
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"恢复默认" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        self.profile[@"gameDir"] = @".";
        [self saveSettings];
        [self.tableView reloadData];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *newGameDir = alert.textFields.firstObject.text;
        newGameDir = [newGameDir stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (newGameDir.length == 0) {
            newGameDir = @".";
        }
        self.profile[@"gameDir"] = newGameDir;
        [self saveSettings];
        [self.tableView reloadData];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openModsManager {
    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    vc.initialMode = ModsManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openShadersManager {
    ShadersManagerViewController *vc = [[ShadersManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    vc.initialMode = ShadersManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openResourcePacksManager {
    ResourcePacksManagerViewController *vc = [[ResourcePacksManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    vc.initialMode = ResourcePacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDataPacksManager {
    DataPacksManagerViewController *vc = [[DataPacksManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openWorldsManager {
    WorldsManagerViewController *vc = [[WorldsManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 组件独立安装（Fabric API / OptiFine）

- (BOOL)isFabricProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    // Fabric profile id 形如 "fabric-loader-0.16.0-1.21"，含 "fabric"
    // Quilt profile id 含 "quilt"
    return [lastVersionId.lowercaseString containsString:@"fabric"];
}

- (BOOL)isOptiFineCompatibleProfile {
    return [self isVanillaProfile] || [self isForgeProfile];
}

/// 是否为原版 (Vanilla) profile
/// lastVersionId 不含 forge/fabric/quilt/neoforge 等加载器标识
- (BOOL)isVanillaProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    NSString *lower = lastVersionId.lowercaseString;
    return ![lower containsString:@"forge"]
        && ![lower containsString:@"fabric"]
        && ![lower containsString:@"quilt"];
}

/// 是否为 Forge profile（排除 NeoForge）
/// 关键修复：原先用 `containsString:@"forge"` 会误判 neoforge 为 forge，
/// 现显式排除 neoforge（参照 FCL/HMCL 的 OptiFine 兼容性判断）
- (BOOL)isForgeProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    NSString *lower = lastVersionId.lowercaseString;
    return [lower containsString:@"forge"] && ![lower containsString:@"neoforge"];
}

/// 当前 profile 的 mods 目录路径
- (NSString *)currentProfileModsPath {
    NSString *gameDir = self.profile[@"gameDir"];
    NSString *baseDir;
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        baseDir = [NSString stringWithUTF8String:env];
    } else {
        baseDir = NSHomeDirectory();
    }

    NSString *modsBase;
    if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
        if ([gameDir isAbsolutePath]) {
            modsBase = gameDir;
        } else {
            modsBase = [baseDir stringByAppendingPathComponent:gameDir];
        }
    } else {
        modsBase = baseDir;
    }

    NSString *modsDir = [modsBase stringByAppendingPathComponent:@"mods"];
    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    return modsDir;
}

/// 当前 profile 的游戏版本（从 lastVersionId 解析）
- (NSString *)currentGameVersion {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return nil;
    // 解析 loader 前的游戏版本：1.21.1-forge-47.3.0 → 1.21.1
    // fabric-loader-0.16.0-1.21 → 1.21
    NSArray<NSString *> *loaders = @[@"forge", @"fabric", @"neoforge", @"quilt", @"fabric-loader"];
    NSString *result = lastVersionId;
    for (NSString *loader in loaders) {
        NSString *delimiter = [NSString stringWithFormat:@"-%@-", loader];
        NSRange range = [result rangeOfString:delimiter options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            result = [result substringToIndex:range.location];
            break;
        }
        // 处理 "fabric-loader-0.16.0-1.21" 形式：取最后一个版本号
        if ([result.lowercaseString hasPrefix:[NSString stringWithFormat:@"%@-", loader]]) {
            // fabric-loader-0.16.0-1.21 → 取最后的 "1.21"
            NSArray *parts = [result componentsSeparatedByString:@"-"];
            if (parts.count >= 2) {
                // 找到形如 1.x.x 的部分
                for (NSString *part in [parts reverseObjectEnumerator]) {
                    if ([part hasPrefix:@"1."]) {
                        return part;
                    }
                }
            }
        }
    }
    return result;
}

- (void)installFabricAPIStandalone {
    if (![self isFabricProfile]) {
        [self showComponentAlert:@"无法安装"
                          message:@"Fabric API 仅对 Fabric 加载器有效。\n\n当前版本不是 Fabric 加载器，无法安装 Fabric API。\n\n如需使用 Fabric，请到下载页面安装 Fabric 加载器。"];
        return;
    }

    NSString *gameVersion = [self currentGameVersion];
    if (!gameVersion) {
        [self showComponentAlert:@"无法安装" message:@"无法解析当前版本的游戏版本号"];
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"安装 Fabric API"
                                                                     message:[NSString stringWithFormat:@"Fabric API 是大多数 Fabric 模组的依赖库。\n\n将下载适配 Minecraft %@ 的最新 Fabric API 到 mods 目录。\n\n游戏版本：%@", gameVersion, gameVersion]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startInstallFabricAPIWithGameVersion:gameVersion];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)installOptiFineStandalone {
    if (![self isOptiFineCompatibleProfile]) {
        [self showComponentAlert:@"无法安装"
                          message:@"OptiFine 仅对原版 (Vanilla) 和 Forge 加载器有效。\n\n当前版本不兼容 OptiFine。\n\nFabric/Quilt/NeoForge 加载器请使用其他优化模组（如 Sodium 等）。"];
        return;
    }

    NSString *gameVersion = [self currentGameVersion];
    if (!gameVersion) {
        [self showComponentAlert:@"无法安装" message:@"无法解析当前版本的游戏版本号"];
        return;
    }

    // 关键修复（参照 FCL/HMCL OptiFine 安装流程）：
    //   - Vanilla profile: 必须以版本补丁方式安装（launchwrapper + tweakClass），
    //     仅把 jar 放进 mods/ 目录对原版完全无效，因为原版没有 mods 加载机制。
    //   - Forge profile: Forge 可作为 mod 加载 OptiFine jar，沿用 mods/ 方式。
    BOOL isVanilla = [self isVanillaProfile];
    NSString *message = nil;
    if (isVanilla) {
        message = [NSString stringWithFormat:
                   @"OptiFine 是 Minecraft 的优化模组，提供光影支持和高帧率。\n\n"
                   @"将下载适配 Minecraft %@ 的最新 OptiFine 并以版本补丁方式安装（参照 FCL/HMCL）：\n"
                   @"  • 创建独立版本：%@-OptiFine_xxx\n"
                   @"  • 通过 launchwrapper + optifine.OptiFineTweaker 加载\n"
                   @"  • 安装完成后会自动切换到新版本\n\n"
                   @"游戏版本：%@", gameVersion, gameVersion, gameVersion];
    } else {
        message = [NSString stringWithFormat:
                   @"OptiFine 是 Minecraft 的优化模组，提供光影支持和高帧率。\n\n"
                   @"将下载适配 Minecraft %@ 的最新 OptiFine 到 mods 目录（Forge 加载器方式）。\n\n"
                   @"游戏版本：%@（当前为 Forge 加载器）", gameVersion, gameVersion];
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"安装 OptiFine"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (isVanilla) {
            [self startInstallOptiFineAsPatch:gameVersion];
        } else {
            [self startInstallOptiFineWithGameVersion:gameVersion];
        }
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showComponentAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIAlertController *)showProgressAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [alert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:alert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];
    [self presentViewController:alert animated:YES completion:nil];
    return alert;
}

- (void)startInstallFabricAPIWithGameVersion:(NSString *)gameVersion {
    // 使用统一下载进度卡片（DownloadProgressCardView），删除散落的 alert+spinner
    UIView *hostView = self.view.window ?: self.view;
    DownloadProgressCardView *progress = [DownloadProgressCardView showInParentView:hostView title:@"正在安装 Fabric API"];
    [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:[NSString stringWithFormat:@"正在搜索适配 %@ 的 Fabric API...", gameVersion]];

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"query"] = @"fabric api";
    filters[@"limit"] = @"20";

    __weak typeof(self) weakSelf = self;
    [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:^(NSArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error || results.count == 0) {
                [progress failWithError:[NSError errorWithDomain:@"FabricAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未找到 Fabric API：%@", error.localizedDescription ?: @"无搜索结果"]}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"未找到 Fabric API：%@", error.localizedDescription ?: @"无搜索结果"]];
                });
                return;
            }

            // 找到标题包含 "fabric api" 且不包含 "kotlin" 的项目
            NSDictionary *fabricAPI = nil;
            for (NSDictionary *mod in results) {
                NSString *title = mod[@"title"] ?: @"";
                if ([title.lowercaseString containsString:@"fabric api"] && ![title.lowercaseString containsString:@"kotlin"]) {
                    fabricAPI = mod;
                    break;
                }
            }
            if (!fabricAPI) {
                [progress failWithError:[NSError errorWithDomain:@"FabricAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"未找到合适的 Fabric API 项目"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf showComponentAlert:@"安装失败" message:@"未找到合适的 Fabric API 项目"];
                });
                return;
            }

            [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:@"正在获取 Fabric API 版本列表..."];

            [[ModrinthAPI sharedInstance] getVersionsForModWithID:fabricAPI[@"id"] completion:^(NSArray<ModVersion *> *versions, NSError *versionError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf2 = weakSelf;
                    if (!strongSelf2) return;

                    if (versionError || versions.count == 0) {
                        [progress failWithError:[NSError errorWithDomain:@"FabricAPI" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"获取 Fabric API 版本失败：%@", versionError.localizedDescription ?: @"无版本"]}]];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [progress dismiss];
                            [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"获取 Fabric API 版本失败：%@", versionError.localizedDescription ?: @"无版本"]];
                        });
                        return;
                    }

                    // 找到匹配当前 gameVersion 的版本
                    ModVersion *matchingVersion = nil;
                    for (ModVersion *ver in versions) {
                        if ([ver.gameVersions containsObject:gameVersion]) {
                            matchingVersion = ver;
                            break;
                        }
                    }
                    if (!matchingVersion) {
                        matchingVersion = versions.firstObject;
                    }

                    NSDictionary *primaryFile = matchingVersion.primaryFile;
                    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
                        [progress failWithError:[NSError errorWithDomain:@"FabricAPI" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Fabric API 文件信息无效"}]];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [progress dismiss];
                            [strongSelf2 showComponentAlert:@"安装失败" message:@"Fabric API 文件信息无效"];
                        });
                        return;
                    }

                    [strongSelf2 downloadFabricAPIFile:primaryFile[@"url"]
                                                filename:primaryFile[@"filename"]
                                              progress:progress
                                              modInfo:fabricAPI];
                });
            }];
        });
    }];
}

- (void)downloadFabricAPIFile:(NSString *)urlString filename:(NSString *)filename progress:(DownloadProgressCardView *)progress modInfo:(NSDictionary *)modInfo {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSURL *url = [NSURL URLWithString:urlString];
        NSError *downloadError = nil;
        NSData *data = [self downloadDataWithURL:url error:&downloadError];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!data || downloadError) {
                [progress failWithError:downloadError ?: [NSError errorWithDomain:@"FabricAPI" code:5 userInfo:@{NSLocalizedDescriptionKey: @"下载失败"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"下载 Fabric API 失败：%@", downloadError.localizedDescription ?: @"未知错误"]];
                });
                return;
            }

            NSString *modsDir = [strongSelf2 currentProfileModsPath];
            NSString *saveFilename = filename ?: @"fabric-api.jar";
            NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

            NSError *writeError = nil;
            BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&writeError];

            if (success) {
                [progress completeWithTitle:@"Fabric API 安装完成"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装成功" message:[NSString stringWithFormat:@"Fabric API 已安装到 mods 目录：\n%@", saveFilename]];
                });
            } else {
                [progress failWithError:writeError ?: [NSError errorWithDomain:@"FabricAPI" code:6 userInfo:@{NSLocalizedDescriptionKey: @"写入失败"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"写入文件失败：%@", writeError.localizedDescription ?: @"未知错误"]];
                });
            }
        });
    });
}

- (void)startInstallOptiFineWithGameVersion:(NSString *)gameVersion {
    // 使用统一下载进度卡片（DownloadProgressCardView），删除散落的 alert+spinner
    UIView *hostView = self.view.window ?: self.view;
    DownloadProgressCardView *progress = [DownloadProgressCardView showInParentView:hostView title:@"正在安装 OptiFine"];
    [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:[NSString stringWithFormat:@"正在查询适配 %@ 的 OptiFine 版本...", gameVersion]];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // BMCL API 列表查询
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        NSURL *url = [NSURL URLWithString:listURL];
        NSError *listError = nil;
        NSData *listData = [self downloadDataWithURL:url error:&listError];

        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:[NSError errorWithDomain:@"OptiFine" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未找到适配 Minecraft %@ 的 OptiFine 版本", gameVersion]}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"未找到适配 Minecraft %@ 的 OptiFine 版本", gameVersion]];
                });
            });
            return;
        }

        // 切换到下载阶段
        [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:[NSString stringWithFormat:@"正在下载 OptiFine %@ %@", optiFineType, optiFinePatch]];

        // 下载 OptiFine
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiFineType, optiFinePatch];
        NSURL *dlURL = [NSURL URLWithString:downloadURL];
        NSError *downloadError = nil;
        NSData *data = [self downloadDataWithURL:dlURL error:&downloadError];

        // fallback: OptiFine 官方源
        if ((!data || downloadError) && filename) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSURL *officialURLObject = [NSURL URLWithString:officialURL];
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURL:officialURLObject error:&officialError];
            if (officialData && !officialError) {
                data = officialData;
                downloadError = nil;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!data || downloadError) {
                [progress failWithError:downloadError ?: [NSError errorWithDomain:@"OptiFine" code:2 userInfo:@{NSLocalizedDescriptionKey: @"下载失败"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"下载 OptiFine 失败：%@", downloadError.localizedDescription ?: @"未知错误"]];
                });
                return;
            }

            NSString *modsDir = [strongSelf2 currentProfileModsPath];
            NSString *saveFilename = filename ?: [NSString stringWithFormat:@"OptiFine_%@_%@_%@.jar", gameVersion, optiFineType, optiFinePatch];
            NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

            NSError *writeError = nil;
            BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&writeError];

            if (success) {
                [progress completeWithTitle:@"OptiFine 安装完成"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装成功" message:[NSString stringWithFormat:@"OptiFine %@ %@ 已安装到 mods 目录", optiFineType, optiFinePatch]];
                });
            } else {
                [progress failWithError:writeError ?: [NSError errorWithDomain:@"OptiFine" code:3 userInfo:@{NSLocalizedDescriptionKey: @"写入失败"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"写入文件失败：%@", writeError.localizedDescription ?: @"未知错误"]];
                });
            }
        });
    });
}

#pragma mark - OptiFine 版本补丁安装（Vanilla profile，参照 FCL/HMCL OptiFineInstallTask）

/// 以版本补丁方式安装 OptiFine（适用于 Vanilla profile）
/// 参照 FCL OptiFineInstallTask 与 HMCL OptiFineInstallTask：
///   1. 下载 OptiFine jar 到 libraries/optifine/OptiFine/<mcVersion>/<versionId>.jar
///   2. 创建 versions/<versionId>/<versionId>.json，mainClass 设为
///      net.minecraft.launchwrapper.Launcher，并附加 --tweakClass optifine.OptiFineTweaker
///   3. inheritsFrom 指向原版版本（vanilla parent 必须已存在）
///   4. 创建新 profile 并切换为当前 profile
- (void)startInstallOptiFineAsPatch:(NSString *)gameVersion {
    UIView *hostView = self.view.window ?: self.view;
    DownloadProgressCardView *progress = [DownloadProgressCardView showInParentView:hostView title:@"正在安装 OptiFine"];
    [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:[NSString stringWithFormat:@"正在查询适配 %@ 的 OptiFine 版本...", gameVersion]];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 1. BMCL API 查询适配当前游戏版本的 OptiFine 列表
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        NSURL *url = [NSURL URLWithString:listURL];
        NSError *listError = nil;
        NSData *listData = [self downloadDataWithURL:url error:&listError];

        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:[NSError errorWithDomain:@"OptiFine" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未找到适配 Minecraft %@ 的 OptiFine 版本", gameVersion]}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"未找到适配 Minecraft %@ 的 OptiFine 版本", gameVersion]];
                });
            });
            return;
        }

        // 2. 下载 OptiFine jar
        [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:[NSString stringWithFormat:@"正在下载 OptiFine %@ %@", optiFineType, optiFinePatch]];
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiFineType, optiFinePatch];
        NSURL *dlURL = [NSURL URLWithString:downloadURL];
        NSError *downloadError = nil;
        NSData *jarData = [self downloadDataWithURL:dlURL error:&downloadError];

        // fallback: OptiFine 官方源
        if ((!jarData || downloadError) && filename.length > 0) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSURL *officialURLObject = [NSURL URLWithString:officialURL];
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURL:officialURLObject error:&officialError];
            if (officialData && !officialError) {
                jarData = officialData;
                downloadError = nil;
            }
        }

        if (!jarData || downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:downloadError ?: [NSError errorWithDomain:@"OptiFine" code:2 userInfo:@{NSLocalizedDescriptionKey: @"下载失败"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"下载 OptiFine 失败：%@", downloadError.localizedDescription ?: @"未知错误"]];
                });
            });
            return;
        }

        // 3. 检查原版父版本必须已存在（否则 inheritsFrom 会失败）
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        NSString *parentJsonPath = [gameDir stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"versions/%@/%@.json", gameVersion, gameVersion]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:parentJsonPath]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:[NSError errorWithDomain:@"OptiFine" code:4 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未找到原版 %@ 的版本信息", gameVersion]}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"未找到原版 %@ 的版本信息。\n\n请先在下载页面安装原版 %@，然后再安装 OptiFine。", gameVersion, gameVersion]];
                });
            });
            return;
        }

        // 4. 写入 jar 到 libraries/optifine/OptiFine/<mcVersion>/<versionId>.jar
        //    参照 FCL/HMCL：OptiFine jar 作为 launchwrapper 的 tweakClass 输入，
        //    mainClass 设为 net.minecraft.launchwrapper.Launcher
        NSString *versionId = [NSString stringWithFormat:@"%@-OptiFine_%@_%@", gameVersion, optiFineType, optiFinePatch];
        NSString *optifineJarPath = [NSString stringWithFormat:@"optifine/OptiFine/%@/%@.jar", gameVersion, versionId];
        NSString *optifineJarAbsPath = [NSString stringWithFormat:@"%@/libraries/%@", gameDir, optifineJarPath];
        NSString *jarDir = [optifineJarAbsPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:jarDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *writeJarError = nil;
        BOOL jarOk = [jarData writeToFile:optifineJarAbsPath options:NSDataWritingAtomic error:&writeJarError];
        if (!jarOk) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:writeJarError ?: [NSError errorWithDomain:@"OptiFine" code:5 userInfo:@{NSLocalizedDescriptionKey: @"写入 jar 失败"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"写入 OptiFine jar 失败：%@", writeJarError.localizedDescription ?: @"未知错误"]];
                });
            });
            return;
        }

        // 5. 创建 version JSON（launchwrapper + tweakClass + inheritsFrom）
        NSDictionary *versionJson = @{
            @"id": versionId,
            @"inheritsFrom": gameVersion,
            @"type": @"release",
            @"mainClass": @"net.minecraft.launchwrapper.Launcher",
            @"minecraftArguments": @"--username ${auth_player_name} --version ${version_name} --gameDir ${game_directory} --assetsDir ${assets_root} --assetIndex ${assets_index_name} --uuid ${auth_uuid} --accessToken ${auth_access_token} --userType ${user_type} --versionType ${version_type} --tweakClass optifine.OptiFineTweaker",
            @"libraries": @[
                @{
                    @"name": [NSString stringWithFormat:@"optifine:OptiFine:%@", gameVersion],
                    @"downloads": @{
                        @"artifact": @{
                            @"path": optifineJarPath,
                            @"url": @"",
                            @"size": @(jarData.length),
                            @"sha1": @""
                        }
                    }
                }
            ],
            @"jar": gameVersion,
            @"minimumLauncherVersion": @21
        };
        NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
        [[NSFileManager defaultManager] createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *jsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:versionJson options:NSJSONWritingPrettyPrinted error:nil];
        NSError *writeJsonError = nil;
        [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&writeJsonError];

        if (writeJsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:writeJsonError];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"安装失败" message:[NSString stringWithFormat:@"写入版本 JSON 失败：%@", writeJsonError.localizedDescription ?: @"未知错误"]];
                });
            });
            return;
        }

        // 6. 注册新 profile 并切换为当前 profile（参照 FCL/HMCL 行为）
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            profile[@"gameDir"] = @".";
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;

            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];

            [progress completeWithTitle:@"OptiFine 安装完成"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [progress dismiss];
                [strongSelf2 showComponentAlert:@"安装成功"
                                         message:[NSString stringWithFormat:
                                                  @"OptiFine %@ %@ 已安装为独立版本\n\n版本 ID：%@\n\n已自动切换到该版本，可直接启动游戏。",
                                                  optiFineType, optiFinePatch, versionId]];
            });
        });
    });
}

- (void)showRendererSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择渲染器"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *renderers = getRendererKeys(NO);
    NSArray *displayNames = getRendererNames(NO);

    for (NSInteger i = 0; i < renderers.count; i++) {
        NSString *renderer = renderers[i];
        NSString *name = i < displayNames.count ? displayNames[i] : renderer;
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedRenderer = renderer;
            [self saveSettings];
            [self.tableView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:3];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

/// 判断当前 profile 的 MC 版本是否为 26.2+（需要图形 API 切换）
- (BOOL)isCurrentProfileModernVersion {
    NSString *versionId = self.profile[@"lastVersionId"] ?: @"";
    // 修复 Fabric/Quilt/Forge loader profile 的版本号识别：
    //   原 implementation 用 hasPrefix:@"26." 判断，但 Fabric profile 的 lastVersionId
    //   形如 "fabric-loader-0.16.0-26.2"，前缀是 "fabric-loader" 不是 "26."，导致
    //   MC 26.2+ Fabric profile 看不到"图形 API"选项。
    //   修复：先用 ModpackExportService.parseVersionId 提取 minecraft 版本号，
    //   再用提取后的版本号判断。也支持 forge/neoforge 形如 "26.2-forge-..."。
    NSDictionary *parsed = [ModpackExportService parseVersionId:versionId];
    NSString *mcVersion = parsed[@"minecraft"] ?: versionId;
    // 26.x 版本（26w02a 等快照也匹配）
    if ([mcVersion hasPrefix:@"26."]) return YES;
    if ([mcVersion hasPrefix:@"26w"]) return YES;
    // 1.21.8+ 版本（Mojang 在 1.21.8 引入 Vulkan API）
    if ([mcVersion hasPrefix:@"1.21."]) {
        NSString *minorStr = [mcVersion substringFromIndex:5];
        NSInteger minor = [minorStr integerValue];
        if (minor >= 8) return YES;
    }
    return NO;
}

/// 图形 API 显示名
- (NSString *)graphicsApiDisplayName:(NSString *)api {
    if ([api isEqualToString:@"prefer_vulkan"]) return @"优先 Vulkan";
    if ([api isEqualToString:@"prefer_opengl"]) return @"优先 OpenGL";
    return @"默认";
}

/// 图形 API 选择器（MC 26.2+ 专用）
- (void)showGraphicsApiSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择图形 API"
                                                                   message:@"MC 26.2+ 游戏内 OpenGL/Vulkan 切换"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *keys = @[@"default", @"prefer_vulkan", @"prefer_opengl"];
    NSArray *names = @[@"默认", @"优先 Vulkan", @"优先 OpenGL"];

    for (NSInteger i = 0; i < keys.count; i++) {
        NSString *key = keys[i];
        NSString *name = i < names.count ? names[i] : key;
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedGraphicsApi = key;
            [self saveSettings];
            [self.tableView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:1 inSection:3];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showJavaVersionSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择Java版本"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 从 java.java_homes 偏好动态获取已安装的 Java 版本列表
    NSMutableDictionary *javaHomes = [getPrefObject(@"java.java_homes") mutableCopy];
    if (!javaHomes) {
        javaHomes = [NSMutableDictionary dictionary];
    }
    NSMutableArray *versions = [[javaHomes allKeys] mutableCopy];
    // "0" 表示自动选择，单独处理
    [versions removeObject:@"0"];
    [versions sortUsingSelector:@selector(compare:)];
    // 自动选项放最前
    [versions insertObject:@"0" atIndex:0];

    for (NSString *ver in versions) {
        NSString *name = [ver isEqualToString:@"0"] ? @"自动选择" : [NSString stringWithFormat:@"Java %@", ver];
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedJavaVersion = ver;
            [self saveSettings];
            [self.tableView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:1 inSection:3];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showMemoryAllocator {
    NSInteger minMemory = 512;
    NSInteger step = 512;
    NSMutableArray *options = [NSMutableArray array];
    for (NSInteger mem = minMemory; mem <= self.maxMemory; mem += step) {
        [options addObject:@(mem)];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"分配内存"
                                                                   message:[NSString stringWithFormat:@"设备总内存: %ld MB\n最大可分配: %ld MB", (long)(self.maxMemory / 0.8), (long)self.maxMemory]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSNumber *memNum in options) {
        NSInteger mem = [memNum integerValue];
        NSString *title = [NSString stringWithFormat:@"%ld MB", (long)mem];
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.allocatedMemory = mem;
            [self saveSettings];
            [self.tableView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:2 inSection:3];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Done / Close

- (void)actionClose {
    // 收起键盘
    [self.view endEditing:YES];
    // 直接关闭，不保存（设置项在编辑过程中已自动保存）
    if (self.navigationController) {
        if (self.navigationController.viewControllers.firstObject == self) {
            [self dismissViewControllerAnimated:YES completion:nil];
        } else {
            [self.navigationController popViewControllerAnimated:YES];
        }
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)actionDone {
    // 收起键盘，触发 EditingDidEnd
    [self.view endEditing:YES];

    NSString *newName = self.profile[@"name"];
    if ([newName length] == 0) {
        // 名称为空，恢复原名
        self.profile[@"name"] = self.originalName;
        newName = self.originalName;
    }

    // 检查重命名冲突
    if (![self.originalName isEqualToString:newName]) {
        // 名称变了，检查新名是否已存在
        if (PLProfiles.current.profiles[newName]) {
            // 重名，提示并取消
            showDialog(@"错误", @"已存在同名版本配置，请使用其他名称");
            return;
        }
        // 删除旧名，添加新名
        if (self.originalName.length > 0) {
            [PLProfiles.current.profiles removeObjectForKey:self.originalName];
        }
        PLProfiles.current.profiles[newName] = self.profile;
        // 如果原来选中的是被重命名的 profile，更新选中
        if ([PLProfiles.current.selectedProfileName isEqualToString:self.originalName]) {
            PLProfiles.current.selectedProfileName = newName;
        }
    } else {
        // 名称没变，直接保存
        PLProfiles.current.profiles[newName] = self.profile;
    }

    [PLProfiles.current save];

    // 发送通知刷新配置文件列表
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:newName];

    // 关闭
    [self actionClose];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

#pragma mark - UA-aware download helper

/// 阶段6修复（参照 FCL）：用带浏览器 User-Agent 的 NSURLSession 替代 NSData dataWithContentsOfURL:
/// 进行同步下载。BMCLAPI 的 optifine/curseforge 转发受 Cloudflare 保护，默认 UA 会被拦截返回 403。
/// 与 DownloadViewController.downloadDataWithURLString:error: 等价，但接收 NSURL 参数
/// （本文件调用处均已构造好 NSURL）。
- (NSData *)downloadDataWithURL:(NSURL *)url error:(NSError **)error {
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProfileSettingsDownload"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil URL"}];
        }
        return nil;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60;
    cfg.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        @"Accept": @"*/*"
    };
    __block NSData *result = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        if (err) {
            resultError = err;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:@"ProfileSettingsDownload"
                                                  code:statusCode
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld for %@", (long)statusCode, url.absoluteString]}];
            } else {
                result = data;
            }
        } else {
            result = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_SEC));
    if (error) *error = resultError;
    [session finishTasksAndInvalidate];
    return result;
}

@end
