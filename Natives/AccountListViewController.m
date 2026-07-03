#import <AuthenticationServices/AuthenticationServices.h>

#import "authenticator/BaseAuthenticator.h"
#import "authenticator/ThirdPartyAuthenticator.h"
#import "AccountListViewController.h"
#import "AccountLoginViewController.h"
#import "ThirdPartyLoginViewController.h"
#import "AFNetworking.h"
#import "LauncherPreferences.h"
#import "UIImageView+AFNetworking.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface AccountListViewController()<ASWebAuthenticationPresentationContextProviding>

@property(nonatomic, strong) NSMutableArray *accountList;
@property(nonatomic) ASWebAuthenticationSession *authVC;

@end

@implementation AccountListViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    if (self.accountList == nil) {
        self.accountList = [NSMutableArray array];
    } else {
        [self.accountList removeAllObjects];
    }

    // List accounts
    NSString *listPath = [NSString stringWithFormat:@"%s/accounts", getenv("POJAV_HOME")];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:listPath error:nil];
    for(NSString *file in files) {
        NSString *path = [listPath stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        [fm fileExistsAtPath:path isDirectory:(&isDir)];
        if(!isDir && [file hasSuffix:@".json"]) {
            [self.accountList addObject:parseJSONFromFile(path)];
        }
    }

    [self.tableView setSeparatorStyle:UITableViewCellSeparatorStyleSingleLine];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.accountList.count + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }

    if (indexPath.row == self.accountList.count) {
        cell.imageView.image = [UIImage imageNamed:@"IconAdd"];
        cell.textLabel.text = localize(@"login.option.add", nil);
        return cell;
    }

    NSDictionary *selected = self.accountList[indexPath.row];
    // By default, display the saved username
    cell.textLabel.text = selected[@"username"];
    if ([selected[@"username"] hasPrefix:@"Demo."]) {
        // Remove the prefix "Demo."
        cell.textLabel.text = [selected[@"username"] substringFromIndex:5];
        cell.detailTextLabel.text = localize(@"login.option.demo", nil);
    } else if (selected[@"clientToken"] != nil) {
        // This is a third-party account
        cell.detailTextLabel.text = localize(@"login.option.3rdparty", nil);
    } else if (selected[@"xboxGamertag"] == nil) {
        cell.detailTextLabel.text = localize(@"login.option.local", nil);
    } else {
        // Display the Xbox gamertag for online accounts
        cell.detailTextLabel.text = selected[@"xboxGamertag"];
    }

    cell.imageView.contentMode = UIViewContentModeCenter;
    [cell.imageView setImageWithURL:[NSURL URLWithString:[selected[@"profilePicURL"] stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"]] placeholderImage:[UIImage imageNamed:@"DefaultAccount"]];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];

    if (indexPath.row == self.accountList.count) {
        [self actionAddAccount:cell];
        return;
    }

    self.modalInPresentation = YES;
    self.tableView.userInteractionEnabled = NO;
    [self addActivityIndicatorTo:cell];

    id callback = ^(id status, BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^(){
            [self callbackMicrosoftAuth:status success:success forCell:cell];
        });
    };
    
    // Check if this is a third party account
    NSDictionary *accountData = self.accountList[indexPath.row];
    if (accountData[@"clientToken"] != nil) {
        // This is a third party account
        [[ThirdPartyAuthenticator loadSavedName:accountData[@"username"]] refreshTokenWithCallback:callback];
    } else {
        // This is a Microsoft or local account
        [[BaseAuthenticator loadSavedName:accountData[@"username"]] refreshTokenWithCallback:callback];
    }
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        // TODO: invalidate token

        NSString *str = self.accountList[indexPath.row][@"username"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), str];
        if (self.whenDelete != nil) {
            self.whenDelete(str);
        }
        NSString *xuid = self.accountList[indexPath.row][@"xuid"];
        if (xuid) {
            [MicrosoftAuthenticator clearTokenDataOfProfile:xuid];
        }
        [fm removeItemAtPath:path error:nil];
        [self.accountList removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.row == self.accountList.count) {
        return UITableViewCellEditingStyleNone;
    } else {
        return UITableViewCellEditingStyleDelete;
    }
}

