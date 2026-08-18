#import <Security/Security.h>
#import "BaseAuthenticator.h"
#import "ThirdPartyAuthenticator.h"
#import "../LauncherPreferences.h"
#import "../ios_uikit_bridge.h"
#import "../utils.h"

@implementation BaseAuthenticator

static BaseAuthenticator *current = nil;

+ (id)current {
    if (current == nil) {
        // selected_account now stores the accountId (older versions stored the username, and loadSavedName migrates it automatically)
        NSString *savedAccount = getPrefObject(@"internal.selected_account");
        if (savedAccount.length > 0) {
            [self loadSavedName:savedAccount];
        }
    }
    return current;
}

+ (void)setCurrent:(BaseAuthenticator *)auth {
    current = auth;
}

/// Generate a unique accountId from the account data.
/// - Microsoft accounts: use the xuid (the Xbox user hash, globally unique, stable and unchanged after login)
/// - Third-party accounts: use the profileId (the character UUID assigned by the authentication server, unique and stable)
/// - Local accounts: there is no natural unique ID, so a random UUID is generated
/// This way even accounts with the same name are distinguished by accountId and file names no longer collide.
+ (NSString *)generateAccountIdForData:(NSMutableDictionary *)authData {
    // Microsoft accounts: prefer the xuid (the uhs from the XSTS response, globally unique and stable)
    NSString *xuid = authData[@"xuid"];
    if (xuid && [xuid length] > 0) {
        return xuid;
    }
    // Third-party accounts: use the profileId (the character UUID assigned by the authentication server, unique and stable)
    NSString *profileId = authData[@"profileId"];
    if (profileId && [profileId length] > 0 &&
        ![profileId isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
        return profileId;
    }
    // Local accounts: there is no natural unique ID, so generate a random UUID
    return [[NSUUID UUID] UUIDString];
}

+ (id)loadSavedName:(NSString *)accountId {
    // accountId may be a new-format accountId or a legacy username (in the migration case)
    NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), accountId];
    NSMutableDictionary *authData = parseJSONFromFile(path);
    if (authData[@"NSErrorObject"] != nil) {
        NSError *error = ((NSError *)authData[@"NSErrorObject"]);
        if (error.code != NSFileReadNoSuchFileError) {
            showDialog(localize(@"Error", nil), error.localizedDescription);
        }
        return nil;
    }

    // Create an authenticator of the matching type from the account data (initWithData sets the current singleton)
    BaseAuthenticator *auth = nil;
    if ([authData[@"expiresAt"] longValue] == 0) {
        auth = [[LocalAuthenticator alloc] initWithData:authData];
    } else if (authData[@"clientToken"] != nil) {
        // If there is a clientToken, this is a third-party account
        auth = [[ThirdPartyAuthenticator alloc] initWithData:authData];
    } else {
        auth = [[MicrosoftAuthenticator alloc] initWithData:authData];
    }

    // Migrate a legacy account: if authData has no accountId field, it is an old account named by username.
    // Generate an accountId, save it to the new file <accountId>.json, delete the old file <username>.json,
    // migrate the avatar file and update selected_account.
    NSString *existingAccountId = authData[@"accountId"];
    if (existingAccountId == nil || [existingAccountId length] == 0) {
        NSString *newAccountId = [BaseAuthenticator generateAccountIdForData:authData];
        authData[@"accountId"] = newAccountId;

        NSString *newPath = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), newAccountId];
        NSError *saveError = saveJSONToFile(authData, newPath);

        if (saveError == nil) {
            // Delete the old file (if the accountId argument differs from the generated newAccountId, the argument was a legacy username)
            if (![accountId isEqualToString:newAccountId]) {
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            }
            // Migrate the avatar file: <username>.png → <accountId>.png
            // The avatar directory is <Documents>/avatars/, separate from the accounts directory (POJAV_HOME/accounts/)
            NSString *username = authData[@"username"];
            if (username && username.length > 0 && ![username isEqualToString:newAccountId]) {
                NSString *docsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                NSString *oldAvatarPath = [NSString stringWithFormat:@"%@/avatars/%@.png", docsDir, username];
                NSString *newAvatarPath = [NSString stringWithFormat:@"%@/avatars/%@.png", docsDir, newAccountId];
                // Only migrate when the old avatar exists and the new one does not, so nothing is overwritten
                if ([NSFileManager.defaultManager fileExistsAtPath:oldAvatarPath] &&
                    ![NSFileManager.defaultManager fileExistsAtPath:newAvatarPath]) {
                    [NSFileManager.defaultManager moveItemAtPath:oldAvatarPath toPath:newAvatarPath error:nil];
                }
            }
            // Update selected_account: if the currently selected entry is the old username/accountId, switch it to the new accountId
            if ([getPrefObject(@"internal.selected_account") isEqualToString:accountId]) {
                setPrefObject(@"internal.selected_account", newAccountId);
            }
        }
    }

    return auth;
}

- (id)initWithData:(NSMutableDictionary *)data {
    current = self = [self init];
    self.authData = data;
    return self;
}

- (id)initWithInput:(NSString *)string {
    NSMutableDictionary *data = [[NSMutableDictionary alloc] init];
    data[@"input"] = string;
    return [self initWithData:data];
}

- (void)loginWithCallback:(Callback)callback {
}

- (void)refreshTokenWithCallback:(Callback)callback {
}

- (BOOL)saveChanges {
    NSError *error;

    [self.authData removeObjectForKey:@"input"];
    [self.authData removeObjectForKey:@"password"];
    // The oldusername mechanism is obsolete: file names now use the accountId, so a username change no longer requires renaming the file
    [self.authData removeObjectForKey:@"oldusername"];

    // Make sure an accountId exists (generated here as a fallback on first save; the normal login flow already sets it in the subclass)
    NSString *accountId = self.authData[@"accountId"];
    if (accountId == nil || [accountId length] == 0) {
        accountId = [BaseAuthenticator generateAccountIdForData:self.authData];
        self.authData[@"accountId"] = accountId;
    }

    // The file name uses the accountId (the unique identifier), so accounts with the same name no longer collide
    NSString *newPath = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), accountId];
    error = saveJSONToFile(self.authData, newPath);

    if (error != nil) {
        showDialog(@"Error while saving file", error.localizedDescription);
    } else {
        // Save the selected account (its accountId), so the login state can be restored after a restart
        setPrefObject(@"internal.selected_account", accountId);
    }
    return error == nil;
}

@end
