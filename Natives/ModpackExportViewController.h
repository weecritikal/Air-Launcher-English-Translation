#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Modpack export controller (following FCL ExportModpackViewModel / HMCL ExportModpackPanel / ZL2 ModpackExportScreen)
///
/// A dedicated export screen offering:
///   - profile selection (with a gameDir preview and loader information)
///   - a choice of 5 formats (Modrinth / CurseForge / MMC / Plain Zip / link list)
///   - name / version / author input
///   - file filtering options (mods / configs / resourcepacks / shaderpacks / saves / options / servers / scripts)
///   - a progress card (percentage + stage text + a cancel button)
///   - a share button once it finishes
@interface ModpackExportViewController : UIViewController

/// The profile name preselected at initialization (may be nil, in which case currentProfile is used)
@property (nonatomic, copy, nullable) NSString *preselectedProfileName;

@end

NS_ASSUME_NONNULL_END
