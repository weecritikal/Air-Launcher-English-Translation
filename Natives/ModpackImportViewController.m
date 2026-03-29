//
//  ModpackImportViewController.m
//  Amethyst
//
//  整合包导入功能实现 - 支持 .zip 和 .mrpack 格式
//

#import "ModpackImportViewController.h"
#import "ModpackImportService.h"
#import "PLProfiles.h"
#import "UnzipKit.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ModpackImportViewController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIButton *importButton;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *importedModpacks;
@property (nonatomic, strong) ModpackImportService *importService;
@property (nonatomic, strong) NSDictionary *currentImportingModpack;
@property (nonatomic, strong) UIVisualEffectView *backgroundBlurView;

@end

@implementation ModpackImportViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"导入整合包";
    
    // 设置毛玻璃背景
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    self.backgroundBlurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.backgroundBlurView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.backgroundBlurView];
    [NSLayoutConstraint activateConstraints:@[
        [self.backgroundBlurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.backgroundBlurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backgroundBlurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.backgroundBlurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    
    self.importService = [[ModpackImportService alloc] init];
    self.importedModpacks = [NSMutableArray array];
    
    [self setupUI];
    [self loadImportedModpacks];
}

- (void)setupUI {
    // 导入按钮
    self.importButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.importButton setTitle:@"选择整合包文件" forState:UIControlStateNormal];
    [self.importButton setImage:[UIImage systemImageNamed:@"doc.badge.plus"] forState:UIControlStateNormal];
    self.importButton.backgroundColor = [UIColor systemBlueColor];
    [self.importButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.importButton.layer.cornerRadius = 10;
    self.importButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.importButton addTarget:self action:@selector(selectModpackFile) forControlEvents:UIControlEventTouchUpInside];
    [self.backgroundBlurView.contentView addSubview:self.importButton];
    
    // 已导入整合包列表
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"ModpackCell"];
    self.tableView.rowHeight = 80;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.backgroundBlurView.contentView addSubview:self.tableView];
    
    // 加载指示器
    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.backgroundBlurView.contentView addSubview:self.activityIndicator];
    
    // 空列表提示
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.text = @"还没有导入的整合包\n点击上方按钮导入";
    self.emptyLabel.numberOfLines = 0;
    [self.backgroundBlurView.contentView addSubview:self.emptyLabel];
    
    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        [self.importButton.topAnchor constraintEqualToAnchor:self.backgroundBlurView.contentView.safeAreaLayoutGuide.topAnchor constant:16],
        [self.importButton.leadingAnchor constraintEqualToAnchor:self.backgroundBlurView.contentView.leadingAnchor constant:16],
        [self.importButton.trailingAnchor constraintEqualToAnchor:self.backgroundBlurView.contentView.trailingAnchor constant:-16],
        [self.importButton.heightAnchor constraintEqualToConstant:50],
        
        [self.tableView.topAnchor constraintEqualToAnchor:self.importButton.bottomAnchor constant:16],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.backgroundBlurView.contentView.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.backgroundBlurView.contentView.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.backgroundBlurView.contentView.safeAreaLayoutGuide.bottomAnchor],
        
        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.backgroundBlurView.contentView.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.backgroundBlurView.contentView.centerYAnchor],
        
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.backgroundBlurView.contentView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.backgroundBlurView.contentView.centerYAnchor]
    ]];
}

- (void)loadImportedModpacks {
    NSArray *modpacks = [self.importService getImportedModpacks];
    [self.importedModpacks removeAllObjects];
    [self.importedModpacks addObjectsFromArray:modpacks];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.emptyLabel.hidden = self.importedModpacks.count > 0;
        [self.tableView reloadData];
    });
}

#pragma mark - 文件选择

- (void)selectModpackFile {
    NSArray<UTType *> *contentTypes = @[
        [UTType typeWithFilenameExtension:@"mrpack"],
        [UTType typeWithFilenameExtension:@"zip"]
    ];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *fileURL = urls.firstObject;
    NSString *fileExtension = fileURL.pathExtension.lowercaseString;
    if (![fileExtension isEqualToString:@"mrpack"] && ![fileExtension isEqualToString:@"zip"]) {
        [self showAlertWithTitle:@"无效的文件" message:@"请选择 .mrpack 或 .zip 文件"];
        return;
    }
    BOOL accessGranted = [fileURL startAccessingSecurityScopedResource];
    if (!accessGranted) {
        [self showAlertWithTitle:@"访问被拒绝" message:@"无法访问选中的文件"];
        return;
    }
    [self.activityIndicator startAnimating];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        NSDictionary *modpackInfo = [self.importService parseModpackAtURL:fileURL error:&error];
        [fileURL stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            if (error) {
                [self showAlertWithTitle:@"解析失败" message:error.localizedDescription];
                return;
            }
            if (modpackInfo) {
                self.currentImportingModpack = modpackInfo;
                [self showModpackImportConfirmation:modpackInfo];
            } else {
                [self showAlertWithTitle:@"解析失败" message:@"无法解析整合包文件"];
            }
        });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {}