- (NSDictionary *)parseQueryItems:(NSString *)url {
    NSMutableDictionary *result = [NSMutableDictionary new];
    NSArray<NSURLQueryItem *> *queryItems = [NSURLComponents componentsWithString:url].queryItems;
    for (NSURLQueryItem *item in queryItems) {
        result[item.name] = item.value;
    }
    return result;
}

- (void)actionAddAccount:(UITableViewCell *)sender {
    // 参照 FCL：push 卡片式登录方式选择页（替代原来的 ActionSheet）
    AccountLoginViewController *loginVC = [[AccountLoginViewController alloc] init];
    loginVC.onSelectLoginType = ^(AccountLoginType type) {
        // 选完登录方式后 pop 回账户列表，再触发对应登录流程
        [self.navigationController popViewControllerAnimated:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            switch (type) {
                case AccountLoginTypeMicrosoft:
                    [self actionLoginMicrosoft:sender];
                    break;
                case AccountLoginTypeLittleSkin:
                    [self actionLoginLittleSkin:sender];
                    break;
                case AccountLoginTypeThirdParty:
                    [self actionLoginThirdParty:sender];
                    break;
                case AccountLoginTypeLocal:
                    [self actionLoginLocal:sender];
                    break;
            }
        });
    };
    [self.navigationController pushViewController:loginVC animated:YES];
}

- (void)actionLoginLocal:(UIView *)sender {
    if (getPrefBool(@"warnings.local_warn")) {
        setPrefBool(@"warnings.local_warn", NO);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"login.warn.title.localmode", nil) message:localize(@"login.warn.message.localmode", nil) preferredStyle:UIAlertControllerStyleActionSheet];
        alert.popoverPresentationController.sourceView = sender;
        alert.popoverPresentationController.sourceRect = sender.bounds;
        UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {[self actionLoginLocal:sender];}];
        [alert addAction:ok];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIAlertController *controller = [UIAlertController alertControllerWithTitle:localize(@"Sign in", nil) message:localize(@"login.option.local", nil) preferredStyle:UIAlertControllerStyleAlert];
    [controller addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = localize(@"login.alert.field.username", nil);
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.borderStyle = UITextBorderStyleRoundedRect;
    }];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray *textFields = controller.textFields;
        UITextField *usernameField = textFields[0];
        if (usernameField.text.length < 3 || usernameField.text.length > 16) {
            controller.message = localize(@"login.error.username.outOfRange", nil);
            [self presentViewController:controller animated:YES completion:nil];
        } else {
            id callback = ^(id status, BOOL success) {
                self.whenItemSelected();
                [self dismissViewControllerAnimated:YES completion:nil];
            };
            [[[LocalAuthenticator alloc] initWithInput:usernameField.text] loginWithCallback:callback];
        }
    }]];
    [controller addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)actionLoginThirdParty:(UIView *)sender {
    // 参照 FCL：push 卡片式第三方登录表单页（替代原 UIAlertController 三字段输入）
    ThirdPartyLoginViewController *vc = [[ThirdPartyLoginViewController alloc] init];
    vc.mode = ThirdPartyLoginModeCustom;
    __weak typeof(self) weakSelf = self;
    vc.onLoginComplete = ^(BOOL success, NSString *errorMessage) {
        if (success) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
            weakSelf.whenItemSelected();
        }
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)actionLoginLittleSkin:(UIView *)sender {
    // 参照 FCL：push 卡片式 LittleSkin 登录表单页（替代原 UIAlertController 双字段输入）
    // LittleSkin 端点固定为 https://littleskin.cn/api/yggdrasil，由 VC 内部预设
    ThirdPartyLoginViewController *vc = [[ThirdPartyLoginViewController alloc] init];
    vc.mode = ThirdPartyLoginModeLittleSkin;
    __weak typeof(self) weakSelf = self;
    vc.onLoginComplete = ^(BOOL success, NSString *errorMessage) {
        if (success) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
            weakSelf.whenItemSelected();
        }
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)actionLoginMicrosoft:(UITableViewCell *)sender {
    NSURL *url = [NSURL URLWithString:@"https://login.live.com/oauth20_authorize.srf?client_id=00000000402b5328&response_type=code&scope=service%3A%3Auser.auth.xboxlive.com%3A%3AMBI_SSL&redirect_url=https%3A%2F%2Flogin.live.com%2Foauth20_desktop.srf"];

    self.authVC =
        [[ASWebAuthenticationSession alloc] initWithURL:url
        callbackURLScheme:@"ms-xal-00000000402b5328"
        completionHandler:^(NSURL * _Nullable callbackURL, NSError * _Nullable error)
    {
        if (callbackURL == nil) {
            if (error.code != ASWebAuthenticationSessionErrorCodeCanceledLogin) {
                showDialog(localize(@"Error", nil), error.localizedDescription);
            }
            return;
        }
        // NSLog(@"URL returned = %@", [callbackURL absoluteString]);

        NSDictionary *queryItems = [self parseQueryItems:callbackURL.absoluteString];
        if (queryItems[@"code"]) {
            dispatch_async(dispatch_get_main_queue(), ^(){
                self.modalInPresentation = YES;
                self.tableView.userInteractionEnabled = NO;
                [self addActivityIndicatorTo:sender];
            });
            id callback = ^(id status, BOOL success) {
                if ([status isKindOfClass:NSString.class] && [status isEqualToString:@"DEMO"] && success) {
                    showDialog(localize(@"login.warn.title.demomode", nil), localize(@"login.warn.message.demomode", nil));
                }
                dispatch_async(dispatch_get_main_queue(), ^(){
                    [self callbackMicrosoftAuth:status success:success forCell:sender];
                });
            };
            [[[MicrosoftAuthenticator alloc] initWithInput:queryItems[@"code"]] loginWithCallback:callback];
        } else {
            if ([queryItems[@"error"] hasPrefix:@"access_denied"]) {
                // Ignore access denial responses
                return;
            }
            showDialog(localize(@"Error", nil), queryItems[@"error_description"]);
        }
    }];

    self.authVC.prefersEphemeralWebBrowserSession = YES;
    self.authVC.presentationContextProvider = self;

    if ([self.authVC start] == NO) {
        showDialog(localize(@"Error", nil), @"Unable to open Safari");
    }
}

