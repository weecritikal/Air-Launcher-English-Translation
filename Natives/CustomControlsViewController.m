#import "CustomControlsViewController.h"
#import "BackgroundManager.h"
#import "DBNumberedSlider.h"
#import "FileListViewController.h"
#import "LauncherPreferences.h"
#import "ios_uikit_bridge.h"

#import "customcontrols/ControlDrawer.h"
#import "customcontrols/ControlJoystick.h"
#import "customcontrols/CustomControlsUtils.h"

#include "glfw_keycodes.h"
#include "utils.h"

@implementation ControlHandleView
// Nothing
@end

// ============================================================================
// CustomControlsViewController
// ============================================================================
// FCL/ZL2 风格键位调整界面
//
// 主要特性：
// 1. 底部浮动工具栏：添加按钮、安全区域、加载、保存、退出
// 2. 现代化上下文菜单：使用 UIAlertController ActionSheet 替换已弃用的 UIMenuController
// 3. 按钮选择高亮：点按时显示边框高亮和调整大小手柄
// 4. 直接编辑模式：点按按钮直接打开属性编辑器（FCL 风格）
// 5. 长按按钮：显示操作菜单（删除、复制）
// 6. 拖拽移动 + 双指缩放控制区域
// 7. 自定义背景适配
// ============================================================================

@interface CustomControlsViewController () <UIGestureRecognizerDelegate, UIPopoverPresentationControllerDelegate>{
}

@property(nonatomic) NSString* currentFileName;
@property(nonatomic) CGRect selectedPoint;
@property(nonatomic) UINavigationBar* navigationBar;

// FCL/ZL2 风格底部工具栏
@property(nonatomic) UIView *bottomToolbar;
@property(nonatomic) CGFloat bottomToolbarHeight;

// 当前被选中的按钮的高亮边框视图
@property(nonatomic) CALayer *selectionHighlightLayer;

@end

@implementation CustomControlsViewController
#define isInGame [self.presentingViewController respondsToSelector:@selector(loadCustomControls)]

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.undoManager removeAllActions];

    // 修复键位调整界面顶部"一行小白条"及"布局越来越奇怪"问题。
    //
    // 之前用 edgesForExtendedLayout=UIRectEdgeNone 修复小白条，但有严重副作用：
    // (1) 改变 self.view.frame，导致 getSafeArea(self.view.frame) 在不同入口下
    //     产生不同 ctrlView frame，键位预览位置漂移（"越来越奇怪"）。
    // (2) isInGame 宏误用为"Nav 包装"判据：入口4（LauncherNavigationController
    //     模态）无 Nav 但 isInGame=NO，错误应用 edgesForExtendedLayout=None，
    //     且小白条仍存在（底层 nav bar 毛玻璃透出），导致"时有时无"。
    //
    // 正确方案：放弃 edgesForExtendedLayout，改从根源消除毛玻璃断层。
    // 小白条根因是 self.view 的 SystemThinMaterial 毛玻璃与 nav bar 的 SystemMaterial
    // 毛玻璃在 nav bar 底边叠加形成不透明度断层。在有 UINavigationController 包装时，
    // 让 nav bar 不透明（translucent=NO），断层自然消失，无需改变 self.view.frame。
    // 无 Nav 包装的游戏内 modal 场景保持原样（无 nav bar 无断层）。
    if (self.navigationController != nil) {
        self.navigationController.navigationBar.translucent = NO;
    }

    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    isControlModifiable = YES;

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];

    UIEdgeInsets insets = UIApplication.sharedApplication.windows.firstObject.safeAreaInsets;

    UILabel *guideLabel = [[UILabel alloc] initWithFrame:self.view.frame];
    guideLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    guideLabel.numberOfLines = 0;
    guideLabel.textAlignment = NSTextAlignmentCenter;
    guideLabel.textColor = UIColor.whiteColor;
    guideLabel.text = localize(@"custom_controls.hint", nil);
    [self.view addSubview:guideLabel];

    self.ctrlView = [[ControlLayout alloc] initWithFrame:getSafeArea(self.view.frame)];
    self.ctrlView.layer.borderColor = UIColor.labelColor.CGColor;
    [self.view addSubview:self.ctrlView];

    // 选择高亮图层：用于在选中的按钮周围显示边框
    _selectionHighlightLayer = [CALayer layer];
    _selectionHighlightLayer.borderWidth = 2.0;
    _selectionHighlightLayer.borderColor = [UIColor systemBlueColor].CGColor;
    _selectionHighlightLayer.cornerRadius = 4.0;
    _selectionHighlightLayer.hidden = YES;
    [self.ctrlView.layer addSublayer:_selectionHighlightLayer];

    // 顶部工具栏高度（40）+ 上下间距（8+8）= 56pt。
    // ctrlView 初始 frame 顶部需预留此高度，避免工具栏遮挡控制区上方的按钮导致无法调整。
    // viewDidLayoutSubviews 中也会应用相同的顶部偏移。
    // 注意：此偏移仅在默认 safeArea 模式（navigationBar.hidden=YES）下生效，
    // 用户切换到 None/Default safeArea 模式时 ctrlView.frame 会被 changeSafeAreaSelection: 重置。

    // Prepare the navigation bar for safe area customization
    UINavigationItem *navigationItem = [[UINavigationItem alloc] init];
    UISegmentedControl *segmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"None", @"Default", @"Custom"]];
    [segmentedControl addTarget:self action:@selector(changeSafeAreaSelection:) forControlEvents:UIControlEventValueChanged];
    [segmentedControl setEnabled:(insets.left+insets.right)>0 forSegmentAtIndex:1];
    [self loadSafeAreaSelectionFor:segmentedControl];
    navigationItem.titleView = segmentedControl;
    navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(actionMenuSafeAreaCancel)];
    navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionMenuSafeAreaDone)];
    self.navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 44.0)];
    self.navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.navigationBar.hidden = YES;
    self.navigationBar.items = @[navigationItem];
    self.navigationBar.translucent = YES;
    [self.view addSubview:self.navigationBar];

    CGFloat buttonScale = getPrefFloat(@"control.button_scale") / 100.0;

    self.resizeView = [[ControlHandleView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    self.resizeView.backgroundColor = self.view.tintColor;
    self.resizeView.layer.cornerRadius = self.resizeView.frame.size.width / 2;
    self.resizeView.clipsToBounds = YES;
    self.resizeView.hidden = YES;
    [self.resizeView addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onTouch:)]];
    [self.view addSubview:self.resizeView];

    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panControlArea:)];
    panGesture.delegate = self;
    panGesture.maximumNumberOfTouches = 1;
    [self.ctrlView addGestureRecognizer:panGesture];

    UIPinchGestureRecognizer *pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinchControlArea:)];
    pinchGesture.delegate = self;
    [self.ctrlView addGestureRecognizer:pinchGesture];

    // FCL/ZL2 风格：不再使用长按手势弹出 UIMenuController，改为底部工具栏处理全局操作。
    // 按钮的点按直接打开编辑器，长按显示操作菜单（删除等）。
    // 底部工具栏提供所有全局操作：添加、安全区域、加载、保存、退出。

    NSString *fileName = self.getDefaultCtrl();
    self.currentFileName = [fileName stringByDeletingPathExtension];
    [self loadControlFile:fileName];

    // FCL/ZL2 风格：底部浮动工具栏
    [self setupBottomToolbar];
}

