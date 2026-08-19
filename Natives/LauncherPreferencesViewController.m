#import <Foundation/Foundation.h>

#import "DBNumberedSlider.h"
#import "HostManagerBridge.h"
#import "LauncherNavigationController.h"
#import "LauncherMenuViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherPrefContCfgViewController.h"
#import "LauncherPrefManageJREViewController.h"
#import "UIKit+hook.h"

#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#import "ImageCropperViewController.h"
#import "CustomIconManager.h"
#import "BackgroundSettingsViewController.h"
#import "BackgroundManager.h"
#import "UpdateChecker.h"
#import "CurseForgeAPIKeyViewController.h"
#import "CustomControlsViewController.h"

@interface LauncherPreferencesViewController()
@property(nonatomic) NSArray<NSString*> *rendererKeys, *rendererList;
@property(nonatomic) BOOL pickingMousePointer;
// The color preference key currently being edited (general.text_color / general.card_color)
@property(nonatomic, copy, nullable) NSString *pickingColorPrefKey;
// The hero card at the top (app name + version + device info), part of the tableHeaderView
@property(nonatomic, strong, nullable) UIView *heroCard;
@end

@implementation LauncherPreferencesViewController

- (id)init {
    self = [super init];
    // self.title is deliberately not set, to avoid a black "Settings" title band in the navigation bar (matching the title-less FCL style)
    return self;
}

- (NSString *)imageName {
    return @"MenuSettings";
}

- (void)openImagePicker {
    // Check whether the image picker is already showing
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *window in scene.windows) {
                    for (UIView *view in window.subviews) {
                        if ([view isKindOfClass:[UIAlertController class]] || 
                            [view isKindOfClass:[UIImagePickerController class]]) {
                            // Return straight away if the relevant controller is already showing
                            return;
                        }
                    }
                }
            }
        }
    }
    
    UIImagePickerController *imagePicker = [[UIImagePickerController alloc] init];
    imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    imagePicker.delegate = self;
    
    // Show the image picker after a delay, so it does not clash with the UIAlertController
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:imagePicker animated:YES completion:nil];
    });
}

- (void)openMousePointerPicker {
    self.pickingMousePointer = YES;
    UIImagePickerController *imagePicker = [[UIImagePickerController alloc] init];
    imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    imagePicker.delegate = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:imagePicker animated:YES completion:nil];
    });
}

#pragma mark - Custom color selection (font/card colors)

- (void)openColorPickerForKey:(NSString *)fullKey title:(NSString *)title {
    if (@available(iOS 14.0, *)) {
        UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
        picker.title = title;
        picker.delegate = self;
        // Preselect the color that is already saved
        NSString *hex = getPrefObject(fullKey);
        UIColor *current = [self colorFromHexString:hex];
        if (current) {
            picker.selectedColor = current;
        }
        self.pickingColorPrefKey = fullKey;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentViewController:picker animated:YES completion:nil];
        });
    } else {
        [self showCustomIconError:@"This iOS version does not support the color picker (iOS 14+ required)"];
    }
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController API_AVAILABLE(ios(14.0)) {
    NSString *key = self.pickingColorPrefKey;
    self.pickingColorPrefKey = nil;
    if (!key) return;
    UIColor *color = viewController.selectedColor;
    NSString *hex = [self hexStringFromColor:color];
    setPrefObject(key, hex);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceChanged" object:nil];
    [self.tableView reloadData];
}

- (nullable UIColor *)colorFromHexString:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] == 0) return nil;
    NSString *clean = [(NSString *)hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

- (NSString *)hexStringFromColor:(UIColor *)color {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%02X%02X%02X", (unsigned)(r * 255), (unsigned)(g * 255), (unsigned)(b * 255)];
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:^{
        // Handle the image only after the picker has fully dismissed
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *selectedImage = info[UIImagePickerControllerOriginalImage];
            if (!selectedImage) {
                [self showCustomIconError:@"Could not read the selected image"];
                return;
            }
            if (self.pickingMousePointer) {
                self.pickingMousePointer = NO;
                NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
                NSData *pngData = UIImagePNGRepresentation(selectedImage);
                [NSFileManager.defaultManager createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                BOOL ok = [pngData writeToFile:path atomically:YES];
                if (ok) {
                    [NSNotificationCenter.defaultCenter postNotificationName:@"MousePointerUpdated" object:nil];
                    [self showSuccessMessage:@"Mouse pointer updated"];
                } else {
                    [self showCustomIconError:@"Failed to save the mouse pointer"];
                }
                return;
            }
            // Show the processing message
            [self showProcessingIndicator];
            
            // Check whether the image is square
            if (selectedImage.size.width != selectedImage.size.height) {
                // If it is not square, open the cropper
                ImageCropperViewController *cropperVC = [[ImageCropperViewController alloc] initWithImage:selectedImage];
                __weak typeof(self) weakSelf = self;
                cropperVC.completionHandler = ^(UIImage * _Nullable croppedImage) {
                    if (croppedImage) {
                        // Save the cropped image
                        [[CustomIconManager sharedManager] saveCustomIcon:croppedImage withCompletion:^(BOOL success, NSError * _Nullable error) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (success) {
                                    [weakSelf showSuccessMessage:@"Image saved. You can now pick it under the app icon settings"];
                                    // Update the app icon picker display
                                    [weakSelf.tableView reloadData];
                                } else {
                                    NSString *errorMessage = error.localizedDescription ?: @"Failed to save the custom icon";
                                    [weakSelf showCustomIconError:errorMessage];
                                }
                            });
                        }];
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf showCustomIconError:@"Image cropping cancelled"];
                        });
                    }
                };
                [weakSelf.navigationController pushViewController:cropperVC animated:YES];
            } else {
                // If it is square, save it directly
                [[CustomIconManager sharedManager] saveCustomIcon:selectedImage withCompletion:^(BOOL success, NSError * _Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (success) {
                            [self showSuccessMessage:@"Image saved. You can now pick it under the app icon settings"];
                            // Update the app icon picker display
                            [self.tableView reloadData];
                        } else {
                            NSString *errorMessage = error.localizedDescription ?: @"Failed to save the custom icon";
                            [self showCustomIconError:errorMessage];
                        }
                    });
                }];
            }
        });
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.pickingMousePointer) {
                self.pickingMousePointer = NO;
            } else {
                [self showCustomIconError:@"Image selection cancelled"];
            }
        });
    }];
}

#pragma mark - Custom Icon Helper Methods

