#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "DBNumberedSlider.h"
#import "LauncherNavigationController.h"
#import "LauncherMenuViewController.h"
#import "LauncherPreferences.h"
#import "PLPrefTableViewController.h"
#import "BackgroundManager.h"
#import "UIKit+hook.h"

#import "ios_uikit_bridge.h"
#import "utils.h"

@interface PLPrefTableViewController()<UIContextMenuInteractionDelegate>{
    NSString *_currentSearchText;
}
@property(nonatomic) UIMenu* currentMenu;
@property(nonatomic) UIBarButtonItem *helpBtn;
@property(nonatomic, strong) UISearchController *searchController;
/// Search results: filteredSections[0] holds every match, flattened (ignoring which section they came from)
@property(nonatomic, strong) NSArray<NSDictionary *> *filteredItems;

@end

@implementation PLPrefTableViewController

- (id)init {
    self = [super init];
    [self initViewCreation];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    if (self.prefSections) {
        self.prefSectionsVisibility = [[NSMutableArray<NSNumber *> alloc] initWithCapacity:self.prefSections.count];
        for (int i = 0; i < self.prefSections.count; i++) {
            [self.prefSectionsVisibility addObject:@(self.prefSectionsVisible)];
        }
    } else {
        // Display one singe section if prefSection is unspecified
        self.prefSectionsVisibility = (id)@[@YES];
    }

    // Search bar initialization (only when searchEnabled=YES, which the subclass sets)
    if (self.searchEnabled) {
        self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
        self.searchController.searchResultsUpdater = self;
        self.searchController.obscuresBackgroundDuringPresentation = NO;
        self.searchController.searchBar.placeholder = @"Search settings...";
        self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
        self.tableView.tableHeaderView = self.searchController.searchBar;
        self.definesPresentationContext = YES;
        _currentSearchText = @"";
    }

    // Adapt to the custom launcher background: make this view controller transparent so the global background (image/video) shows through.
    // Called after the tableView is recreated, so makeViewControllerTransparent operates on the final tableView.
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // Listen for background UI effect changes: when the user switches between frosted glass and translucent, or adjusts the opacity,
    // call makeViewControllerTransparent again to apply the latest look and keep the background showing correctly.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (NSString *)currentSearchText {
    return _currentSearchText ?: @"";
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    _currentSearchText = query ?: @"";

    if (query.length == 0) {
        self.filteredItems = nil;
        [self.tableView reloadData];
        return;
    }

    // Flatten every setting in prefContents and fuzzy-match on title/key/icon/localizedTitle
    NSMutableArray *results = [NSMutableArray array];
    NSString *lowerQuery = query.lowercaseString;
    for (int s = 0; s < self.prefContents.count; s++) {
        NSArray *section = self.prefContents[s];
        // Item 0 is the section header, so it is skipped
        for (int r = (self.prefSections ? 1 : 0); r < section.count; r++) {
            NSDictionary *item = section[r];
            NSString *title = item[@"title"];
            if (!title) {
                title = [NSString stringWithFormat:@"preference.title.%@", item[@"key"]];
            }
            NSString *localizedTitle = localize(title, nil);
            NSString *key = item[@"key"] ?: @"";
            NSString *icon = item[@"icon"] ?: @"";
            // Match the localized title, the key, the icon name and the original title
            if ([localizedTitle.lowercaseString containsString:lowerQuery] ||
                [key.lowercaseString containsString:lowerQuery] ||
                [icon.lowercaseString containsString:lowerQuery] ||
                [title.lowercaseString containsString:lowerQuery]) {
                // Record the original section and row, so a tap can locate it
                NSMutableDictionary *matched = [item mutableCopy];
                matched[@"__origSection"] = @(s);
                matched[@"__origRow"] = @(r);
                matched[@"__localizedTitle"] = localizedTitle;
                [results addObject:matched];
            }
        }
    }
    self.filteredItems = results;
    [self.tableView reloadData];
}

