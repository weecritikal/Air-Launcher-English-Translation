#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherPrefGameDirViewController.h"
#import "BackgroundManager.h"
#import "NSFileManager+NRFileManager.h"
#import "PLProfiles.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface LauncherPrefGameDirViewController ()<UITextFieldDelegate>
@property(nonatomic) NSMutableArray *array;
@end

@implementation LauncherPrefGameDirViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setTitle:localize(@"preference.title.game_directory", nil)];

    self.array = [[NSMutableArray alloc] init];
    [self.array addObject:@"default"];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.sectionFooterHeight = 50;

    NSString *path = [NSString stringWithFormat:@"%s/instances", getenv("POJAV_HOME")];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *files = [fm contentsOfDirectoryAtPath:path error:nil];
    BOOL isDir;
    for (NSString *file in files) {
        [fm fileExistsAtPath:path isDirectory:(&isDir)];
        if (isDir && ![file isEqualToString:@"default"]) {
            [self.array addObject:file];
        }
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

- (void)changeSelectionTo:(NSString *)name {
    if (getenv("DEMO_LOCK")) return;

    setPrefObject(@"general.game_directory", name);
    NSString *multidirPath = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), name];
    NSString *lasmPath = @(getenv("POJAV_GAME_DIR"));
    NSError *removeError = nil;
    [NSFileManager.defaultManager removeItemAtPath:lasmPath error:&removeError];
    // A removeItem failure is not necessarily fatal (lasmPath may not exist on the first switch), so it is ignored

    NSError *linkError = nil;
    BOOL linkOK = [NSFileManager.defaultManager createSymbolicLinkAtPath:lasmPath
                                                       withDestinationPath:multidirPath
                                                                     error:&linkError];
    if (!linkOK) {
        // The symbolic link could not be created: POJAV_GAME_DIR is still a broken link and every later path will fail.
        // Tell the user and return early, rather than making the state worse.
        NSLog(@"[GameDir] createSymbolicLink failed: %@", linkError.localizedDescription);
        showDialog(localize(@"Error", nil),
                   [NSString stringWithFormat:@"Could not switch the game directory: failed to create a symbolic link\n\n%@", linkError.localizedDescription]);
        return;
    }
    [NSFileManager.defaultManager changeCurrentDirectoryPath:lasmPath];
    // Point pref.instancePath at the launcher_preferences.plist of the new directory
    // (it recomputes from POJAV_GAME_DIR internally; the bug that required restarting the launcher has been fixed)
    toggleIsolatedPref(NO);

    // Refresh the PLProfiles cache, so later reads use the launcher_profiles.json of the new game directory
    [PLProfiles updateCurrent];

    // Try calling reloadProfileList directly if navigationController responds to that selector
    if ([self.navigationController respondsToSelector:@selector(reloadProfileList)]) {
        [self.navigationController performSelector:@selector(reloadProfileList)];
    } else {
        // Otherwise post a notification
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    }

    // Post a notification to refresh the version profiles and the profile editor screen
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.array.count;
}

- (UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITextField *view;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        view = [[UITextField alloc] initWithFrame:CGRectMake(20, 10, (cell.bounds.size.width-40)/2, cell.bounds.size.height-20)];
        [view addTarget:view action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
        view.autocorrectionType = UITextAutocorrectionTypeNo;
        view.autocapitalizationType = UITextAutocapitalizationTypeNone;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        view.delegate = self;
        view.returnKeyType = UIReturnKeyDone;
        view.userInteractionEnabled = indexPath.row != 0;
        [cell.contentView addSubview:view];
        cell.detailTextLabel.text = @"...";
    }
    view = cell.contentView.subviews.firstObject;
    view.placeholder = self.array[indexPath.row];
    view.text = self.array[indexPath.row];
    cell.textLabel.hidden = YES;
    cell.textLabel.text = view.text;

    // Calculate the instance size
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        unsigned long long folderSize = 0;
        NSString *directory = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), self.array[indexPath.row]];
        [NSFileManager.defaultManager nr_getAllocatedSize:&folderSize ofDirectoryAtURL:[NSURL fileURLWithPath:directory] error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:folderSize countStyle:NSByteCountFormatterCountStyleMemory];
        });
    });

    if ([getPrefObject(@"general.game_directory") isEqualToString:self.array[indexPath.row]]) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    return cell;
}

- (UIView *)tableView:(UITableView *)tableView 
viewForFooterInSection:(NSInteger)section
{
    UITextField *view = [[UITextField alloc] init];
    [view addTarget:view action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
    view.autocorrectionType = UITextAutocorrectionTypeNo;
    view.autocapitalizationType = UITextAutocapitalizationTypeNone;
    view.delegate = self;
    view.placeholder = localize(@"preference.multidir.add_directory", nil);
    view.returnKeyType = UIReturnKeyDone;
    return view;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self changeSelectionTo:self.array[indexPath.row]];
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    for (int i = 0; i < self.array.count; i++) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]];
        if (i == indexPath.row) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
}

