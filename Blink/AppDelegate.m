////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2019 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

#import "AppDelegate.h"
#import "BKiCloudSyncHandler.h"
#import <BlinkConfig/BlinkPaths.h>
#import "BLKDefaults.h"
#import <BlinkConfig/BKHosts.h>
#import <BlinkConfig/BKPubKey.h>
#import "UICKeyChainStore.h"
#import <ios_system/ios_system.h>
#import <UserNotifications/UserNotifications.h>
#include <libssh/callbacks.h>
#include "xcall.h"
#include "Blink-Swift.h"

#ifdef BLINK_BUILD_ENABLED
extern void build_auto_start_wg_ports(void);
extern void rebind_ports(void);
#endif


@import CloudKit;

@interface AppDelegate () <UNUserNotificationCenterDelegate>
@end

@implementation AppDelegate {
  NSTimer *_suspendTimer;
  UIBackgroundTaskIdentifier _suspendTaskId;
  BOOL _suspendedMode;
  BOOL _enforceSuspension;
}

static NSString * const BLKAPNsTokenDefaultsKey = @"tmux.apns_device_token";
static NSString * const BLKTmuxAPNsKeychainService = @"sh.blink.tmux.apns";
static NSString * const BLKTmuxAPNsKeychainPrefix = @"tmux.apns.private.";

static UICKeyChainStore * _BLKTmuxAPNsKeychain(void) {
  return [UICKeyChainStore keyChainStoreWithService:BLKTmuxAPNsKeychainService];
}

static NSString * _Nullable _BLKTmuxNormalizedServiceBaseURL(NSString *rawURL) {
  NSString *value = [rawURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (value.length == 0) {
    return nil;
  }

  NSURLComponents *components = [NSURLComponents componentsWithString:value];
  if (!components.host.length) {
    return nil;
  }
  NSString *scheme = components.scheme.lowercaseString;
  if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
    return nil;
  }

  components.scheme = scheme;
  components.user = nil;
  components.password = nil;
  components.query = nil;
  components.fragment = nil;

  NSString *path = components.percentEncodedPath.lowercaseString ?: @"";
  if ([path isEqualToString:@"/"] ||
      [path isEqualToString:@"/healthz"] ||
      [path isEqualToString:@"/healthz/"] ||
      [path isEqualToString:@"/v1/healthz"] ||
      [path isEqualToString:@"/v1/healthz/"]) {
    components.percentEncodedPath = @"";
  }

  NSString *normalized = components.string;
  if (normalized.length == 0) {
    return nil;
  }
  if ([normalized hasSuffix:@"/"]) {
    return [normalized substringToIndex:normalized.length - 1];
  }
  return normalized;
}
  
void __on_pipebroken_signal(int signum){
  NSLog(@"PIPE is broken");
}

