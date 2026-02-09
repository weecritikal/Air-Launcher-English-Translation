//
//  TouchControllerPreferencesViewController.m
//  Angel Aura Amethyst
//
//  TouchController 设置页面实现
//

#import "TouchControllerPreferencesViewController.h"
#import "LauncherPreferences.h"
#import "PLPreferences.h"
#import "config.h"
#import "utils.h"

// 定义通信方式枚举
typedef NS_ENUM(NSInteger, TouchControllerCommMode) {
    TouchControllerCommModeDisabled = 0,
    TouchControllerCommModeUDP = 1,
    TouchControllerCommModeStaticLib = 2
};

@interface TouchControllerPreferencesViewController ()

@end

@implementation TouchControllerPreferencesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"TouchController", @"preference.touchcontroller.title");
    
    // 配置设置内容
    self.prefContents = @[
        @[
            @{@"icon": @"gamecontroller"},
            @{@"key": @"mod_touch_mode",
              @"icon": @"antenna.radiowaves.left.and.right",
              @"hasDetail": @YES,
              @"type": self.typeChildPane,
              @"canDismissWithSwipe": @NO
            },
            @{@"key": @"mod_touch_about",
              @"icon": @"info.circle",
              @"type": self.typeButton,
              @"canDismissWithSwipe": @NO,
              @"action": ^void(){
                  [self showInfoAlert];
              }
            }
        ]
    ];
}

- (void)initViewCreation {
    __weak typeof(self) weakSelf = self;
    
    // 通信方式选择
    self.typeChildPane = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        NSInteger mode = [weakSelf.getPreference(section, key) integerValue];
        switch (mode) {
            case TouchControllerCommModeUDP:
                cell.detailTextLabel.text = localize(@"UDP Protocol", @"preference.touchcontroller.mode.udp");
                break;
            case TouchControllerCommModeStaticLib:
                cell.detailTextLabel.text = localize(@"Static Library", @"preference.touchcontroller.mode.staticlib");
                break;
            default:
                cell.detailTextLabel.text = localize(@"Disabled", @"preference.touchcontroller.mode.disabled");
                break;
        }
    };
    
    // 按钮类型
    self.typeButton = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.textLabel.textColor = weakSelf.view.tintColor;
    };
}

- (void)updateTouchControllerSetting:(TouchControllerCommMode)mode {
    switch (mode) {
        case TouchControllerCommModeDisabled:
            // 禁用 TouchController
            self.setPreference(@"control", @"mod_touch_enable", @NO);
            self.setPreference(@"control", @"mod_touch_mode", @0);
            [self removeUDPEnvironmentVariable];
            NSLog(@"[TouchController] Disabled");
            break;

        case TouchControllerCommModeUDP:
            // 启用 UDP 模式
            self.setPreference(@"control", @"mod_touch_enable", @YES);
            self.setPreference(@"control", @"mod_touch_mode", @1);
            [self setUDPEnvironmentVariable];
            NSLog(@"[TouchController] Enabled with UDP mode");
            break;

        case TouchControllerCommModeStaticLib:
            // 启用静态库模式
            self.setPreference(@"control", @"mod_touch_enable", @YES);
            self.setPreference(@"control", @"mod_touch_mode", @2);
            [self removeUDPEnvironmentVariable];
            NSLog(@"[TouchController] Enabled with Static Library mode");
            break;
    }
}

- (void)setUDPEnvironmentVariable {
    NSString *currentEnv = getPrefObject(@"java.env_variables");
    if ([currentEnv isKindOfClass:[NSString class]]) {
        if (![currentEnv containsString:@"TOUCH_CONTROLLER_PROXY=12450"]) {
            NSString *newEnv = [currentEnv stringByAppendingString:@" TOUCH_CONTROLLER_PROXY=12450"];
            setPrefObject(@"java.env_variables", newEnv);
        }
    } else {
        setPrefObject(@"java.env_variables", @"TOUCH_CONTROLLER_PROXY=12450");
    }
}

- (void)removeUDPEnvironmentVariable {
    NSString *currentEnv = getPrefObject(@"java.env_variables");
    if ([currentEnv isKindOfClass:[NSString class]]) {
        NSString *newEnv = [currentEnv stringByReplacingOccurrencesOfString:@" TOUCH_CONTROLLER_PROXY=12450" withString:@""];
        setPrefObject(@"java.env_variables", newEnv);
    }
}

