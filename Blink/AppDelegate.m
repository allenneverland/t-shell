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
#import <SSH/SSH.h>
#import "UICKeyChainStore.h"
#import <ios_system/ios_system.h>
#import <UserNotifications/UserNotifications.h>
#import <math.h>
#import <CommonCrypto/CommonDigest.h>
#include "xcall.h"
#include "Blink-Swift.h"

#ifdef BLINK_BUILD_ENABLED
extern void build_auto_start_wg_ports(void);
extern void rebind_ports(void);
#endif


@import CloudKit;

@interface AppDelegate () <UNUserNotificationCenterDelegate>
- (void)_requestTmuxPushRegistrationForHostAlias:(NSString *)hostAlias;
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
static NSTimeInterval const BLKTmuxAPNSBackgroundThrottleSeconds = 20;
static NSInteger const BLKTmuxAPNSBackgroundMaxAttempts = 4;

static dispatch_queue_t _BLKTmuxAPNSRegistrationQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create("sh.blink.tmux.apns.registration", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static NSMutableSet<NSString *> * _BLKTmuxAPNSInFlightHosts(void) {
  static NSMutableSet<NSString *> *set;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    set = [NSMutableSet set];
  });
  return set;
}

static NSMutableDictionary<NSString *, NSDate *> * _BLKTmuxAPNSLastAttemptByHost(void) {
  static NSMutableDictionary<NSString *, NSDate *> *map;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    map = [NSMutableDictionary dictionary];
  });
  return map;
}

static UICKeyChainStore * _BLKTmuxAPNsKeychain(void) {
  return [UICKeyChainStore keyChainStoreWithService:BLKTmuxAPNsKeychainService];
}

static NSString * _Nullable _BLKAPNSEnvironmentFromEmbeddedProvision(void) {
  NSURL *provisionURL = [NSBundle.mainBundle URLForResource:@"embedded" withExtension:@"mobileprovision"];
  if (!provisionURL) {
    return nil;
  }

  NSData *rawData = [NSData dataWithContentsOfURL:provisionURL];
  if (rawData.length == 0) {
    return nil;
  }

  NSString *rawText = [[NSString alloc] initWithData:rawData encoding:NSISOLatin1StringEncoding];
  if (rawText.length == 0) {
    return nil;
  }

  NSRange plistStart = [rawText rangeOfString:@"<?xml"];
  NSRange plistEnd = [rawText rangeOfString:@"</plist>"];
  if (plistStart.location == NSNotFound || plistEnd.location == NSNotFound || plistEnd.location <= plistStart.location) {
    return nil;
  }

  NSUInteger plistLength = (plistEnd.location + plistEnd.length) - plistStart.location;
  NSString *plistSlice = [rawText substringWithRange:NSMakeRange(plistStart.location, plistLength)];
  NSData *plistData = [plistSlice dataUsingEncoding:NSUTF8StringEncoding];
  if (plistData.length == 0) {
    return nil;
  }

  NSError *error = nil;
  id root = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:nil error:&error];
  if (error || ![root isKindOfClass:NSDictionary.class]) {
    return nil;
  }

  NSDictionary *dict = (NSDictionary *)root;
  NSDictionary *entitlements = [dict[@"Entitlements"] isKindOfClass:NSDictionary.class] ? dict[@"Entitlements"] : nil;
  NSString *environment = [entitlements[@"aps-environment"] isKindOfClass:NSString.class] ? entitlements[@"aps-environment"] : nil;
  return environment.length > 0 ? environment : nil;
}

static NSString * _BLKTrimmedOrEmpty(NSString *value) {
  if (!value) {
    return @"";
  }
  return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString * _BLKTmuxServiceTokenFingerprint(NSString *serviceToken) {
  NSString *cleanToken = _BLKTrimmedOrEmpty(serviceToken);
  if (cleanToken.length == 0) {
    return @"";
  }

  NSData *tokenData = [cleanToken dataUsingEncoding:NSUTF8StringEncoding];
  if (tokenData.length == 0) {
    return @"";
  }

  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(tokenData.bytes, (CC_LONG)tokenData.length, digest);

  NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
    [hex appendFormat:@"%02x", digest[i]];
  }
  return hex;
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
  SSHInitializeRuntime();
}