/// 设置底部浮动工具栏（FCL/ZL2 风格）
///
/// 工具栏包含 5 个按钮：
/// 1. 添加 — 弹出 ActionSheet 选择添加按钮/抽屉/摇杆
/// 2. 安全区域 — 切换安全区域编辑模式
/// 3. 加载 — 从文件列表加载布局
/// 4. 保存 — 保存当前布局
/// 5. 退出 — 退出键位编辑
///
/// 工具栏样式：
/// - 半透明深色背景，圆角
/// - 浮动在底部安全区域上方
/// - 每个按钮包含 SF Symbol 图标 + 文字标签
- (void)setupBottomToolbar {
    _bottomToolbarHeight = 64.0;

    _bottomToolbar = [[UIView alloc] init];
    _bottomToolbar.translatesAutoresizingMaskIntoConstraints = NO;
    _bottomToolbar.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.88];
    _bottomToolbar.layer.cornerRadius = 16.0;
    _bottomToolbar.layer.masksToBounds = YES;
    _bottomToolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_bottomToolbar];

    // 创建工具栏按钮
    UIButton *addButton = [self createToolbarButtonWithTitle:localize(@"custom_controls.control_menu.add_button", nil)
                                                       image:@"plus.circle.fill"
                                                     action:@selector(showAddActionSheet)
                                                  tintColor:[UIColor systemGreenColor]];

    UIButton *safeAreaButton = [self createToolbarButtonWithTitle:localize(@"custom_controls.control_menu.safe_area", nil)
                                                            image:@"rectangle.dashed"
                                                          action:@selector(actionMenuSafeArea)
                                                       tintColor:[UIColor systemOrangeColor]];

    UIButton *loadButton = [self createToolbarButtonWithTitle:localize(@"custom_controls.control_menu.load", nil)
                                                        image:@"folder.fill"
                                                      action:@selector(actionMenuLoad)
                                                   tintColor:[UIColor systemBlueColor]];

    UIButton *saveButton = [self createToolbarButtonWithTitle:localize(@"custom_controls.control_menu.save", nil)
                                                        image:@"tray.and.arrow.down.fill"
                                                      action:@selector(actionMenuSave)
                                                   tintColor:[UIColor systemBlueColor]];

    UIButton *exitButton = [self createToolbarButtonWithTitle:localize(@"custom_controls.control_menu.exit", nil)
                                                        image:@"xmark.circle.fill"
                                                      action:@selector(actionMenuExit)
                                                   tintColor:[UIColor systemRedColor]];

    [_bottomToolbar addSubview:addButton];
    [_bottomToolbar addSubview:safeAreaButton];
    [_bottomToolbar addSubview:loadButton];
    [_bottomToolbar addSubview:saveButton];
    [_bottomToolbar addSubview:exitButton];

    // 使用 auto-layout 布局工具栏和按钮
    [NSLayoutConstraint activateConstraints:@[
        // 工具栏位置：底部浮动，左右留边距
        [_bottomToolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_bottomToolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_bottomToolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [_bottomToolbar.heightAnchor constraintEqualToConstant:_bottomToolbarHeight],

        // 按钮等宽分布
        [addButton.leadingAnchor constraintEqualToAnchor:_bottomToolbar.leadingAnchor constant:4],
        [addButton.topAnchor constraintEqualToAnchor:_bottomToolbar.topAnchor constant:4],
        [addButton.bottomAnchor constraintEqualToAnchor:_bottomToolbar.bottomAnchor constant:-4],

        [safeAreaButton.leadingAnchor constraintEqualToAnchor:addButton.trailingAnchor constant:2],
        [safeAreaButton.topAnchor constraintEqualToAnchor:_bottomToolbar.topAnchor constant:4],
        [safeAreaButton.bottomAnchor constraintEqualToAnchor:_bottomToolbar.bottomAnchor constant:-4],

        [loadButton.leadingAnchor constraintEqualToAnchor:safeAreaButton.trailingAnchor constant:2],
        [loadButton.topAnchor constraintEqualToAnchor:_bottomToolbar.topAnchor constant:4],
        [loadButton.bottomAnchor constraintEqualToAnchor:_bottomToolbar.bottomAnchor constant:-4],

        [saveButton.leadingAnchor constraintEqualToAnchor:loadButton.trailingAnchor constant:2],
        [saveButton.topAnchor constraintEqualToAnchor:_bottomToolbar.topAnchor constant:4],
        [saveButton.bottomAnchor constraintEqualToAnchor:_bottomToolbar.bottomAnchor constant:-4],

        [exitButton.leadingAnchor constraintEqualToAnchor:saveButton.trailingAnchor constant:2],
        [exitButton.trailingAnchor constraintEqualToAnchor:_bottomToolbar.trailingAnchor constant:-4],
        [exitButton.topAnchor constraintEqualToAnchor:_bottomToolbar.topAnchor constant:4],
        [exitButton.bottomAnchor constraintEqualToAnchor:_bottomToolbar.bottomAnchor constant:-4],

        // 5 个按钮等宽
        [safeAreaButton.widthAnchor constraintEqualToAnchor:addButton.widthAnchor],
        [loadButton.widthAnchor constraintEqualToAnchor:addButton.widthAnchor],
        [saveButton.widthAnchor constraintEqualToAnchor:addButton.widthAnchor],
        [exitButton.widthAnchor constraintEqualToAnchor:addButton.widthAnchor],
    ]];
}

/// 创建工具栏按钮（FCL/ZL2 风格：SF Symbol 图标 + 文字标签，纵向排列）
- (UIButton *)createToolbarButtonWithTitle:(NSString *)title
                                     image:(NSString *)systemImageName
                                   action:(SEL)action
                                tintColor:(UIColor *)tintColor {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tintColor = tintColor;

    // 图标
    UIImage *icon = [UIImage systemImageNamed:systemImageName];
    [button setImage:icon forState:UIControlStateNormal];

    // 文字
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.5;
    button.titleLabel.lineBreakMode = NSLineBreakByClipping;

    // 纵向排列图标和文字
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    [button setContentEdgeInsets:UIEdgeInsetsMake(6, 4, 6, 4)];
    [button setTitleEdgeInsets:UIEdgeInsetsMake(0, -icon.size.width, -18, 0)];
    [button setImageEdgeInsets:UIEdgeInsetsMake(-8, 0, 0, -button.titleLabel.intrinsicContentSize.width)];

    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    return button;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    isControlModifiable = NO;
    if (isInGame) {
        [self.presentingViewController performSelector:@selector(loadCustomControls)];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)sender shouldReceiveTouch:(UITouch *)touch {
    return sender.view != self.view || !CGRectContainsPoint(self.resizeView.frame, [sender locationInView:self.view]);
}

- (void)panControlArea:(UIPanGestureRecognizer *)sender {
    static CGPoint previous;
    if (sender.state == UIGestureRecognizerStateBegan) {
        [self setButtonMenuVisibleForView:nil];
        self.resizeView.hidden = self.ctrlView.layer.borderWidth == 0;
        self.resizeView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner;
        previous = [sender locationInView:self.view];
        return;
    } else if (self.navigationBar.hidden) {
        return;
    }

    CGPoint current = [sender locationInView:self.view];

    CGRect rect = self.ctrlView.frame;
    rect.origin.x = clamp(rect.origin.x + current.x - previous.x, 0, self.view.frame.size.width - rect.size.width);
    rect.origin.y = clamp(rect.origin.y + current.y - previous.y, 0, self.view.frame.size.height - rect.size.height);
    self.ctrlView.frame = rect;

    self.resizeView.frame = CGRectMake(CGRectGetMaxX(self.ctrlView.frame) - self.resizeView.frame.size.width, CGRectGetMaxY(self.ctrlView.frame) - self.resizeView.frame.size.height, self.resizeView.frame.size.width, self.resizeView.frame.size.height);

    previous = current;
}

- (void)pinchControlArea:(UIPinchGestureRecognizer *)sender {
    if (sender.numberOfTouches < 2 || self.navigationBar.hidden) {
        return;
    }

    static CGPoint previous;
    CGPoint current = [sender locationInView:self.view];
    if (sender.state == UIGestureRecognizerStateBegan) {
        previous = current;
        return;
    }

    self.ctrlView.frame = CGRectMake(
        clamp(self.ctrlView.frame.origin.x + current.x - previous.x, 0, self.view.frame.size.width - self.ctrlView.frame.size.width),
        clamp(self.ctrlView.frame.origin.y + current.y - previous.y, 0, self.view.frame.size.height - self.ctrlView.frame.size.height),
        clamp(self.ctrlView.frame.size.width * sender.scale, self.view.frame.size.width / 2, self.view.frame.size.width),
        clamp(self.ctrlView.frame.size.height * sender.scale, self.view.frame.size.height / 2, self.view.frame.size.height)
    );
    self.resizeView.frame = CGRectMake(CGRectGetMaxX(self.ctrlView.frame), CGRectGetMaxY(self.ctrlView.frame), self.resizeView.frame.size.width, self.resizeView.frame.size.height);

    previous = current;

    sender.scale = 1.0;
}

- (void)loadControlFile:(NSString *)file {
    [self.ctrlView loadControlFile:file];
    for (ControlButton *button in self.ctrlView.subviews) {
        [self setupButtonGestures:button];
    }
}

/// 为按钮设置手势识别器
///
/// FCL/ZL2 风格：
/// - 点按 → 直接打开属性编辑器
/// - 长按 → 显示操作菜单（删除、复制）
/// - 拖拽 → 移动按钮位置
- (void)setupButtonGestures:(ControlButton *)button {
    // 点按：打开属性编辑器（FCL 风格，直接编辑而非先弹出菜单）
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onButtonTapped:)];
    tapGesture.numberOfTapsRequired = 1;
    [button addGestureRecognizer:tapGesture];

    // 长按：显示操作菜单（删除等）
    UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onButtonLongPressed:)];
    longPressGesture.minimumPressDuration = 0.5;
    [button addGestureRecognizer:longPressGesture];

    // 拖拽：移动按钮
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onTouch:)];
    [button addGestureRecognizer:panGesture];
}