- (UIBarButtonItem *)drawHelpButton {
    if (!self.helpBtn) {
        self.helpBtn = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"questionmark.circle"] style:UIBarButtonItemStyleDone target:self action:@selector(toggleDetailVisibility)];
    }
    return self.helpBtn;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Put navigation buttons back in place if we're first of the navigation controller
    if (self.hasDetail && self.navigationController) {
        self.navigationItem.rightBarButtonItems = @[[self drawHelpButton]];
    }

    // Scan for child pane cells and reload them
    // FIXME: any cheaper operations?
    NSMutableArray *indexPaths = [[NSMutableArray alloc] init];
    for (int section = 0; section < self.prefContents.count; section++) {
        if (!self.prefSectionsVisibility[section].boolValue) {
            continue;
        }
        for (int row = 0; row < self.prefContents[section].count; row++) {
            if (self.prefContents[section][row][@"type"] == self.typeChildPane) {
                [indexPaths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
            }
        }
    }
    [self.tableView reloadRowsAtIndexPaths:indexPaths withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark UITableView

- (void)toggleDetailVisibility {
    self.prefDetailVisible = !self.prefDetailVisible;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // The search results form one flat section
    if (self.filteredItems) return 1;
    return self.prefSectionsVisibility.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // Search results mode
    if (self.filteredItems) {
        return self.filteredItems.count;
    }
    if (self.prefSectionsVisibility[section].boolValue) {
        return self.prefContents[section].count;
    }
    return 1;
}

- (UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Search results mode: use the flattened filteredItems
    if (self.filteredItems) {
        NSDictionary *item = self.filteredItems[indexPath.row];
        NSString *cellID = @"searchResultCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
            cell.textLabel.adjustsFontSizeToFitWidth = YES;
            cell.textLabel.numberOfLines = 0;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        cell.textLabel.text = item[@"__localizedTitle"];
        // The subtitle shows which section it belongs to
        NSNumber *origSection = item[@"__origSection"];
        if (origSection && self.prefSections && origSection.intValue < (int)self.prefSections.count) {
            NSString *sectionKey = self.prefSections[origSection.intValue];
            cell.detailTextLabel.text = localize(([NSString stringWithFormat:@"preference.section.%@", sectionKey]), nil);
        } else {
            cell.detailTextLabel.text = nil;
        }
        cell.imageView.image = [UIImage systemImageNamed:item[@"icon"]];
        cell.imageView.tintColor = [item[@"destructive"] boolValue] ? UIColor.systemRedColor : nil;
        cell.userInteractionEnabled = YES;
        return cell;
    }

    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    NSString *cellID;
    UITableViewCellStyle cellStyle;
    if (item[@"type"] == self.typeChildPane || item[@"type"] == self.typePickField) {
        cellID = @"cellValue1";
        cellStyle = UITableViewCellStyleValue1;
    } else {
        cellID = @"cellSubtitle";
        cellStyle = UITableViewCellStyleSubtitle;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:cellStyle reuseIdentifier:cellID];
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    }
    // Reset cell properties, as it could be reused
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.textColor = nil;
    cell.detailTextLabel.text = nil;

    NSString *key = item[@"key"];
    if (indexPath.row == 0 && self.prefSections) {
        key = self.prefSections[indexPath.section];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.text = localize(([NSString stringWithFormat:@"preference.section.%@", key]), nil);
    } else {
        CreateView createView = item[@"type"];
        createView(cell, self.prefSections[indexPath.section], key, item);
        if (cell.accessoryView) {
            objc_setAssociatedObject(cell.accessoryView, @"section", self.prefSections[indexPath.section], OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(cell.accessoryView, @"key", key, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(cell.accessoryView, @"item", item, OBJC_ASSOCIATION_ASSIGN);
        }
        cell.textLabel.text = localize((item[@"title"] ? item[@"title"] :
            [NSString stringWithFormat:@"preference.title.%@", key]), nil);
    }

    // Set general properties
    BOOL destructive = [item[@"destructive"] boolValue];
    cell.imageView.tintColor = destructive ? UIColor.systemRedColor : nil;
    cell.imageView.image = [UIImage systemImageNamed:item[@"icon"]];
    
    if (cellStyle != UITableViewCellStyleValue1) {
        cell.detailTextLabel.text = nil;
        if ([item[@"hasDetail"] boolValue] && self.prefDetailVisible) {
            cell.detailTextLabel.text = localize(([NSString stringWithFormat:@"preference.detail.%@", key]), nil);
        }
    }

    // Check if one has enable condition and call if it does
    BOOL(^checkEnable)(void) = item[@"enableCondition"];
    cell.userInteractionEnabled = !checkEnable || checkEnable();
    cell.textLabel.enabled = cell.detailTextLabel.enabled = cell.userInteractionEnabled;
    [(id)cell.accessoryView setEnabled:cell.userInteractionEnabled];

    return cell;
}

#pragma mark initViewCreation, showAlert, checkWarn

- (void)initViewCreation {
    __weak PLPrefTableViewController *weakSelf = self;

    self.typeButton = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        BOOL destructive = [item[@"destructive"] boolValue];
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.textLabel.textColor = destructive ? UIColor.systemRedColor : weakSelf.view.tintColor;
    };

    self.typeChildPane = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        id value = weakSelf.getPreference(section, key);
        if ([value isKindOfClass:[NSString class]]) {
            cell.detailTextLabel.text = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            cell.detailTextLabel.text = [value boolValue] ? @"YES" : @"NO";
        } else {
            cell.detailTextLabel.text = [value description];
        }
    };

    self.typeTextField = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        Class cls = item[@"customClass"];
        if (!cls) cls = UITextField.class;
        UITextField *view = [[cls alloc] initWithFrame:CGRectMake(0, 0, cell.bounds.size.width / 2.1, cell.bounds.size.height)];
        [view addTarget:view action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
        view.adjustsFontSizeToFitWidth = YES;
        view.autocorrectionType = UITextAutocorrectionTypeNo;
        view.autocapitalizationType = UITextAutocapitalizationTypeNone;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
        //view.contentVerticalAlignment = UIControlContentVerticalAlignmentTop;
        view.delegate = weakSelf;
        //view.nonEditingLinebreakMode = NSLineBreakByCharWrapping;
        view.returnKeyType = UIReturnKeyDone;
        view.textAlignment = NSTextAlignmentRight;
        view.placeholder = localize((item[@"placeholder"] ? item[@"placeholder"] :
            [NSString stringWithFormat:@"preference.placeholder.%@", key]), nil);
        view.text = weakSelf.getPreference(section, key);
        cell.accessoryView = view;
    };

    self.typePickField = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        id value = weakSelf.getPreference(section, key);
        if ([value isKindOfClass:[NSString class]]) {
            cell.detailTextLabel.text = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            cell.detailTextLabel.text = [value boolValue] ? @"YES" : @"NO";
        } else {
            cell.detailTextLabel.text = [value description];
        }
    };

    self.typeSlider = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        DBNumberedSlider *view = [[DBNumberedSlider alloc] initWithFrame:CGRectMake(0, 0, cell.bounds.size.width / 2.1, cell.bounds.size.height)];
        [view addTarget:weakSelf action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
        view.minimumValue = [item[@"min"] intValue];
        view.maximumValue = [item[@"max"] intValue];
        view.continuous = YES;
        view.value = [weakSelf.getPreference(section, key) intValue];
        cell.accessoryView = view;
    };

    self.typeSwitch = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        UISwitch *view = [[UISwitch alloc] init];
        NSArray *customSwitchValue = item[@"customSwitchValue"];
        if (customSwitchValue == nil) {
            [view setOn:[weakSelf.getPreference(section, key) boolValue] animated:NO];
        } else {
            [view setOn:[weakSelf.getPreference(section, key) isEqualToString:customSwitchValue[1]] animated:NO];
        }
        [view addTarget:weakSelf action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = view;
    };
}

