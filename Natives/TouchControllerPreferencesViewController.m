//
//  TouchControllerPreferencesViewController.m
//  Angel Aura Amethyst
//
//  TouchController settings page implementation
//

#import "TouchControllerPreferencesViewController.h"
#import "LauncherPreferences.h"
#import "PLPreferences.h"
#import "BackgroundManager.h"
#import "config.h"
#import "utils.h"

// Define the communication method enum
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
    self.title = localize(@"preference.touchcontroller.title", nil);

    // Add the close button
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];

    // Adapt to the custom launcher background: make this view controller transparent so the global background (image/video) shows through.
    // Although the superclass PLPrefTableViewController's viewDidLoad already calls makeViewControllerTransparent,
    // it is called again here to make sure this subclass's background setting is still correct after all initialization completes.
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // Listen for background UI effect changes: when the user switches between frosted glass and translucent, or adjusts the opacity,
    // call makeViewControllerTransparent again to apply the latest look and keep the background showing correctly.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)initViewCreation {
    __weak typeof(self) weakSelf = self;

    // Make sure every option is visible
    self.prefSectionsVisible = YES;

    // Set the preference getter and setter blocks
    self.getPreference = ^id(NSString *section, NSString *key){
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        return getPrefObject(keyFull);
    };
    self.setPreference = ^(NSString *section, NSString *key, id value){
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        setPrefObject(keyFull, value);
    };

    // Call the superclass initializer
    [super initViewCreation];

    // Communication method selection
    self.typeChildPane = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.textLabel.text = item[@"title"];
        NSInteger mode = [weakSelf.getPreference(section, key) integerValue];
        switch (mode) {
            case TouchControllerCommModeUDP:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.mode.udp", nil) ?: @"UDP Protocol";
                break;
            case TouchControllerCommModeStaticLib:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.mode.staticlib", nil) ?: @"Static Library";
                break;
            default:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.mode.disabled", nil) ?: @"Disabled";
                break;
        }
    };

    // Button type
    self.typeButton = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.textLabel.text = item[@"title"];
        cell.textLabel.textColor = weakSelf.view.tintColor;
    };

    // Slider type (vibration strength)
    self.typeSlider = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = item[@"title"];

        // Create the slider
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
        NSInteger value = [weakSelf.getPreference(section, key) integerValue];
        if (value < 1) value = 1;
        if (value > 3) value = 3;
        slider.value = value;
        slider.minimumValue = [item[@"min"] floatValue];
        slider.maximumValue = [item[@"max"] floatValue];
        slider.continuous = YES;

        // Set the detail text
        switch (value) {
            case 1:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.light", nil) ?: @"Light";
                break;
            case 2:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.medium", nil) ?: @"Medium";
                break;
            case 3:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.heavy", nil) ?: @"Heavy";
                break;
            default:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.medium", nil) ?: @"Medium";
                break;
        }

        // Slider change handling
        [slider addTarget:weakSelf action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];

        // Add the slider to the accessory view
        cell.accessoryView = slider;
    };

    // Switch type
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

    // Set up the preferences section
    self.prefSections = @[@"control"];

    // Configure the settings content
    self.prefContents = @[
        @[
            @{@"key": @"mod_touch_mode",
              @"icon": @"antenna.radiowaves.left.and.right",
              @"hasDetail": @YES,
              @"type": self.typeChildPane,
              @"canDismissWithSwipe": @NO,
              @"title": localize(@"preference.touchcontroller.mode.title", nil) ?: @"Communication Mode"
            },
            @{@"key": @"mod_touch_vibrate_enable",
              @"icon": @"waveform.path",
              @"type": self.typeSwitch,
              @"canDismissWithSwipe": @NO,
              @"title": localize(@"preference.touchcontroller.vibrate.enable", nil) ?: @"Enable Vibration"
            },
            @{@"key": @"mod_touch_vibrate_intensity",
              @"icon": @"speaker.wave.2",
              @"type": self.typeSlider,
              @"hasDetail": @YES,
              @"canDismissWithSwipe": @NO,
              @"min": @1,
              @"max": @3,
              @"step": @1,
              @"title": localize(@"preference.touchcontroller.vibrate.intensity", nil) ?: @"Vibration Intensity"
            },
            @{@"key": @"mod_touch_moveview_enable",
              @"icon": @"arrow.triangle.2.circlepath",
              @"type": self.typeSwitch,
              @"canDismissWithSwipe": @NO,
              @"title": localize(@"preference.touchcontroller.moveview.enable", nil) ?: @"Enable Move View"
            },
            @{@"key": @"mod_touch_about",
              @"icon": @"info.circle",
              @"type": self.typeButton,
              @"canDismissWithSwipe": @NO,
              @"action": ^void(){
                  [weakSelf showInfoAlert];
              },
              @"title": localize(@"preference.touchcontroller.about", nil) ?: @"About TouchController"
            }
        ]
    ];
}