- (void)viewDidLayoutSubviews {
    if (self.navigationBar.hidden) {
        // 默认 safeArea 模式：ctrlView 需在顶部工具栏和底部浮动工具栏之间。
        //
        // 顶部预留：工具栏 40pt + 上间距 8 + 下间距 8 = 56pt
        //
        // 底部预留：底部浮动工具栏通过 Auto Layout 固定在 safeAreaLayoutGuide.bottomAnchor
        // 上方 8pt 处，工具栏高度 64pt。所以工具栏顶部距 safeArea 底部 = 8 + 64 = 72pt。
        // 但 getSafeArea() 返回的 frame 的 top/bottom 偏移为 0（只有左右偏移），
        // 因此 safeFrame 底部 = self.view.frame 底部（含 Home Indicator 区域）。
        // 为避免 ctrlView 与工具栏重叠，需从 safeFrame 底部减去：
        //   Home Indicator 高度 + 工具栏下间距 8 + 工具栏高度 64 + 上间距 8
        // 由于无法预知 Home Indicator 精确高度，直接用 self.view.safeAreaInsets.bottom
        // 获取当前设备的 Home Indicator 高度。
        CGFloat topInset = 56.0;
        CGFloat homeIndicator = self.view.safeAreaInsets.bottom;
        CGFloat bottomInset = homeIndicator + 8.0 + _bottomToolbarHeight + 8.0;

        CGRect safeFrame = getSafeArea(self.view.frame);
        safeFrame.origin.y += topInset;
        safeFrame.size.height -= topInset + bottomInset;
        self.ctrlView.frame = safeFrame;
    }

    // Update dynamic position for each view
    for (UIView *view in self.ctrlView.subviews) {
        if ([view isKindOfClass:[ControlButton class]]) {
            [(ControlButton *)view update];
        }
    }

    // 更新选择高亮的位置
    [self updateSelectionHighlight];
}

- (void)changeSafeAreaSelection:(UISegmentedControl *)sender {
    switch (sender.selectedSegmentIndex) {
        case 0:
            self.ctrlView.frame = self.view.frame;
            break;
        case 1:
            self.ctrlView.frame = UIEdgeInsetsInsetRect(self.view.frame, getDefaultSafeArea());
            break;
        case 2:
            self.ctrlView.frame = getSafeArea(self.view.frame);
            break;
    }
    self.ctrlView.userInteractionEnabled = sender.selectedSegmentIndex == 2;
    self.resizeView.hidden = sender.selectedSegmentIndex != 2;
}

- (void)loadSafeAreaSelectionFor:(UISegmentedControl *)control {
    if (CGRectEqualToRect(self.ctrlView.frame, UIScreen.mainScreen.bounds)) {
        control.selectedSegmentIndex = 0;
    } else {
        control.selectedSegmentIndex = !CGRectEqualToRect(self.ctrlView.frame, UIEdgeInsetsInsetRect(self.view.frame, getDefaultSafeArea())) + 1;
    }
}

#pragma mark - FCL/ZL2 风格按钮交互

/// 按钮点按事件：直接打开属性编辑器（FCL 风格）
- (void)onButtonTapped:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateEnded) return;

    self.currentGesture = sender;

    // 显示选择高亮
    [self setButtonMenuVisibleForView:sender.view];

    // 直接打开编辑器
    [self actionMenuBtnEdit];
}

/// 按钮长按事件：显示操作菜单（删除、添加子按钮等）
- (void)onButtonLongPressed:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;

    self.currentGesture = sender;
    [self setButtonMenuVisibleForView:sender.view];

    [self showButtonActionSheet];
}

/// 显示"添加"操作菜单（FCL/ZL2 风格底部 ActionSheet）
- (void)showAddActionSheet {
    // 设置添加位置为控制区域中心
    CGPoint center = CGPointMake(self.ctrlView.frame.size.width / 2, self.ctrlView.frame.size.height / 2);
    self.selectedPoint = CGRectMake(center.x, center.y, 1.0, 1.0);

    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:nil
                                                                         message:nil
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];

    [actionSheet addAction:[UIAlertAction actionWithTitle:localize(@"custom_controls.control_menu.add_button", nil)
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *action) {
        [self actionMenuAddButton];
    }]];

    [actionSheet addAction:[UIAlertAction actionWithTitle:localize(@"custom_controls.control_menu.add_drawer", nil)
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *action) {
        [self actionMenuAddDrawer];
    }]];

    [actionSheet addAction:[UIAlertAction actionWithTitle:localize(@"custom_controls.control_menu.add_joystick", nil)
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *action) {
        [self actionMenuAddJoystick];
    }]];

    [actionSheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                                    style:UIAlertActionStyleCancel
                                                  handler:nil]];

    // iPad 适配：使用 popover
    if (actionSheet.popoverPresentationController) {
        actionSheet.popoverPresentationController.sourceView = self.view;
        actionSheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height - _bottomToolbarHeight, 1, 1);
        actionSheet.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionDown;
    }

    [self presentViewController:actionSheet animated:YES completion:nil];
}

/// 显示按钮操作菜单（删除、编辑等）
- (void)showButtonActionSheet {
    ControlButton *button = (ControlButton *)self.currentGesture.view;
    if (!button) return;

    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:nil
                                                                         message:nil
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];

    [actionSheet addAction:[UIAlertAction actionWithTitle:localize(@"Edit", nil)
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *action) {
        [self actionMenuBtnEdit];
    }]];

    // 抽屉类型可以添加子按钮
    if ([button isKindOfClass:[ControlDrawer class]]) {
        [actionSheet addAction:[UIAlertAction actionWithTitle:localize(@"custom_controls.button_menu.add_subbutton", nil)
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *action) {
            [self actionMenuAddSubButton];
        }]];
    }

    [actionSheet addAction:[UIAlertAction actionWithTitle:localize(@"Remove", nil)
                                                    style:UIAlertActionStyleDestructive
                                                  handler:^(UIAlertAction *action) {
        [self actionMenuBtnDelete];
    }]];

    [actionSheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                                    style:UIAlertActionStyleCancel
                                                  handler:nil]];

    // iPad 适配：使用 popover
    if (actionSheet.popoverPresentationController) {
        actionSheet.popoverPresentationController.sourceView = button;
        actionSheet.popoverPresentationController.sourceRect = button.bounds;
        actionSheet.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }

    [self presentViewController:actionSheet animated:YES completion:nil];
}

#pragma mark - 操作菜单方法

- (void)actionMenuExit {
    if (self.undoManager.canUndo) {
        [self actionMenuSaveWithExit:YES];
        return;
    }
    [self dismissViewControllerAnimated:!isInGame completion:nil];
}

