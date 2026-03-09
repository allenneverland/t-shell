////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2018 Blink Mobile Shell Project
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

#import <Foundation/Foundation.h>
@import CloudKit;


enum BKMoshPrediction {
  BKMoshPredictionAdaptive,
  BKMoshPredictionAlways,
  BKMoshPredictionNever,
  BKMoshPredictionExperimental
};

enum BKMoshExperimentalIP {
  BKMoshExperimentalIPNone,
  BKMoshExperimentalIPLocal,
  BKMoshExperimentalIPRemote,
};

enum BKAgentForward {
  BKAgentForwardNo,
  BKAgentForwardConfirm,
  BKAgentForwardYes,
};


@interface BKHosts : NSObject <NSSecureCoding>

@property (nonatomic, strong) NSString *host;
@property (nonatomic, strong) NSString *hostName;
@property (nonatomic, strong) NSNumber *port;
@property (nonatomic, strong) NSString *user;
@property (nonatomic, strong) NSString *passwordRef;
@property (readonly) NSString *password;
@property (nonatomic, strong) NSString *key;
@property (nonatomic, strong) NSString *moshServer;
@property (nonatomic, strong) NSString *moshPredictOverwrite;
@property (nonatomic, strong) NSNumber *moshExperimentalIP;
@property (nonatomic, strong) NSNumber *moshPort;
@property (nonatomic, strong) NSNumber *moshPortEnd;
@property (nonatomic, strong) NSString *moshStartup;
@property (nonatomic, strong) NSNumber *prediction;
@property (nonatomic, strong) NSString *proxyCmd;
@property (nonatomic, strong) NSString *proxyJump;
@property (nonatomic, strong) CKRecordID *iCloudRecordId;
@property (nonatomic, strong) NSDate *lastModifiedTime;
@property (nonatomic, strong) NSNumber *iCloudConflictDetected;
@property (nonatomic, strong) BKHosts *iCloudConflictCopy;
@property (nonatomic, strong) NSString *sshConfigAttachment;
@property (nonatomic, strong) NSString *fpDomainsJSON;
@property (nonatomic, strong) NSNumber *agentForwardPrompt;
@property (nonatomic, strong) NSArray<NSString *> *agentForwardKeys;
// Advanced override for tmux control/push endpoint.
// Leave empty to derive endpoint from hostName automatically.
@property (nonatomic, strong) NSString *tmuxServiceURL;
@property (nonatomic, strong) NSString *tmuxServiceToken;
@property (nonatomic, strong) NSString *tmuxPushDeviceId;
@property (nonatomic, strong) NSString *tmuxPushDeviceName;
@property (nonatomic, strong) NSString *tmuxPushDeviceApiToken;
@property (nonatomic, strong) NSString *tmuxLastRegisteredAPNSToken;
@property (nonatomic, strong) NSNumber *tmuxPushEnabled;
@property (nonatomic, strong) NSString *tmuxAPNSKeyID;
@property (nonatomic, strong) NSString *tmuxAPNSTeamID;
@property (nonatomic, strong) NSString *tmuxAPNSBundleID;

+ (instancetype)withHost:(NSString *)ID;
+ (void)loadHosts NS_SWIFT_NAME(loadHosts());
+ (void)resetHostsiCloudInformation;
+ (BOOL)saveHosts;
+ (BOOL)forceSaveHosts;
+ (instancetype)saveHost:(NSString *)host
             withNewHost:(NSString *)newHost
                hostName:(NSString *)hostName
                 sshPort:(NSString *)sshPort
                    user:(NSString *)user
                password:(NSString *)password
                 hostKey:(NSString *)hostKey
              moshServer:(NSString *)moshServer
    moshPredictOverwrite:(NSString *)moshPredictOverwrite
      moshExperimentalIP:(enum BKMoshExperimentalIP)moshExperimentalIP
           moshPortRange:(NSString *)moshPortRange
              startUpCmd:(NSString *)startUpCmd
              prediction:(enum BKMoshPrediction)prediction
                proxyCmd:(NSString *)proxyCmd
               proxyJump:(NSString *)proxyJump
     sshConfigAttachment:(NSString *)sshConfigAttachment
           fpDomainsJSON:(NSString *)fpDomainsJSON
      agentForwardPrompt:(enum BKAgentForward)agentForwardPrompt
        agentForwardKeys:(NSArray<NSString *> *)agentForwardKeys
          tmuxServiceURL:(NSString *)tmuxServiceURL
        tmuxServiceToken:(NSString *)tmuxServiceToken
        tmuxPushDeviceId:(NSString *)tmuxPushDeviceId
      tmuxPushDeviceName:(NSString *)tmuxPushDeviceName
  tmuxPushDeviceApiToken:(NSString *)tmuxPushDeviceApiToken
         tmuxPushEnabled:(NSNumber *)tmuxPushEnabled
           tmuxAPNSKeyID:(NSString *)tmuxAPNSKeyID
         tmuxAPNSTeamID:(NSString *)tmuxAPNSTeamID
        tmuxAPNSBundleID:(NSString *)tmuxAPNSBundleID
