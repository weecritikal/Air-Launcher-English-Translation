#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ResourcePacksManagerViewController.h"
#import "DataPacksManagerViewController.h"
#import "WorldsManagerViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import "BackgroundManager.h"

@interface ProfileSettingsViewController () <UITextFieldDelegate>

@property (nonatomic, strong) NSArray<NSArray *> *sections;
@property (nonatomic, strong) NSString *selectedRenderer;
@property (nonatomic, strong) NSString *selectedJavaVersion;
@property (nonatomic, assign) NSInteger allocatedMemory;
@property (nonatomic, assign) NSInteger maxMemory;
// 服务器地址（FCL 风格：留空则不自动加入）
@property (nonatomic, strong) NSString *serverIp;

@end

@implementation ProfileSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = [NSString stringWithFormat:@"%@ 设置", self.profileName ?: @"版本"];
    self.view.backgroundColor = [UIColor clearColor];
    
    // 设置表格
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.backgroundColor = [UIColor clearColor];
    
    // 计算最大内存
    [self calculateMaxMemory];
    
    // 加载设置
    [self loadSettings];
    
    // 设置分区
    [self setupSections];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)calculateMaxMemory {
    // 获取设备总内存 (字节)
    long long totalMemory = [NSProcessInfo processInfo].physicalMemory;
    // 转换为 MB
    self.maxMemory = (NSInteger)(totalMemory / (1024 * 1024));
    // 留一些给系统，最大可用为总内存的 80%
    self.maxMemory = (NSInteger)(self.maxMemory * 0.8);
    // 确保最小值
    if (self.maxMemory < 1024) {
        self.maxMemory = 1024;
    }
}

- (void)loadSettings {
    // 加载当前版本的设置
    NSMutableDictionary *profile = PLProfiles.current.profiles[self.profileName];
    
    // 渲染器
    self.selectedRenderer = profile[@"renderer"] ?: @"auto";
    
    // Java版本（兼容旧版直装器写入的 NSDictionary 格式）
    id javaVerRaw = profile[@"javaVersion"];
    if ([javaVerRaw isKindOfClass:[NSDictionary class]]) {
        id major = javaVerRaw[@"majorVersion"];
        self.selectedJavaVersion = major ? [major description] : @"auto";
    } else {
        self.selectedJavaVersion = [javaVerRaw isKindOfClass:[NSString class]] ? javaVerRaw : @"auto";
    }
    
    // 内存分配 (MB)
    self.allocatedMemory = [profile[@"allocatedMemory"] integerValue];
    if (self.allocatedMemory == 0) {
        // 默认内存：最大内存的一半或 2048MB，取较小值
        self.allocatedMemory = MIN(self.maxMemory / 2, 2048);
    }
    // 确保不超过最大内存
    if (self.allocatedMemory > self.maxMemory) {
        self.allocatedMemory = self.maxMemory;
    }

    // 服务器地址（默认空字符串，留空不自动加入）
    self.serverIp = [PLProfiles.current serverIpForProfile:self.profileName] ?: @"";
}

- (void)setupSections {
    self.sections = @[
        @[@"模组管理"],
        @[@"光影管理"],
        @[@"渲染器", @"Java版本", @"内存分配"],
        @[@"服务器地址"],
        @[@"资源包管理"],
        @[@"数据包管理"],
        @[@"世界管理"]
    ];
}

