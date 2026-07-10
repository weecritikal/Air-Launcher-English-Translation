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
#import "AIFixViewController.h"
#import "CurseForgeAPIKeyViewController.h"
#import "DownloadFloatingBall.h"

@interface LauncherPreferencesViewController()
@property(nonatomic) NSArray<NSString*> *rendererKeys, *rendererList;
@property(nonatomic) BOOL pickingMousePointer;
// 当前正在选择的颜色偏好键（general.text_color / general.card_color）
@property(nonatomic, copy, nullable) NSString *pickingColorPrefKey;
@end

@implementation LauncherPreferencesViewController

- (id)init {
    self = [super init];
    self.title = localize(@"Settings", nil);
    return self;
}

- (NSString *)imageName {
    return @"MenuSettings";
}

- (void)openImagePicker {
    // 检查是否已经显示了图片选择器
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *window in scene.windows) {
                    for (UIView *view in window.subviews) {
                        if ([view isKindOfClass:[UIAlertController class]] || 
                            [view isKindOfClass:[UIImagePickerController class]]) {
                            // 如果已经显示了相关控制器，直接返回
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
    
    // 延迟显示图片选择器，避免与UIAlertController冲突
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

#pragma mark - 自定义颜色选择（字体/卡片颜色）

- (void)openColorPickerForKey:(NSString *)fullKey title:(NSString *)title {
    if (@available(iOS 14.0, *)) {
        UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
        picker.title = title;
        picker.delegate = self;
        // 预选当前已保存的颜色
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
        [self showCustomIconError:@"当前系统版本不支持颜色选择器（需 iOS 14+）"];
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
        // 在图片选择器完全关闭后再处理图片
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *selectedImage = info[UIImagePickerControllerOriginalImage];
            if (!selectedImage) {
                [self showCustomIconError:@"无法获取选中的图片"];
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
                    [self showSuccessMessage:@"鼠标指针已更新"];
                } else {
                    [self showCustomIconError:@"保存鼠标指针失败"];
                }
                return;
            }
            // 显示处理中的提示
            [self showProcessingIndicator];
            
            // 检查图片是否为正方形
            if (selectedImage.size.width != selectedImage.size.height) {
                // 如果不是正方形，打开裁剪界面
                ImageCropperViewController *cropperVC = [[ImageCropperViewController alloc] initWithImage:selectedImage];
                __weak typeof(self) weakSelf = self;
                cropperVC.completionHandler = ^(UIImage * _Nullable croppedImage) {
                    if (croppedImage) {
                        // 保存裁剪后的图片
                        [[CustomIconManager sharedManager] saveCustomIcon:croppedImage withCompletion:^(BOOL success, NSError * _Nullable error) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (success) {
                                    [weakSelf showSuccessMessage:@"图片已保存，您可以在应用图标设置中选择自定义图标"];
                                    // 更新应用图标选择器的显示
                                    [weakSelf.tableView reloadData];
                                } else {
                                    NSString *errorMessage = error.localizedDescription ?: @"保存自定义图标失败";
                                    [weakSelf showCustomIconError:errorMessage];
                                }
                            });
                        }];
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [weakSelf showCustomIconError:@"图片裁剪已取消"];
                        });
                    }
                };
                [weakSelf.navigationController pushViewController:cropperVC animated:YES];
            } else {
                // 如果是正方形，直接保存
                [[CustomIconManager sharedManager] saveCustomIcon:selectedImage withCompletion:^(BOOL success, NSError * _Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (success) {
                            [self showSuccessMessage:@"图片已保存，您可以在应用图标设置中选择自定义图标"];
                            // 更新应用图标选择器的显示
                            [self.tableView reloadData];
                        } else {
                            NSString *errorMessage = error.localizedDescription ?: @"保存自定义图标失败";
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
                [self showCustomIconError:@"图片选择已取消"];
            }
        });
    }];
}

#pragma mark - Custom Icon Helper Methods