void __setupProcessEnv(void) {
  
  NSBundle *mainBundle = [NSBundle mainBundle];
  int forceOverwrite = 1;
  NSString *SSL_CERT_FILE = [mainBundle pathForResource:@"cacert" ofType:@"pem"];
  setenv("SSL_CERT_FILE", SSL_CERT_FILE.UTF8String, forceOverwrite);
  
  NSString *locales_path = [mainBundle pathForResource:@"locales" ofType:@"bundle"];
  setenv("PATH_LOCALE", locales_path.UTF8String, forceOverwrite);
  setlocale(LC_ALL, "UTF-8");
  setenv("TERM", "xterm-256color", forceOverwrite);
  setenv("LANG", "en_US.UTF-8", forceOverwrite);
  setenv("VIMRUNTIME", [[mainBundle resourcePath] stringByAppendingPathComponent:@"/vim"].UTF8String, 1);
  ssh_threads_set_callbacks(ssh_threads_get_pthread());
  ssh_init();
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  
  [Migrator perform];

  [AppDelegate reloadDefaults];
  [[UIView appearance] setTintColor:[UIColor blinkTint]];
  
  signal(SIGPIPE, __on_pipebroken_signal);
 
  dispatch_queue_t bgQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
  dispatch_async(bgQueue, ^{
    [BlinkPaths linkDocumentsIfNeeded];
    [BlinkPaths linkICloudDriveIfNeeded];
    
  });

  sideLoading = false; // Turn off extra commands from iOS system
  initializeEnvironment(); // initialize environment variables for iOS system
  dispatch_async(bgQueue, ^{
    addCommandList([[NSBundle mainBundle] pathForResource:@"blinkCommandsDictionary" ofType:@"plist"]); // Load blink commands to ios_system
    __setupProcessEnv(); // we should call this after ios_system initializeEnvironment to override its defaults.
    [AppDelegate _loadProfileVars];
  });
  
  NSString *homePath = BlinkPaths.homePath;
  setenv("HOME", homePath.UTF8String, 1);
  setenv("SSH_HOME", homePath.UTF8String, 1);
  setenv("CURL_HOME", homePath.UTF8String, 1);
  
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc addObserver:self
         selector:@selector(_onSceneDidEnterBackground:)
             name:UISceneDidEnterBackgroundNotification object:nil];
  [nc addObserver:self
           selector:@selector(_onSceneWillEnterForeground:)
               name:UISceneWillEnterForegroundNotification object:nil];
  [nc addObserver:self
         selector:@selector(_onSceneDidActiveNotification:)
             name:UISceneDidActivateNotification object:nil];
  [nc addObserver:self
         selector: @selector(_onScreenConnect)
             name:UIScreenDidConnectNotification object:nil];
  
  [UNUserNotificationCenter currentNotificationCenter].delegate = self;
  [self _configurePushNotifications];
  [self _registerAPNsForConfiguredTmuxHostsIfNeeded];
  
//  [nc addObserver:self selector:@selector(_logEvent:) name:nil object:nil];
//  [nc addObserver:self selector:@selector(_active) name:@"UIApplicationSystemNavigationActionChangedNotification" object:nil];

  [UIApplication sharedApplication].applicationSupportsShakeToEdit = NO;
  
  [_NSFileProviderManager syncWithBKHosts];
  
  [PurchasesUserModelObjc preparePurchasesUserModel];
  
#ifdef BLINK_BUILD_ENABLED
  build_auto_start_wg_ports();
#endif
  
  return YES;
}

- (void)_configurePushNotifications {
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
    switch (settings.authorizationStatus) {
      case UNAuthorizationStatusAuthorized:
      case UNAuthorizationStatusProvisional:
      case UNAuthorizationStatusEphemeral:
        dispatch_async(dispatch_get_main_queue(), ^{
          [UIApplication.sharedApplication registerForRemoteNotifications];
        });
        break;
      case UNAuthorizationStatusNotDetermined:
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                              completionHandler:^(BOOL granted, NSError * _Nullable error) {
          if (error) {
            NSLog(@"[APNs] Permission request error: %@", error.localizedDescription);
          }
          if (granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
              [UIApplication.sharedApplication registerForRemoteNotifications];
            });
          }
        }];
        break;
      case UNAuthorizationStatusDenied:
      default:
        break;
    }
  }];
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
  const unsigned char *dataBuffer = (const unsigned char *)deviceToken.bytes;
  if (!dataBuffer) {
    return;
  }

  NSMutableString *token = [NSMutableString stringWithCapacity:(deviceToken.length * 2)];
  for (NSInteger i = 0; i < deviceToken.length; i++) {
    [token appendFormat:@"%02x", dataBuffer[i]];
  }
  [[NSUserDefaults standardUserDefaults] setObject:token forKey:BLKAPNsTokenDefaultsKey];
  [[NSUserDefaults standardUserDefaults] synchronize];
  [self _registerAPNsForConfiguredTmuxHostsIfNeeded];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
  NSLog(@"[APNs] Failed to register for remote notifications: %@", error.localizedDescription);
}

