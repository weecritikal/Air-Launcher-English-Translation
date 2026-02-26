#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, PLSettingsLayoutMode) {
    PLSettingsLayoutModeClassic = 0,
    PLSettingsLayoutModeCard = 1
};

typedef void(^CreateView)(UITableViewCell *, NSString *,NSString *, NSDictionary *);
typedef id (^GetPreferenceBlock)(NSString *, NSString *);
typedef void (^SetPreferenceBlock)(NSString *, NSString *, id);

@interface PLPrefTableViewController : UIViewController<UITextFieldDelegate, UICollectionViewDataSource, UICollectionViewDelegate>

@property(nonatomic) CreateView typeButton, typeChildPane, typePickField, typeTextField, typeSlider, typeSwitch;

@property(nonatomic) GetPreferenceBlock getPreference;
@property(nonatomic) SetPreferenceBlock setPreference;
@property(nonatomic) BOOL prefSectionsVisible, hasDetail;

@property(nonatomic) NSArray<NSString*>* prefSections;
@property(nonatomic) NSMutableArray<NSNumber*>* prefSectionsVisibility;
@property(nonatomic) NSArray<NSArray<NSDictionary*>*>* prefContents;
@property(nonatomic) BOOL prefDetailVisible;

// 布局模式
@property(nonatomic) PLSettingsLayoutMode layoutMode;
// 布局切换器
@property(nonatomic) UISegmentedControl *layoutSwitcher;
// 控制是否显示列表/卡片布局切换器，默认为 NO
@property(nonatomic) BOOL showLayoutSwitcher;

// 当前使用的列表视图（UITableView 或 UICollectionView）
@property(nonatomic, readonly) UIScrollView *scrollView;

// 列表视图（供子类使用，如 FabricInstallViewController）
@property(nonatomic, readonly) UITableView *tableView;

// 卡片视图
@property(nonatomic, readonly) UICollectionView *collectionView;

- (UIBarButtonItem *)drawHelpButton;
- (void)initViewCreation;

// 供子类调用：获取指定 indexPath 的 cell（列表模式）
- (UITableViewCell *)cellForIndexPath:(NSIndexPath *)indexPath;

@end