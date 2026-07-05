#import "CustomControlsViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "GameMenuOverlayView.h"
#import "TrackedTextField.h"
#import "utils.h"

// 暴露 class extension 中的私有属性，供 category 使用
@interface SurfaceViewController()
@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) BOOL toggleHidden;
- (void)updateControlHiddenState:(BOOL)hide;
@end

@implementation SurfaceViewController(Navigation)

- (void)initCategory_Navigation {
    // FCL 风格：完全删除原来的右侧滑动调出菜单的方式
    // 菜单改为通过悬浮按钮（GameMenuOverlayView）触发
    // 参照 FCL GameMenu.java 和 ZL2 GameMenuSubscreen.kt 的菜单选项
    self.menuArray = @[
        @"game.menu.force_close",          // 强制关闭（FCL/ZL2 都有）
        @"game.menu.log_output",            // 日志输出（FCL switch_show_log / ZL2 game_menu_option_switch_log）
        @"game.menu.custom_controls",       // 按键布局编辑（FCL edit_mode / ZL2 control_manage_info_edit）
        @"game.menu.toggle_stats",          // FPS/内存显示开关（FCL switch_show_fps+switch_show_memory / ZL2 switch_fps+switch_memory）
        @"game.menu.toggle_controls",       // 隐藏/显示控制按钮（FCL hide_all）
        @"game.menu.toggle_virtual_mouse",  // 虚拟鼠标开关（FCL 鼠标分组 / ZL2 ControlMouse）
        @"game.menu.toggle_keyboard",       // 游戏内键盘（FCL open_quick_input / ZL2 game_menu_option_input_method）
        @"game.menu.resolution",            // 分辨率调整（FCL window_scale / ZL2 resolutionRatio）
        @"Settings"                         // 设置（启动器偏好设置）
    ];

    self.menuView = [[UITableView alloc] initWithFrame:CGRectMake(self.view.frame.size.width + 30.0, 0,
        self.view.frame.size.width * 0.3 - 36.0 * 0.7, self.view.frame.size.height)];

    //menuView.backgroundColor = [UIColor colorWithRed:240.0/255.0 green:240.0/255.0 blue:240.0/255.0 alpha:1];
    self.menuView.dataSource = self;
    self.menuView.delegate = self;
    self.menuView.hidden = YES;
    self.menuView.layer.cornerRadius = 12;
    self.menuView.scrollEnabled = YES;  // 菜单项增多，启用滚动
    self.menuView.separatorInset = UIEdgeInsetsZero;
    [self.view addSubview:self.menuView];

    // FCL/ZL2 风格悬浮按钮 + FPS/内存显示
    GameMenuOverlayView *overlay = [[GameMenuOverlayView alloc] initWithParentView:self.view];
    __weak typeof(self) weakSelf = self;
    overlay.onMenuButtonTapped = ^{
        [weakSelf toggleMenu];
    };
    self.gameMenuOverlay = overlay;
}

/// 切换菜单显示状态（悬浮按钮点击触发）
- (void)toggleMenu {
    if (self.menuView.hidden) {
        // 打开菜单
        self.menuView.hidden = NO;
        [self animateMenuScale:0.7 duration:0.3];
    } else {
        // 关闭菜单
        [self animateMenuScale:1.0 duration:0.3];
    }
}

- (void)setupCategory_Navigation {
    // FCL 风格：完全删除原来的右侧滑动调出菜单的方式
    // 不再注册 UIScreenEdgePanGestureRecognizer，菜单通过悬浮按钮触发
    // 保留空方法体，因为 SurfaceViewController.m 中通过 performSelector 调用
}

static CGPoint lastCenterPoint;
- (void)animateMenuScale:(CGFloat)scale duration:(CGFloat)duration {
    CGFloat centerX = self.rootView.bounds.size.width / 2;
    CGFloat centerY = self.rootView.bounds.size.height / 2;
    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        lastCenterPoint.x = centerX * scale;
        self.rootView.center = CGPointMake(lastCenterPoint.x, centerY);
        self.rootView.transform = CGAffineTransformScale(CGAffineTransformIdentity, scale, scale);
        self.menuView.transform = CGAffineTransformScale(CGAffineTransformIdentity, (1.1-scale)*2.5, (1.1-scale)*2.5);
        // 限制菜单高度不超过屏幕高度的 80%，避免菜单项过多时超出屏幕
        CGFloat menuHeight = MIN(self.menuView.contentSize.height, self.view.frame.size.height * 0.8);
        self.menuView.frame = CGRectMake(self.rootView.frame.size.width, self.rootView.frame.origin.y, self.menuView.frame.size.width, menuHeight);
    } completion:^(BOOL finished) {
        self.menuView.hidden = scale == 1.0;
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsStatusBarAppearanceUpdate];
    }];
}