- (void)_registerAPNsForConfiguredTmuxHostsIfNeeded {
  NSString *apnsToken = [[NSUserDefaults standardUserDefaults] stringForKey:BLKAPNsTokenDefaultsKey];
  if (apnsToken.length == 0) {
    return;
  }

  for (BKHosts *host in [BKHosts allHosts]) {
    if (!(host.tmuxPushEnabled.boolValue)) {
      continue;
    }
    NSString *serviceURL = [host.tmuxServiceURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (serviceURL.length == 0) {
      continue;
    }
    [self _registerAPNSToken:apnsToken forTmuxHost:host];
  }
}

- (void)_registerAPNSToken:(NSString *)apnsToken forTmuxHost:(BKHosts *)host {
  NSString *normalizedURL = _BLKTmuxNormalizedServiceBaseURL(host.tmuxServiceURL ?: @"");
  if (normalizedURL.length == 0) {
    return;
  }
  NSString *serviceToken = [host.tmuxServiceToken stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (serviceToken.length == 0) {
    return;
  }

  NSString *deviceId = host.tmuxPushDeviceId.length > 0 ? host.tmuxPushDeviceId : host.host;
  NSString *deviceName = host.tmuxPushDeviceName.length > 0 ? host.tmuxPushDeviceName : UIDevice.currentDevice.name;
  NSString *serverName = host.host.length > 0 ? host.host : @"tshell";
  if (deviceId.length == 0) {
    return;
  }

  NSURL *registerURL = [NSURL URLWithString:[normalizedURL stringByAppendingString:@"/v1/push/devices/register"]];
  if (!registerURL) {
    return;
  }

  NSMutableURLRequest *registerRequest = [NSMutableURLRequest requestWithURL:registerURL];
  registerRequest.HTTPMethod = @"POST";
  [registerRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [registerRequest setValue:[NSString stringWithFormat:@"Bearer %@", serviceToken] forHTTPHeaderField:@"Authorization"];

  #if DEBUG
    BOOL sandbox = YES;
  #else
    BOOL sandbox = NO;
  #endif

  NSDictionary *registerBody = @{
    @"token": apnsToken,
    @"sandbox": @(sandbox),
    @"device_id": deviceId,
    @"device_name": deviceName,
    @"server_name": serverName
  };
  NSError *registerBodyError = nil;
  registerRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:registerBody options:0 error:&registerBodyError];
  if (registerBodyError) {
    return;
  }

  NSURLSessionDataTask *registerTask = [[NSURLSession sharedSession] dataTaskWithRequest:registerRequest completionHandler:^(NSData * _Nullable registerData, NSURLResponse * _Nullable registerResponse, NSError * _Nullable registerError) {
    if (registerError || !registerData) {
      return;
    }

    NSHTTPURLResponse *registerHTTP = (NSHTTPURLResponse *)registerResponse;
    if (registerHTTP.statusCode < 200 || registerHTTP.statusCode > 299) {
      return;
    }

    NSError *registerJSONError = nil;
    NSDictionary *registerJSON = [NSJSONSerialization JSONObjectWithData:registerData options:0 error:&registerJSONError];
    if (registerJSONError || ![registerJSON isKindOfClass:NSDictionary.class]) {
      return;
    }

    NSString *deviceApiToken = registerJSON[@"device_api_token"];
    dispatch_async(dispatch_get_main_queue(), ^{
      host.tmuxPushDeviceApiToken = deviceApiToken ?: host.tmuxPushDeviceApiToken;
      [BKHosts saveHosts];
    });
  }];
  [registerTask resume];
}

//- (void)_active {
//  [[SmarterTermInput shared] realBecomeFirstResponder];
//}
//- (void)_logEvent:(NSNotification *)n {
//  NSLog(@"event, %@, %@", n.name, n.userInfo);
//  if ([n.name isEqualToString:@"UIApplicationSystemNavigationActionChangedNotification"]) {
//    [[SmarterTermInput shared] realBecomeFirstResponder];
//  }
//
//}

+ (void)reloadDefaults {
  [BLKDefaults loadDefaults];
  [BKPubKey loadIDS];
  [BKHosts loadHosts];
  [AppDelegate _loadProfileVars];
}

+ (NSString * _Nullable)currentAPNSToken {
  return [[NSUserDefaults standardUserDefaults] stringForKey:BLKAPNsTokenDefaultsKey];
}

+ (void)requestRemoteNotificationsRegistrationIfNeeded {
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIApplication.sharedApplication registerForRemoteNotifications];
  });
}