- (void)actionMenuSaveWithExit:(BOOL)exit {
    UIAlertController *controller = [UIAlertController alertControllerWithTitle: localize(@"custom_controls.control_menu.save", nil)
        message:exit?localize(@"custom_controls.control_menu.exit.warn", nil):@""
        preferredStyle:UIAlertControllerStyleAlert];
    [controller addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Name";
        textField.text = self.currentFileName;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.borderStyle = UITextBorderStyleRoundedRect;
    }];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray *textFields = controller.textFields;
        UITextField *field = textFields[0];
        NSError *error;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:self.ctrlView.layoutDictionary options:NSJSONWritingPrettyPrinted error:&error];
        if (jsonData == nil) {
            showDialog(localize(@"custom_controls.control_menu.save.error.json", nil), error.localizedDescription);
            return;
        }
        BOOL success = [jsonData writeToFile:[NSString stringWithFormat:@"%s/controlmap/%@.json", getenv("POJAV_HOME"), field.text] options:NSDataWritingAtomic error:&error];
        if (!success) {
            showDialog(localize(@"custom_controls.control_menu.save.error.write", nil), error.localizedDescription);
            return;
        }

        if (exit) {
            [self dismissViewControllerAnimated:!isInGame completion:nil];
        }

        self.currentFileName = field.text;
        [self.undoManager removeAllActions];
    }]];
    if (exit) {
        [controller addAction:[UIAlertAction actionWithTitle:localize(@"custom_controls.control_menu.discard_changes", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self dismissViewControllerAnimated:!isInGame completion:nil];
        }]];
    }
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)actionMenuSave {
    [self actionMenuSaveWithExit:NO];
}

- (void)actionOpenFilePicker:(void (^)(NSString *name))handler {
    FileListViewController *vc = [[FileListViewController alloc] init];
    vc.listPath = [NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")];
    vc.whenItemSelected = handler;
    vc.modalPresentationStyle = UIModalPresentationPopover;
    vc.preferredContentSize = CGSizeMake(350, 250);

    UIPopoverPresentationController *popoverController = [vc popoverPresentationController];
    popoverController.sourceView = self.view;
    popoverController.sourceRect = self.selectedPoint;
    popoverController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    popoverController.delegate = self;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)actionMenuLoad {
    [self actionOpenFilePicker:^void(NSString* name) {
        self.currentFileName = name;
        name = [NSString stringWithFormat:@"%@.json", name];
        [self loadControlFile:name];
        self.setDefaultCtrl(name);
    }];
}

- (void)actionMenuSafeArea {
    // Set _UIBarBackground alpha to 0.8
    self.navigationBar.subviews[0].alpha = 0.8;

    BOOL isCustom = ((UISegmentedControl *)self.navigationBar.items[0].titleView).selectedSegmentIndex == 2;

    self.navigationBar.hidden = !self.navigationBar.hidden;
    self.ctrlView.layer.borderWidth = self.navigationBar.hidden ? 0 : 2;
    self.ctrlView.userInteractionEnabled = self.navigationBar.hidden || isCustom;
    self.resizeView.frame = CGRectMake(CGRectGetMaxX(self.ctrlView.frame), CGRectGetMaxY(self.ctrlView.frame), self.resizeView.frame.size.width, self.resizeView.frame.size.height);
    self.resizeView.hidden = self.navigationBar.hidden || !isCustom;
    self.resizeView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner;
    self.resizeView.target = nil;

    // 隐藏底部工具栏（安全区域编辑模式下）
    self.bottomToolbar.hidden = !self.navigationBar.hidden ? NO : YES;
}

- (void)actionMenuSafeAreaCancel {
    self.ctrlView.frame = getSafeArea(self.view.frame);
    [self actionMenuSafeArea];
}

- (void)actionMenuSafeAreaDone {
    setSafeArea(self.view.frame.size, self.ctrlView.frame);
    [self actionMenuSafeArea];
}

- (void)actionMenuAddButtonWithDrawer:(ControlDrawer *)drawer {
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"name"] = @"New";
    dict[@"keycodes"] = @[@0, @0, @0, @0].mutableCopy;
    dict[@"dynamicX"] = @"0";
    dict[@"dynamicY"] = @"0";
    dict[@"width"] = @(50.0);
    dict[@"height"] = @(50.0);
    dict[@"opacity"] = @(1);
    dict[@"cornerRadius"] = @(0);
    dict[@"bgColor"] = @(0x4d000000);
    ControlButton *button;
    if (drawer == nil) {
        dict[@"displayInGame"] = dict[@"displayInMenu"] = @YES;
        button = [ControlButton buttonWithProperties:dict];
        [self doAddButton:button atIndex:@([self.ctrlView.layoutDictionary[@"mControlDataList"] count])];
        [button snapAndAlignX:self.selectedPoint.origin.x-25.0 Y:self.selectedPoint.origin.y-25.0];
        [button update];
    } else {
        button = [ControlSubButton buttonWithProperties:dict];
        ((ControlSubButton *)button).parentDrawer = drawer;
        [self doAddButton:button atIndex:@(drawer.buttons.count)];
        [button snapAndAlignX:self.selectedPoint.origin.x-25.0 Y:self.selectedPoint.origin.y-25.0];
        [button update];
        [drawer syncButtons];
    }

    [self setupButtonGestures:button];
}

- (void)actionMenuAddButton {
    // FCL/ZL2 风格：从工具栏添加时，位置设为控制区域中心
    if (self.selectedPoint.size.width <= 1.0) {
        CGPoint center = CGPointMake(self.ctrlView.frame.size.width / 2, self.ctrlView.frame.size.height / 2);
        self.selectedPoint = CGRectMake(center.x, center.y, 1.0, 1.0);
    }
    [self actionMenuAddButtonWithDrawer:nil];
}

- (void)actionMenuAddDrawer {
    // FCL/ZL2 风格：从工具栏添加时，位置设为控制区域中心
    if (self.selectedPoint.size.width <= 1.0) {
        CGPoint center = CGPointMake(self.ctrlView.frame.size.width / 2, self.ctrlView.frame.size.height / 2);
        self.selectedPoint = CGRectMake(center.x, center.y, 1.0, 1.0);
    }

    NSMutableDictionary *properties = [[NSMutableDictionary alloc] init];
    properties[@"name"] = @"New";
    properties[@"dynamicX"] = @"0";
    properties[@"dynamicY"] = @"0";
    properties[@"width"] = @(50.0);
    properties[@"height"] = @(50.0);
    properties[@"opacity"] = @(1);
    properties[@"cornerRadius"] = @(0);
    properties[@"bgColor"] = @(0x4d000000);
    properties[@"displayInGame"] = properties[@"displayInMenu"] = @YES;
    NSMutableDictionary *data = [[NSMutableDictionary alloc] init];
    data[@"orientation"] = @"FREE";
    data[@"properties"] = properties;
    data[@"buttonProperties"] = [[NSMutableArray alloc] init];
    ControlDrawer *button = [ControlDrawer buttonWithData:data];
    [self doAddButton:button atIndex:@([self.ctrlView.layoutDictionary[@"mDrawerDataList"] count])];
    [button snapAndAlignX:self.selectedPoint.origin.x-25.0 Y:self.selectedPoint.origin.y-25.0];
    [button update];

    [self setupButtonGestures:button];
}

- (void)actionMenuAddSubButton {
    self.selectedPoint = CGRectMake(self.currentGesture.view.frame.origin.x + 25.0, self.currentGesture.view.frame.origin.y + 25.0, 1.0, 1.0);
    [self actionMenuAddButtonWithDrawer:(ControlDrawer *)self.currentGesture.view];
}