// Slider value change handling
- (void)sliderValueChanged:(UISlider *)slider {
    NSInteger value = (NSInteger)round(slider.value);
    self.setPreference(@"control", @"mod_touch_vibrate_intensity", @(value));

    // Update the detail text
    UITableViewCell *cell = (UITableViewCell *)slider.superview;
    while (cell && ![cell isKindOfClass:[UITableViewCell class]]) {
        cell = (UITableViewCell *)cell.superview;
    }

    if (cell) {
        switch (value) {
            case 1:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.light", nil) ?: @"Light";
                break;
            case 2:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.medium", nil) ?: @"Medium";
                break;
            case 3:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.heavy", nil) ?: @"Heavy";
                break;
            default:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.medium", nil) ?: @"Medium";
                break;
        }
    }
}

- (void)updateTouchControllerSetting:(TouchControllerCommMode)mode {
    switch (mode) {
        case TouchControllerCommModeDisabled:
            // Disable TouchController
            self.setPreference(@"control", @"mod_touch_enable", @NO);
            self.setPreference(@"control", @"mod_touch_mode", @0);
            [self removeUDPEnvironmentVariable];
            NSLog(@"[TouchController] Disabled");
            break;

        case TouchControllerCommModeUDP:
            // Enable UDP mode
            self.setPreference(@"control", @"mod_touch_enable", @YES);
            self.setPreference(@"control", @"mod_touch_mode", @1);
            [self setUDPEnvironmentVariable];
            NSLog(@"[TouchController] Enabled with UDP mode");
            break;

        case TouchControllerCommModeStaticLib:
            // Enable static library mode
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"preference.touchcontroller.select_mode.title", nil) ?: @"Select Communication Mode"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // Get the current mode
    NSInteger currentMode = [self.getPreference(@"control", @"mod_touch_mode") integerValue];
    if (currentMode == 0) currentMode = TouchControllerCommModeDisabled;
    if (![self.getPreference(@"control", @"mod_touch_enable") boolValue]) currentMode = TouchControllerCommModeDisabled;

    // Disabled option
    UIAlertAction *disableAction = [UIAlertAction actionWithTitle:localize(@"preference.touchcontroller.mode.disabled", nil) ?: @"Disabled"
                                                             style:UIAlertActionStyleDestructive
                                                           handler:^(UIAlertAction * _Nonnull action) {
        [self updateTouchControllerSetting:TouchControllerCommModeDisabled];
        [self.tableView reloadData];
    }];
    if (currentMode == TouchControllerCommModeDisabled) {
        [disableAction setValue:@(YES) forKey:@"checked"];
    }
    [alert addAction:disableAction];

    // UDP mode option
    UIAlertAction *udpAction = [UIAlertAction actionWithTitle:localize(@"preference.touchcontroller.mode.udp", nil) ?: @"UDP Protocol"
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

    // Static library mode option
    UIAlertAction *staticLibAction = [UIAlertAction actionWithTitle:localize(@"preference.touchcontroller.mode.staticlib", nil) ?: @"Static Library"
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

    // Cancel button
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"preference.touchcontroller.cancel", nil) ?: @"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // iPad support
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
            title = localize(@"preference.touchcontroller.udp.title", nil) ?: @"UDP Protocol Mode";
            message = localize(@"preference.touchcontroller.udp.message", nil) ?: @"TouchController will communicate via UDP port 12450. This mode is compatible with most servers and provides stable network communication.";
            break;

        case TouchControllerCommModeStaticLib:
            title = localize(@"preference.touchcontroller.staticlib.title", nil) ?: @"Static Library Mode";
            message = localize(@"preference.touchcontroller.staticlib.message", nil) ?: @"TouchController will use native static library for high-performance local communication via Unix Domain Socket. This mode provides better performance but requires the static library to be linked.";
            break;

        default:
            return;
    }

    UIAlertController *infoAlert = [UIAlertController alertControllerWithTitle:title
                                                                         message:message
                                                                  preferredStyle:UIAlertControllerStyleAlert];

    [infoAlert addAction:[UIAlertAction actionWithTitle:localize(@"preference.touchcontroller.ok", nil) ?: @"OK"
                                                   style:UIAlertActionStyleDefault
                                                 handler:nil]];

    [self presentViewController:infoAlert animated:YES completion:nil];
}

- (void)showInfoAlert {
    UIAlertController *infoAlert = [UIAlertController alertControllerWithTitle:localize(@"preference.touchcontroller.about.title", nil) ?: @"About TouchController"
                                                                         message:localize(@"preference.touchcontroller.about.message", nil) ?: @"TouchController is a Minecraft mod that adds touch controls to Java Edition. This launcher supports two communication modes:\n\n• UDP Protocol: Network-based communication\n• Static Library: High-performance local communication\n\nVisit GitHub for more information."
                                                                  preferredStyle:UIAlertControllerStyleAlert];

    [infoAlert addAction:[UIAlertAction actionWithTitle:localize(@"preference.touchcontroller.ok", nil) ?: @"OK"
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

#pragma mark - Close Button Action

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

/// Re-apply the background effect: called when the BackgroundUIEffectChanged notification arrives.
/// Re-applies the opacity/frosted-glass effect to this view controller via BackgroundManager,
/// and clears the tableView background and backgroundView manually so the global background shows through.
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end