+ (NSString * _Nullable)tmuxAPNsPrivateKeyForHostAlias:(NSString *)hostAlias {
  NSString *alias = [hostAlias stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (alias.length == 0) {
    return nil;
  }
  NSString *keyRef = [BLKTmuxAPNsKeychainPrefix stringByAppendingString:alias];
  return [_BLKTmuxAPNsKeychain() stringForKey:keyRef];
}

+ (void)setTmuxAPNsPrivateKey:(NSString * _Nullable)privateKey forHostAlias:(NSString *)hostAlias {
  NSString *alias = [hostAlias stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (alias.length == 0) {
    return;
  }
  NSString *keyRef = [BLKTmuxAPNsKeychainPrefix stringByAppendingString:alias];
  NSString *value = [privateKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (value.length == 0) {
    [_BLKTmuxAPNsKeychain() removeItemForKey:keyRef];
    return;
  }
  [_BLKTmuxAPNsKeychain() setString:value forKey:keyRef];
}

+ (void)removeTmuxAPNsPrivateKeyForHostAlias:(NSString *)hostAlias {
  NSString *alias = [hostAlias stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (alias.length == 0) {
    return;
  }
  NSString *keyRef = [BLKTmuxAPNsKeychainPrefix stringByAppendingString:alias];
  [_BLKTmuxAPNsKeychain() removeItemForKey:keyRef];
}

+ (void)_loadProfileVars {
  NSCharacterSet *whiteSpace = [NSCharacterSet whitespaceCharacterSet];
  NSString *profile = [NSString stringWithContentsOfFile:[BlinkPaths blinkProfileFile] encoding:NSUTF8StringEncoding error:nil];
  [profile enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
    NSMutableArray<NSString *> *parts = [[line componentsSeparatedByString:@"="] mutableCopy];
    if (parts.count < 2) {
      return;
    }
    
    NSString *varName = [parts.firstObject stringByTrimmingCharactersInSet:whiteSpace];
    if (varName.length == 0) {
      return;
    }
    [parts removeObjectAtIndex:0];
    NSString *varValue = [[parts componentsJoinedByString:@"="] stringByTrimmingCharactersInSet:whiteSpace];
    if ([varValue hasSuffix:@"\""] || [varValue hasPrefix:@"\""]) {
      NSData *data =  [varValue dataUsingEncoding:NSUTF8StringEncoding];
      varValue = [varValue substringWithRange:NSMakeRange(1, varValue.length - 1)];
      if (data) {
        id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
        if ([value isKindOfClass:[NSString class]]) {
          varValue = value;
        }
      }
    }
    if (varValue.length == 0) {
      return;
    }
    BOOL forceOverwrite = 1;
    setenv(varName.UTF8String, varValue.UTF8String, forceOverwrite);
  }];
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
  [[BKiCloudSyncHandler sharedHandler]checkForReachabilityAndSync:nil];
  BOOL handledTmuxNotification = [SpaceController handleTmuxRemoteNotification:userInfo];
  completionHandler(handledTmuxNotification ? UIBackgroundFetchResultNewData : UIBackgroundFetchResultNoData);
}

// MARK: NSUserActivity

- (BOOL)application:(UIApplication *)application willContinueUserActivityWithType:(NSString *)userActivityType 
{
  return YES;
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray * _Nullable))restorationHandler
{
  return YES;
}

- (BOOL)application:(UIApplication *)application shouldAllowExtensionPointIdentifier:(NSString *)extensionPointIdentifier {
  if ([extensionPointIdentifier isEqualToString: UIApplicationKeyboardExtensionPointIdentifier]) {
    return ![BLKDefaults disableCustomKeyboards];
  }
  return YES;
}

#pragma mark - State saving and restoring

- (void)applicationProtectedDataWillBecomeUnavailable:(UIApplication *)application
{
  // If a scene is not yet in the background, then await for it to suspend
  NSArray * scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
  for (UIScene *scene in scenes) {
    if (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive) {
      _enforceSuspension = true;
      return;
    }
  }

  [self _suspendApplicationOnProtectedDataWillBecomeUnavailable];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
  [self _suspendApplicationOnWillTerminate];
}

- (void)_startMonitoringForSuspending
{
  if (_suspendedMode) {
    return;
  }
  
  UIApplication *application = [UIApplication sharedApplication];
  
  [self _cancelApplicationSuspendTask];
  
  _suspendTaskId = [application beginBackgroundTaskWithName:@"Suspend" expirationHandler:^{
    [self _suspendApplicationWithExpirationHandler];
  }];
  
  NSTimeInterval time = MIN(application.backgroundTimeRemaining * 0.9, 5 * 60);
  [_suspendTimer invalidate];
  _suspendTimer = [NSTimer scheduledTimerWithTimeInterval:time
                                                   target:self
                                                 selector:@selector(_suspendApplicationWithSuspendTimer)
                                                 userInfo:nil
                                                  repeats:NO];
}

- (void)_cancelApplicationSuspendTask {
  [_suspendTimer invalidate];
  if (_suspendTaskId != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:_suspendTaskId];
  }
  _suspendTaskId = UIBackgroundTaskInvalid;
}

- (void)_cancelApplicationSuspend {
  [self _cancelApplicationSuspendTask];
 
  // We can't resume if we don't have access to protected data
  if (UIApplication.sharedApplication.isProtectedDataAvailable) {
    if (_suspendedMode) {
#ifdef BLINK_BUILD_ENABLED
      rebind_ports();
#endif
    }

    _suspendedMode = NO;
  }
}

// Simple wrappers to get the reason of failure from call stack
- (void)_suspendApplicationWithSuspendTimer {
  [self _suspendApplication];
}

- (void)_suspendApplicationWithExpirationHandler {
  [self _suspendApplication];
}

- (void)_suspendApplicationOnWillTerminate {
  [self _suspendApplication];
}

- (void)_suspendApplicationOnProtectedDataWillBecomeUnavailable {
  [self _suspendApplication];
}

- (void)_suspendApplication {
  [_suspendTimer invalidate];

  _enforceSuspension = false;
  
  if (_suspendedMode) {
    return;
  }
  
  [[SessionRegistry shared] suspend];
  _suspendedMode = YES;
  [self _cancelApplicationSuspendTask];
}

#pragma mark - Scenes

- (UISceneConfiguration *) application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                               options:(UISceneConnectionOptions *)options {
  for (NSUserActivity * activity in options.userActivities) {
    if ([activity.activityType isEqual:@"com.allenneverland.tshell.whatsnew"]) {
      return [UISceneConfiguration configurationWithName:@"whatsnew"
                                             sessionRole:connectingSceneSession.role];
    }
  }
  return [UISceneConfiguration configurationWithName:@"main"
                                         sessionRole:connectingSceneSession.role];
}



- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
  [SpaceController onDidDiscardSceneSessions: sceneSessions];
}