- (void)actionMenuAddJoystick {
    // FCL/ZL2 风格：从工具栏添加时，位置设为控制区域中心
    if (self.selectedPoint.size.width <= 1.0) {
        CGPoint center = CGPointMake(self.ctrlView.frame.size.width / 2, self.ctrlView.frame.size.height / 2);
        self.selectedPoint = CGRectMake(center.x, center.y, 1.0, 1.0);
    }

    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"dynamicX"] = @"0";
    dict[@"dynamicY"] = @"0";
    dict[@"width"] = @(100.0);
    dict[@"height"] = @(100.0);
    dict[@"opacity"] = @(1);
    dict[@"bgColor"] = @(0x4d000000);
    dict[@"strokeColor"] = @(0xffffffff);
    dict[@"displayInGame"] = dict[@"displayInMenu"] = @YES;
    dict[@"forwardLock"] = @NO;
    ControlJoystick *button = [ControlJoystick buttonWithProperties:dict];
    [self doAddButton:button atIndex:@([self.ctrlView.layoutDictionary[@"mJoystickDataList"] count])];
    [button snapAndAlignX:self.selectedPoint.origin.x-25.0 Y:self.selectedPoint.origin.y-25.0];
    [button update];
    [self setupButtonGestures:button];
}

- (void)actionMenuBtnCopy {
    // copy
}

- (void)actionMenuBtnDelete {
    self.resizeView.hidden = YES;
    self.selectionHighlightLayer.hidden = YES;
    ControlButton *button = (ControlButton *)self.currentGesture.view;
    [self doRemoveButton:button];
}

- (void)actionMenuBtnEdit {
    CCMenuViewController *vc = [[CCMenuViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    vc.preferredContentSize = self.view.frame.size;
    if (![self.currentGesture isKindOfClass:[UILongPressGestureRecognizer class]]) {
        vc.targetButton = (ControlButton *)self.currentGesture.view;
    }
    [self presentViewController:vc animated:YES completion:nil];
}

/// 设置按钮选中状态（FCL/ZL2 风格选择高亮）
///
/// 显示选择高亮边框和调整大小手柄。
/// 替换了原来的 UIMenuController 逻辑。
- (void)setButtonMenuVisibleForView:(UIView *)view {
    self.resizeView.layer.maskedCorners = kCALayerMaxXMaxYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner;
    self.resizeView.target = (ControlButton *)view;

    if (view) {
        // 显示选择高亮
        self.selectionHighlightLayer.hidden = NO;
        self.selectionHighlightLayer.frame = view.bounds;

        // 显示调整大小手柄
        CGPoint origin = [self.ctrlView convertPoint:view.frame.origin toView:self.view];
        self.resizeView.frame = CGRectMake(origin.x + view.frame.size.width, origin.y + view.frame.size.height, self.resizeView.frame.size.width, self.resizeView.frame.size.height);
        self.resizeView.hidden = NO;
    } else {
        // 隐藏选择高亮和调整大小手柄
        self.selectionHighlightLayer.hidden = YES;
        self.resizeView.hidden = YES;
    }
}

/// 更新选择高亮的位置（在 viewDidLayoutSubviews 中调用）
- (void)updateSelectionHighlight {
    if (!self.selectionHighlightLayer.hidden && self.resizeView.target) {
        self.selectionHighlightLayer.frame = self.resizeView.target.bounds;
    }
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return getPrefBool(@"debug.debug_hide_home_indicator");
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)onTouchAreaHandleView:(UIPanGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateChanged) return;
    CGPoint translation = [sender translationInView:sender.view];

    // Perform safe area resize
    CGRect targetFrame = self.ctrlView.frame;
    targetFrame.size.width += translation.x;
    targetFrame.size.height += translation.y;
    self.ctrlView.frame = targetFrame;

    // Keep track of handle view location
    targetFrame = self.resizeView.frame;
    targetFrame.origin.x = CGRectGetMaxX(self.ctrlView.frame) - targetFrame.size.width;
    targetFrame.origin.y = CGRectGetMaxY(self.ctrlView.frame) - targetFrame.size.height;
    self.resizeView.frame = targetFrame;

    [sender setTranslation:CGPointZero inView:sender.view];
}

- (void)onTouchButtonHandleView:(UIPanGestureRecognizer *)sender {
    static CGRect origButtonRect;

    CGPoint translation = [sender translationInView:sender.view];
    CGFloat width, height;

    switch (sender.state) {
        case UIGestureRecognizerStateBegan: {
            // Save old button frame
            origButtonRect = self.resizeView.target.frame;
        } break;
        case UIGestureRecognizerStateChanged: {
            // Perform button resize
            width = MAX(10, [self.resizeView.target.properties[@"width"] floatValue] + translation.x);
            height = MAX(10, [self.resizeView.target.properties[@"height"] floatValue] + translation.y);
            self.resizeView.target.properties[@"width"] = @(width);
            self.resizeView.target.properties[@"height"] = @(height);
            [self.resizeView.target update];
            [sender setTranslation:CGPointZero inView:sender.view];

            // Keep track of handle view location
            self.resizeView.frame = CGRectMake(CGRectGetMaxX(self.resizeView.target.frame), CGRectGetMaxY(self.resizeView.target.frame),
                self.resizeView.frame.size.width, self.resizeView.frame.size.height);

            // 更新选择高亮
            self.selectionHighlightLayer.frame = self.resizeView.target.bounds;
        } break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateEnded: {
            [self doMoveOrResizeButton:self.resizeView.target from:origButtonRect to:self.resizeView.target.frame];
        } break;
        default: break;
    }
}

- (void)onTouch:(UIPanGestureRecognizer *)sender {
    static CGRect origButtonRect;

    if ([sender.view isKindOfClass:ControlHandleView.class]) {
        if (self.resizeView.target == nil) {
            [self onTouchAreaHandleView:sender];
        } else if ([self.resizeView.target isKindOfClass:ControlButton.class]) {
            [self onTouchButtonHandleView:sender];
        }
        return;
    }

    CGPoint translation = [sender translationInView:sender.view];

    ControlButton *button = (ControlButton *)sender.view;
    if ([button isKindOfClass:ControlSubButton.class] &&
        ![((ControlSubButton *)button).parentDrawer.drawerData[@"orientation"] isEqualToString:@"FREE"]) return;

    switch (sender.state) {
        case UIGestureRecognizerStateBegan: {
            origButtonRect = button.frame;
            [self setButtonMenuVisibleForView:button];
        } break;
        case UIGestureRecognizerStateChanged: {
            //button.center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
            [button snapAndAlignX:clamp(button.frame.origin.x+translation.x, 0, self.ctrlView.frame.size.width - button.frame.size.width) Y:clamp(button.frame.origin.y+translation.y, 0, self.ctrlView.frame.size.height - button.frame.size.height)];
            [sender setTranslation:CGPointZero inView:button];
            self.resizeView.frame = CGRectMake(CGRectGetMaxX(button.frame), CGRectGetMaxY(button.frame), self.resizeView.frame.size.width, self.resizeView.frame.size.height);

            // 更新选择高亮
            self.selectionHighlightLayer.frame = button.bounds;
        } break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateEnded: {
            [self doMoveOrResizeButton:button from:origButtonRect to:button.frame];
        } break;
        default: break;
    }
}

#pragma mark - UIPopoverPresentationControllerDelegate
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 并重新对 self.view 应用视觉效果，确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[BackgroundManager sharedManager] applyEffectToView:self.view];
    });
}

@end

// ============================================================================
// CCMenuViewController — 按钮属性编辑器
// ============================================================================
// FCL/ZL2 风格卡片式属性编辑面板
//
// 改进：
// 1. 使用 auto-layout 布局卡片容器
// 2. 分区显示属性（基础、外观、行为）
// 3. 卡片式圆角容器，更好的视觉层次
// 4. 保持所有现有属性编辑功能
// ============================================================================

#define TAG_SLIDER_STROKEWIDTH 10

#define VISIBILITY_ALWAYS 0
#define VISIBILITY_IN_GAME 1
#define VISIBILITY_IN_MENU 2

CGFloat currentY;

@interface CCMenuViewController () <UIPickerViewDataSource, UIPickerViewDelegate> {
}