- (void)showProcessingIndicator {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Processing" message:@"Processing the image you selected..." preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    // Dismiss the message automatically after 2 seconds
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)showSuccessMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Success" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showCustomIconError:(NSString *)errorMessage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error" message:errorMessage preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad
{
    // Hide the navigation bar band completely (only when this is a non-modal root page and the only VC on the stack)
    // Set it as early as possible, to avoid the navigation bar flickering
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
    }

    // Enable settings search (this must be set before super viewDidLoad, since the superclass creates the searchController from it)
    self.searchEnabled = YES;

    self.getPreference = ^id(NSString *section, NSString *key){
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        return getPrefObject(keyFull);
    };
    self.setPreference = ^(NSString *section, NSString *key, id value){
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        setPrefObject(keyFull, value);
    };
    
    self.hasDetail = YES;
    // Descriptions start visible. They used to be hidden whenever this screen sat inside a
    // navigation controller, revealed only by the "?" button in the navigation bar - the same bar
    // this screen hides when it is the root page. So the explanation of what a setting does, right
    // down to "enable this if your mods require loading .dylib at runtime", could not be reached at
    // all. The "?" button still collapses them for anyone who wants a shorter list.
    self.prefDetailVisible = YES;
    
    self.prefSections = @[@"general", @"video", @"mobileglues", @"control", @"java", @"debug"];

    self.rendererKeys = getRendererKeys(NO);
    self.rendererList = getRendererNames(NO);
    
    // Check whether we are in game: if the visible view controller is SurfaceViewController, the game is running
    BOOL(^whenNotInGame)() = ^BOOL(){
        UIViewController *visibleVC = currentVC();
        return ![visibleVC isKindOfClass:NSClassFromString(@"SurfaceViewController")];
    };

    // --- Define the block that shows the popup, using weakSelf to avoid a retain cycle ---
    __weak typeof(self) weakSelf = self;
    void (^showTouchInfoAlert)(BOOL) = ^(BOOL enabled) {
        // This block only shows the explanation and no longer makes any decisions
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"preference.popup.touch_info.title", nil)
                                                                           message:localize(@"preference.popup.touch_info.message", nil)
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"GitHub" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/TouchController/TouchController"] options:@{} completionHandler:nil];
            }]];
            
            [weakSelf presentViewController:alert animated:YES completion:nil];
        });
    };
    
    
    // -----------------------------------------------------------

    self.prefContents = @[
        @[
            // General settings
            @{@"icon": @"cube"},
            @{@"key": @"check_sha",
              @"hasDetail": @YES,
              @"icon": @"lock.shield",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            // The Download Source and Mod Mirror rows are gone. Both existed only to pick
            // between the official servers and a mainland-China mirror (BMCLAPI for game
            // resources, MCIM for mods). With the mirrors retired there was one option left,
            // and a setting offering a single choice is just a dead row. Everything uses the
            // official sources now, and PLPreferences migrates installs off the mirrors.
            @{@"key": @"ui_layout",
              @"title": @"UI layout",
              @"hasDetail": @YES,
              @"icon": @"rectangle.split.3x3",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"vs",
                  @"card"
              ],
              @"pickList": @[
                  @"VS three-column layout",
                  @"Card layout"
              ]
            },
            @{@"key": @"ui_theme",
              @"title": @"Appearance",
              @"hasDetail": @YES,
              @"icon": @"circle.lefthalf.filled",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"dark",
                  @"light",
                  @"auto"
              ],
              @"pickList": @[
                  @"Dark mode",
                  @"Light mode",
                  @"Match system"
              ],
              @"action": ^(NSString *value){
                  // Apply the theme live; SceneDelegate handles the notification.
                  // Operations that would reset the account preferences, such as loadPreferences(YES), are not called;
                  // only window.overrideUserInterfaceStyle is set, so the account data is untouched.
                  [[NSNotificationCenter defaultCenter] postNotificationName:@"UIThemeChanged" object:value];
              }
            },
            @{@"key": @"custom_accent_color",
              @"title": @"Theme accent color",
              @"hasDetail": @YES,
              @"icon": @"paintpalette.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.accent_color" title:@"Theme accent color"];
              }
            },
            @{@"key": @"custom_text_color",
              @"title": @"Font color",
              @"hasDetail": @YES,
              @"icon": @"textformat",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.text_color" title:@"Font color"];
              }
            },
            @{@"key": @"custom_card_color",
              @"title": @"Card color",
              @"hasDetail": @YES,
              @"icon": @"rectangle.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.card_color" title:@"Card color"];
              }
            },
            @{@"key": @"reset_appearance_colors",
              @"title": @"Reset theme / font / card colors",
              @"icon": @"arrow.counterclockwise",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  setPrefObject(@"general.accent_color", @"");
                  setPrefObject(@"general.text_color", @"");
                  setPrefObject(@"general.card_color", @"");
                  [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceChanged" object:nil];
                  [self.tableView reloadData];
              }
            },
            @{@"key": @"multi_threaded",
              @"title": @"Multi-threaded download",
              @"hasDetail": @YES,
              @"icon": @"bolt.fill",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"curseforge_api_key",
              @"hasDetail": @YES,
              @"icon": @"key.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  CurseForgeAPIKeyViewController *vc = [[CurseForgeAPIKeyViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            },
            @{@"key": @"cosmetica",
              @"hasDetail": @YES,
              @"icon": @"eyeglasses",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"debug_logging",
              @"hasDetail": @YES,
              @"icon": @"doc.badge.gearshape",
              @"type": self.typeSwitch,
              @"action": ^(BOOL enabled){
                  debugLogEnabled = enabled;
                  NSLog(@"[Debugging] Debug log enabled: %@", enabled ? @"YES" : @"NO");
              }
            },
            @{@"key": @"appicon",
              @"hasDetail": @YES,
              @"icon": @"paintbrush",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"action": ^void(NSString *iconName) {
                  if ([iconName isEqualToString:@"AppIcon-Light"]) {
                      iconName = nil;
                      [[CustomIconManager sharedManager] removeCustomIcon];
                  } else if ([iconName isEqualToString:@"CustomIcon"]) {
                      if (![[CustomIconManager sharedManager] hasCustomIcon]) {
                          dispatch_async(dispatch_get_main_queue(), ^{
                              UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Notice" message:@"Set a custom app icon first: Settings > Custom app icon" preferredStyle:UIAlertControllerStyleAlert];
                              UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
                              [alert addAction:okAction];
                              [self presentViewController:alert animated:YES completion:nil];
                          });
                          dispatch_async(dispatch_get_main_queue(), ^{
                              [self.tableView reloadData];
                          });
                          return;
                      }
                      [[CustomIconManager sharedManager] setCustomIconWithCompletion:^(BOOL success, NSError * _Nullable error) {
                          if (!success) {
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  NSLog(@"Error in appicon: %@", error);
                                  showDialog(localize(@"Error", nil), error.localizedDescription);
                              });
                          }
                      }];
                      return;
                  }
                  [UIApplication.sharedApplication setAlternateIconName:iconName completionHandler:^(NSError * _Nullable error) {
                      if (error == nil) return;
                      NSLog(@"Error in appicon: %@", error);
                      showDialog(localize(@"Error", nil), error.localizedDescription);
                  }];
              },
              @"pickKeys": @[
                  @"AppIcon-Light",
                  @"CustomIcon"
              ],
              @"pickList": @[
                  localize(@"preference.title.appicon-default", nil),
                  localize(@"preference.title.appicon-custom", nil)
              ]
            },
            @{@"key": @"custom_appicon",
              @"hasDetail": @YES,
              @"icon": @"photo",
              @"type": self.typeButton,
              @"enableCondition": ^BOOL(){
                  return NO;
              },
              @"action": ^void(){
                  [self openImagePicker];
              }
            },
            @{@"key": @"launcher_background",
              @"hasDetail": @YES,
              @"icon": @"photo.fill.on.rectangle.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  BackgroundSettingsViewController *bgVC = [[BackgroundSettingsViewController alloc] init];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:bgVC];
                  nav.modalPresentationStyle = UIModalPresentationFormSheet;
                  [self presentViewController:nav animated:YES completion:nil];
              }
            },
            @{@"key": @"hidden_sidebar",
              @"hasDetail": @YES,
              @"icon": @"sidebar.leading",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"announcement_preview_level",
              @"hasDetail": @YES,
              @"icon": @"megaphone",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"full",
                  @"summary",
                  @"title_only"
              ],
              @"pickList": @[
                  @"Full (title + date + summary)",
                  @"Summary only (title + summary)",
                  @"Title only"
              ]
            },
            @{@"key": @"reset_warnings",
              @"icon": @"exclamationmark.triangle",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  resetWarnings();
              }
            },
            @{@"key": @"reset_settings",
              @"icon": @"trash",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"requestReload": @YES,
              @"showConfirmPrompt": @YES,
              @"destructive": @YES,
              @"action": ^void(){
                  loadPreferences(YES);
                  [self.tableView reloadData];
              }
            },
            @{@"key": @"memory_limit_help",
              @"hasDetail": @YES,
              @"icon": @"memorychip",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self showMemoryLimitHelp];
              }
            },
            @{@"key": @"erase_demo_data",
              @"icon": @"trash",
              @"type": self.typeButton,
              @"enableCondition": ^BOOL(){
                  NSString *demoPath = [NSString stringWithFormat:@"%s/.demo", getenv("POJAV_HOME")];
                  int count = [NSFileManager.defaultManager contentsOfDirectoryAtPath:demoPath error:nil].count;
                  return whenNotInGame() && count > 0;
              },
              @"showConfirmPrompt": @YES,
              @"destructive": @YES,
              @"action": ^void(){
                  NSString *demoPath = [NSString stringWithFormat:@"%s/.demo", getenv("POJAV_HOME")];
                  NSError *error;
                  if([NSFileManager.defaultManager removeItemAtPath:demoPath error:&error]) {
                      [NSFileManager.defaultManager createDirectoryAtPath:demoPath
                                              withIntermediateDirectories:YES attributes:nil error:nil];
                      [NSFileManager.defaultManager changeCurrentDirectoryPath:demoPath];
                      if (getenv("DEMO_LOCK")) {
                          [(LauncherNavigationController *)self.navigationController fetchLocalVersionList];
                      }
                  } else {
                      NSLog(@"Error in erase_demo_data: %@", error);
                      showDialog(localize(@"Error", nil), error.localizedDescription);
                  }
              }
            },
            @{@"key": @"check_update",
              @"hasDetail": @YES,
              @"icon": @"arrow.triangle.2.circlepath",
              @"type": self.typeButton,
              @"action": ^void(){
                  [self checkForUpdateFromSettings];
              }
            }
        ], @[
            // Video and renderer settings
            @{@"icon": @"video"},
            @{@"key": @"renderer",
              @"hasDetail": @YES,
              @"icon": @"cpu",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": self.rendererKeys,
              @"pickList": self.rendererList
            },
            @{@"key": @"resolution",
              @"hasDetail": @YES,
              @"icon": @"viewfinder",
              @"type": self.typeSlider,
              @"min": @(25),
              @"max": @(150)
            },
            // The frame rate cap option has been removed: CADisplayLink always uses the adaptive 30-120Hz range,
            // and the screen hardware decides the real frame rate (60Hz devices stay at 60, 120Hz ProMotion devices reach 120).
            // There is no "cap the frame rate at 60FPS" switch any more, so a user cannot lock the frame rate down by mistake.
            // Unlock the frame rate (disabling vertical sync): three layers disable VSync together, letting the game exceed the refresh rate.
            // This is not limited to ProMotion devices: a 60Hz device is locked to 60 by VSync too and needs unlocking as well.
            @{@"key": @"disable_game_vsync",
              @"hasDetail": @YES,
              @"icon": @"hare",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"performance_hud",
              @"hasDetail": @YES,
              @"icon": @"waveform.path.ecg",
              @"type": self.typeSwitch,
              @"enableCondition": ^BOOL(){
                  return [CAMetalLayer instancesRespondToSelector:@selector(developerHUDProperties)];
              }
            },
            @{@"key": @"fullscreen_airplay",
              @"hasDetail": @YES,
              @"icon": @"airplayvideo",
              @"type": self.typeSwitch,
              @"action": ^(BOOL enabled){
                  if (self.navigationController != nil) return;
                  if (UIApplication.sharedApplication.connectedScenes.count < 2) return;
                  if (enabled) {
                      [self.presentingViewController performSelector:@selector(switchToExternalDisplay)];
                  } else {
                      [self.presentingViewController performSelector:@selector(switchToInternalDisplay)];
                  }
              }
            },
            @{@"key": @"silence_other_audio",
              @"hasDetail": @YES,
              @"icon": @"speaker.slash",
              @"type": self.typeSwitch
            },
            @{@"key": @"silence_with_switch",
              @"hasDetail": @YES,
              @"icon": @"speaker.zzz",
              @"type": self.typeSwitch
            },
            @{@"key": @"allow_microphone",
              @"hasDetail": @YES,
              @"icon": @"mic",
              @"type": self.typeSwitch
            },
        ], @[
            // MobileGlues settings
            // When the renderer is MobileGlues or Vulkan, the <POJAV_HOME>/MG/config.json written by
            // init_loadMobileGluesConfig() is read by MobileGlues and takes effect.
            // The OpenGL fallback of the Vulkan renderer is MobileGlues (aligned with the Ynnyny repo).
            // The Auto renderer resolves to ANGLE and never loads MobileGlues.
            @{@"icon": @"cpu"},
            @{@"key": @"enable_angle",
              @"hasDetail": @YES,
              @"icon": @"triangle",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"enable_no_error",
              @"hasDetail": @YES,
              @"icon": @"exclamationmark.triangle",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"1", @"2"],
              @"pickList": @[
                  localize(@"preference.title.mg_enable_no_error-0", nil),
                  localize(@"preference.title.mg_enable_no_error-1", nil),
                  localize(@"preference.title.mg_enable_no_error-2", nil)
              ]
            },
            @{@"key": @"enable_ext_timer_query",
              @"hasDetail": @YES,
              @"icon": @"clock",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"enable_ext_compute_shader",
              @"hasDetail": @YES,
              @"icon": @"cube.transparent",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"enable_ext_direct_state_access",
              @"hasDetail": @YES,
              @"icon": @"directconnect",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"max_glsl_cache_size",
              @"hasDetail": @YES,
              @"icon": @"memorychip",
              @"type": self.typeSlider,
              @"min": @(0),
              @"max": @(256),
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"multidraw_mode",
              @"hasDetail": @YES,
              @"icon": @"square.stack.3d.down.dottedline",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"1", @"2"],
              @"pickList": @[
                  localize(@"preference.title.mg_multidraw_mode-0", nil),
                  localize(@"preference.title.mg_multidraw_mode-1", nil),
                  localize(@"preference.title.mg_multidraw_mode-2", nil)
              ]
            },
            @{@"key": @"angle_depth_clear_fix_mode",
              @"hasDetail": @YES,
              @"icon": @"rectangle.3.group",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"custom_gl_version",
              @"hasDetail": @YES,
              @"icon": @"number",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"4.0", @"4.1", @"4.2", @"4.3", @"4.4", @"4.5", @"4.6"],
              @"pickList": @[
                  localize(@"preference.title.mg_custom_gl_version-0", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.0", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.1", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.2", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.3", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.4", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.5", nil),
                  localize(@"preference.title.mg_custom_gl_version-4.6", nil)
              ]
            },
            @{@"key": @"fsr1_setting",
              @"hasDetail": @YES,
              @"icon": @"square.grid.3x2",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[@"0", @"1", @"2", @"3"],
              @"pickList": @[
                  localize(@"preference.title.mg_fsr1_setting-0", nil),
                  localize(@"preference.title.mg_fsr1_setting-1", nil),
                  localize(@"preference.title.mg_fsr1_setting-2", nil),
                  localize(@"preference.title.mg_fsr1_setting-3", nil)
              ]
            },
        ], @[
            // Control settings
            @{@"icon": @"gamecontroller"},
            
            // --- [Change] TouchController mod support ---
            @{@"key": @"mod_touch_enable",
              @"icon": @"hand.point.up.left", // SF Symbols icon
              @"hasDetail": @YES,
              @"type": self.typeChildPane,
              @"enableCondition": whenNotInGame,
              @"canDismissWithSwipe": @NO,
              @"class": NSClassFromString(@"TouchControllerPreferencesViewController")
            },
            // ------------------------------------------

            // --- [New] Custom controls (moved here from the left menu) ---
            @{@"key": @"custom_controls",
              @"icon": @"gamecontroller.fill",
              @"hasDetail": @YES,
              @"type": self.typeChildPane,
              @"enableCondition": whenNotInGame,
              @"canDismissWithSwipe": @NO,
              @"class": CustomControlsViewController.class
            },
            // ---------------------------------------------

            @{@"key": @"default_gamepad_ctrl",
                @"icon": @"hammer",
                @"type": self.typeChildPane,
                @"enableCondition": whenNotInGame,
                @"canDismissWithSwipe": @NO,
                @"class": LauncherPrefContCfgViewController.class
            },
            @{@"key": @"custom_mouse_pointer",
                @"icon": @"cursorarrow",
                @"hasDetail": @YES,
                @"type": self.typeButton,
                @"enableCondition": whenNotInGame,
                @"action": ^void(){
                    [self openMousePointerPicker];
                }
            },
            @{@"key": @"hardware_hide",
                @"icon": @"eye.slash",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"reset_mouse_pointer",
                @"icon": @"arrow.counterclockwise",
                @"hasDetail": @YES,
                @"type": self.typeButton,
                @"enableCondition": whenNotInGame,
                @"action": ^void(){
                    NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
                    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                    [NSNotificationCenter.defaultCenter postNotificationName:@"MousePointerUpdated" object:nil];
                    [self showSuccessMessage:@"Mouse pointer reset to default"];
                }
            },
            @{@"key": @"recording_hide",
                @"icon": @"eye.slash",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            
            // --- [Rework] Two-finger keyboard control ---
            // Also changed to the button + popup pattern, which finally fixes the switch springing back
            @{@"key": @"two_finger_keyboard", 
              @"icon": @"keyboard", // Keyboard icon
              @"hasDetail": @YES,
              @"type": self.typeButton, // Important: changed to the Button type
              
              @"action": ^void() {
                  // 1. Read the current state
                  BOOL isOn = getPrefBool(@"control.two_finger_keyboard");
                  
                  // 2. Build the popup
                  NSString *title = localize(@"preference.title.two_finger_keyboard", nil);
                  // Set a default title when there is no localization
                  if (!title || [title isEqualToString:@"preference.title.two_finger_keyboard"]) {
                      title = @"Two-finger keyboard";
                  }
                  
                  NSString *statusMsg = isOn ? @"[✓] Current state: ON" : @"[✗] Current state: OFF";
                  NSString *msg = [NSString stringWithFormat:@"%@\n\nWhen enabled, long-press the screen with two fingers in game to bring up the keyboard.\nThis feature was made by WeiErLiTeo.", statusMsg];
                  
                  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
                  
                  // 3. Show different buttons depending on the current state
                  if (!isOn) {
                      [alert addAction:[UIAlertAction actionWithTitle:@"Enable" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                          // Force it on
                          setPrefBool(@"control.two_finger_keyboard", YES);
                          [weakSelf showSuccessMessage:@"Two-finger keyboard turned on"];
                          // Refresh the screen
                          [weakSelf.tableView reloadData];
                      }]];
                  } else {
                      [alert addAction:[UIAlertAction actionWithTitle:@"Disable" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                          // Force it off
                          setPrefBool(@"control.two_finger_keyboard", NO);
                          [weakSelf showSuccessMessage:@"Two-finger keyboard turned off"];
                          // Refresh the screen
                          [weakSelf.tableView reloadData];
                      }]];
                  }
                  
                  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                  
                  [weakSelf presentViewController:alert animated:YES completion:nil];
              }
            },
            // -----------------------------
            
            @{@"key": @"gesture_mouse",
                @"icon": @"cursorarrow.click",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"gesture_hotbar",
                @"icon": @"hand.tap",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"disable_haptics",
                @"icon": @"wave.3.left",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"slideable_hotbar",
                @"hasDetail": @YES,
                @"icon": @"slider.horizontal.below.rectangle",
                @"type": self.typeSwitch,
                // --- [Change] Add the disable condition ---
                @"enableCondition": ^BOOL(){
                    // Disable this option while TouchController is enabled (returning NO disables/grays it out)
                    return ![self.getPreference(@"control", @"mod_touch_enable") boolValue];
                }
            },
            @{@"key": @"press_duration",
                @"hasDetail": @YES,
                @"icon": @"cursorarrow.click.badge.clock",
                @"type": self.typeSlider,
                @"min": @(100),
                @"max": @(1000),
            },
            @{@"key": @"button_scale",
                @"hasDetail": @YES,
                @"icon": @"aspectratio",
                @"type": self.typeSlider,
                @"min": @(50), // 80?
                @"max": @(500)
            },
            @{@"key": @"mouse_scale",
                @"hasDetail": @YES,
                @"icon": @"arrow.up.left.and.arrow.down.right.circle",
                @"type": self.typeSlider,
                @"min": @(25),
                @"max": @(300)
            },
            @{@"key": @"mouse_speed",
                @"hasDetail": @YES,
                @"icon": @"cursorarrow.motionlines",
                @"type": self.typeSlider,
                @"min": @(25),
                @"max": @(300)
            },
            @{@"key": @"virtmouse_enable",
                @"hasDetail": @YES,
                @"icon": @"cursorarrow.rays",
                @"type": self.typeSwitch
            },
            @{@"key": @"gyroscope_enable",
                @"hasDetail": @YES,
                @"icon": @"gyroscope",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return realUIIdiom != UIUserInterfaceIdiomTV;
                }
            },
            @{@"key": @"gyroscope_invert_x_axis",
                @"hasDetail": @YES,
                @"icon": @"arrow.left.and.right",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return realUIIdiom != UIUserInterfaceIdiomTV;
                }
            },
            @{@"key": @"gyroscope_sensitivity",
                @"hasDetail": @YES,
                @"icon": @"move.3d",
                @"type": self.typeSlider,
                @"min": @(50),
                @"max": @(300),
                @"enableCondition": ^BOOL(){
                    return realUIIdiom != UIUserInterfaceIdiomTV;
                }
            }
        ], @[
        // Java tweaks
            @{@"icon": @"sparkles"},
            @{@"key": @"manage_runtime",
                @"hasDetail": @YES,
                @"icon": @"cube",
                @"type": self.typeChildPane,
                @"canDismissWithSwipe": @YES,
                @"class": LauncherPrefManageJREViewController.class,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"java_args",
                @"hasDetail": @YES,
                @"icon": @"slider.vertical.3",
                @"type": self.typeTextField,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"env_variables",
                @"hasDetail": @YES,
                @"icon": @"terminal",
                @"type": self.typeTextField,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"auto_ram",
                @"hasDetail": @YES,
                @"icon": @"slider.horizontal.3",
                @"type": self.typeSwitch,
                @"enableCondition": whenNotInGame,
                @"warnCondition": ^BOOL(){
                    return !isJailbroken;
                },
                @"warnKey": @"auto_ram_warn",
                @"requestReload": @YES
            },
            @{@"key": @"allocated_memory",
                @"hasDetail": @YES,
                @"icon": @"memorychip",
                @"type": self.typeSlider,
                @"min": @(250),
                @"max": @((NSProcessInfo.processInfo.physicalMemory / 1048576) * 0.85),
                @"enableCondition": ^BOOL(){
                    return !getPrefBool(@"java.auto_ram") && whenNotInGame();
                },
                @"warnCondition": ^BOOL(DBNumberedSlider *view){
                    return view.value >= NSProcessInfo.processInfo.physicalMemory / 1048576 * 0.37;
                },
                @"warnKey": @"mem_warn"
            }
        ], @[
            // Debug settings - only recommended for developer use
            @{@"icon": @"ladybug"},
            @{@"key": @"debug_universal_script_jit",
                @"icon": @"scroll",
                @"type": self.typeSwitch,
                @"requestReload": @YES,
                @"enableCondition": ^BOOL(){
                    // Synced from catsruledogs: DeviceNeedsDebugJITMapping() replaces the old TXM flag combination
                    // Based on JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED, so this switch also appears on iOS 26+ devices without TXM
                    return DeviceNeedsDebugJITMapping() && whenNotInGame();
                },
            },
            @{@"key": @"debug_always_attached_jit",
                @"hasDetail": @YES,
                @"icon": @"app.connected.to.app.below.fill",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return getPrefBool(@"debug.debug_universal_script_jit") && whenNotInGame();
                },
            },
            @{@"key": @"debug_skip_wait_jit",
                @"hasDetail": @YES,
                @"icon": @"forward",
                @"type": self.typeSwitch,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"debug_hide_home_indicator",
                @"hasDetail": @YES,
                @"icon": @"iphone.and.arrow.forward",
                @"type": self.typeSwitch,
                @"enableCondition": ^BOOL(){
                    return
                        self.splitViewController.view.safeAreaInsets.bottom > 0 ||
                        self.view.safeAreaInsets.bottom > 0;
                }
            },
            @{@"key": @"debug_ipad_ui",
                @"hasDetail": @YES,
                @"icon": @"ipad",
                @"type": self.typeSwitch,
                @"enableCondition": whenNotInGame
            },
            @{@"key": @"debug_auto_correction",
                @"hasDetail": @YES,
                @"icon": @"textformat.abc.dottedunderline",
                @"type": self.typeSwitch
            }
        ]
    ];

    [super viewDidLoad];
    // Adapt to the custom launcher background: make this view controller transparent through BackgroundManager,
    // so the global background container (image/video) shows through. It must be called after super viewDidLoad,
    // to make sure both the view and the tableView exist.
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // Hero card at the top: app name + version + device info (following the L3 large-card spec of Air-Design v1.2)
    // Wrapped together with the search bar as the tableHeaderView, search bar on top and hero card below
    [self setupHeroHeader];

    // Apply transparent background if global background is active
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        
        // Make separator visible on background
        self.tableView.separatorEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        self.tableView.separatorColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    }
    
    if (self.navigationController == nil) {
        self.tableView.alpha = 0.9;
    }
    if (NSProcessInfo.processInfo.isMacCatalystApp) {
        UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeClose];
        closeButton.frame = CGRectOffset(closeButton.frame, 10, 10);
        [closeButton addTarget:self action:@selector(actionClose) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:closeButton];
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // Listen for background UI effect changes: when the user switches between frosted glass and translucent, or adjusts the opacity,
    // call makeViewControllerTransparent again to apply the latest look and keep the background showing correctly.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(openCurseForgeAPIKeySettings)
                                                 name:@"OpenCurseForgeAPIKeySettings"
                                               object:nil];
}

