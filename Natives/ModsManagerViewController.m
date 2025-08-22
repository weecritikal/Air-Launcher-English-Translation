//
//  ModsManagerViewController.m
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//

#import "ModsManagerViewController.h"
#import "ModTableViewCell.h"
#import "ModService.h"
#import "ModItem.h"

@interface ModsManagerViewController () <UITableViewDataSource, UITableViewDelegate, ModTableViewCellDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<ModItem *> *mods;
@end

@implementation ModsManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"管理 Mod";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.tableView registerClass:[ModTableViewCell class] forCellReuseIdentifier:@"ModCell"];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshList)];
    self.navigationItem.rightBarButtonItem = refresh;

    [self refreshList];
}

- (void)refreshList {
    __weak typeof(self) wself = self;
    [[ModService sharedService] scanModsForProfile:self.profileName completion:^(NSArray<ModItem *> *mods) {
        __strong typeof(wself) sself = wself;
        sself.mods = mods;
        [sself.tableView reloadData];
        for (ModItem *m in mods) {
            [[ModService sharedService] fetchMetadataForMod:m completion:^(ModItem *item, NSError * _Nullable error) {
                NSUInteger idx = [sself.mods indexOfObjectPassingTest:^BOOL(ModItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                    return [obj.filePath isEqualToString:item.filePath];
                }];
                if (idx != NSNotFound) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [sself.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:idx inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
                    });
                }
            }];
        }
    }];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.mods.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
    ModItem *m = self.mods[indexPath.row];
    cell.delegate = self;
    [cell configureWithMod:m];
    return cell;
}

#pragma mark - ModTableViewCellDelegate

- (void)modCellDidTapToggle:(UITableViewCell *)cell {
    NSIndexPath *ip = [self.tableView indexPathForCell:cell];
    if (!ip) return;
    ModItem *mod = self.mods[ip.row];
    NSString *title = mod.disabled ? @"启用 Mod" : @"禁用 Mod";
    NSString *message = mod.disabled ? @"确定启用此 Mod 吗？" : @"确定禁用此 Mod 吗？";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) wself = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(wself) sself = wself;
        NSError *err = nil;
        BOOL ok = [[ModService sharedService] toggleEnableForMod:mod error:&err];
        if (!ok) {
            UIAlertController *errAc = [UIAlertController alertControllerWithTitle:@"错误" message:err.localizedDescription ?: @"操作失败" preferredStyle:UIAlertControllerStyleAlert];
            [errAc addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [sself presentViewController:errAc animated:YES completion:nil];
        } else {
            [sself refreshList];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)modCellDidTapDelete:(UITableViewCell *)cell {
    NSIndexPath *ip = [self.tableView indexPathForCell:cell];
    if (!ip) return;
    ModItem *mod = self.mods[ip.row];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"删除 Mod" message:@"确认删除此 Mod 文件吗？此操作不可撤销。" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) wself = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(wself) sself = wself;
        NSError *err = nil;
        BOOL ok = [[ModService sharedService] deleteMod:mod error:&err];
        if (!ok) {
            UIAlertController *errAc = [UIAlertController alertControllerWithTitle:@"错误" message:err.localizedDescription ?: @"删除失败" preferredStyle:UIAlertControllerStyleAlert];
            [errAc addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [sself presentViewController:errAc animated:YES completion:nil];
        } else {
            [sself refreshList];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end