#import <UIKit/UIKit.h>

typedef void(^CreateView)(UITableViewCell *, NSString *,NSString *, NSDictionary *);
typedef id (^GetPreferenceBlock)(NSString *, NSString *);
typedef void (^SetPreferenceBlock)(NSString *, NSString *, id);

@interface PLPrefTableViewController : UITableViewController<UITextFieldDelegate>

@property(nonatomic) CreateView typeButton, typeChildPane, typePickField, typeTextField, typeSlider, typeSwitch;

@property(nonatomic) GetPreferenceBlock getPreference;
@property(nonatomic) SetPreferenceBlock setPreference;
@property(nonatomic) BOOL prefSectionsVisible, hasDetail;

@property(nonatomic) NSArray<NSString*>* prefSections;
@property(nonatomic) NSMutableArray<NSNumber*>* prefSectionsVisibility;
@property(nonatomic) NSArray<NSArray<NSDictionary*>*>* prefContents;
@property(nonatomic) BOOL prefDetailVisible;

// 控制是否显示列表/卡片布局切换器，默认为 NO
@property(nonatomic) BOOL showLayoutSwitcher;

- (UIBarButtonItem *)drawHelpButton;
- (void)initViewCreation;

@end
