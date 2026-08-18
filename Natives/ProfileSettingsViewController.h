#import <UIKit/UIKit.h>

// Version settings - manages the mods/shaders/Java/memory/renderer/server/resource packs/worlds of the current version
// It absorbed the version picker and rename features of the old LauncherProfileEditorViewController
// Following the FCL style, it is the single Edit Profile page
//
// Rework (Air-Design v1.2):
//   - a hero card at the top: the profile name + the current version pill + the game directory
//   - 5 Bento groups: version info / content / install components / advanced / server
//   - a two-column landscape layout: left (version info, content) + right (install components, advanced, server)
//   - UIViewController + leftTableView / rightTableView provide the two landscape columns
@interface ProfileSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

// When editing an existing profile, set profileName (looked up in PLProfiles.current.profiles)
@property (nonatomic, copy, nullable) NSString *profileName;
// When creating a profile, pass the profile dictionary directly (as an alternative to profileName)
@property (nonatomic, strong, nullable) NSMutableDictionary *profile;

@end