#pragma mark - 导入确认

- (void)showModpackImportConfirmation:(NSDictionary *)modpackInfo {
    NSString *name = modpackInfo[@"name"] ?: @"未知";
    NSString *version = modpackInfo[@"version"] ?: @"未知";
    NSString *mcVersion = modpackInfo[@"minecraftVersion"] ?: @"未知";
    NSString *loader = modpackInfo[@"loader"] ?: @"未知";
    NSString *loaderVersion = modpackInfo[@"loaderVersion"] ?: @"";
    NSString *message = [NSString stringWithFormat:@"名称: %@\n版本: %@\nMinecraft: %@\n加载器: %@ %@\n\n是否导入此整合包？", name, version, mcVersion, loader, loaderVersion];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入整合包" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        self.currentImportingModpack = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startModpackImport:modpackInfo];
    }]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)startModpackImport:(NSDictionary *)modpackInfo {
    [self.activityIndicator startAnimating];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        BOOL success = [self.importService importModpack:modpackInfo error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            self.currentImportingModpack = nil;
            if (success) {
                [self showAlertWithTitle:@"导入成功" message:[NSString stringWithFormat:@"整合包 '%@' 已成功导入。", modpackInfo[@"name"]] completion:^{
                    [self loadImportedModpacks];
                }];
            } else {
                NSString *errorMsg = error ? error.localizedDescription : @"未知错误";
                [self showAlertWithTitle:@"导入失败" message:errorMsg];
            }
        });
    });
}

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.importedModpacks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackCell" forIndexPath:indexPath];
    NSDictionary *modpack = self.importedModpacks[indexPath.row];
    NSString *name = modpack[@"name"] ?: @"未知";
    NSString *mcVersion = modpack[@"minecraftVersion"] ?: @"未知";
    NSString *loader = modpack[@"loader"] ?: @"未知";
    cell.textLabel.text = name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Minecraft %@ - %@", mcVersion, loader];
    cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = [UIColor clearColor];
    // 添加卡片背景
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.layer.cornerRadius = 12;
    blurView.layer.masksToBounds = YES;
    [cell.contentView insertSubview:blurView atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
        [blurView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12],
        [blurView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12],
        [blurView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4]
    ]];
    cell.backgroundView = nil;
    return cell;
}

#pragma mark - UITableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *modpack = self.importedModpacks[indexPath.row];
    [self showModpackOptions:modpack];
}

- (void)showModpackOptions:(NSDictionary *)modpack {
    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:modpack[@"name"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"启动整合包" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self launchModpack:modpack];
    }]];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteModpack:modpack];
    }]];
    [actionSheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        actionSheet.popoverPresentationController.sourceView = self.view;
        actionSheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:actionSheet animated:YES completion:nil];
}

- (void)launchModpack:(NSDictionary *)modpack {
    NSString *profileName = modpack[@"profileName"];
    if (profileName && PLProfiles.current.profiles[profileName]) {
        PLProfiles.current.selectedProfileName = profileName;
        [self showAlertWithTitle:@"配置文件已选择" message:[NSString stringWithFormat:@"已切换到整合包配置文件: %@", profileName]];
    } else {
        [self showAlertWithTitle:@"错误" message:@"找不到整合包配置文件"];
    }
}

- (void)deleteModpack:(NSDictionary *)modpack {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认删除" message:[NSString stringWithFormat:@"删除整合包 '%@'？此操作无法撤销。", modpack[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self.activityIndicator startAnimating];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error = nil;
            BOOL success = [self.importService deleteModpack:modpack error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.activityIndicator stopAnimating];
                if (success) {
                    [self loadImportedModpacks];
                } else {
                    [self showAlertWithTitle:@"删除失败" message:error.localizedDescription];
                }
            });
        });
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

#pragma mark - 辅助方法

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    [self showAlertWithTitle:title message:message completion:nil];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message completion:(void (^ _Nullable)(void))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (completion) completion();
    }]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

@end