#pragma mark - Hero Header (the app information card at the top)

- (NSString *)appName {
    // Prefer CFBundleDisplayName (the user-visible name), then CFBundleName, falling back to "Air"
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *name = info[@"CFBundleDisplayName"];
    if (name.length == 0) {
        name = info[@"CFBundleName"];
    }
    return name.length ? name : @"Air";
}

- (void)setupHeroHeader {
    // The superclass viewDidLoad has already set searchController.searchBar as the tableHeaderView
    // Here the searchBar is taken back out and rewrapped, together with the hero card, into a new tableHeaderView
    // Note: searchController is a private property of the superclass PLPrefTableViewController and cannot be reached directly by subclasses,
    // but the superclass has set its searchBar as tableView.tableHeaderView, so it can be read from there.
    UISearchBar *searchBar = nil;
    UIView *currentHeader = self.tableView.tableHeaderView;
    if ([currentHeader isKindOfClass:[UISearchBar class]]) {
        searchBar = (UISearchBar *)currentHeader;
    }
    [searchBar removeFromSuperview];

    // Make the searchBar adapt to the custom background (transparent, with the text color following the system)
    searchBar.barTintColor = [UIColor clearColor];
    searchBar.tintColor = accentColor();
    searchBar.backgroundImage = [UIImage new]; // Remove the default background
    if (@available(iOS 13.0, *)) {
        searchBar.searchTextField.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    }

    // ===== Hero card (an L3 large card: 16pt radius + translucent background + frosted glass + light border + medium shadow) =====
    UIView *heroCard = [[UIView alloc] init];
    heroCard.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.14]; // surface-bright
    heroCard.layer.cornerRadius = 16;
    heroCard.layer.cornerCurve = kCACornerCurveContinuous;
    heroCard.layer.borderWidth = 0.5;
    heroCard.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    heroCard.layer.shadowColor = [UIColor blackColor].CGColor;
    heroCard.layer.shadowOpacity = 0.12;
    heroCard.layer.shadowRadius = 8;
    heroCard.layer.shadowOffset = CGSizeMake(0, 3);
    [[BackgroundManager sharedManager] applyEffectToView:heroCard];

    // Hero icon (56x56, 14pt radius, solid accentColor background, white SF Symbol)
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.image = [UIImage systemImageNamed:@"cube.fill"];
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeCenter;
    iconView.backgroundColor = accentColor();
    iconView.layer.cornerRadius = 14;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
    [heroCard addSubview:iconView];

    // Title (the app name, 17pt bold, labelColor)
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = [self appName];
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.8;
    [heroCard addSubview:titleLabel];

    // Subtitle (first line: the app version; second line: the device name · the iOS version)
    UILabel *subtitleLabel = [[UILabel alloc] init];
    NSString *appVersion = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0";
    NSString *deviceName = [HostManager GetModelName] ?: UIDevice.currentDevice.name ?: @"iPhone";
    NSString *systemVersion = UIDevice.currentDevice.systemVersion ?: @"";
    NSString *subtitle = [NSString stringWithFormat:@"v%@\n%@ · iOS %@", appVersion, deviceName, systemVersion];
    subtitleLabel.text = subtitle;
    subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.numberOfLines = 0;
    [heroCard addSubview:subtitleLabel];

    // Chevron on the right (12x12, tertiary labelColor)
    UIImageView *chevronView = [[UIImageView alloc] init];
    chevronView.image = [UIImage systemImageNamed:@"chevron.right"];
    chevronView.tintColor = [UIColor tertiaryLabelColor];
    chevronView.contentMode = UIViewContentModeScaleAspectFit;
    [heroCard addSubview:chevronView];

    self.heroCard = heroCard;

    // ===== Container view: searchBar (top) + heroCard (bottom) =====
    UIView *container = [[UIView alloc] init];
    [container addSubview:searchBar];
    [container addSubview:heroCard];

    // Enable AutoLayout
    searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    heroCard.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    chevronView.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        // searchBar: flush with the top and both sides
        [searchBar.topAnchor constraintEqualToAnchor:container.topAnchor],
        [searchBar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [searchBar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        // heroCard: 16pt margin on each side, 8pt below the searchBar, 8pt above the bottom of the container
        [heroCard.topAnchor constraintEqualToAnchor:searchBar.bottomAnchor constant:8],
        [heroCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [heroCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [heroCard.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],

        // iconView: 56x56, 16pt from the left and 16pt top and bottom
        [iconView.leadingAnchor constraintEqualToAnchor:heroCard.leadingAnchor constant:16],
        [iconView.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:16],
        [iconView.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],
        [iconView.widthAnchor constraintEqualToConstant:56],
        [iconView.heightAnchor constraintEqualToConstant:56],

        // titleLabel: 14pt to the right of iconView, 18pt from the top
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:18],
        [titleLabel.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-8],

        // subtitleLabel: 2pt below titleLabel
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-8],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],

        // chevronView: 12x12, 16pt from the right, vertically centered
        [chevronView.trailingAnchor constraintEqualToAnchor:heroCard.trailingAnchor constant:-16],
        [chevronView.centerYAnchor constraintEqualToAnchor:heroCard.centerYAnchor],
        [chevronView.widthAnchor constraintEqualToConstant:12],
        [chevronView.heightAnchor constraintEqualToConstant:12],
    ]];

    // UITableView does not size the tableHeaderView from AutoLayout automatically,
    // so it has to be laid out and given a frame by hand. systemLayoutSizeFitting computes a suitable height.
    CGFloat width = self.tableView.bounds.size.width;
    if (width == 0) width = [UIScreen mainScreen].bounds.size.width;
    container.frame = CGRectMake(0, 0, width, 0);
    [container setNeedsLayout];
    [container layoutIfNeeded];
    CGFloat fittingHeight = [container systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                                               withHorizontalFittingPriority:UILayoutPriorityRequired
                                                     verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    container.frame = CGRectMake(0, 0, width, fittingHeight);

    self.tableView.tableHeaderView = container;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"OpenCurseForgeAPIKeySettings" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Hide the navigation bar band again (topViewController == self after popping back to the root page)
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = YES;
    }

    // Re-apply transparency when appearing (in case background was just set)
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        
        // Refresh cells to apply background styling
        [self.tableView reloadData];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Show the navigation bar when a child page is pushed (it needs a back button)
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil) {
        self.navigationController.navigationBarHidden = NO;
    }
    if (self.navigationController == nil) {
        [self.presentingViewController performSelector:@selector(updatePreferenceChanges)];
    }
}