- (id)createOpenScheme:(NSString *)scheme at:(NSString *)directory {
    return ^(UIAction *action) {
        [UIApplication.sharedApplication
            openURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", scheme, directory]]
            options:@{} completionHandler:nil];
    };
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point 
{
    NSArray *menuItems;
    NSMutableArray *openItems = [[NSMutableArray alloc] init];

    NSString *directory = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), self.array[indexPath.row]];
    NSDictionary *apps = @{
        @"shareddocuments": @"Files",
        @"filza": @"Filza",
        @"santander": @"Santander",
    };
    for (NSString *key in apps.allKeys) {
        NSString *url = [NSString stringWithFormat:@"%@://", key];
        if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:url]]) {
            [openItems addObject:[UIAction
                actionWithTitle:apps[key]
                image:nil
                identifier:nil
                handler:[self createOpenScheme:key at:directory]]];
        }
    }
    UIMenu *open = [UIMenu
        menuWithTitle:@""
        image:nil
        identifier:nil
        options:UIMenuOptionsDisplayInline
        children:openItems];

    if (indexPath.row == 0) {
        // You can't delete or rename the default instance, though there will be a reset action (TODO)
        menuItems = @[open];
    } else {
        UIAction *rename = [UIAction
            actionWithTitle:localize(@"Rename", nil)
            image:[UIImage systemImageNamed:@"pencil"]
            identifier:nil
            handler:^(UIAction *action) {
                UITableViewCell *view = [self.tableView cellForRowAtIndexPath:indexPath];
                [view.contentView.subviews.firstObject becomeFirstResponder];
            }
        ];

        UIAction *delete = [UIAction
            actionWithTitle:localize(@"Delete", nil)
            image:[UIImage systemImageNamed:@"trash"]
            identifier:nil
            handler:^(UIAction *action) {
                [self actionDeleteAtIndexPath:indexPath];
            }
        ];
        delete.attributes = UIMenuElementAttributesDestructive;

        menuItems = @[open, rename, delete];
    }

    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
        previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
            return [UIMenu menuWithTitle:self.array[indexPath.row] children:menuItems];
        }
    ];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [self actionDeleteAtIndexPath:indexPath];
    }
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.row == 0) {
        // TODO: Reset action?
        return UITableViewCellEditingStyleNone;
    } else {
        return UITableViewCellEditingStyleDelete;
    }
}

- (void)actionDeleteAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *view = [self.tableView cellForRowAtIndexPath:indexPath];
    NSString *title = localize(@"preference.title.confirm", nil);
    NSString *message = [NSString stringWithFormat:localize(@"preference.title.confirm.delete_game_directory", nil), self.array[indexPath.row]];
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
    confirmAlert.popoverPresentationController.sourceView = view;
    confirmAlert.popoverPresentationController.sourceRect = view.bounds;
    UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        NSString *directory = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), self.array[indexPath.row]];
        NSError *error;
        if([NSFileManager.defaultManager removeItemAtPath:directory error:&error]) {
            if ([getPrefObject(@"general.game_directory") isEqualToString:self.array[indexPath.row]]) {
                [self changeSelectionTo:self.array[0]];
                [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]].accessoryType = UITableViewCellAccessoryCheckmark;
            }
            [self.array removeObjectAtIndex:indexPath.row];
            [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        } else {
            showDialog(localize(@"Error", nil), error.localizedDescription);
        }
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
    [confirmAlert addAction:cancel];
    [confirmAlert addAction:ok];
    [self presentViewController:confirmAlert animated:YES completion:nil];
}

- (void) dismissModalViewController {
    dismissModalViewController(self);
}

#pragma mark UITextField

- (void)textFieldDidEndEditing:(UITextField *)sender {
    BOOL isFooterView = sender.superview == self.tableView;
    if (!sender.hasText || [sender.text isEqualToString:sender.placeholder]) {
        if (isFooterView) {
            return;
        }
        sender.text = sender.placeholder;
        return;
    }

    NSError *error;

    NSString *dest = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), sender.text];
    if (isFooterView) {
        [NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:NO attributes:nil error:&error];
    } else {
        NSString *source = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), sender.placeholder];
        [NSFileManager.defaultManager moveItemAtPath:source toPath:dest error:&error];
    }

    if (error == nil) {
        [self changeSelectionTo:sender.text];
        if (isFooterView) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:self.array.count inSection:0];
            [self.array addObject:sender.text];
            [self.tableView beginUpdates];
            [self.tableView insertRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            [self.tableView endUpdates];
            [self tableView:self.tableView didSelectRowAtIndexPath:indexPath];
            // Clear text
            sender.text = @"";
        } else {
            int index = [self.array indexOfObject:sender.placeholder];
            self.array[index] = sender.placeholder = sender.text;
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
            [self tableView:self.tableView didSelectRowAtIndexPath:indexPath];
        }
    } else {
        // Restore to the previous name if we encounter an error
        if (!isFooterView) {
            sender.text = sender.placeholder;
        }
        showDialog(localize(@"Error", nil), error.localizedDescription);
    }
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    [textField invalidateIntrinsicContentSize];
    CGRect frame = textField.frame;
    frame.size.width = MAX(50, textField.intrinsicContentSize.width + 10);
    textField.frame = frame;
    return YES;
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