- (void)showAlertOnView:(UIView *)view title:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
    alert.popoverPresentationController.sourceView = view;
    alert.popoverPresentationController.sourceRect = view.bounds;
    UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:ok];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)checkWarn:(UIView *)view {
    NSDictionary *item = objc_getAssociatedObject(view, @"item");
    NSString *key = item[@"key"];

    BOOL(^isWarnable)(UIView *) = item[@"warnCondition"];
    NSString *warnKey = item[@"warnKey"];
    // Display warning if: warn condition is met and either one of these:
    // - does not have warnKey, always warn
    // - has warnKey and its value is YES, warn once and set it to NO
    if (isWarnable && isWarnable(view) && (!warnKey || [self.getPreference(@"warnings", warnKey) boolValue])) {
        if (warnKey) {
            self.setPreference(@"warnings", warnKey, @NO);
        }

        NSString *message = localize(([NSString stringWithFormat:@"preference.warn.%@", key]), nil);
        [self showAlertOnView:view title:localize(@"Warning", nil) message:message];
    }
}

#pragma mark Control event handlers

- (void)sliderMoved:(DBNumberedSlider *)sender {
    [self checkWarn:sender];
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = objc_getAssociatedObject(sender, @"key");

    sender.value = (int)sender.value;
    self.setPreference(section, key, @(sender.value));
}

