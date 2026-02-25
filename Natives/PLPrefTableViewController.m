#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "DBNumberedSlider.h"
#import "LauncherNavigationController.h"
#import "LauncherMenuViewController.h"
#import "LauncherPreferences.h"
#import "PLPrefTableViewController.h"
#import "PLCardSettingCell.h"
#import "UIKit+hook.h"

#import "ios_uikit_bridge.h"
#import "utils.h"
#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"

@interface PLPrefTableViewController()<UIContextMenuInteractionDelegate>{}
@property(nonatomic) UIMenu* currentMenu;
@property(nonatomic) UIBarButtonItem *helpBtn;
@property(nonatomic) UIView *cardHeaderView;

@end

@implementation PLPrefTableViewController

- (id)init {
    self = [super init];
    [self initViewCreation];
    // 从偏好设置加载布局模式
    _layoutMode = (PLSettingsLayoutMode)[[NSUserDefaults standardUserDefaults] integerForKey:@"settings_layout_mode"];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self setupTableView];
    [self setupLayoutSwitcher];
    
    if (self.prefSections) {
        self.prefSectionsVisibility = [[NSMutableArray<NSNumber *> alloc] initWithCapacity:self.prefSections.count];
        for (int i = 0; i < self.prefSections.count; i++) {
            [self.prefSectionsVisibility addObject:@(self.prefSectionsVisible)];
        }
    } else {
        // Display one singe section if prefSection is unspecified
        self.prefSectionsVisibility = (id)@[@YES];
    }
}

- (void)setupTableView {
    UITableViewStyle style = (self.layoutMode == PLSettingsLayoutModeCard) ? 
        UITableViewStylePlain : UITableViewStyleInsetGrouped;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:style];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    
    // 卡片式布局的特殊配置
    if (self.layoutMode == PLSettingsLayoutModeCard) {
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        self.tableView.backgroundColor = [UIColor systemBackgroundColor];
        self.tableView.contentInset = UIEdgeInsetsMake(8, 12, 12, 12);
        // 注册自定义卡片Cell
        [self.tableView registerClass:[PLCardSettingCell class] forCellReuseIdentifier:@"CardCell"];
    }
}

- (void)setupLayoutSwitcher {
    self.layoutSwitcher = [[UISegmentedControl alloc] initWithItems:@[@"列表", @"卡片"]];
    self.layoutSwitcher.selectedSegmentIndex = self.layoutMode;
    self.layoutSwitcher.translatesAutoresizingMaskIntoConstraints = NO;
    [self.layoutSwitcher addTarget:self action:@selector(layoutModeChanged:) forControlEvents:UIControlEventValueChanged];
    
    // 创建卡片头部视图
    self.cardHeaderView = [[UIView alloc] init];
    self.cardHeaderView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardHeaderView addSubview:self.layoutSwitcher];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.layoutSwitcher.topAnchor constraintEqualToAnchor:self.cardHeaderView.topAnchor constant:8],
        [self.layoutSwitcher.centerXAnchor constraintEqualToAnchor:self.cardHeaderView.centerXAnchor],
        [self.layoutSwitcher.bottomAnchor constraintEqualToAnchor:self.cardHeaderView.bottomAnchor constant:-8]
    ]];
}

- (void)layoutModeChanged:(UISegmentedControl *)sender {
    PLSettingsLayoutMode newMode = (PLSettingsLayoutMode)sender.selectedSegmentIndex;
    if (newMode != self.layoutMode) {
        [self switchToLayoutMode:newMode];
    }
}

- (void)switchToLayoutMode:(PLSettingsLayoutMode)mode {
    self.layoutMode = mode;
    [self saveLayoutPreference];
    
    // 重新创建tableView
    [self setupTableView];
    
    // 如果有卡片头部视图，设置为tableHeaderView
    if (mode == PLSettingsLayoutModeCard) {
        CGFloat headerWidth = self.view.bounds.size.width - 24;
        self.cardHeaderView.frame = CGRectMake(0, 0, headerWidth, 50);
        self.tableView.tableHeaderView = self.cardHeaderView;
    } else {
        self.tableView.tableHeaderView = nil;
    }
    
    [self.view addSubview:self.tableView];
    [self.tableView reloadData];
}

