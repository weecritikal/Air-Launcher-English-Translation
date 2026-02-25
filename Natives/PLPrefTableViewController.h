#import <UIKit/UIKit.h>

typedef void(^CreateView)(UITableViewCell *, NSString *,NSString *, NSDictionary *);
typedef id (^GetPreferenceBlock)(NSString *, NSString *);
typedef void (^SetPreferenceBlock)(NSString *, NSString *, id);

// 布局模式枚举
typedef NS_ENUM(NSInteger, PLSettingsLayoutMode) {
    PLSettingsLayoutModeClassic = 0,   // 传统列表布局
    PLSettingsLayoutModeCard = 1       // 卡片式布局
};

@interface PLPrefTableViewController : UITableViewController<UITextFieldDelegate>

@property(nonatomic) CreateView typeButton, typeChildPane, typePickField, typeTextField, typeSlider, typeSwitch;

@property(nonatomic) GetPreferenceBlock getPreference;
@property(nonatomic) SetPreferenceBlock setPreference;
@property(nonatomic) BOOL prefSectionsVisible, hasDetail;

@property(nonatomic) NSArray<NSString*>* prefSections;
@property(nonatomic) NSMutableArray<NSNumber*>* prefSectionsVisibility;
@property(nonatomic) NSArray<NSArray<NSDictionary*>*>* prefContents;
@property(nonatomic) BOOL prefDetailVisible;

// 新增：布局模式相关
@property(nonatomic) PLSettingsLayoutMode layoutMode;
@property(nonatomic, strong) UISegmentedControl *layoutSwitcher;

- (UIBarButtonItem *)drawHelpButton;
- (void)initViewCreation;

// 新增：布局切换方法
- (void)switchToLayoutMode:(PLSettingsLayoutMode)mode;
- (void)saveLayoutPreference;

@end