- (void)actionForceClose {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
        message:localize(@"game.menu.confirm.force_close", nil)
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:cancelAction];

    UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
        [UIView animateWithDuration:0.4 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            self.rootView.center = CGPointMake(self.rootView.bounds.size.width/-2, self.rootView.center.y);
            self.menuView.frame = CGRectMake(self.view.frame.size.width, 0, 0, 0);
        } completion:^(BOOL finished) {
            if (fatalExitGroup == nil) {
                exit(0);
            } else {
                dispatch_group_leave(fatalExitGroup);
            }
        }];
    }];
    [alert addAction:okAction];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenCustomControls {
    [self animateMenuScale:1 duration:0.5];
    [self.ctrlView removeAllButtons];
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        if (PLProfiles.current.selectedProfile[@"defaultTouchCtrl"]) {
            // Save default to current profile
            PLProfiles.current.selectedProfile[@"defaultTouchCtrl"] = name;
        } else {
            // Save default to preferences
            setPrefObject(@"control.default_ctrl", name);
        }
    };
    vc.getDefaultCtrl = ^{
        return [PLProfiles resolveKeyForCurrentProfile:@"defaultTouchCtrl"];
    };
    [self presentViewController:vc animated:NO completion:nil];
}

- (void)actionOpenPreferences {
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    [self presentViewController:vc animated:YES completion:nil];
}

/// FCL 风格：隐藏/显示控制按钮（对应 FCL hide_all 开关）
- (void)actionToggleControls {
    self.toggleHidden = !self.toggleHidden;
    [self updateControlHiddenState:self.toggleHidden];
}

/// FCL 风格：切换虚拟鼠标（对应 FCL 鼠标分组 / ZL2 ControlMouse）
- (void)actionToggleVirtualMouse {
    if (!isGrabbing) {
        virtualMouseEnabled = !virtualMouseEnabled;
        self.mousePointerView.hidden = !virtualMouseEnabled;
        setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
}

/// FCL 风格：打开/关闭游戏内键盘（对应 FCL open_quick_input / ZL2 input_method）
- (void)actionToggleKeyboard {
    if (self.inputTextField.isFirstResponder) {
        [self.inputTextField resignFirstResponder];
        self.inputTextField.alpha = 1.0f;
    } else {
        [self.inputTextField becomeFirstResponder];
        self.inputTextField.text = @" ";
    }
}

/// FCL/ZL2 风格：调整游戏分辨率（对应 FCL window_scale / ZL2 resolutionRatio）
- (void)actionAdjustResolution {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"game.menu.resolution", nil)
                                                                   message:localize(@"game.menu.resolution.message", nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *options = @[@25, @50, @75, @100, @125, @150];
    NSInteger currentValue = (NSInteger)getPrefFloat(@"video.resolution");
    for (NSNumber *value in options) {
        NSString *title = [NSString stringWithFormat:@"%ld%%", (long)value.intValue];
        if (value.intValue == currentValue) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            setPrefFloat(@"video.resolution", value.floatValue);
            [self updateSavedResolution];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenNavigationMenu {
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    if (!self.menuView.hidden) {
        return 0;
    }
    return UIRectEdgeBottom | UIRectEdgeRight;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return self.menuView.hidden &&
        getPrefBool(@"debug.debug_hide_home_indicator");
}

- (BOOL)prefersStatusBarHidden {
    return self.menuView.hidden;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.menuArray.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }
    cell.backgroundColor = UIColor.systemFillColor;

    cell.textLabel.text = localize(self.menuArray[indexPath.row], nil);

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self didSelectMenuItem:indexPath.row];
}

- (void)didSelectMenuItem:(int)item {
    switch (item) {
        case 0: // 强制关闭
            [self actionForceClose];
            break;
        case 1: // 日志输出
            [self.logOutputView actionToggleLogOutput];
            break;
        case 2: // 按键布局编辑
            [self actionOpenCustomControls];
            break;
        case 3: // FPS/内存显示开关
            if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
                [(GameMenuOverlayView *)self.gameMenuOverlay toggleStatsLabel];
            }
            break;
        case 4: // 隐藏/显示控制按钮
            [self actionToggleControls];
            break;
        case 5: // 虚拟鼠标开关
            [self actionToggleVirtualMouse];
            break;
        case 6: // 游戏内键盘
            [self actionToggleKeyboard];
            break;
        case 7: // 分辨率调整
            [self actionAdjustResolution];
            break;
        case 8: // 设置
            [self actionOpenPreferences];
            break;
    }
}

- (void)viewWillTransitionToSize_Navigation:(CGRect)frame {
    if (self.rootView.transform.a != 0) {
        CGFloat centerX = self.rootView.bounds.size.width / 2;
        CGFloat centerY = self.rootView.bounds.size.height / 2;
        self.rootView.center = lastCenterPoint = CGPointMake(centerX * self.rootView.transform.a, centerY);
    }

    self.menuView.frame = CGRectMake(self.rootView.frame.size.width, self.rootView.frame.origin.y,
        frame.size.width*0.3 - 30.0*0.7, self.menuView.contentSize.height);
}

@end