+ (void)prepareShellRuntimeSynchronously {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sideLoading = false; // Turn off extra commands from iOS system
    initializeEnvironment(); // initialize environment variables for iOS system

    NSString *blinkCommandListPath = [[NSBundle mainBundle] pathForResource:@"blinkCommandsDictionary" ofType:@"plist"];
    if (blinkCommandListPath.length == 0) {
      NSLog(@"[shell] blinkCommandsDictionary.plist not found. Builtin blink commands may be unavailable.");
    } else {
      NSError *commandListError = addCommandList(blinkCommandListPath); // Load blink commands to ios_system
      if (commandListError != nil) {
        NSLog(@"[shell] Failed loading blinkCommandsDictionary.plist: %@", commandListError.localizedDescription);
      }
    }

    // Call this after ios_system initializeEnvironment to override ios_system defaults.
    __setupProcessEnv();
  });
}

+ (NSArray<NSString *> *)availableShellCommands {
  return commandsAsArray();
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

  [AppDelegate prepareShellRuntimeSynchronously];
  dispatch_async(bgQueue, ^{
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
  NSString *apnsToken = [[[NSUserDefaults standardUserDefaults] stringForKey:BLKAPNsTokenDefaultsKey]
    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (apnsToken.length == 0) {
    return;
  }

  for (BKHosts *host in [BKHosts allHosts]) {
    if (!(host.tmuxPushEnabled.boolValue)) {
      continue;
    }
    NSString *resolvedURL = [BKHosts tmuxResolvedBaseURLForHost:host];
    if (resolvedURL.length == 0) {
      NSString *alias = host.host.length > 0 ? host.host : @"(unknown)";
      if ([BKHosts tmuxEndpointOverrideRequiresHTTPSForHost:host]) {
        NSLog(@"[tmux] Skipping APNs registration for %@: endpoint override uses insecure HTTP. Migrate to HTTPS.", alias);
      } else if ([BKHosts tmuxEndpointOverrideIsInvalidForHost:host]) {
        NSLog(@"[tmux] Skipping APNs registration for %@: endpoint override is invalid. Use a valid HTTPS endpoint.", alias);
      }
      continue;
    }

    NSString *serviceToken = _BLKTrimmedOrEmpty(host.tmuxServiceToken);
    if (serviceToken.length == 0) {
      continue;
    }

    NSString *deviceApiToken = _BLKTrimmedOrEmpty(host.tmuxPushDeviceApiToken);
    NSString *lastRegisteredToken = _BLKTrimmedOrEmpty(host.tmuxLastRegisteredAPNSToken);
    NSString *lastRegisteredEndpoint = _BLKTrimmedOrEmpty(host.tmuxLastRegisteredEndpoint);
    NSString *lastRegisteredTokenHash = _BLKTrimmedOrEmpty(host.tmuxLastRegisteredServiceTokenHash);
    NSString *serviceTokenHash = _BLKTmuxServiceTokenFingerprint(serviceToken);
    BOOL registrationFresh =
      deviceApiToken.length > 0 &&
      [lastRegisteredToken isEqualToString:apnsToken] &&
      [lastRegisteredEndpoint isEqualToString:resolvedURL] &&
      [lastRegisteredTokenHash isEqualToString:serviceTokenHash];
    if (registrationFresh) {
      continue;
    }

    [self _enqueueAPNSTokenRegistration:apnsToken forTmuxHost:host];
  }
}

- (void)_requestTmuxPushRegistrationForHostAlias:(NSString *)hostAlias {
  NSString *cleanAlias = _BLKTrimmedOrEmpty(hostAlias);
  if (cleanAlias.length == 0) {
    return;
  }

  BKHosts *targetHost = nil;
  for (BKHosts *host in [BKHosts allHosts]) {
    NSString *alias = _BLKTrimmedOrEmpty(host.host);
    NSString *hostName = _BLKTrimmedOrEmpty(host.hostName);
    BOOL matchAlias = [alias caseInsensitiveCompare:cleanAlias] == NSOrderedSame;
    BOOL matchHostName = [hostName caseInsensitiveCompare:cleanAlias] == NSOrderedSame;
    if (matchAlias || matchHostName) {
      targetHost = host;
      break;
    }
  }

  if (!targetHost || !targetHost.tmuxPushEnabled.boolValue) {
    return;
  }

  targetHost.tmuxPushDeviceApiToken = @"";
  targetHost.tmuxLastRegisteredAPNSToken = @"";
  targetHost.tmuxLastRegisteredEndpoint = @"";
  targetHost.tmuxLastRegisteredServiceTokenHash = @"";
  [BKHosts saveHosts];

  [AppDelegate requestRemoteNotificationsRegistrationIfNeeded];

  NSString *apnsToken = _BLKTrimmedOrEmpty([AppDelegate currentAPNSToken]);
  if (apnsToken.length == 0) {
    return;
  }
  [self _enqueueAPNSTokenRegistration:apnsToken forTmuxHost:targetHost];
}

- (void)_enqueueAPNSTokenRegistration:(NSString *)apnsToken forTmuxHost:(BKHosts *)host {
  NSString *hostKey = [self _tmuxAPNSHostKey:host];
  if (hostKey.length == 0) {
    return;
  }

  __block BOOL shouldStart = NO;
  dispatch_sync(_BLKTmuxAPNSRegistrationQueue(), ^{
    NSMutableSet<NSString *> *inFlight = _BLKTmuxAPNSInFlightHosts();
    if ([inFlight containsObject:hostKey]) {
      return;
    }

    NSDate *lastAttempt = _BLKTmuxAPNSLastAttemptByHost()[hostKey];
    if (lastAttempt && [[NSDate date] timeIntervalSinceDate:lastAttempt] < BLKTmuxAPNSBackgroundThrottleSeconds) {
      return;
    }

    [inFlight addObject:hostKey];
    _BLKTmuxAPNSLastAttemptByHost()[hostKey] = [NSDate date];
    shouldStart = YES;
  });

  if (!shouldStart) {
    return;
  }

  [self _registerAPNSToken:apnsToken forTmuxHost:host hostKey:hostKey attempt:1];
}

- (NSString *)_tmuxAPNSHostKey:(BKHosts *)host {
  NSString *alias = [host.host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (alias.length > 0) {
    return alias;
  }
  NSString *hostName = [host.hostName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (hostName.length > 0) {
    return hostName;
  }
  return @"";
}

- (void)_finishAPNSTokenRegistrationForHostKey:(NSString *)hostKey {
  if (hostKey.length == 0) {
    return;
  }
  dispatch_async(_BLKTmuxAPNSRegistrationQueue(), ^{
    [_BLKTmuxAPNSInFlightHosts() removeObject:hostKey];
  });
}

- (BOOL)_shouldRetryAPNSTokenRegistrationForError:(NSError *)error statusCode:(NSInteger)statusCode {
  if (error != nil) {
    return YES;
  }
  return statusCode == 429 || (statusCode >= 500 && statusCode <= 599);
}

- (NSTimeInterval)_retryDelayForAPNSTokenAttempt:(NSInteger)attempt {
  NSInteger bounded = MAX(0, MIN(attempt - 1, 4));
  NSTimeInterval base = pow(2.0, bounded);
  NSTimeInterval jitter = ((double)arc4random_uniform(1000) / 1000.0) * 0.75;
  return MIN(base + jitter, 12.0);
}

- (void)_registerAPNSToken:(NSString *)apnsToken forTmuxHost:(BKHosts *)host hostKey:(NSString *)hostKey attempt:(NSInteger)attempt {
  NSString *normalizedURL = [BKHosts tmuxResolvedBaseURLForHost:host];
  if (normalizedURL.length == 0) {
    [self _finishAPNSTokenRegistrationForHostKey:hostKey];
    return;
  }
  NSString *serviceToken = _BLKTrimmedOrEmpty(host.tmuxServiceToken);
  if (serviceToken.length == 0) {
    [self _finishAPNSTokenRegistrationForHostKey:hostKey];
    return;
  }

  NSString *deviceId = host.tmuxPushDeviceId.length > 0 ? host.tmuxPushDeviceId : host.host;
  NSString *deviceName = host.tmuxPushDeviceName.length > 0 ? host.tmuxPushDeviceName : UIDevice.currentDevice.name;
  NSString *serverName = host.host.length > 0 ? host.host : @"tshell";
  if (deviceId.length == 0) {
    [self _finishAPNSTokenRegistrationForHostKey:hostKey];
    return;
  }

  NSURL *registerURL = [NSURL URLWithString:[normalizedURL stringByAppendingString:@"/v1/push/devices/register"]];
  if (!registerURL) {
    [self _finishAPNSTokenRegistrationForHostKey:hostKey];
    return;
  }

  NSMutableURLRequest *registerRequest = [NSMutableURLRequest requestWithURL:registerURL];
  registerRequest.HTTPMethod = @"POST";
  registerRequest.timeoutInterval = 8;
  [registerRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [registerRequest setValue:[NSString stringWithFormat:@"Bearer %@", serviceToken] forHTTPHeaderField:@"Authorization"];

  BOOL sandbox = [AppDelegate isAPNSSandboxEnvironment];

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
    [self _finishAPNSTokenRegistrationForHostKey:hostKey];
    return;
  }

  NSURLSessionDataTask *registerTask = [[NSURLSession sharedSession] dataTaskWithRequest:registerRequest completionHandler:^(NSData * _Nullable registerData, NSURLResponse * _Nullable registerResponse, NSError * _Nullable registerError) {
    NSHTTPURLResponse *registerHTTP = (NSHTTPURLResponse *)registerResponse;
    NSInteger statusCode = registerHTTP.statusCode;
    BOOL retryable = [self _shouldRetryAPNSTokenRegistrationForError:registerError statusCode:statusCode];
    BOOL hasData = registerData.length > 0;
    if ((registerError || !hasData || statusCode < 200 || statusCode > 299) && retryable && attempt < BLKTmuxAPNSBackgroundMaxAttempts) {
      NSTimeInterval delay = [self _retryDelayForAPNSTokenAttempt:attempt];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _registerAPNSToken:apnsToken forTmuxHost:host hostKey:hostKey attempt:attempt + 1];
      });
      return;
    }

    if (registerError || !hasData || statusCode < 200 || statusCode > 299) {
      if (statusCode == 401 || statusCode == 403) {
        dispatch_async(dispatch_get_main_queue(), ^{
          host.tmuxPushDeviceApiToken = @"";
          host.tmuxLastRegisteredAPNSToken = @"";
          host.tmuxLastRegisteredEndpoint = @"";
          host.tmuxLastRegisteredServiceTokenHash = @"";
          [BKHosts saveHosts];
        });
      }
      [self _finishAPNSTokenRegistrationForHostKey:hostKey];
      return;
    }

    NSError *registerJSONError = nil;
    NSDictionary *registerJSON = [NSJSONSerialization JSONObjectWithData:registerData options:0 error:&registerJSONError];
    if (registerJSONError || ![registerJSON isKindOfClass:NSDictionary.class]) {
      [self _finishAPNSTokenRegistrationForHostKey:hostKey];
      return;
    }

    NSString *deviceApiToken = [registerJSON[@"device_api_token"] isKindOfClass:NSString.class] ? registerJSON[@"device_api_token"] : @"";
    if (deviceApiToken.length == 0) {
      [self _finishAPNSTokenRegistrationForHostKey:hostKey];
      return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      host.tmuxPushDeviceApiToken = deviceApiToken;
      host.tmuxLastRegisteredAPNSToken = apnsToken;
      host.tmuxLastRegisteredEndpoint = normalizedURL;
      host.tmuxLastRegisteredServiceTokenHash = _BLKTmuxServiceTokenFingerprint(serviceToken);
      [BKHosts saveHosts];
      [self _finishAPNSTokenRegistrationForHostKey:hostKey];
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

+ (BOOL)isAPNSSandboxEnvironment {
  static dispatch_once_t onceToken;
  static BOOL sandbox = YES;

  dispatch_once(&onceToken, ^{
    BOOL resolved = NO;
    NSString *environment = _BLKAPNSEnvironmentFromEmbeddedProvision();
    if (environment.length > 0) {
      NSString *lower = environment.lowercaseString;
      if ([lower isEqualToString:@"development"]) {
        sandbox = YES;
        resolved = YES;
      } else if ([lower isEqualToString:@"production"]) {
        sandbox = NO;
        resolved = YES;
      }
    }

    if (!resolved) {
      #if DEBUG
        sandbox = YES;
      #else
        sandbox = NO;
      #endif
    }
  });

  return sandbox;
}

+ (void)requestRemoteNotificationsRegistrationIfNeeded {
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIApplication.sharedApplication registerForRemoteNotifications];
  });
}

+ (void)requestTmuxPushRegistrationForHostAlias:(NSString *)hostAlias {
  NSString *cleanAlias = _BLKTrimmedOrEmpty(hostAlias);
  if (cleanAlias.length == 0) {
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    AppDelegate *delegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
    if (![delegate isKindOfClass:AppDelegate.class]) {
      return;
    }
    [delegate _requestTmuxPushRegistrationForHostAlias:cleanAlias];
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