- (void)showModeSelectionAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"Select Communication Mode", @"preference.touchcontroller.select_mode.title")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 获取当前模式
    NSInteger currentMode = [self.getPreference(@"control", @"mod_touch_mode") integerValue];
    if (currentMode == 0) currentMode = TouchControllerCommModeDisabled;
    if (![self.getPreference(@"control", @"mod_touch_enable") boolValue]) currentMode = TouchControllerCommModeDisabled;

    // 禁用选项
    UIAlertAction *disableAction = [UIAlertAction actionWithTitle:localize(@"Disabled", @"preference.touchcontroller.mode.disabled")
                                                             style:UIAlertActionStyleDestructive
                                                           handler:^(UIAlertAction * _Nonnull action) {
        [self updateTouchControllerSetting:TouchControllerCommModeDisabled];
        [self.tableView reloadData];
    }];
    if (currentMode == TouchControllerCommModeDisabled) {
        [disableAction setValue:@(YES) forKey:@"checked"];
    }
    [alert addAction:disableAction];

    // UDP 模式选项
    UIAlertAction *udpAction = [UIAlertAction actionWithTitle:localize(@"UDP Protocol", @"preference.touchcontroller.mode.udp")
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
        [self updateTouchControllerSetting:TouchControllerCommModeUDP];
        [self.tableView reloadData];
        [self showModeDescriptionAlert:TouchControllerCommModeUDP];
    }];
    if (currentMode == TouchControllerCommModeUDP) {
        [udpAction setValue:@(YES) forKey:@"checked"];
    }
    [alert addAction:udpAction];

    // 静态库模式选项
    UIAlertAction *staticLibAction = [UIAlertAction actionWithTitle:localize(@"Static Library", @"preference.touchcontroller.mode.staticlib")
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(UIAlertAction * _Nonnull action) {
        [self updateTouchControllerSetting:TouchControllerCommModeStaticLib];
        [self.tableView reloadData];
        [self showModeDescriptionAlert:TouchControllerCommModeStaticLib];
    }];
    if (currentMode == TouchControllerCommModeStaticLib) {
        [staticLibAction setValue:@(YES) forKey:@"checked"];
    }
    [alert addAction:staticLibAction];

    // 取消按钮
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", @"preference.touchcontroller.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // iPad 支持
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showModeDescriptionAlert:(TouchControllerCommMode)mode {
    NSString *title, *message;

    switch (mode) {
        case TouchControllerCommModeUDP:
            title = localize(@"UDP Protocol Mode", @"preference.touchcontroller.udp.title");
            message = localize(@"TouchController will communicate via UDP port 12450. This mode is compatible with most servers and provides stable network communication.", @"preference.touchcontroller.udp.message");
            break;

        case TouchControllerCommModeStaticLib:
            title = localize(@"Static Library Mode", @"preference.touchcontroller.staticlib.title");
            message = localize(@"TouchController will use native static library for high-performance local communication via Unix Domain Socket. This mode provides better performance but requires the static library to be linked.", @"preference.touchcontroller.staticlib.message");
            break;

        default:
            return;
    }

    UIAlertController *infoAlert = [UIAlertController alertControllerWithTitle:title
                                                                         message:message
                                                                  preferredStyle:UIAlertControllerStyleAlert];

    [infoAlert addAction:[UIAlertAction actionWithTitle:localize(@"OK", @"preference.touchcontroller.ok")
                                                   style:UIAlertActionStyleDefault
                                                 handler:nil]];

    [self presentViewController:infoAlert animated:YES completion:nil];
}

- (void)showInfoAlert {
    UIAlertController *infoAlert = [UIAlertController alertControllerWithTitle:localize(@"About TouchController", @"preference.touchcontroller.about.title")
                                                                         message:localize(@"TouchController is a Minecraft mod that adds touch controls to Java Edition. This launcher supports two communication modes:\n\n• UDP Protocol: Network-based communication\n• Static Library: High-performance local communication\n\nVisit GitHub for more information.", @"preference.touchcontroller.about.message")
                                                                  preferredStyle:UIAlertControllerStyleAlert];

    [infoAlert addAction:[UIAlertAction actionWithTitle:localize(@"OK", @"preference.touchcontroller.ok")
                                                   style:UIAlertActionStyleDefault
                                                 handler:nil]];

    [infoAlert addAction:[UIAlertAction actionWithTitle:@"GitHub"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * _Nonnull action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/TouchController/TouchController"]
                                            options:@{}
                                  completionHandler:nil];
    }]];

    [self presentViewController:infoAlert animated:YES completion:nil];
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *key = self.prefContents[indexPath.section][indexPath.row][@"key"];
    if ([key isEqualToString:@"mod_touch_mode"]) {
        [self showModeSelectionAlert];
    } else if ([key isEqualToString:@"mod_touch_about"]) {
        [self showInfoAlert];
    }
}

@end