- (void)switchChanged:(UISwitch *)sender {
    [self checkWarn:sender];
    NSDictionary *item = objc_getAssociatedObject(sender, @"item");
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = item[@"key"];

    // Special switches may define custom value instead of NO/YES
    NSArray *customSwitchValue = item[@"customSwitchValue"];
    self.setPreference(section, key, customSwitchValue ?
        customSwitchValue[sender.isOn] : @(sender.isOn));

    void(^invokeAction)(BOOL) = item[@"action"];
    if (invokeAction) {
        invokeAction(sender.isOn);
    }

    // Some settings may affect the availability of other settings
    // In this case, a switch may request to reload to apply user interaction change
    if ([item[@"requestReload"] boolValue]) {
        // TODO: only reload needed rows
        [self.tableView reloadData];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    // Search results mode: jump to the original section and expand it
    if (self.filteredItems) {
        NSDictionary *item = self.filteredItems[indexPath.row];
        NSNumber *origSection = item[@"__origSection"];
        NSNumber *origRow = item[@"__origRow"];
        if (!origSection || !origRow) return;

        // Close the search and restore the original layout
        // Note: UISearchController has no setActive:animated:, so the active property is used instead
        self.searchController.active = NO;
        self.filteredItems = nil;
        _currentSearchText = @"";

        // Expand the matching section
        if (origSection.intValue < (int)self.prefSectionsVisibility.count) {
            self.prefSectionsVisibility[origSection.intValue] = @YES;
        }
        [self.tableView reloadData];

        // Scroll to the item and trigger its original tap behavior
        NSIndexPath *origIndexPath = [NSIndexPath indexPathForRow:origRow.intValue inSection:origSection.intValue];
        [self.tableView scrollToRowAtIndexPath:origIndexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
        // Trigger it after a delay, once the scroll finishes
        dispatch_async(dispatch_get_main_queue(), ^{
            [self tableView:tableView didSelectRowAtIndexPath:origIndexPath];
        });
        return;
    }

    if (indexPath.row == 0 && self.prefSections) {
        self.prefSectionsVisibility[indexPath.section] = @(![self.prefSectionsVisibility[indexPath.section] boolValue]);
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationFade];
        return;
    }

    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    if (item[@"type"] == self.typeButton) {
        [self tableView:tableView invokeActionWithPromptAtIndexPath:indexPath];
        return;
    } else if (item[@"type"] == self.typeChildPane) {
        [self tableView:tableView openChildPaneAtIndexPath:indexPath];
        return;
    } else if (item[@"type"] == self.typePickField) {
        [self tableView:tableView openPickerAtIndexPath:indexPath];
        return;
    } else if (realUIIdiom != UIUserInterfaceIdiomTV) {
        return;
    }

    // userInterfaceIdiom = tvOS
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (item[@"type"] == self.typeSwitch) {
        UISwitch *view = (id)cell.accessoryView;
        view.on = !view.isOn;
        [view sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

#pragma mark External UITableView functions

- (void)tableView:(UITableView *)tableView openChildPaneAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    UIViewController *vc = [item[@"class"] new];
    if ([item[@"canDismissWithSwipe"] boolValue]) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.navigationBar.prefersLargeTitles = YES;
        nav.modalInPresentation = YES;
        [self.navigationController presentViewController:nav animated:YES completion:nil];
    }
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location
{
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

- (_UIContextMenuStyle *)_contextMenuInteraction:(UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
{
    _UIContextMenuStyle *style = [_UIContextMenuStyle defaultStyle];
    style.preferredLayout = 3; // _UIContextMenuLayoutCompactMenu
    return style;
}

- (void)tableView:(UITableView *)tableView openPickerAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    NSString *message = nil;
    if ([item[@"hasDetail"] boolValue]) {
        message = localize(([NSString stringWithFormat:@"preference.detail.%@", item[@"key"]]), nil);
    }

    NSArray *pickKeys = item[@"pickKeys"];
    NSArray *pickList = item[@"pickList"];

    // Fix for the option popup menu being squeezed and unusable on iPhone.
    // The root cause: the compact UIContextMenuInteraction menu (preferredLayout=3) anchors to the narrow
    // cell.detailTextLabel.frame, which squeezed several options into a tiny floating bubble on a narrow iPhone screen.
    // The fix: use a UIAlertController action sheet on iPhone, giving a standard full-width picker
    // where every option has room to be tapped. iPad keeps the compact UIContextMenuInteraction menu
    // (an anchored popover feels more natural on a large screen).
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:message
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        for (int i = 0; i < pickList.count; i++) {
            NSString *title = pickList[i];
            NSString *value = pickKeys[i];
            // Prefix the current selection with ✓ so the user can see the current value at a glance
            if ([cell.detailTextLabel.text isEqualToString:value]) {
                title = [NSString stringWithFormat:@"✓ %@", title];
            }
            UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction *a) {
                cell.detailTextLabel.text = value;
                self.setPreference(self.prefSections[indexPath.section], item[@"key"], value);
                void(^invokeAction)(NSString *) = item[@"action"];
                if (invokeAction) {
                    invokeAction(value);
                }
            }];
            [alert addAction:action];
        }
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                                   style:UIAlertActionStyleCancel
                                                 handler:nil]];
        // Configure popoverPresentationController defensively (an action sheet comes up from the bottom on iPhone,
        // so popoverPresentationController is unused, but setting sourceView avoids a crash in iPad split view)
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // iPad: keep the compact UIContextMenuInteraction menu
    NSMutableArray<UIAction *> *menuItems = [[NSMutableArray alloc] init];
    for (int i = 0; i < pickList.count; i++) {
        [menuItems addObject:[UIAction
            actionWithTitle:pickList[i]
            image:nil identifier:nil
            handler:^(UIAction *action) {
                cell.detailTextLabel.text = pickKeys[i];
                self.setPreference(self.prefSections[indexPath.section], item[@"key"], pickKeys[i]);
                void(^invokeAction)(NSString *) = item[@"action"];
                if (invokeAction) {
                    invokeAction(pickKeys[i]);
                }
            }]];
        if ([cell.detailTextLabel.text isEqualToString:pickKeys[i]]) {
            menuItems.lastObject.state = UIMenuElementStateOn;
        }
    }

    self.currentMenu = [UIMenu menuWithTitle:message children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    // Attach it to the cell itself rather than detailTextLabel, so a UITargetedPreview assertion cannot fire while detailTextLabel is not in a window yet
    [cell addInteraction:interaction];
    CGRect detailFrame = cell.detailTextLabel.frame;
    CGPoint location = CGPointMake(CGRectGetMidX(detailFrame), CGRectGetMidY(detailFrame));
    [interaction _presentMenuAtLocation:location];
}

- (void)tableView:(UITableView *)tableView invokeActionWithPromptAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *view = [self.tableView cellForRowAtIndexPath:indexPath];
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    NSString *key = item[@"key"];

    if ([item[@"showConfirmPrompt"] boolValue]) {
        BOOL destructive = [item[@"destructive"] boolValue];
        NSString *title = localize(@"preference.title.confirm", nil);
        NSString *message = localize(([NSString stringWithFormat:@"preference.title.confirm.%@", key]), nil);
        UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
        confirmAlert.popoverPresentationController.sourceView = view;
        confirmAlert.popoverPresentationController.sourceRect = view.bounds;
        UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:destructive?UIAlertActionStyleDestructive:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self tableView:tableView invokeActionAtIndexPath:indexPath];
        }];
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
        [confirmAlert addAction:cancel];
        [confirmAlert addAction:ok];
        [self presentViewController:confirmAlert animated:YES completion:nil];
    } else {
        [self tableView:tableView invokeActionAtIndexPath:indexPath];
    }
}

- (void)tableView:(UITableView *)tableView invokeActionAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    NSString *key = item[@"key"];

    void(^invokeAction)(void) = item[@"action"];
    if (invokeAction) {
        invokeAction();
    }

    // For typeButton actions, no "done" message is shown
    if (item[@"type"] != self.typeButton) {
        UIView *view = [self.tableView cellForRowAtIndexPath:indexPath];
        NSString *title = localize(([NSString stringWithFormat:@"preference.title.done.%@", key]), nil);
        [self showAlertOnView:view title:title message:nil];
    }
}

#pragma mark UITextField

- (void)textFieldDidEndEditing:(UITextField *)sender {
    [self checkWarn:sender];
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = objc_getAssociatedObject(sender, @"key");

    self.setPreference(section, key, sender.text);
}

/// Re-apply the background effect: called when the BackgroundUIEffectChanged notification arrives.
/// Re-applies the opacity/frosted-glass effect to this view controller via BackgroundManager,
/// so the tableView background is transparent and the global background shows through.
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
