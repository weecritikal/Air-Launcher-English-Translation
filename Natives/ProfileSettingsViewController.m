#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "utils.h"

@interface ProfileSettingsViewController ()

@property (nonatomic, strong) NSArray<NSArray *> *sections;
@property (nonatomic, strong) NSString *selectedRenderer;
@property (nonatomic, strong) NSString *selectedJavaVersion;
@property (nonatomic, assign) NSInteger allocatedMemory;
@property (nonatomic, assign) NSInteger maxMemory;

@end

@implementation ProfileSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = [NSString stringWithFormat:@"%@ 设置", self.profileName ?: @"版本"];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    // 设置表格
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    
    // 计算最大内存
    [self calculateMaxMemory];
    
    // 加载设置
    [self loadSettings];
    
    // 设置分区
    [self setupSections];
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
    NSDictionary *profile = PLProfiles.current.profiles[self.profileName];
    
    // 渲染器
    self.selectedRenderer = profile[@"renderer"] ?: @"auto";
    
    // Java版本
    self.selectedJavaVersion = profile[@"javaVersion"] ?: @"auto";
    
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
}

- (void)setupSections {
    self.sections = @[
        @[@"模组管理"],
        @[@"光影管理"],
        @[@"渲染器", @"Java版本", @"内存分配"]
    ];
}

- (void)saveSettings {
    NSMutableDictionary *profile = [PLProfiles.current.profiles[self.profileName] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    
    profile[@"renderer"] = self.selectedRenderer;
    profile[@"javaVersion"] = self.selectedJavaVersion;
    profile[@"allocatedMemory"] = @(self.allocatedMemory);
    
    [PLProfiles.current saveProfile:profile withName:self.profileName];
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
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"SettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellIdentifier];
    }
    
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
    }
    
    return cell;
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
    }
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

@end