- (void)saveLayoutPreference {
    [[NSUserDefaults standardUserDefaults] setInteger:self.layoutMode forKey:@"settings_layout_mode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (UIBarButtonItem *)drawAccountButton {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 40, 40);
    button.layer.cornerRadius = 20;
    button.layer.masksToBounds = YES;
    button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    
    if (currentAuth && currentAuth.authData) {
        NSString *username = currentAuth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
        }
        [button setTitle:username ?: @"?" forState:UIControlStateNormal];
        
        // 加载头像
        NSString *avatarURL = currentAuth.authData[@"profilePicURL"];
        if (avatarURL) {
            avatarURL = [avatarURL stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:avatarURL]];
                if (imageData) {
                    UIImage *image = [UIImage imageWithData:imageData];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [button setImage:image forState:UIControlStateNormal];
                        [button setTitle:@"" forState:UIControlStateNormal];
                    });
                }
            });
        }
    } else {
        [button setImage:[UIImage systemImageNamed:@"person.circle"] forState:UIControlStateNormal];
        button.tintColor = [UIColor systemGrayColor];
    }
    
    [button addTarget:self action:@selector(selectAccount:) forControlEvents:UIControlEventTouchUpInside];
    return [[UIBarButtonItem alloc] initWithCustomView:button];
}

