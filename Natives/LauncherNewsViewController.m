#import "LauncherNewsViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "LauncherPreferences.h"
#import "utils.h"

@interface LauncherNewsViewController ()

@property(nonatomic, strong) UIImageView *skinImageView;
@property(nonatomic, strong) UILabel *welcomeLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, strong) UIView *skinContainer;

@end

@implementation LauncherNewsViewController

- (id)init {
    self = [super init];
    self.title = @"主页";
    return self;
}

- (NSString *)imageName {
    return @"MenuNews";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // FCL Style: Transparent background
    self.view.backgroundColor = [UIColor clearColor];
    
    [self setupUI];
    [self updateSkinDisplay];
    
    // 监听账户变化通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateSkinDisplay)
                                                 name:@"AccountChanged"
                                               object:nil];
    
    // Memory warning
    if(!isJailbroken && getPrefBool(@"warnings.limited_ram_warn") && (roundf(NSProcessInfo.processInfo.physicalMemory / 0x1000000) < 3900)) {
        [self showWarningAlert:@"limited_ram" hasPreference:YES exitWhenCompleted:NO];
    }
    
    // FCL Style: Hide navigation bar in split view
    self.navigationController.navigationBarHidden = YES;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    // 皮肤容器
    self.skinContainer = [[UIView alloc] init];
    self.skinContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.skinContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.skinContainer];
    
    // 欢迎标签
    self.welcomeLabel = [[UILabel alloc] init];
    self.welcomeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.welcomeLabel.font = [UIFont boldSystemFontOfSize:28];
    self.welcomeLabel.textColor = [UIColor labelColor];
    self.welcomeLabel.textAlignment = NSTextAlignmentCenter;
    self.welcomeLabel.text = @"欢迎";
    [self.view addSubview:self.welcomeLabel];
    
    // 版本标签
    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:14];
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    self.versionLabel.textAlignment = NSTextAlignmentCenter;
    self.versionLabel.text = @"Amethyst iOS Remastered";
    [self.view addSubview:self.versionLabel];
    
    // 皮肤图片视图
    self.skinImageView = [[UIImageView alloc] init];
    self.skinImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.skinImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.skinImageView.backgroundColor = [UIColor clearColor];
    [self.skinContainer addSubview:self.skinImageView];
    
    // 约束
    [NSLayoutConstraint activateConstraints:@[
        // 欢迎标签
        [self.welcomeLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:40],
        [self.welcomeLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        
        // 版本标签
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.welcomeLabel.bottomAnchor constant:8],
        [self.versionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        
        // 皮肤容器
        [self.skinContainer.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:30],
        [self.skinContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.skinContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.skinContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        
        // 皮肤图片
        [self.skinImageView.centerXAnchor constraintEqualToAnchor:self.skinContainer.centerXAnchor],
        [self.skinImageView.centerYAnchor constraintEqualToAnchor:self.skinContainer.centerYAnchor],
        [self.skinImageView.widthAnchor constraintEqualToConstant:200],
        [self.skinImageView.heightAnchor constraintEqualToConstant:400]
    ]];
}

- (void)updateSkinDisplay {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    
    if (currentAuth && currentAuth.authData) {
        NSString *username = currentAuth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
            self.welcomeLabel.text = [NSString stringWithFormat:@"欢迎, %@", username];
        }
        
        // 加载皮肤
        NSString *uuid = currentAuth.authData[@"uuid"];
        if (uuid) {
            [self loadSkinForUUID:uuid];
        } else {
            // 显示默认皮肤
            self.skinImageView.image = [self defaultSkinImage];
        }
    } else {
        self.welcomeLabel.text = @"欢迎";
        self.skinImageView.image = [self defaultSkinImage];
    }
}

- (void)loadSkinForUUID:(NSString *)uuid {
    // 从Mojang API获取皮肤
    NSString *skinURL = [NSString stringWithFormat:@"https://crafatar.com/renders/body/%@?overlay", uuid];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:skinURL]];
        if (imageData) {
            UIImage *skinImage = [UIImage imageWithData:imageData];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (skinImage) {
                    self.skinImageView.image = skinImage;
                } else {
                    self.skinImageView.image = [self defaultSkinImage];
                }
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.skinImageView.image = [self defaultSkinImage];
            });
        }
    });
}

- (UIImage *)defaultSkinImage {
    // 返回默认皮肤（Steve）
    // 这里可以使用一个默认的皮肤图片，或者从资源加载
    return [UIImage systemImageNamed:@"person.fill"];
}

- (void)showWarningAlert:(NSString *)key hasPreference:(BOOL)isPreferenced exitWhenCompleted:(BOOL)shouldExit {
    UIAlertController *warning = [UIAlertController
                                      alertControllerWithTitle:localize([NSString stringWithFormat:@"login.warn.title.%@", key], nil)
                                      message:localize([NSString stringWithFormat:@"login.warn.message.%@", key], nil)
                                      preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *action;
    if(isPreferenced) {
        action = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
            setPrefBool([NSString stringWithFormat:@"warnings.%@_warn", key], NO);
        }];
    } else if(shouldExit) {
        action = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
            [UIApplication.sharedApplication performSelector:@selector(suspend)];
            usleep(100*1000);
            exit(0);
        }];
    } else {
        action = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil];
    }
    warning.popoverPresentationController.sourceView = self.view;
    warning.popoverPresentationController.sourceRect = self.view.bounds;
    [warning addAction:action];
    [self presentViewController:warning animated:YES completion:nil];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end