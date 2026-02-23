#import "VersionManagerViewController.h"
#import "PLProfiles.h"
#import "ProfileSettingsViewController.h"
#import "utils.h"

@interface VersionManagerViewController ()
@property (nonatomic, strong) NSArray<NSString *> *versionList;
@property (nonatomic, strong) NSString *selectedVersion;
@end

@implementation VersionManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"管理版本";
    self.view.backgroundColor = [UIColor clearColor];
    
    // 设置表格
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.backgroundColor = [UIColor clearColor];
    
    // 加载版本列表
    [self loadVersionList];
    
    // 获取当前选中的版本
    self.selectedVersion = PLProfiles.current.selectedProfileName;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadVersionList];
    self.selectedVersion = PLProfiles.current.selectedProfileName;
    [self.tableView reloadData];
}

- (void)loadVersionList {
    // 从PLProfiles获取所有版本
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableArray *versions = [NSMutableArray array];
    for (NSString *key in profiles.allKeys) {
        [versions addObject:key];
    }
    // 排序
    self.versionList = [versions sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        return [obj2 compare:obj1];
    }];
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.versionList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"VersionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
        cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.7];
    }
    
    NSString *versionName = self.versionList[indexPath.row];
    NSDictionary *profile = PLProfiles.current.profiles[versionName];
    NSString *versionId = profile[@"lastVersionId"] ?: @"unknown";
    
    cell.textLabel.text = versionName;
    cell.detailTextLabel.text = versionId;
    
    // 如果是当前选中的版本，显示勾选标记
    if ([versionName isEqualToString:self.selectedVersion]) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    
    return cell;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSString *versionName = self.versionList[indexPath.row];
    
    // 显示操作菜单
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:versionName
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    // 选择此版本
    [alert addAction:[UIAlertAction actionWithTitle:@"选择此版本"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self selectVersion:versionName];
    }]];
    
    // 版本设置
    [alert addAction:[UIAlertAction actionWithTitle:@"版本设置"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self openVersionSettings:versionName];
    }]];
    
    // 删除版本
    [alert addAction:[UIAlertAction actionWithTitle:@"删除版本"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self deleteVersion:versionName];
    }]];
    
    // 取消
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    // iPad支持
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)selectVersion:(NSString *)versionName {
    // 设置当前选中的版本
    PLProfiles.current.selectedProfileName = versionName;
    
    self.selectedVersion = versionName;
    [self.tableView reloadData];
    
    // 发送通知更新UI
    [[NSNotificationCenter defaultCenter] postNotificationName:@"VersionChanged" object:versionName];
}

- (void)openVersionSettings:(NSString *)versionName {
    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = versionName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)deleteVersion:(NSString *)versionName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认删除"
                                                                   message:[NSString stringWithFormat:@"确定要删除版本 \"%@\" 吗？此操作不可恢复。", versionName]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        // 删除版本
        NSMutableDictionary *profiles = PLProfiles.current.profiles;
        [profiles removeObjectForKey:versionName];
        
        // 如果删除的是当前选中的版本，清空选择
        if ([PLProfiles.current.selectedProfileName isEqualToString:versionName]) {
            PLProfiles.current.selectedProfileName = profiles.allKeys.firstObject;
        }
        
        // 保存更改
        [PLProfiles.current save];
        
        // 删除版本文件夹
        NSString *gameDir = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), versionName];
        [[NSFileManager defaultManager] removeItemAtPath:gameDir error:nil];
        
        // 刷新列表
        [self loadVersionList];
        [self.tableView reloadData];
    }]];
    
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