- (void)actionClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

/// Re-apply the background effect: called when the BackgroundUIEffectChanged notification arrives.
/// Re-applies the opacity/frosted-glass effect to this view controller via BackgroundManager,
/// and set the tableView background to transparent and remove the default backgroundView, so the global background shows through.
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

#pragma mark - Check For Update

/// The "Check for updates" entry on the settings page: calls UpdateChecker to check for a stable release and shows the result in an alert.
- (void)checkForUpdateFromSettings {
    /* Show a loading alert */
    UIAlertController *loadingAlert = [UIAlertController
        alertControllerWithTitle:localize(@"check_update.checking", @"Checking for updates…")
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loadingAlert animated:YES completion:nil];

    [UpdateChecker checkForUpdateWithCompletion:^(UpdateInfo *info, NSError *error) {
        [loadingAlert dismissViewControllerAnimated:YES completion:^{
            if (error || info == nil) {
                [self showUpdateAlertWithTitle:localize(@"check_update.failed", @"Update check failed")
                                         message:error.localizedDescription ?: @"Unknown error"
                                       hasUpdate:NO
                                          info:nil];
                return;
            }
            if (info.hasUpdate) {
                [self showUpdateAvailableAlert:info];
            } else {
                [self showUpdateAlertWithTitle:localize(@"check_update.up_to_date", @"You're up to date")
                                         message:[NSString stringWithFormat:
                                             localize(@"check_update.current_version", @"You're on version %@, the latest stable release."),
                                             info.currentVersion]
                                       hasUpdate:NO
                                          info:nil];
            }
        }];
    }];
}