- (void)selectAccount:(UIButton *)sender {
    AccountListViewController *vc = [[AccountListViewController alloc] init];
    vc.whenItemSelected = ^void() {
        [self viewWillAppear:NO];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (UIBarButtonItem *)drawHelpButton {
    if (!self.helpBtn) {
        self.helpBtn = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"questionmark.circle"] style:UIBarButtonItemStyleDone target:self action:@selector(toggleDetailVisibility)];
    }
    return self.helpBtn;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Put navigation buttons back in place if we're first of the navigation controller
    if (self.hasDetail && self.navigationController) {
        self.navigationItem.rightBarButtonItems = @[[self drawAccountButton], [self drawHelpButton]];
    }
    
    // 卡片式布局时设置tableHeaderView
    if (self.layoutMode == PLSettingsLayoutModeCard && self.cardHeaderView) {
        CGFloat headerWidth = self.view.bounds.size.width - 24;
        self.cardHeaderView.frame = CGRectMake(0, 0, headerWidth, 50);
        self.tableView.tableHeaderView = self.cardHeaderView;
    }

    // Scan for child pane cells and reload them
    // FIXME: any cheaper operations?
    NSMutableArray *indexPaths = [[NSMutableArray alloc] init];
    for (int section = 0; section < self.prefContents.count; section++) {
        if (!self.prefSectionsVisibility[section].boolValue) {
            continue;
        }
        for (int row = 0; row < self.prefContents[section].count; row++) {
            if (self.prefContents[section][row][@"type"] == self.typeChildPane) {
                [indexPaths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
            }
        }
    }
    [self.tableView reloadRowsAtIndexPaths:indexPaths withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark UITableView

- (void)toggleDetailVisibility {
    self.prefDetailVisible = !self.prefDetailVisible;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.prefSectionsVisibility.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.prefSectionsVisibility[section].boolValue) {
        NSInteger count = self.prefContents[section].count;
        // 卡片式布局不显示section标题行
        if (self.layoutMode == PLSettingsLayoutModeCard && self.prefSections) {
            count = count; // 保持原样，卡片模式下第一行也是设置项
        }
        return count;
    }
    return 1;
}

- (UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    
    // 卡片式布局
    if (self.layoutMode == PLSettingsLayoutModeCard) {
        return [self cardCellForRowAtIndexPath:indexPath item:item];
    }

    NSString *cellID;
    UITableViewCellStyle cellStyle;
    if (item[@"type"] == self.typeChildPane || item[@"type"] == self.typePickField) {
        cellID = @"cellValue1";
        cellStyle = UITableViewCellStyleValue1;
    } else {
        cellID = @"cellSubtitle";
        cellStyle = UITableViewCellStyleSubtitle;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:cellStyle reuseIdentifier:cellID];
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    }
    // Reset cell properties, as it could be reused
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.textColor = nil;
    cell.detailTextLabel.text = nil;

    NSString *key = item[@"key"];
    if (indexPath.row == 0 && self.prefSections) {
        key = self.prefSections[indexPath.section];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.text = localize(([NSString stringWithFormat:@"preference.section.%@", key]), nil);
    } else {
        CreateView createView = item[@"type"];
        createView(cell, self.prefSections[indexPath.section], key, item);
        if (cell.accessoryView) {
            objc_setAssociatedObject(cell.accessoryView, @"section", self.prefSections[indexPath.section], OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(cell.accessoryView, @"key", key, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(cell.accessoryView, @"item", item, OBJC_ASSOCIATION_ASSIGN);
        }
        cell.textLabel.text = localize((item[@"title"] ? item[@"title"] :
            [NSString stringWithFormat:@"preference.title.%@", key]), nil);
    }

    // Set general properties
    BOOL destructive = [item[@"destructive"] boolValue];
    cell.imageView.tintColor = destructive ? UIColor.systemRedColor : nil;
    cell.imageView.image = [UIImage systemImageNamed:item[@"icon"]];
    
    if (cellStyle != UITableViewCellStyleValue1) {
        cell.detailTextLabel.text = nil;
        if ([item[@"hasDetail"] boolValue] && self.prefDetailVisible) {
            cell.detailTextLabel.text = localize(([NSString stringWithFormat:@"preference.detail.%@", key]), nil);
        }
    }

    // Check if one has enable condition and call if it does
    BOOL(^checkEnable)(void) = item[@"enableCondition"];
    cell.userInteractionEnabled = !checkEnable || checkEnable();
    cell.textLabel.enabled = cell.detailTextLabel.enabled = cell.userInteractionEnabled;
    [(id)cell.accessoryView setEnabled:cell.userInteractionEnabled];

    return cell;
}

// 卡片式布局的Cell配置
- (PLCardSettingCell *)cardCellForRowAtIndexPath:(NSIndexPath *)indexPath item:(NSDictionary *)item {
    PLCardSettingCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"CardCell"];
    if (!cell) {
        cell = [[PLCardSettingCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"CardCell"];
    }
    
    NSString *key = item[@"key"];
    NSString *section = self.prefSections[indexPath.section];
    
    // 设置标题和图标
    NSString *title = localize((item[@"title"] ? item[@"title"] :
        [NSString stringWithFormat:@"preference.title.%@", key]), nil);
    
    NSString *subtitle = nil;
    if ([item[@"hasDetail"] boolValue] && self.prefDetailVisible) {
        subtitle = localize(([NSString stringWithFormat:@"preference.detail.%@", key]), nil);
    }
    
    BOOL destructive = [item[@"destructive"] boolValue];
    [cell configureWithTitle:title subtitle:subtitle icon:item[@"icon"] detail:nil destructive:destructive];
    
    // 计算卡片位置
    NSInteger rowCount = self.prefContents[indexPath.section].count;
    NSInteger position = 3; // single
    if (rowCount > 1) {
        if (indexPath.row == 0) position = 0; // top
        else if (indexPath.row == rowCount - 1) position = 2; // bottom
        else position = 1; // middle
    }
    [cell setCardPosition:position];
    
    // 配置附件视图
    if (item[@"type"] == self.typeSwitch) {
        UISwitch *sw = [[UISwitch alloc] init];
        NSArray *customSwitchValue = item[@"customSwitchValue"];
        if (customSwitchValue == nil) {
            [sw setOn:[self.getPreference(section, key) boolValue] animated:NO];
        } else {
            [sw setOn:[self.getPreference(section, key) isEqualToString:customSwitchValue[1]] animated:NO];
        }
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(sw, @"section", section, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(sw, @"key", key, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(sw, @"item", item, OBJC_ASSOCIATION_ASSIGN);
        [cell setAccessoryView:sw];
    } else if (item[@"type"] == self.typeSlider) {
        DBNumberedSlider *slider = [[DBNumberedSlider alloc] initWithFrame:CGRectMake(0, 0, 120, 30)];
        slider.minimumValue = [item[@"min"] intValue];
        slider.maximumValue = [item[@"max"] intValue];
        slider.value = [self.getPreference(section, key) intValue];
        slider.continuous = YES;
        [slider addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(slider, @"section", section, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(slider, @"key", key, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(slider, @"item", item, OBJC_ASSOCIATION_ASSIGN);
        [cell setAccessoryView:slider];
    } else if (item[@"type"] == self.typePickField || item[@"type"] == self.typeChildPane) {
        // 显示当前值
        id value = self.getPreference(section, key);
        NSString *detailText = nil;
        if ([value isKindOfClass:[NSString class]]) {
            detailText = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            detailText = [value boolValue] ? @"ON" : @"OFF";
        } else if (value) {
            detailText = [value description];
        }
        cell.detailLabel.text = detailText;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (item[@"type"] == self.typeTextField) {
        UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 120, 30)];
        textField.textAlignment = NSTextAlignmentRight;
        textField.text = self.getPreference(section, key);
        textField.delegate = self;
        textField.returnKeyType = UIReturnKeyDone;
        objc_setAssociatedObject(textField, @"section", section, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(textField, @"key", key, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(textField, @"item", item, OBJC_ASSOCIATION_ASSIGN);
        [cell setAccessoryView:textField];
    } else if (item[@"type"] == self.typeButton) {
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
    }
    
    // 检查启用条件
    BOOL(^checkEnable)(void) = item[@"enableCondition"];
    cell.userInteractionEnabled = !checkEnable || checkEnable();
    cell.contentView.alpha = cell.userInteractionEnabled ? 1.0 : 0.5;
    
    return cell;
}

#pragma mark initViewCreation, showAlert, checkWarn

- (void)initViewCreation {
    __weak PLPrefTableViewController *weakSelf = self;

    self.typeButton = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        BOOL destructive = [item[@"destructive"] boolValue];
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.textLabel.textColor = destructive ? UIColor.systemRedColor : weakSelf.view.tintColor;
    };

    self.typeChildPane = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        id value = weakSelf.getPreference(section, key);
        if ([value isKindOfClass:[NSString class]]) {
            cell.detailTextLabel.text = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            cell.detailTextLabel.text = [value boolValue] ? @"YES" : @"NO";
        } else {
            cell.detailTextLabel.text = [value description];
        }
    };

    self.typeTextField = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        Class cls = item[@"customClass"];
        if (!cls) cls = UITextField.class;
        UITextField *view = [[cls alloc] initWithFrame:CGRectMake(0, 0, cell.bounds.size.width / 2.1, cell.bounds.size.height)];
        [view addTarget:view action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
        view.adjustsFontSizeToFitWidth = YES;
        view.autocorrectionType = UITextAutocorrectionTypeNo;
        view.autocapitalizationType = UITextAutocapitalizationTypeNone;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
        //view.contentVerticalAlignment = UIControlContentVerticalAlignmentTop;
        view.delegate = weakSelf;
        //view.nonEditingLinebreakMode = NSLineBreakByCharWrapping;
        view.returnKeyType = UIReturnKeyDone;
        view.textAlignment = NSTextAlignmentRight;
        view.placeholder = localize((item[@"placeholder"] ? item[@"placeholder"] :
            [NSString stringWithFormat:@"preference.placeholder.%@", key]), nil);
        view.text = weakSelf.getPreference(section, key);
        cell.accessoryView = view;
    };

    self.typePickField = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        id value = weakSelf.getPreference(section, key);
        if ([value isKindOfClass:[NSString class]]) {
            cell.detailTextLabel.text = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            cell.detailTextLabel.text = [value boolValue] ? @"YES" : @"NO";
        } else {
            cell.detailTextLabel.text = [value description];
        }
    };

    self.typeSlider = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        DBNumberedSlider *view = [[DBNumberedSlider alloc] initWithFrame:CGRectMake(0, 0, cell.bounds.size.width / 2.1, cell.bounds.size.height)];
        [view addTarget:weakSelf action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
        view.minimumValue = [item[@"min"] intValue];
        view.maximumValue = [item[@"max"] intValue];
        view.continuous = YES;
        view.value = [weakSelf.getPreference(section, key) intValue];
        cell.accessoryView = view;
    };

    self.typeSwitch = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        UISwitch *view = [[UISwitch alloc] init];
        NSArray *customSwitchValue = item[@"customSwitchValue"];
        if (customSwitchValue == nil) {
            [view setOn:[weakSelf.getPreference(section, key) boolValue] animated:NO];
        } else {
            [view setOn:[weakSelf.getPreference(section, key) isEqualToString:customSwitchValue[1]] animated:NO];
        }
        [view addTarget:weakSelf action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = view;
    };
}

- (void)showAlertOnView:(UIView *)view title:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
    alert.popoverPresentationController.sourceView = view;
    alert.popoverPresentationController.sourceRect = view.bounds;
    UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:ok];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)checkWarn:(UIView *)view {
    NSDictionary *item = objc_getAssociatedObject(view, @"item");
    NSString *key = item[@"key"];

    BOOL(^isWarnable)(UIView *) = item[@"warnCondition"];
    NSString *warnKey = item[@"warnKey"];
    // Display warning if: warn condition is met and either one of these:
    // - does not have warnKey, always warn
    // - has warnKey and its value is YES, warn once and set it to NO
    if (isWarnable && isWarnable(view) && (!warnKey || [self.getPreference(@"warnings", warnKey) boolValue])) {
        if (warnKey) {
            self.setPreference(@"warnings", warnKey, @NO);
        }

        NSString *message = localize(([NSString stringWithFormat:@"preference.warn.%@", key]), nil);
        [self showAlertOnView:view title:localize(@"Warning", nil) message:message];
    }
}

#pragma mark Control event handlers

- (void)sliderMoved:(DBNumberedSlider *)sender {
    [self checkWarn:sender];
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = objc_getAssociatedObject(sender, @"key");

    sender.value = (int)sender.value;
    self.setPreference(section, key, @(sender.value));
}

- (void)switchChanged:(UISwitch *)sender {
    [self checkWarn:sender];
    NSDictionary *item = objc_getAssociatedObject(sender, @"item");
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = item[@"key"];

    // Special switches may define custom value instead of NO/YES
    NSArray *customSwitchValue = item[@"customSwitchValue"];
    self.setPreference(section, key, customSwitchValue ?
        customSwitchValue[sender.isOn] : @(sender.isOn));

    void(^invokeAction)(BOOL) = item[@"action"];
    if (invokeAction) {
        invokeAction(sender.isOn);
    }

    // Some settings may affect the availability of other settings
    // In this case, a switch may request to reload to apply user interaction change
    if ([item[@"requestReload"] boolValue]) {
        // TODO: only reload needed rows
        [self.tableView reloadData];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    
    // 卡片式布局没有section标题行，不需要处理折叠
    if (self.layoutMode == PLSettingsLayoutModeClassic) {
        if (indexPath.row == 0 && self.prefSections) {
            self.prefSectionsVisibility[indexPath.section] = @(![self.prefSectionsVisibility[indexPath.section] boolValue]);
            [tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationFade];
            return;
        }
    }

    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    if (item[@"type"] == self.typeButton) {
        [self tableView:tableView invokeActionWithPromptAtIndexPath:indexPath];
        return;
    } else if (item[@"type"] == self.typeChildPane) {
        [self tableView:tableView openChildPaneAtIndexPath:indexPath];
        return;
    } else if (item[@"type"] == self.typePickField) {
        [self tableView:tableView openPickerAtIndexPath:indexPath];
        return;
    } else if (realUIIdiom != UIUserInterfaceIdiomTV) {
        return;
    }

    // userInterfaceIdiom = tvOS
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (item[@"type"] == self.typeSwitch) {
        UISwitch *view = (id)cell.accessoryView;
        view.on = !view.isOn;
        [view sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

#pragma mark External UITableView functions

- (void)tableView:(UITableView *)tableView openChildPaneAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    UIViewController *vc = [item[@"class"] new];
    if ([item[@"canDismissWithSwipe"] boolValue]) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.navigationBar.prefersLargeTitles = YES;
        nav.modalInPresentation = YES;
        [self.navigationController presentViewController:nav animated:YES completion:nil];
    }
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location
{
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

- (_UIContextMenuStyle *)_contextMenuInteraction:(UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
{
    _UIContextMenuStyle *style = [_UIContextMenuStyle defaultStyle];
    style.preferredLayout = 3; // _UIContextMenuLayoutCompactMenu
    return style;
}

- (void)tableView:(UITableView *)tableView openPickerAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    NSString *message = nil;
    if ([item[@"hasDetail"] boolValue]) {
        message = localize(([NSString stringWithFormat:@"preference.detail.%@", item[@"key"]]), nil);
    }

    NSArray *pickKeys = item[@"pickKeys"];
    NSArray *pickList = item[@"pickList"];
    NSMutableArray<UIAction *> *menuItems = [[NSMutableArray alloc] init];
    for (int i = 0; i < pickList.count; i++) {
        [menuItems addObject:[UIAction
            actionWithTitle:pickList[i]
            image:nil identifier:nil
            handler:^(UIAction *action) {
                cell.detailTextLabel.text = pickKeys[i];
                self.setPreference(self.prefSections[indexPath.section], item[@"key"], pickKeys[i]);
                void(^invokeAction)(NSString *) = item[@"action"];
                if (invokeAction) {
                    invokeAction(pickKeys[i]);
                }
            }]];
        if ([cell.detailTextLabel.text isEqualToString:pickKeys[i]]) {
            menuItems.lastObject.state = UIMenuElementStateOn;
        }
    }

    self.currentMenu = [UIMenu menuWithTitle:message children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    cell.detailTextLabel.interactions = @[interaction];
    [interaction _presentMenuAtLocation:CGPointZero];
}

- (void)tableView:(UITableView *)tableView invokeActionWithPromptAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *view = [self.tableView cellForRowAtIndexPath:indexPath];
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    NSString *key = item[@"key"];

    if ([item[@"showConfirmPrompt"] boolValue]) {
        BOOL destructive = [item[@"destructive"] boolValue];
        NSString *title = localize(@"preference.title.confirm", nil);
        NSString *message = localize(([NSString stringWithFormat:@"preference.title.confirm.%@", key]), nil);
        UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
        confirmAlert.popoverPresentationController.sourceView = view;
        confirmAlert.popoverPresentationController.sourceRect = view.bounds;
        UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:destructive?UIAlertActionStyleDestructive:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self tableView:tableView invokeActionAtIndexPath:indexPath];
        }];
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
        [confirmAlert addAction:cancel];
        [confirmAlert addAction:ok];
        [self presentViewController:confirmAlert animated:YES completion:nil];
    } else {
        [self tableView:tableView invokeActionAtIndexPath:indexPath];
    }
}

- (void)tableView:(UITableView *)tableView invokeActionAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    NSString *key = item[@"key"];

    void(^invokeAction)(void) = item[@"action"];
    if (invokeAction) {
        invokeAction();
    }

    // 对于typeButton类型的操作，不显示done提示
    if (item[@"type"] != self.typeButton) {
        UIView *view = [self.tableView cellForRowAtIndexPath:indexPath];
        NSString *title = localize(([NSString stringWithFormat:@"preference.title.done.%@", key]), nil);
        [self showAlertOnView:view title:title message:nil];
    }
}

#pragma mark UITextField

- (void)textFieldDidEndEditing:(UITextField *)sender {
    [self checkWarn:sender];
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = objc_getAssociatedObject(sender, @"key");

    self.setPreference(section, key, sender.text);
}

@end

#pragma mark - Card Setting Cell

// 卡片式设置Cell - 参考ZalithLauncher2的卡片设计
@interface PLCardSettingCell : UITableViewCell
@property (nonatomic, strong) UIView *cardContainer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UIView *accessoryContainer;
@property (nonatomic, strong) UIView *topSeparator;
@property (nonatomic, strong) UIView *bottomSeparator;
@end

@implementation PLCardSettingCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        
        // 卡片容器
        _cardContainer = [[UIView alloc] init];
        _cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
        _cardContainer.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        _cardContainer.layer.cornerRadius = 14;
        _cardContainer.layer.masksToBounds = NO;
        // 添加阴影效果
        _cardContainer.layer.shadowColor = [UIColor blackColor].CGColor;
        _cardContainer.layer.shadowOffset = CGSizeMake(0, 1);
        _cardContainer.layer.shadowOpacity = 0.1;
        _cardContainer.layer.shadowRadius = 3;
        [self.contentView addSubview:_cardContainer];
        
        // 图标
        _iconView = [[UIImageView alloc] init];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.tintColor = [UIColor systemBlueColor];
        [_cardContainer addSubview:_iconView];
        
        // 标题
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.numberOfLines = 0;
        [_cardContainer addSubview:_titleLabel];
        
        // 副标题
        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subtitleLabel.font = [UIFont systemFontOfSize:12];
        _subtitleLabel.textColor = [UIColor secondaryLabelColor];
        _subtitleLabel.numberOfLines = 2;
        _subtitleLabel.hidden = YES;
        [_cardContainer addSubview:_subtitleLabel];
        
        // 详情标签（用于显示值）
        _detailLabel = [[UILabel alloc] init];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.font = [UIFont systemFontOfSize:14];
        _detailLabel.textColor = [UIColor secondaryLabelColor];
        _detailLabel.textAlignment = NSTextAlignmentRight;
        [_cardContainer addSubview:_detailLabel];
        
        // 附件容器
        _accessoryContainer = [[UIView alloc] init];
        _accessoryContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardContainer addSubview:_accessoryContainer];
        
        // 顶部分隔线（用于分组内的中间项）
        _topSeparator = [[UIView alloc] init];
        _topSeparator.translatesAutoresizingMaskIntoConstraints = NO;
        _topSeparator.backgroundColor = [UIColor separatorColor];
        _topSeparator.hidden = YES;
        [_cardContainer addSubview:_topSeparator];
        
        // 底部分隔线
        _bottomSeparator = [[UIView alloc] init];
        _bottomSeparator.translatesAutoresizingMaskIntoConstraints = NO;
        _bottomSeparator.backgroundColor = [UIColor separatorColor];
        _bottomSeparator.hidden = YES;
        [_cardContainer addSubview:_bottomSeparator];
        
        // 布局约束
        [NSLayoutConstraint activateConstraints:@[
            // 卡片容器
            [_cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [_cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
            
            // 图标
            [_iconView.leadingAnchor constraintEqualToAnchor:_cardContainer.leadingAnchor constant:16],
            [_iconView.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:28],
            [_iconView.heightAnchor constraintEqualToConstant:28],
            
            // 标题
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_titleLabel.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor constant:12],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_detailLabel.leadingAnchor constant:-8],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_accessoryContainer.leadingAnchor constant:-8],
            
            // 副标题
            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
            [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            
            // 详情标签
            [_detailLabel.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-16],
            [_detailLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
            [_detailLabel.widthAnchor constraintLessThanOrEqualToConstant:120],
            
            // 附件容器
            [_accessoryContainer.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-16],
            [_accessoryContainer.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
            [_accessoryContainer.widthAnchor constraintLessThanOrEqualToConstant:150],
            
            // 顶部分隔线
            [_topSeparator.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor],
            [_topSeparator.leadingAnchor constraintEqualToAnchor:_cardContainer.leadingAnchor constant:16],
            [_topSeparator.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor],
            [_topSeparator.heightAnchor constraintEqualToConstant:0.5],
            
            // 底部分隔线
            [_bottomSeparator.bottomAnchor constraintEqualToAnchor:_cardContainer.bottomAnchor],
            [_bottomSeparator.leadingAnchor constraintEqualToAnchor:_cardContainer.leadingAnchor constant:16],
            [_bottomSeparator.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor],
            [_bottomSeparator.heightAnchor constraintEqualToConstant:0.5],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.titleLabel.text = nil;
    self.subtitleLabel.text = nil;
    self.detailLabel.text = nil;
    self.iconView.image = nil;
    self.topSeparator.hidden = YES;
    self.bottomSeparator.hidden = YES;
    self.accessoryContainer.hidden = YES;
    for (UIView *view in self.accessoryContainer.subviews) {
        [view removeFromSuperview];
    }
}

- (void)configureWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(NSString *)iconName detail:(NSString *)detail destructive:(BOOL)destructive {
    self.titleLabel.text = title;
    self.titleLabel.textColor = destructive ? [UIColor systemRedColor] : [UIColor labelColor];
    
    if (subtitle.length > 0) {
        self.subtitleLabel.text = subtitle;
        self.subtitleLabel.hidden = NO;
    } else {
        self.subtitleLabel.hidden = YES;
    }
    
    if (iconName.length > 0) {
        UIImage *icon = [UIImage systemImageNamed:iconName];
        self.iconView.image = icon;
        self.iconView.tintColor = destructive ? [UIColor systemRedColor] : [UIColor systemBlueColor];
        self.iconView.hidden = NO;
    } else {
        self.iconView.hidden = YES;
    }
    
    if (detail.length > 0) {
        self.detailLabel.text = detail;
        self.detailLabel.hidden = NO;
    } else {
        self.detailLabel.hidden = YES;
    }
}

- (void)setAccessoryView:(UIView *)view {
    for (UIView *subview in self.accessoryContainer.subviews) {
        [subview removeFromSuperview];
    }
    if (view) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.accessoryContainer addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:self.accessoryContainer.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:self.accessoryContainer.bottomAnchor],
            [view.leadingAnchor constraintEqualToAnchor:self.accessoryContainer.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:self.accessoryContainer.trailingAnchor]
        ]];
        self.accessoryContainer.hidden = NO;
    } else {
        self.accessoryContainer.hidden = YES;
    }
}

- (void)setCardPosition:(NSInteger)position {
    // position: 0=top, 1=middle, 2=bottom, 3=single
    switch (position) {
        case 0: // Top
            self.cardContainer.layer.cornerRadius = 14;
            self.cardContainer.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
            self.bottomSeparator.hidden = NO;
            break;
        case 1: // Middle
            self.cardContainer.layer.cornerRadius = 0;
            self.topSeparator.hidden = NO;
            self.bottomSeparator.hidden = NO;
            break;
        case 2: // Bottom
            self.cardContainer.layer.cornerRadius = 14;
            self.cardContainer.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
            self.topSeparator.hidden = NO;
            break;
        default: // Single
            self.cardContainer.layer.cornerRadius = 14;
            self.cardContainer.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
            break;
    }
}

@end