- (void)addActivityIndicatorTo:(UITableViewCell *)cell {
    UIActivityIndicatorViewStyle indicatorStyle = UIActivityIndicatorViewStyleMedium;
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:indicatorStyle];
    cell.accessoryView = indicator;
    [indicator sizeToFit];
    [indicator startAnimating];
}

- (void)removeActivityIndicatorFrom:(UITableViewCell *)cell {
    UIActivityIndicatorView *indicator = (id)cell.accessoryView;
    [indicator stopAnimating];
    cell.accessoryView = nil;
}

- (void)callbackMicrosoftAuth:(id)status success:(BOOL)success forCell:(UITableViewCell *)cell {
    if (status != nil) {
        if (success) {
            // Успешный вход с некоторым сообщением
            if ([status isKindOfClass:[NSError class]]) {
                cell.detailTextLabel.text = [status localizedDescription];
            } else {
                if ([status isKindOfClass:[NSString class]] && [status isEqualToString:@"DEMO"]) {
                    showDialog(localize(@"login.warn.title.demomode", nil), localize(@"login.warn.message.demomode", nil));
                }
                cell.detailTextLabel.text = [status isKindOfClass:[NSString class]] ? status : @"";
            }
        } else {
            // Ошибка аутентификации
            self.modalInPresentation = NO;
            self.tableView.userInteractionEnabled = YES;
            [self removeActivityIndicatorFrom:cell];
            
            if ([status isKindOfClass:[NSError class]]) {
                cell.detailTextLabel.text = [status localizedDescription];
                NSData *errorData = ((NSError *)status).userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
                if (errorData) {
                    NSString *errorStr = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
                    NSLog(@"[MSA] Error: %@", errorStr);
                    showDialog(localize(@"Error", nil), errorStr);
                } else {
                    showDialog(localize(@"Error", nil), [status localizedDescription]);
                }
            } else if ([status isKindOfClass:[NSString class]]) {
                cell.detailTextLabel.text = status;
                showDialog(localize(@"Error", nil), status);
            } else {
                // Handle case where status is neither NSError nor NSString
                cell.detailTextLabel.text = @"";
                showDialog(localize(@"Error", nil), localize(@"login.error.invalid_response", nil));
            }
        }
    } else if (success) {
        // Успешный вход без сообщений
        self.whenItemSelected();
        [self removeActivityIndicatorFrom:cell];
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - UIPopoverPresentationControllerDelegate
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

#pragma mark - ASWebAuthenticationPresentationContextProviding
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return UIApplication.sharedApplication.windows.firstObject;
}

@end
