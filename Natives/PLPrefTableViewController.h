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

/// Search: whether the search bar is enabled (a subclass sets it to YES in viewDidLoad)
@property(nonatomic) BOOL searchEnabled;
/// The current search term (read-only, updated internally by searchController)
@property(nonatomic, readonly) NSString *currentSearchText;
/// The search results (read-only; non-nil while searching and nil otherwise).
/// A subclass can use it to tell whether search mode is active and to read the filtered items
/// (each of which carries internal fields such as __origSection / __origRow / __localizedTitle)
@property(nonatomic, readonly, nullable) NSArray *filteredItems;

- (UIBarButtonItem *)drawHelpButton;
- (void)initViewCreation;

/// Open a sub-page (triggered by a typeChildPane setting)
/// A subclass can override this to customize the navigation for a specific key, then call super for the rest
- (void)tableView:(UITableView *)tableView openChildPaneAtIndexPath:(NSIndexPath *)indexPath;

@end