- (void)showUpdateAlertWithTitle:(NSString *)title
                         message:(NSString *)message
                       hasUpdate:(BOOL)hasUpdate
                          info:(nullable UpdateInfo *)info {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", @"OK")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// Show the update details popup when a new version is found (following the FCL/ZL2 style)
- (void)showUpdateAvailableAlert:(UpdateInfo *)info {
    NSString *title = [NSString stringWithFormat:localize(@"check_update.new_version_title",
                                                          @"New version available: v%@"), info.latestVersion];
    /* Truncate the changelog: if it is very long, show only the first 500 characters plus an ellipsis */
    NSString *notes = info.releaseNotes ?: @"";
    if (notes.length > 500) {
        notes = [[notes substringToIndex:500] stringByAppendingString:@"…"];
    }
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@",
                         localize(@"check_update.new_version_message",
                                  @"Tap \"Go to downloads\" to open the GitHub Releases page and get the latest version."),
                         notes];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"check_update.download", @"Go to downloads")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [UpdateChecker openReleasePage];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Memory Limit Help

- (void)showMemoryLimitHelp {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"mem_help.title", @"About the memory limit")
                         message:localize(@"mem_help.message",
                             @"On iOS 18 / iOS 26 a single instance is capped at about 1440 MB of memory, so large modpacks may crash from running out of memory.\n\n"
                              "How to fix:\n"
                              "Use GetMoreRam (a LiveContainer plugin) to lift the memory limit.\n"
                              "GetMoreRam repository: github.com/hugeBlack/GetMoreRam\n\n"
                              "Restart the launcher after installing for it to take effect.\n\n"
                              "If you are not using LiveContainer, try lowering the memory allocation (Settings > Java > Memory allocation), "
                              "but some modpacks may not run properly within the memory limit.")
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"GetMoreRam"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:@"https://github.com/hugeBlack/GetMoreRam"];
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - CurseForge API Key Settings

- (void)openCurseForgeAPIKeySettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Get the top VC through UIScene (rather than keyWindow)
        UIViewController *topVC = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                topVC = windowScene.windows.firstObject.rootViewController;
                if (topVC) {
                    break;
                }
            }
        }
        if (!topVC) {
            // Second best: take any UIWindowScene
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    topVC = windowScene.windows.firstObject.rootViewController;
                    if (topVC) {
                        break;
                    }
                }
            }
        }
        if (!topVC) {
            return;
        }

        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }

        CurseForgeAPIKeyViewController *vc = [[CurseForgeAPIKeyViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [topVC presentViewController:nav animated:YES completion:nil];
    });
}

#pragma mark - UITableView Data Source Override

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

    // ===== iOS Settings app style: colored rounded icon backgrounds =====
    // Following the iOS Settings app: the icon on the left of each row sits on a colored rounded square,
    // with the icon itself rendered as a white SF Symbol. Each section gets its own color:
    //   general=blue / video=purple / control=green / java=orange / debug=red
    // Destructive rows always use a red background.
    // Search results use a blue-gray background.
    [self applySettingsAppStyleToCell:cell indexPath:indexPath];

    // Apply background styling if global background is active
    if ([[BackgroundManager sharedManager] hasBackground]) {
        // Set semi-transparent dark background for cells
        [[BackgroundManager sharedManager] applyEffectToCell:cell];

        // Set white text for better visibility on dark background
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.shadowColor = [UIColor blackColor];
        cell.textLabel.shadowOffset = CGSizeMake(0, 1);

        // Detail text light gray
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
        cell.detailTextLabel.shadowColor = [UIColor blackColor];
        cell.detailTextLabel.shadowOffset = CGSizeMake(0, 1);

        // Tint color for icons and accessories: the theme accent color (accentColor)
        cell.tintColor = accentColor();

        // Handle specific cell types
        NSArray *subviews = cell.contentView.subviews;
        for (UIView *subview in subviews) {
            // Style sliders
            if ([subview isKindOfClass:[UISlider class]]) {
                UISlider *slider = (UISlider *)subview;
                slider.tintColor = accentColor();
                slider.thumbTintColor = [UIColor whiteColor];
            }

            // Style switches
            if ([subview isKindOfClass:[UISwitch class]]) {
                UISwitch *switchControl = (UISwitch *)subview;
                switchControl.onTintColor = accentColor();
            }

            // Style text fields
            if ([subview isKindOfClass:[UITextField class]]) {
                UITextField *textField = (UITextField *)subview;
                textField.textColor = [UIColor whiteColor];
                textField.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.6];
                textField.layer.cornerRadius = 8;
            }

            // Style labels
            if ([subview isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)subview;
                label.textColor = [UIColor whiteColor];
                label.shadowColor = [UIColor blackColor];
                label.shadowOffset = CGSizeMake(0, 1);
            }
        }

        // Style the picker label if exists
        if (cell.accessoryView && [cell.accessoryView isKindOfClass:[UILabel class]]) {
            UILabel *pickerLabel = (UILabel *)cell.accessoryView;
            pickerLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
        }
    } else {
        // Reset to default when no background
        cell.backgroundColor = [UIColor secondarySystemBackgroundColor];
        cell.textLabel.textColor = [UIColor labelColor];
        cell.textLabel.shadowColor = nil;
        cell.textLabel.shadowOffset = CGSizeZero;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.shadowColor = nil;
        cell.detailTextLabel.shadowOffset = CGSizeZero;
    }

    return cell;
}

