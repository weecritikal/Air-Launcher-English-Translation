#import <UIKit/UIKit.h>

typedef void(^CreateView)(UITableViewCell *, NSString *,NSString *, NSDictionary *);
typedef id (^GetPreferenceBlock)(NSString *, NSString *);
typedef void (^SetPreferenceBlock)(NSString *, NSString *, id);

@interface PLPrefTableViewController : UITableViewController<UITextFieldDelegate, UISearchResultsUpdating>

@property(nonatomic) CreateView typeButton, typeChildPane, typePickField, typeTextField, typeSlider, typeSwitch;

@property(nonatomic) GetPreferenceBlock getPreference;
@property(nonatomic) SetPreferenceBlock setPreference;
@property(nonatomic) BOOL prefSectionsVisible, hasDetail;

@property(nonatomic) NSArray<NSString*>* prefSections;
@property(nonatomic) NSMutableArray<NSNumber*>* prefSectionsVisibility;
@property(nonatomic) NSArray<NSArray<NSDictionary*>*>* prefContents;
@property(nonatomic) BOOL prefDetailVisible;

/// 搜索功能：是否启用搜索栏（子类在 viewDidLoad 设置 YES 启用）
@property(nonatomic) BOOL searchEnabled;
/// 当前搜索关键词（仅读，由 searchController 内部更新）
@property(nonatomic, readonly) NSString *currentSearchText;

- (UIBarButtonItem *)drawHelpButton;
- (void)initViewCreation;

@end