;
+ (void)_replaceHost:(BKHosts *)newHost;
+ (void)updateHost:(NSString *)host withiCloudId:(CKRecordID *)iCloudId andLastModifiedTime:(NSDate *)lastModifiedTime;
+ (void)markHost:(NSString *)host forRecord:(CKRecord *)record withConflict:(BOOL)hasConflict;
+ (NSMutableArray<BKHosts *> *)all;
+ (NSArray<BKHosts *> *)allHosts;
+ (NSInteger)count;
+ (CKRecord *)recordFromHost:(BKHosts *)host;
+ (BKHosts *)hostFromRecord:(CKRecord *)hostRecord;
+ (instancetype)withiCloudId:(CKRecordID *)record;
+ (NSString * _Nullable)tmuxNormalizeBaseURL:(NSString *)rawURL NS_SWIFT_NAME(tmuxNormalizeBaseURL(_:));
+ (NSString * _Nullable)tmuxDefaultBaseURLForHostName:(NSString *)hostName NS_SWIFT_NAME(tmuxDefaultBaseURL(forHostName:));
+ (NSString * _Nullable)tmuxResolvedBaseURLForHost:(BKHosts *)host NS_SWIFT_NAME(tmuxResolvedBaseURL(for:));
+ (BOOL)tmuxEndpointOverrideRequiresHTTPSForHost:(BKHosts *)host NS_SWIFT_NAME(tmuxEndpointOverrideRequiresHTTPS(for:));
+ (BOOL)tmuxEndpointOverrideIsInvalidForHost:(BKHosts *)host NS_SWIFT_NAME(tmuxEndpointOverrideIsInvalid(for:));


- (id)initWithAlias:(NSString *)alias
           hostName:(NSString *)hostName
            sshPort:(NSString *)sshPort
               user:(NSString *)user
        passwordRef:(NSString *)passwordRef
            hostKey:(NSString *)hostKey
         moshServer:(NSString *)moshServer
      moshPortRange:(NSString *)moshPortRange
moshPredictOverwrite:(NSString *)moshPredictOverwrite
 moshExperimentalIP:(enum BKMoshExperimentalIP)moshExperimentalIP
         startUpCmd:(NSString *)startUpCmd
         prediction:(enum BKMoshPrediction)prediction
           proxyCmd:(NSString *)proxyCmd
          proxyJump:(NSString *)proxyJump
sshConfigAttachment:(NSString *)sshConfigAttachment
      fpDomainsJSON:(NSString *)fpDomainsJSON
 agentForwardPrompt:(enum BKAgentForward)agentForwardPrompt
   agentForwardKeys:(NSArray<NSString *> *)agentForwardKeys
     tmuxServiceURL:(NSString *)tmuxServiceURL
   tmuxServiceToken:(NSString *)tmuxServiceToken
   tmuxPushDeviceId:(NSString *)tmuxPushDeviceId
 tmuxPushDeviceName:(NSString *)tmuxPushDeviceName
 tmuxPushDeviceApiToken:(NSString *)tmuxPushDeviceApiToken
    tmuxPushEnabled:(NSNumber *)tmuxPushEnabled
      tmuxAPNSKeyID:(NSString *)tmuxAPNSKeyID
    tmuxAPNSTeamID:(NSString *)tmuxAPNSTeamID
   tmuxAPNSBundleID:(NSString *)tmuxAPNSBundleID;

@end