/// iOS Settings app style icon background: give cell.imageView a rounded colored background and a white icon
/// Following the iOS Settings app (General=gray, Display=blue, Privacy=blue and so on)
/// Called from cellForRow; purely decorative, changing neither the cell data nor its behavior
- (void)applySettingsAppStyleToCell:(UITableViewCell *)cell indexPath:(NSIndexPath *)indexPath {
    UIImageView *iconView = cell.imageView;
    if (!iconView) return;

    // Work out whether this is a section header row (row 0 with prefSections)
    // Section header rows get no colored background and keep their original style (so they are not confused with the rows inside a group)
    BOOL isSectionHeader = (indexPath.row == 0 && self.prefSections && !self.filteredItems);
    if (isSectionHeader) {
        // Section header: restore the default tint (no background), so the icon keeps the system look
        iconView.backgroundColor = [UIColor clearColor];
        iconView.layer.cornerRadius = 0;
        iconView.layer.masksToBounds = NO;
        // Section header icons use the theme accent color (accentColor), matching the play button and the selected menu state
        iconView.tintColor = accentColor();
        return;
    }

    // Read the data for this row
    NSDictionary *item = nil;
    if (self.filteredItems) {
        // Search results mode
        item = self.filteredItems[indexPath.row];
    } else if (self.prefSections && indexPath.section < (NSInteger)self.prefContents.count) {
        NSArray *sectionItems = self.prefContents[indexPath.section];
        if (indexPath.row < (NSInteger)sectionItems.count) {
            item = sectionItems[indexPath.row];
        }
    }

    // Work out whether this is a destructive row
    BOOL destructive = [item[@"destructive"] boolValue];

    // Get the icon name and re-render it with UIImageSymbolConfiguration as a white SF Symbol at a suitable size
    NSString *iconName = item[@"icon"];
    UIImage *styledIcon = nil;
    if (iconName.length > 0) {
        // Use UIImageSymbolConfiguration to control the icon size and color
        // pointSize 16 suits the 29pt imageView of a default UITableViewCell (leaving room for padding)
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16
                                                                                            weight:UIFontWeightMedium];
        styledIcon = [UIImage systemImageNamed:iconName withConfiguration:config];
        if (!styledIcon) {
            styledIcon = [UIImage systemImageNamed:iconName];
        }
    }

    // Set the icon: rendered white as a template, so it shows on the colored background
    if (styledIcon) {
        // withTintColor renders the SF Symbol white (template mode) to match the background color
        UIImage *whiteIcon = [styledIcon imageWithTintColor:[UIColor whiteColor]
                                               renderingMode:UIImageRenderingModeAlwaysOriginal];
        iconView.image = whiteIcon;
    }
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeCenter;

    // Set the colored rounded background
    UIColor *bgColor = [self iconBackgroundColorForItem:item indexPath:indexPath destructive:destructive];
    iconView.backgroundColor = bgColor;
    iconView.layer.cornerRadius = 7;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
}