@property(nonatomic) NSMutableArray *keyCodeMap, *keyValueMap;
@property(nonatomic) NSArray *arrOrientation, *arrVisibility;
@property(nonatomic) NSMutableDictionary* oldProperties;

@property UITextField *activeField;
@property(nonatomic) UIScrollView* scrollView;
@property(nonatomic) UITextField *editName, *editSizeWidth, *editSizeHeight;
@property(nonatomic) UITextView* editMapping;
@property(nonatomic) UIPickerView* pickerMapping;
@property(nonatomic) UISegmentedControl *ctrlOrientation, *ctrlVisibility;
@property(nonatomic) UISwitch *switchFwdLock, *switchToggleable, *switchMousePass, *switchSwipeable;
@property(nonatomic) UIColorWell *colorWellBackground, *colorWellStroke;
@property(nonatomic) DBNumberedSlider *sliderStrokeWidth, *sliderCornerRadius, *sliderOpacity;

@end

@implementation CCMenuViewController

- (UILabel*)addLabel:(NSString *)name {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0.0, currentY, 0.0, 0.0)];
    label.text = name;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [label sizeToFit];
    [self.scrollView addSubview:label];
    return label;
}

/// 添加分区标题（FCL/ZL2 风格）
- (UILabel*)addSectionHeader:(NSString *)name {
    currentY += 8.0;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0.0, currentY, 0.0, 0.0)];
    label.text = name;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    [label sizeToFit];
    [self.scrollView addSubview:label];
    currentY += label.frame.size.height + 8.0;
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.keyCodeMap = [[NSMutableArray alloc] init];
    self.keyValueMap = [[NSMutableArray alloc] init];
    initKeycodeTable(self.keyCodeMap, self.keyValueMap);

    self.oldProperties = self.targetButton.properties.mutableCopy;
    currentY = 6.0;

    CGFloat shortest = MIN(self.view.frame.size.width, self.view.frame.size.height);
    CGFloat tempW = MIN(self.view.frame.size.width * 0.75, shortest);
    CGFloat tempH = MIN(self.view.frame.size.height * 0.6, shortest);

    UIVisualEffectView *blurView;
    blurView = [[UIVisualEffectView alloc] init];
    blurView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    blurView.frame = CGRectMake(
        (self.view.frame.size.width - MAX(tempW, tempH))/2,
        (self.view.frame.size.height - MIN(tempW, tempH))/2,
        MAX(tempW, tempH), MIN(tempW, tempH));
    blurView.layer.cornerRadius = 16.0;
    blurView.clipsToBounds = YES;
    [self.view addSubview:blurView];
    [[BackgroundManager sharedManager] applyEffectToView:blurView];

    UIBarButtonItem *btnFlexibleSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:self action:nil];

    UIToolbar *popoverToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0.0, 0.0,   blurView.frame.size.width, 44.0)];
    UIPanGestureRecognizer *dragVCGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragViewController:)];
    dragVCGesture.minimumNumberOfTouches = 1;
    dragVCGesture.maximumNumberOfTouches = 1;
    [popoverToolbar addGestureRecognizer:dragVCGesture];

    // FCL/ZL2 风格：标题显示按钮名称
    NSString *titleText = @"编辑按钮";
    if (self.targetButton.properties[@"name"]) {
        titleText = [NSString stringWithFormat:@"编辑：%@", self.targetButton.properties[@"name"]];
    }
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = titleText;
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [titleLabel sizeToFit];
    UIBarButtonItem *titleItem = [[UIBarButtonItem alloc] initWithCustomView:titleLabel];

    UIBarButtonItem *popoverCancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(actionEditCancel)];
    UIBarButtonItem *popoverDoneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionEditFinish)];
    popoverToolbar.items = @[popoverCancelButton, btnFlexibleSpace, titleItem, btnFlexibleSpace, popoverDoneButton];
    [blurView.contentView addSubview:popoverToolbar];

    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(5.0, popoverToolbar.frame.size.height, blurView.frame.size.width - 10.0, blurView.frame.size.height - popoverToolbar.frame.size.height)];
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [blurView.contentView addSubview:self.scrollView];

    UIToolbar *editPickToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0.0, 0.0, blurView.frame.size.width, 44.0)];

    UIBarButtonItem *editDoneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeTextField)];
    editPickToolbar.items = @[btnFlexibleSpace, editDoneButton];

    CGFloat width = blurView.frame.size.width - 10.0;
    CGFloat height = blurView.frame.size.height - 10.0;

    // ========================================================================
    // 分区：基础属性
    // ========================================================================
    [self addSectionHeader:localize(@"custom_controls.button_edit.section.basic", nil)];

    // Property: Name
    if (![self.targetButton isKindOfClass:ControlJoystick.class]) {
        UILabel *labelName = [self addLabel:localize(@"custom_controls.button_edit.name", nil)];
        self.editName = [[UITextField alloc] initWithFrame:CGRectMake(labelName.frame.size.width + 5.0, currentY, width - labelName.frame.size.width - 5.0, labelName.frame.size.height)];
        [self.editName addTarget:self action:@selector(textFieldEditingChanged) forControlEvents:UIControlEventEditingChanged];
        [self.editName addTarget:self.editName action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
        self.editName.placeholder = localize(@"custom_controls.button_edit.name", nil);
        self.editName.returnKeyType = UIReturnKeyDone;
        self.editName.text = self.targetButton.properties[@"name"];
        self.editName.borderStyle = UITextBorderStyleRoundedRect;
        [self.scrollView addSubview:self.editName];
        currentY += labelName.frame.size.height + 15.0;
    }

    if (![self.targetButton isKindOfClass:ControlSubButton.class] ||
    [((ControlSubButton *)self.targetButton).parentDrawer.drawerData[@"orientation"] isEqualToString:@"FREE"]) {
        // Property: Size
        UILabel *labelSize = [self addLabel:localize(@"custom_controls.button_edit.size", nil)];
        // width / 2.0 + (labelSize.frame.size.width + 4.0) / 2.0
        CGFloat editSizeWidthValue = (width - labelSize.frame.size.width) / 2 - labelSize.frame.size.height / 2;
        UILabel *labelSizeX = [[UILabel alloc] initWithFrame:CGRectMake(labelSize.frame.size.width + editSizeWidthValue, labelSize.frame.origin.y, labelSize.frame.size.height, labelSize.frame.size.height)];
        labelSizeX.text = @"x";
        [self.scrollView addSubview:labelSizeX];
        self.editSizeWidth = [[UITextField alloc] initWithFrame:CGRectMake(labelSize.frame.size.width, labelSize.frame.origin.y, editSizeWidthValue, labelSize.frame.size.height)];
        [self.editSizeWidth addTarget:self action:@selector(textFieldEditingChanged) forControlEvents:UIControlEventEditingChanged];
        [self.editSizeWidth addTarget:self.editSizeWidth action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
        self.editSizeWidth.keyboardType = UIKeyboardTypeDecimalPad;
        self.editSizeWidth.placeholder = @"width";
        self.editSizeWidth.returnKeyType = UIReturnKeyDone;
        self.editSizeWidth.text = [self.targetButton.properties[@"width"] stringValue];
        self.editSizeWidth.textAlignment = NSTextAlignmentCenter;
        self.editSizeWidth.borderStyle = UITextBorderStyleRoundedRect;
        [self.scrollView addSubview:self.editSizeWidth];
        self.editSizeHeight = [[UITextField alloc] initWithFrame:CGRectMake(labelSizeX.frame.origin.x + labelSizeX.frame.size.width, labelSize.frame.origin.y, editSizeWidthValue, labelSize.frame.size.height)];
        [self.editSizeHeight addTarget:self action:@selector(textFieldEditingChanged) forControlEvents:UIControlEventEditingChanged];
        [self.editSizeHeight addTarget:self.editSizeHeight action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
        self.editSizeHeight.keyboardType = UIKeyboardTypeDecimalPad;
        self.editSizeHeight.placeholder = @"height";
        self.editSizeHeight.returnKeyType = UIReturnKeyDone;
        self.editSizeHeight.text = [self.targetButton.properties[@"height"] stringValue];
        self.editSizeHeight.textAlignment = NSTextAlignmentCenter;
        self.editSizeHeight.borderStyle = UITextBorderStyleRoundedRect;
        [self.scrollView addSubview:self.editSizeHeight];
        currentY += labelSize.frame.size.height + 15.0;
    }

    // ========================================================================
    // 分区：按键映射 / 方向 / 前向锁定
    // ========================================================================
    [self addSectionHeader:localize(@"custom_controls.button_edit.section.input", nil)];

    if ([self.targetButton isKindOfClass:ControlDrawer.class]) {
        // Property: Orientation
        self.arrOrientation = @[@"DOWN", @"LEFT", @"UP", @"RIGHT", @"FREE"];
        UILabel *labelOrientation = [self addLabel:localize(@"custom_controls.button_edit.orientation", nil)];
        self.ctrlOrientation = [[UISegmentedControl alloc] initWithItems:self.arrOrientation];
        [self.ctrlOrientation addTarget:self action:@selector(orientationValueChanged:) forControlEvents:UIControlEventValueChanged];
        self.ctrlOrientation.frame = CGRectMake(labelOrientation.frame.size.width + 5.0, currentY - 5.0, width - labelOrientation.frame.size.width - 5.0, 30.0);
        self.ctrlOrientation.selectedSegmentIndex = [self.arrOrientation indexOfObject:
            ((ControlDrawer *)self.targetButton).drawerData[@"orientation"]];
        [self.scrollView addSubview:self.ctrlOrientation];
        currentY += labelOrientation.frame.size.height + 15.0;
    } else if ([self.targetButton isKindOfClass:ControlJoystick.class]) {
        // Property: Forward lock
        UILabel *labelFwdLock = [self addLabel:localize(@"custom_controls.button_edit.forward_lock", nil)];
        self.switchFwdLock = [[UISwitch alloc] initWithFrame:CGRectMake(width - 62.0, currentY - 5.0, 50.0, 30)];
        [self.switchFwdLock setOn:[self.targetButton.properties[@"forwardLock"] boolValue] animated:NO];
        [self.scrollView addSubview:self.switchFwdLock];
        currentY += labelFwdLock.frame.size.height + 15.0;
    } else {
        // Property: Mapping
        UILabel *labelMapping = [self addLabel:localize(@"custom_controls.button_edit.mapping", nil)];

        self.editMapping = [[UITextView alloc] initWithFrame:CGRectMake(0,0,1,1)];
        self.editMapping.text = @"\n\n\n";
        [self.editMapping sizeToFit];
        self.editMapping.scrollEnabled = NO;
        self.editMapping.frame = CGRectMake(labelMapping.frame.size.width + 5.0, labelMapping.frame.origin.y, width - labelMapping.frame.size.width - 5.0, self.editMapping.frame.size.height);

        self.pickerMapping = [[UIPickerView alloc] init];
        self.pickerMapping.delegate = self;
        self.pickerMapping.dataSource = self;
        [self.pickerMapping reloadAllComponents];
        for (int i = 0; i < 4; i++) {
            [self.pickerMapping selectRow:[self.keyValueMap indexOfObject:self.targetButton.properties[@"keycodes"][i]] inComponent:i animated:NO];
        }
        [self pickerView:self.pickerMapping didSelectRow:0 inComponent:0];

        self.editMapping.inputAccessoryView = editPickToolbar;
        self.editMapping.inputView = self.pickerMapping;
        [self.scrollView addSubview:self.editMapping];
        currentY += self.editMapping.frame.size.height + 15.0;
    }

    // ========================================================================
    // 分区：行为
    // ========================================================================
    [self addSectionHeader:localize(@"custom_controls.button_edit.section.behavior", nil)];

    if (![self.targetButton isKindOfClass:ControlJoystick.class]) {
        // Property: Toggleable
        UILabel *labelToggleable = [self addLabel:localize(@"custom_controls.button_edit.toggleable", nil)];
        self.switchToggleable = [[UISwitch alloc] initWithFrame:CGRectMake(width - 62.0, currentY - 5.0, 50.0, 30)];
        [self.switchToggleable setOn:[self.targetButton.properties[@"isToggle"] boolValue] animated:NO];
        [self.scrollView addSubview:self.switchToggleable];
        currentY += labelToggleable.frame.size.height + 15.0;


        // Property: Mouse pass
        UILabel *labelMousePass = [self addLabel:localize(@"custom_controls.button_edit.mouse_pass", nil)];
        self.switchMousePass = [[UISwitch alloc] initWithFrame:CGRectMake(width - 62.0, currentY - 5.0, 50.0, 30)];
        [self.switchMousePass setOn:[self.targetButton.properties[@"passThruEnabled"] boolValue]];
        [self.scrollView addSubview:self.switchMousePass];
        currentY += labelMousePass.frame.size.height + 15.0;


        // Property: Swipeable
        UILabel *labelSwipeable = [self addLabel:localize(@"custom_controls.button_edit.swipeable", nil)];
        self.switchSwipeable = [[UISwitch alloc] initWithFrame:CGRectMake(width - 62.0, currentY - 5.0, 50.0, 30)];
        [self.switchSwipeable setOn:[self.targetButton.properties[@"isSwipeable"] boolValue]];
        [self.scrollView addSubview:self.switchSwipeable];
        currentY += labelSwipeable.frame.size.height + 15.0;
    }

    // ========================================================================
    // 分区：外观
    // ========================================================================
    [self addSectionHeader:localize(@"custom_controls.button_edit.section.appearance", nil)];

    // Property: Background color
    UILabel *labelBGColor = [self addLabel:localize(@"custom_controls.button_edit.bg_color", nil)];
    self.colorWellBackground = [[UIColorWell alloc] initWithFrame:CGRectMake(width - 42.0, currentY - 5.0, 30.0, 30.0)];
    [self.colorWellBackground addTarget:self action:@selector(colorWellChanged) forControlEvents:UIControlEventValueChanged];
    self.colorWellBackground.selectedColor = convertARGB2UIColor([self.targetButton.properties[@"bgColor"] intValue]);
    [self.scrollView addSubview:self.colorWellBackground];
    currentY += labelBGColor.frame.size.height + 15.0;

    // Property: Stroke width
    UILabel *labelStrokeWidth = [self addLabel:localize(@"custom_controls.button_edit.stroke_width", nil)];
    self.sliderStrokeWidth = [[DBNumberedSlider alloc] initWithFrame:CGRectMake(labelStrokeWidth.frame.size.width + 5.0, currentY - 5.0, width - labelStrokeWidth.frame.size.width - 5.0, 30.0)];
    self.sliderStrokeWidth.continuous = YES;
    self.sliderStrokeWidth.maximumValue = MAX([self.targetButton.properties[@"width"] intValue], [self.targetButton.properties[@"height"] intValue]) / 2;
    self.sliderStrokeWidth.tag = TAG_SLIDER_STROKEWIDTH;
    self.sliderStrokeWidth.value = [self.targetButton.properties[@"strokeWidth"] intValue];
    [self.sliderStrokeWidth addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.sliderStrokeWidth];
    currentY += labelStrokeWidth.frame.size.height + 15.0;


    // Property: Stroke color
    UILabel *labelStrokeColor = [self addLabel:localize(@"custom_controls.button_edit.stroke_color", nil)];
    self.colorWellStroke = [[UIColorWell alloc] initWithFrame:CGRectMake(width - 42.0, currentY - 5.0, 30.0, 30.0)];
    [self.colorWellStroke addTarget:self action:@selector(colorWellChanged) forControlEvents:UIControlEventValueChanged];
    self.colorWellStroke.selectedColor = convertARGB2UIColor([self.targetButton.properties[@"strokeColor"] intValue]);
    [self.scrollView addSubview:self.colorWellStroke];
    currentY += labelStrokeColor.frame.size.height + 15.0;


    // Property: Corner radius
    if (![self.targetButton isKindOfClass:ControlJoystick.class]) {
        UILabel *labelCornerRadius = [self addLabel:localize(@"custom_controls.button_edit.corner_radius", nil)];
        self.sliderCornerRadius = [[DBNumberedSlider alloc] initWithFrame:CGRectMake(labelCornerRadius.frame.size.width + 5.0, currentY - 5.0, width - labelCornerRadius.frame.size.width - 5.0, 30.0)];
        self.sliderCornerRadius.continuous = YES;
        self.sliderCornerRadius.maximumValue = 100;
        self.sliderCornerRadius.value = [self.targetButton.properties[@"cornerRadius"] intValue];
        [self.sliderCornerRadius addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
        [self.scrollView addSubview:self.sliderCornerRadius];
        currentY += labelCornerRadius.frame.size.height + 15.0;
    }


    // Property: Button Opacity
    UILabel *labelOpacity = [self addLabel:localize(@"custom_controls.button_edit.opacity", nil)];
    self.sliderOpacity = [[DBNumberedSlider alloc] initWithFrame:CGRectMake(labelOpacity.frame.size.width + 5.0, currentY - 5.0, width - labelOpacity.frame.size.width - 5.0, 30.0)];
    self.sliderOpacity.continuous = YES;
    self.sliderOpacity.minimumValue = 1;
    self.sliderOpacity.maximumValue = 100;
    self.sliderOpacity.value = [self.targetButton.properties[@"opacity"] floatValue] * 100.0;
    [self.sliderOpacity addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.sliderOpacity];
    currentY += labelOpacity.frame.size.height + 15.0;


    // Property: Visibility
    self.arrVisibility = @[localize(@"Always", nil), localize(@"In game", nil), localize(@"In menu", nil)];
    UILabel *labelVisibility = [self addLabel:localize(@"custom_controls.button_edit.visibility", nil)];
    self.ctrlVisibility = [[UISegmentedControl alloc] initWithItems:self.arrVisibility];
    [self.ctrlVisibility addTarget:self action:@selector(visibilityValueChanged:) forControlEvents:UIControlEventValueChanged];
    self.ctrlVisibility.frame = CGRectMake(labelVisibility.frame.size.width + 5.0, currentY - 5.0, width - labelVisibility.frame.size.width - 5.0, 30.0);
    BOOL displayInGame = [self.targetButton.properties[@"displayInGame"] boolValue];
    BOOL displayInMenu = [self.targetButton.properties[@"displayInMenu"] boolValue];
    if (displayInGame && displayInMenu) {
        self.ctrlVisibility.selectedSegmentIndex = VISIBILITY_ALWAYS;
    } else if (displayInGame) {
        self.ctrlVisibility.selectedSegmentIndex = VISIBILITY_IN_GAME;
    } else if (displayInMenu) {
        self.ctrlVisibility.selectedSegmentIndex = VISIBILITY_IN_MENU;
    } // else the segment is not chosen
    [self.scrollView addSubview:self.ctrlVisibility];
    currentY += labelVisibility.frame.size.height + 15.0;

    self.scrollView.contentSize = CGSizeMake(self.scrollView.contentSize.width, currentY);
}

#pragma mark - Gesture callback
- (void)dragViewController:(UIPanGestureRecognizer *)sender {
    static CGPoint lastPoint;
    CGPoint point = [sender translationInView:self.view];
    if (sender.state != UIGestureRecognizerStateBegan) {
        CGRect rect = self.view.subviews[0].frame;
        rect.origin.x = clamp(rect.origin.x - lastPoint.x + point.x, -self.view.frame.size.width/2, self.view.frame.size.width - sender.view.frame.size.width/2);
        rect.origin.y = clamp(rect.origin.y - lastPoint.y + point.y, 0, self.view.frame.size.height - sender.view.frame.size.height);
        self.view.subviews[0].frame = rect;
    }
    lastPoint = point;
}

#pragma mark - Color picker functions

- (void)colorWellChanged {
    self.targetButton.properties[@"bgColor"] = @(convertUIColor2ARGB(self.colorWellBackground.selectedColor));
    self.targetButton.properties[@"strokeColor"] = @(convertUIColor2ARGB(self.colorWellStroke.selectedColor));
    [self.targetButton update];
}

 - (void)textFieldEditingChanged {
    self.targetButton.properties[@"name"] = self.editName.text;
    self.targetButton.properties[@"width"]  = @([self.editSizeWidth.text floatValue]);
    self.targetButton.properties[@"height"] = @([self.editSizeHeight.text floatValue]);
    [self.targetButton update];
}

#pragma mark - Control editor
- (void)actionEditCancel {
    self.targetButton.properties = self.oldProperties;
    [self.targetButton update];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionEditFinish {
    if (self.switchFwdLock) {
        self.targetButton.properties[@"forwardLock"] = @(self.switchFwdLock.isOn);
    }
    self.targetButton.properties[@"isToggle"] = @(self.switchToggleable.isOn);
    self.targetButton.properties[@"passThruEnabled"] = @(self.switchMousePass.isOn);
    self.targetButton.properties[@"isSwipeable"] = @(self.switchSwipeable.isOn);

    NSMutableDictionary *newProperties = self.targetButton.properties.mutableCopy;

    for (NSString *key in self.oldProperties) {
        if ([self.oldProperties[key] isEqual:newProperties[key]]) {
            [newProperties removeObjectForKey:key];
        }
    }

    [(CustomControlsViewController *)self.presentingViewController
        doUpdateButton:self.targetButton from:self.oldProperties to:newProperties];
    self.oldProperties = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)orientationValueChanged:(UISegmentedControl *)sender {
    ((ControlDrawer *)self.targetButton).drawerData[@"orientation"] =
        self.arrOrientation[sender.selectedSegmentIndex];
    [(ControlDrawer *)self.targetButton syncButtons];
}

- (void)sliderValueChanged:(DBNumberedSlider *)sender {
    if (sender.tag == TAG_SLIDER_STROKEWIDTH) {
        self.colorWellStroke.enabled = sender.value != 0;
        self.targetButton.properties[@"strokeWidth"] = @((NSInteger) self.sliderStrokeWidth.value);
    } else {
        [sender setValue:(NSInteger)sender.value animated:NO];
        self.targetButton.properties[@"cornerRadius"] = @((NSInteger) self.sliderCornerRadius.value);
        self.targetButton.properties[@"opacity"] = @(self.sliderOpacity.value / 100.0);
    }
    [self.targetButton update];
}

- (void)visibilityValueChanged:(UISegmentedControl *)sender {
    self.targetButton.properties[@"displayInGame"] = [NSNumber numberWithBool:sender.selectedSegmentIndex != VISIBILITY_IN_MENU];
    self.targetButton.properties[@"displayInMenu"] = [NSNumber numberWithBool:sender.selectedSegmentIndex != VISIBILITY_IN_GAME];
}

#pragma mark - UIPickerView stuff
- (UIView *)pickerView:(UIPickerView *)pickerView viewForRow:(NSInteger)row forComponent:(NSInteger)component reusingView:(UIView *)view
{
    UILabel *label = (UILabel *)view;
    if (label == nil) {
        label = [UILabel new];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.5;
        label.textAlignment = NSTextAlignmentCenter;
    }
    label.text = [self pickerView:pickerView titleForRow:row forComponent:component];

    return label;
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    self.editMapping.text = [NSString stringWithFormat:@"1: %@\n2: %@\n3: %@\n4: %@",
        self.keyCodeMap[[pickerView selectedRowInComponent:0]],
        self.keyCodeMap[[pickerView selectedRowInComponent:1]],
        self.keyCodeMap[[pickerView selectedRowInComponent:2]],
        self.keyCodeMap[[pickerView selectedRowInComponent:3]]
    ];

    for (int i = 0; i < 4; i++) {
        self.targetButton.properties[@"keycodes"][i] = self.keyValueMap[[self.pickerMapping selectedRowInComponent:i]];
    }
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)thePickerView {
    return 4;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return self.keyCodeMap.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    return self.keyCodeMap[row];
}

- (void)closeTextField {
    [self.editMapping endEditing:YES];
}

@end