- (void)showProcessingIndicator {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"处理中" message:@"正在处理您选择的图片..." preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    // 2秒后自动关闭提示
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)showSuccessMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"成功" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showCustomIconError:(NSString *)errorMessage {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误" message:errorMessage preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad
{
    // 启用设置项搜索（必须在 super viewDidLoad 之前设置，父类据此创建 searchController）
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
    self.prefDetailVisible = self.navigationController == nil;
    
    self.prefSections = @[@"general", @"video", @"control", @"java", @"debug"];

    self.rendererKeys = getRendererKeys(NO);
    self.rendererList = getRendererNames(NO);
    
    // 检查是否在游戏中：如果当前可见视图控制器是 SurfaceViewController，则在游戏中
    BOOL(^whenNotInGame)() = ^BOOL(){
        UIViewController *visibleVC = currentVC();
        return ![visibleVC isKindOfClass:NSClassFromString(@"SurfaceViewController")];
    };

    // --- 定义弹窗显示的 Block，防止循环引用使用 weakSelf ---
    __weak typeof(self) weakSelf = self;
    void (^showTouchInfoAlert)(BOOL) = ^(BOOL enabled) {
        // 这个 Block 仅用于显示说明，不再负责逻辑判断
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
            @{@"key": @"download_source",
              @"hasDetail": @YES,
              @"icon": @"arrow.down.circle",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"official",
                  @"bmclapi"
              ],
              @"pickList": @[
                  localize(@"preference.title.download_source-official", nil),
                  localize(@"preference.title.download_source-bmclapi", nil)
              ]
            },
            @{@"key": @"ui_layout",
              @"title": @"UI 布局",
              @"hasDetail": @YES,
              @"icon": @"rectangle.split.3x3",
              @"type": self.typePickField,
              @"enableCondition": whenNotInGame,
              @"pickKeys": @[
                  @"vs",
                  @"card"
              ],
              @"pickList": @[
                  @"VS 三栏布局",
                  @"卡片式布局"
              ]
            },
            @{@"key": @"ui_theme",
              @"title": @"外观模式",
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
                  @"深色模式",
                  @"浅色模式",
                  @"跟随系统"
              ],
              @"action": ^(NSString *value){
                  // 实时应用主题，发通知由 SceneDelegate 处理。
                  // 不调用 loadPreferences(YES) 等会重置账号偏好的操作，
                  // 仅设置 window.overrideUserInterfaceStyle，账号数据不受影响。
                  [[NSNotificationCenter defaultCenter] postNotificationName:@"UIThemeChanged" object:value];
              }
            },
            @{@"key": @"custom_text_color",
              @"title": @"字体颜色",
              @"hasDetail": @YES,
              @"icon": @"textformat",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.text_color" title:@"字体颜色"];
              }
            },
            @{@"key": @"custom_card_color",
              @"title": @"卡片颜色",
              @"hasDetail": @YES,
              @"icon": @"rectangle.fill",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  [self openColorPickerForKey:@"general.card_color" title:@"卡片颜色"];
              }
            },
            @{@"key": @"reset_appearance_colors",
              @"title": @"重置字体/卡片颜色",
              @"icon": @"arrow.counterclockwise",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  setPrefObject(@"general.text_color", @"");
                  setPrefObject(@"general.card_color", @"");
                  [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceChanged" object:nil];
                  [self.tableView reloadData];
              }
            },
            @{@"key": @"floating_ball_enabled",
              @"title": @"下载悬浮球",
              @"hasDetail": @YES,
              @"icon": @"circle.fill",
              @"type": self.typeSwitch,
              @"enableCondition": whenNotInGame,
              @"action": ^(BOOL enabled){
                  [[NSNotificationCenter defaultCenter] postNotificationName:DownloadFloatingBallSettingsDidChangeNotification object:nil];
              }
            },
            @{@"key": @"floating_ball_size",
              @"title": @"悬浮球大小",
              @"hasDetail": @YES,
              @"icon": @"slider.horizontal.3",
              @"type": self.typeSlider,
              @"min": @40,
              @"max": @100,
              @"enableCondition": ^BOOL(){ return getPrefBool(@"general.floating_ball_enabled") && whenNotInGame(); }
            },
            @{@"key": @"multi_threaded",
              @"title": @"多线程下载",
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
                              UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"请先设置自定义应用图标：设置 > 自定义应用图标" preferredStyle:UIAlertControllerStyleAlert];
                              UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil];
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
            @{@"key": @"news_url",
              @"hasDetail": @YES,
              @"icon": @"link",
              @"type": self.typeTextField,
              @"placeholder": @"https://amethyst.ct.ws/welcome",
              @"enableCondition": whenNotInGame
            },
            @{@"key": @"reset_news_url",
              @"icon": @"arrow.counterclockwise",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  setPrefObject(@"general.news_url", nil);
              }
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
            @{@"key": @"ai_crash_fix",
              @"hasDetail": @YES,
              @"icon": @"cpu",
              @"type": self.typeButton,
              @"enableCondition": whenNotInGame,
              @"action": ^void(){
                  AIFixViewController *aiFixVC = [[AIFixViewController alloc] initForSettings];
                  aiFixVC.modalPresentationStyle = UIModalPresentationOverFullScreen;

                  aiFixVC.view.alpha = 0;
                  aiFixVC.view.transform = CGAffineTransformMakeScale(0.9, 0.9);

                  [self presentViewController:aiFixVC animated:NO completion:^{
                      [UIView animateWithDuration:0.4
                                            delay:0
                           usingSpringWithDamping:0.8
                            initialSpringVelocity:0.5
                                          options:UIViewAnimationOptionCurveEaseOut
                                       animations:^{
                          aiFixVC.view.alpha = 1;
                          aiFixVC.view.transform = CGAffineTransformIdentity;
                      } completion:nil];
                  }];
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
            @{@"key": @"max_framerate",
              @"hasDetail": @YES,
              @"icon": @"timelapse",
              @"type": self.typeSwitch,
              @"enableCondition": ^BOOL(){
                  return whenNotInGame() && (UIScreen.mainScreen.maximumFramesPerSecond > 60);
              }
            },
            // 解锁帧率（关闭垂直同步）：三层联动关闭 VSync，让游戏帧率可超过屏幕刷新率。
            // 不限制 ProMotion 设备：60Hz 设备同样会被 VSync 锁在 60，也需要解锁。
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
            // Control settings
            @{@"icon": @"gamecontroller"},
            
            // --- [修改] TouchController 模组支持 ---
            @{@"key": @"mod_touch_enable",
              @"icon": @"hand.point.up.left", // SF Symbols 图标
              @"hasDetail": @YES,
              @"type": self.typeChildPane,
              @"enableCondition": whenNotInGame,
              @"canDismissWithSwipe": @NO,
              @"class": NSClassFromString(@"TouchControllerPreferencesViewController")
            },
            // ------------------------------------------

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
            @{@"key": @"reset_mouse_pointer",
                @"icon": @"arrow.counterclockwise",
                @"hasDetail": @YES,
                @"type": self.typeButton,
                @"enableCondition": whenNotInGame,
                @"action": ^void(){
                    NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
                    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                    [NSNotificationCenter.defaultCenter postNotificationName:@"MousePointerUpdated" object:nil];
                    [self showSuccessMessage:@"鼠标指针已恢复默认"];
                }
            },
            @{@"key": @"hardware_hide",
                @"icon": @"eye.slash",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            @{@"key": @"recording_hide",
                @"icon": @"eye.slash",
                @"hasDetail": @YES,
                @"type": self.typeSwitch,
            },
            
            // --- [重构] 双指呼出键盘控制 ---
            // 同样改为按钮+弹窗模式，彻底解决开关回弹问题
            @{@"key": @"two_finger_keyboard", 
              @"icon": @"keyboard", // 键盘图标
              @"hasDetail": @YES,
              @"type": self.typeButton, // 关键：改为 Button 类型
              
              @"action": ^void() {
                  // 1. 获取当前状态
                  BOOL isOn = getPrefBool(@"control.two_finger_keyboard");
                  
                  // 2. 构建弹窗
                  NSString *title = localize(@"preference.title.two_finger_keyboard", nil);
                  // 如果没有 localization，设置默认标题
                  if (!title || [title isEqualToString:@"preference.title.two_finger_keyboard"]) {
                      title = @"双指呼出键盘";
                  }
                  
                  NSString *statusMsg = isOn ? @"[✓] 当前状态: 已开启 (ON)" : @"[✗] 当前状态: 已关闭 (OFF)";
                  NSString *msg = [NSString stringWithFormat:@"%@\n\n开启后，在游戏中双指同时长按屏幕可呼出键盘。\n此功能由WeiErLiTeo制作。", statusMsg];
                  
                  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
                  
                  // 3. 根据当前状态显示不同的按钮
                  if (!isOn) {
                      [alert addAction:[UIAlertAction actionWithTitle:@"开启 (Enable)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                          // 强制开启
                          setPrefBool(@"control.two_finger_keyboard", YES);
                          [weakSelf showSuccessMessage:@"双指呼出键盘已开启"];
                          // 刷新界面
                          [weakSelf.tableView reloadData];
                      }]];
                  } else {
                      [alert addAction:[UIAlertAction actionWithTitle:@"关闭 (Disable)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                          // 强制关闭
                          setPrefBool(@"control.two_finger_keyboard", NO);
                          [weakSelf showSuccessMessage:@"双指呼出键盘已关闭"];
                          // 刷新界面
                          [weakSelf.tableView reloadData];
                      }]];
                  }
                  
                  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                  
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
                // --- [修改] 添加禁用条件 ---
                @"enableCondition": ^BOOL(){
                    // 当 TouchController 启用时，禁用此选项（返回 NO 表示禁用/变灰）
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
                    return DeviceRequiresTXMWorkaround() && whenNotInGame();
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

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(openCurseForgeAPIKeySettings)
                                                 name:@"OpenCurseForgeAPIKeySettings"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"OpenCurseForgeAPIKeySettings" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
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

#pragma mark - Memory Limit Help

- (void)showMemoryLimitHelp {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"mem_help.title", @"关于内存限制")
                         message:localize(@"mem_help.message",
                             @"iOS 18 / iOS 26 单实例内存上限约为 1440MB，玩大型整合包时可能因内存不足崩溃。\n\n"
                              "解决方法：\n"
                              "使用 GetMoreRam (LiveContainer 插件) 解除内存限制。\n"
                              "GetMoreRam 仓库：github.com/hugeBlack/GetMoreRam\n\n"
                              "安装后重启启动器即可生效。\n\n"
                              "如果不使用 LiveContainer，可尝试降低内存分配（设置 > Java > 内存分配），"
                              "但部分整合包在内存限制下可能无法正常运行。")
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
        // 通过 UIScene 获取顶层 VC（不使用 keyWindow）
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
            // 退而求其次：取任意一个 UIWindowScene
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
        
        // Tint color for icons and accessories
        cell.tintColor = [UIColor systemBlueColor];
        
        // Handle specific cell types
        NSArray *subviews = cell.contentView.subviews;
        for (UIView *subview in subviews) {
            // Style sliders
            if ([subview isKindOfClass:[UISlider class]]) {
                UISlider *slider = (UISlider *)subview;
                slider.tintColor = [UIColor systemBlueColor];
                slider.thumbTintColor = [UIColor whiteColor];
            }
            
            // Style switches
            if ([subview isKindOfClass:[UISwitch class]]) {
                UISwitch *switchControl = (UISwitch *)subview;
                switchControl.onTintColor = [UIColor systemBlueColor];
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