/// Return the iOS Settings app style background color for a row, from its section and icon name
/// Following the iOS Settings app: each feature area gets its own color, so the grouping is obvious at a glance
- (UIColor *)iconBackgroundColorForItem:(NSDictionary *)item
                              indexPath:(NSIndexPath *)indexPath
                             destructive:(BOOL)destructive {
    // Destructive rows always get a red background
    if (destructive) {
        return [UIColor systemRedColor];
    }

    // Search results mode: always a blue-gray background
    if (self.filteredItems) {
        NSNumber *origSection = item[@"__origSection"];
        if (origSection) {
            return [self colorForPreferenceSection:origSection.intValue];
        }
        return [UIColor systemBlueColor];
    }

    // Normal mode: colored by section
    return [self colorForPreferenceSection:indexPath.section];
}

/// Section index -> color mapping (following the module colors of the iOS Settings app)
/// general=blue (general settings) / video=purple (display) / control=green (controls) / java=orange (runtime) / debug=red (debugging)
- (UIColor *)colorForPreferenceSection:(NSInteger)section {
    if (!self.prefSections || section >= (NSInteger)self.prefSections.count) {
        return [UIColor systemGrayColor];
    }
    NSString *sectionKey = self.prefSections[section];
    if ([sectionKey isEqualToString:@"general"]) {
        return [UIColor systemBlueColor];
    } else if ([sectionKey isEqualToString:@"video"]) {
        return [UIColor systemPurpleColor];
    } else if ([sectionKey isEqualToString:@"mobileglues"]) {
        return [UIColor systemIndigoColor];
    } else if ([sectionKey isEqualToString:@"control"]) {
        return [UIColor systemGreenColor];
    } else if ([sectionKey isEqualToString:@"java"]) {
        return [UIColor systemOrangeColor];
    } else if ([sectionKey isEqualToString:@"debug"]) {
        return [UIColor systemRedColor];
    }
    return [UIColor systemGrayColor];
}

#pragma mark - UITableView Delegate

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) { // Add to general section
        NSString *versionString = [NSString stringWithFormat:@"Amethyst iOS Remastered %@\n%@ on %@ (%s)\nPID: %d",
            NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
            UIDevice.currentDevice.completeOSVersion, [HostManager GetModelName], getenv("POJAV_DETECTEDINST"), getpid()];
        
        // Style footer for background if needed
        if ([[BackgroundManager sharedManager] hasBackground]) {
            // Footer text is handled by the table view, but we can ensure visibility
            // by making sure the section has appropriate styling
        }
        
        return versionString;
    }

    NSString *footer = NSLocalizedStringWithDefaultValue(([NSString stringWithFormat:@"preference.section.footer.%@", self.prefSections[section]]), @"Localizable", NSBundle.mainBundle, @" ", nil);
    if ([footer isEqualToString:@" "]) {
        return nil;
    }
    return footer;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    // Style section headers for background visibility
    if ([[BackgroundManager sharedManager] hasBackground]) {
        if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
            UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
            header.textLabel.textColor = [UIColor whiteColor];
            header.textLabel.shadowColor = [UIColor blackColor];
            header.textLabel.shadowOffset = CGSizeMake(0, 1);
            header.backgroundView = [[UIView alloc] init];
            header.backgroundView.backgroundColor = [UIColor clearColor];
        }
    }
}

/// Override the sub-page navigation to give CustomControlsViewController the callback blocks it needs
- (void)tableView:(UITableView *)tableView openChildPaneAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    // Special case: the custom controls screen needs the setDefaultCtrl / getDefaultCtrl callbacks
    if ([item[@"key"] isEqualToString:@"custom_controls"]) {
        CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.setDefaultCtrl = ^(NSString *name){
            setPrefObject(@"control.default_ctrl", name);
        };
        vc.getDefaultCtrl = ^{
            return getPrefObject(@"control.default_ctrl");
        };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.navigationBar.prefersLargeTitles = YES;
        nav.modalInPresentation = YES;
        [self.navigationController presentViewController:nav animated:YES completion:nil];
        return;
    }

    // Every other row takes the default superclass path
    [super tableView:tableView openChildPaneAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    // Style section footers for background visibility
    if ([[BackgroundManager sharedManager] hasBackground]) {
        if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
            UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
            footer.textLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
            footer.textLabel.shadowColor = [UIColor blackColor];
            footer.textLabel.shadowOffset = CGSizeMake(0, 1);
            footer.backgroundView = [[UIView alloc] init];
            footer.backgroundView.backgroundColor = [UIColor clearColor];
        }
    }
}

@end
