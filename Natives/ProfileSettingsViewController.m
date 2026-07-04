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
#import "ios_uikit_bridge.h" // for showDialog
#import "utils.h"
#import "BackgroundManager.h"

@interface ProfileSettingsViewController () <UITextFieldDelegate, UIPickerViewDataSource, UIPickerViewDelegate>

@property (nonatomic, strong) NSArray<NSArray *> *sections;
@property (nonatomic, strong) NSString *selectedRenderer;
@property (nonatomic, strong) NSString *selectedJavaVersion;
@property (nonatomic, assign) NSInteger allocatedMemory;
@property (nonatomic, assign) NSInteger maxMemory;
// 服务器地址（FCL 风格：留空则不自动加入）
@property (nonatomic, strong) NSString *serverIp;
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

    // 确保 profile 有 name 字段
    self.originalName = self.profile[@"name"];
    if ([self.originalName length] == 0) {
        self.originalName = self.profileName ?: @"New Profile";
        self.profile[@"name"] = self.originalName;
    }

    self.title = [NSString stringWithFormat:@"%@ 设置", self.originalName];
    self.view.backgroundColor = [UIColor clearColor];

    // 导航栏按钮
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];

    // 设置表格
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.backgroundColor = [UIColor clearColor];

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
}

#pragma mark - Sections

- (void)setupSections {
    self.sections = @[
        @[@"名称", @"游戏版本", @"游戏目录"],
        @[@"模组管理"],
        @[@"光影管理"],
        @[@"渲染器", @"Java版本", @"内存分配"],
        @[@"服务器地址"],
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
    existing[@"javaVersion"] = self.selectedJavaVersion;
    existing[@"allocatedMemory"] = @(self.allocatedMemory);
    existing[@"serverIp"] = self.serverIp ?: @"";
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
        case 5: return @"资源包";
        case 6: return @"数据包";
        case 7: return @"世界";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 4) {
        return @"启动游戏后自动加入此服务器（参照 FCL）\n格式：host 或 host:port（IPv6 为 [host]:port），留空则不自动加入";
    }
    if (section == 0) {
        return @"游戏目录决定存档/模组/配置文件的隔离位置";
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
                cell.accessoryType = UITableViewCellAccessoryNone;
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
            } else if ([title isEqualToString:@"Java版本"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"j.square"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self.selectedJavaVersion isEqualToString:@"0"] ? @"自动" : [NSString stringWithFormat:@"Java %@", self.selectedJavaVersion];
            } else if ([title isEqualToString:@"内存分配"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB / %ld MB", (long)self.allocatedMemory, (long)self.maxMemory];
            }
            break;

        case 4: // 服务器地址（FCL 风格）
            cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            cell.accessoryView = [self buildServerIpTextField];
            break;

        case 5: // 资源包管理
            cell.imageView.image = [UIImage systemImageNamed:@"rectangle.stack.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;

        case 6: // 数据包管理
            cell.imageView.image = [UIImage systemImageNamed:@"shippingbox.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;

        case 7: // 世界管理
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
            newVersionList = localVersionList;
        } else {
            NSString *type = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"][self.versionTypeControl.selectedSegmentIndex];
            newVersionList = [remoteVersionList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(type == %@)", type]];
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
            } else if ([title isEqualToString:@"Java版本"]) {
                [self showJavaVersionSelector];
            } else if ([title isEqualToString:@"内存分配"]) {
                [self showMemoryAllocator];
            }
            break;

        case 4: // 服务器地址
            [self focusTextFieldInCellAtIndexPath:indexPath];
            break;

        case 5: // 资源包管理
            [self openResourcePacksManager];
            break;

        case 6: // 数据包管理
            [self openDataPacksManager];
            break;

        case 7: // 世界管理
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

@end