- (void)_onSceneDidEnterBackground:(NSNotification *)notification {
  NSArray * scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
  for (UIScene *scene in scenes) {
    if (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive) {
      return;
    }
  }
  if (_enforceSuspension) {
    [self _suspendApplication];
  } else {
    [self _startMonitoringForSuspending];
  }
}

- (void)_onSceneWillEnterForeground:(NSNotification *)notification {
  [self _cancelApplicationSuspend];
}

- (void)_onSceneDidActiveNotification:(NSNotification *)notification {
  [self _cancelApplicationSuspend];
}

- (void)_onScreenConnect {
  [BLKDefaults applyExternalScreenCompensation:BLKDefaults.overscanCompensation];
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
  UNNotificationPresentationOptions opts = UNNotificationPresentationOptionSound | UNNotificationPresentationOptionList | UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionBadge;
  completionHandler(opts);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completionHandler {
  NSDictionary *userInfo = response.notification.request.content.userInfo;
  if ([SpaceController handleTmuxRemoteNotification:userInfo]) {
    completionHandler();
    return;
  }

  if ([response.targetScene.delegate isKindOfClass:[SceneDelegate class]]) {
    SceneDelegate *sceneDelegate = (SceneDelegate *)response.targetScene.delegate;
    SpaceController *ctrl = sceneDelegate.spaceController;
    [ctrl moveToShellWithKey:response.notification.request.content.threadIdentifier];
  }
  
  completionHandler();
}

#pragma mark - Menu Building

- (void)buildMenuWithBuilder:(id<UIMenuBuilder>)builder {
  if (builder.system == UIMenuSystem.mainSystem) {
    [MenuController buildMenuWith:builder];
  }
}

@end