- (void)saveSettings {
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[self.profileName] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }

    profile[@"renderer"] = self.selectedRenderer;
    profile[@"javaVersion"] = self.selectedJavaVersion;
    profile[@"allocatedMemory"] = @(self.allocatedMemory);
    // 服务器地址持久化（FCL 风格：留空则不自动加入）
    profile[@"serverIp"] = self.serverIp ?: @"";

    profiles[self.profileName] = profile;
    [PLProfiles.current save];
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
        case 0: return @"模组";
        case 1: return @"光影";
        case 2: return @"高级设置";
        case 3: return @"服务器";
        case 4: return @"资源包";
        case 5: return @"数据包";
        case 6: return @"世界";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 3) {
        // 说明文字（参照 FCL）：留空则不自动加入
        return @"启动游戏后自动加入此服务器（参照 FCL）\n格式：host 或 host:port（IPv6 为 [host]:port），留空则不自动加入";
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

    // 重置复用 cell 的状态，避免上一行的 accessoryView（如服务器输入框）残留
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;

    NSString *title = self.sections[indexPath.section][indexPath.row];
    cell.textLabel.text = title;

    switch (indexPath.section) {
        case 0: // 模组管理
            cell.imageView.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.detailTextLabel.text = nil;
            break;

        case 1: // 光影管理
            cell.imageView.image = [UIImage systemImageNamed:@"paintbrush.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.detailTextLabel.text = nil;
            break;

        case 2: // 高级设置
            if ([title isEqualToString:@"渲染器"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"cpu"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self rendererDisplayName:self.selectedRenderer];
            } else if ([title isEqualToString:@"Java版本"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"j.square"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self.selectedJavaVersion isEqualToString:@"auto"] ? @"自动" : self.selectedJavaVersion;
            } else if ([title isEqualToString:@"内存分配"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB / %ld MB", (long)self.allocatedMemory, (long)self.maxMemory];
            }
            break;

        case 3: // 服务器地址（FCL 风格）
            cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            cell.detailTextLabel.text = nil;
            cell.accessoryView = [self buildServerIpTextField];
            break;

        case 4: // 资源包管理
            cell.imageView.image = [UIImage systemImageNamed:@"rectangle.stack.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.detailTextLabel.text = nil;
            break;

        case 5: // 数据包管理
            cell.imageView.image = [UIImage systemImageNamed:@"shippingbox.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.detailTextLabel.text = nil;
            break;

        case 6: // 世界管理
            cell.imageView.image = [UIImage systemImageNamed:@"globe.asia.australia.fill"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.detailTextLabel.text = nil;
            break;
    }

    return cell;
}

// 构建服务器地址输入框（UITextField），双向绑定到当前 profile 的 serverIp
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
    // 编辑结束（回车收起键盘或失焦）时持久化保存；仅监听 EditingDidEnd 避免重复触发
    [textField addTarget:self action:@selector(serverIpTextFieldEditingDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    return textField;
}

#pragma mark - 服务器地址输入框事件

// 输入过程中实时同步到 self.serverIp
- (void)serverIpTextFieldEditingChanged:(UITextField *)textField {
    self.serverIp = textField.text ?: @"";
}

// 结束编辑（回车 / 失焦）时持久化保存
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

- (NSString *)rendererDisplayName:(NSString *)renderer {
    NSDictionary *names = @{
        @"auto": @"自动",
        @"zink": @"Zink (Vulkan)",
        @"gl4es": @"GL4ES (OpenGL ES)",
        @"angle": @"ANGLE (Metal)",
        @"mobileglues": @"MobileGlues"
    };
    return names[renderer] ?: renderer;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSString *title = self.sections[indexPath.section][indexPath.row];
    
    switch (indexPath.section) {
        case 0: // 模组管理
            [self openModsManager];
            break;
            
        case 1: // 光影管理
            [self openShadersManager];
            break;
            
        case 2: // 高级设置
            if ([title isEqualToString:@"渲染器"]) {
                [self showRendererSelector];
            } else if ([title isEqualToString:@"Java版本"]) {
                [self showJavaVersionSelector];
            } else if ([title isEqualToString:@"内存分配"]) {
                [self showMemoryAllocator];
            }
            break;

        case 3: // 服务器地址：点击行时聚焦输入框
            [self focusServerIpTextFieldAtIndexPath:indexPath];
            break;

        case 4: // 资源包管理
            [self openResourcePacksManager];
            break;

        case 5: // 数据包管理
            [self openDataPacksManager];
            break;

        case 6: // 世界管理
            [self openWorldsManager];
            break;
    }
}

// 定位服务器地址 cell 中的输入框并聚焦
- (void)focusServerIpTextFieldAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    if (!cell) return;
    UITextField *textField = [self findTextFieldInView:cell.contentView];
    if ([textField canBecomeFirstResponder]) {
        [textField becomeFirstResponder];
    }
}

// 递归查找 contentView 中的 UITextField（即服务器地址输入框）
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
    vc.profileName = self.profileName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openShadersManager {
    ShadersManagerViewController *vc = [[ShadersManagerViewController alloc] init];
    vc.profileName = self.profileName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openResourcePacksManager {
    ResourcePacksManagerViewController *vc = [[ResourcePacksManagerViewController alloc] init];
    vc.profileName = self.profileName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDataPacksManager {
    DataPacksManagerViewController *vc = [[DataPacksManagerViewController alloc] init];
    vc.profileName = self.profileName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openWorldsManager {
    WorldsManagerViewController *vc = [[WorldsManagerViewController alloc] init];
    vc.profileName = self.profileName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showRendererSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择渲染器"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *renderers = @[@"auto", @"zink", @"gl4es", @"angle", @"mobileglues"];
    NSArray *displayNames = @[@"自动", @"Zink (Vulkan)", @"GL4ES (OpenGL ES)", @"ANGLE (Metal)", @"MobileGlues"];
    
    for (NSInteger i = 0; i < renderers.count; i++) {
        NSString *renderer = renderers[i];
        NSString *name = displayNames[i];
        UIAlertActionStyle style = [self.selectedRenderer isEqualToString:renderer] ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault;
        
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:style
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedRenderer = renderer;
            [self saveSettings];
            [self.tableView reloadData];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    // iPad支持
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:2];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showJavaVersionSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择Java版本"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"自动选择"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        self.selectedJavaVersion = @"auto";
        [self saveSettings];
        [self.tableView reloadData];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Java 8"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        self.selectedJavaVersion = @"java8";
        [self saveSettings];
        [self.tableView reloadData];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Java 17"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        self.selectedJavaVersion = @"java17";
        [self saveSettings];
        [self.tableView reloadData];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Java 21"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        self.selectedJavaVersion = @"java21";
        [self saveSettings];
        [self.tableView reloadData];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Java 25"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        self.selectedJavaVersion = @"java25";
        [self saveSettings];
        [self.tableView reloadData];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    // iPad支持
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:1 inSection:2];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showMemoryAllocator {
    // 计算建议内存值
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
        UIAlertActionStyle style = (self.allocatedMemory == mem) ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault;
        
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:style
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.allocatedMemory = mem;
            [self saveSettings];
            [self.tableView reloadData];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    // iPad支持
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:2 inSection:2];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
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
