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
}

- (void)updateTouchControllerSetting:(TouchControllerCommMode)mode {
    switch (mode) {
        case TouchControllerCommModeDisabled:
            // 禁用 TouchController
            setPrefObject(@"control.mod_touch_enable", @NO);
            setPrefObject(@"control.mod_touch_mode", @0);
            [self removeUDPEnvironmentVariable];
            NSLog(@"[TouchController] Disabled");
            break;

        case TouchControllerCommModeUDP:
            // 启用 UDP 模式
            setPrefObject(@"control.mod_touch_enable", @YES);
            setPrefObject(@"control.mod_touch_mode", @1);
            [self setUDPEnvironmentVariable];
            NSLog(@"[TouchController] Enabled with UDP mode");
            break;

        case TouchControllerCommModeStaticLib:
            // 启用静态库模式
            setPrefObject(@"control.mod_touch_enable", @YES);
            setPrefObject(@"control.mod_touch_mode", @2);
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

- (NSString *)getCurrentModeTitle {
    NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
    switch (mode) {
        case TouchControllerCommModeUDP:
            return localize(@"UDP Protocol", @"preference.touchcontroller.mode.udp");
        case TouchControllerCommModeStaticLib:
            return localize(@"Static Library", @"preference.touchcontroller.mode.staticlib");
        default:
            return localize(@"Disabled", @"preference.touchcontroller.mode.disabled");
    }
}

- (void)showModeSelectionAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"Select Communication Mode", @"preference.touchcontroller.select_mode.title")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 获取当前模式
    NSInteger currentMode = [getPrefObject(@"control.mod_touch_mode") integerValue];
    if (currentMode == 0) currentMode = TouchControllerCommModeDisabled;
    if (![getPrefObject(@"control.mod_touch_enable") boolValue]) currentMode = TouchControllerCommModeDisabled;

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
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
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

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return localize(@"Communication Mode", @"preference.touchcontroller.section.mode");
        case 1:
            return localize(@"Information", @"preference.touchcontroller.section.info");
        default:
            return @"";
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return 1;
        case 1:
            return 1;
        default:
            return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];

    if (indexPath.section == 0) {
        // 通信方式选择
        cell.textLabel.text = localize(@"Communication Mode", @"preference.touchcontroller.mode.title");
        cell.detailTextLabel.text = [self getCurrentModeTitle];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        // 信息
        cell.textLabel.text = localize(@"About TouchController", @"preference.touchcontroller.about");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    return cell;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0 && indexPath.row == 0) {
        [self showModeSelectionAlert];
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        [self showInfoAlert];
    }
}

@end