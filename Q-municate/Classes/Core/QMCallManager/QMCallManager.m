//
//  QMCallManager.m
//  Q-municate
//
//  Created by Vitaliy Gorbachov on 5/10/16.
//  Copyright © 2016 Quickblox. All rights reserved.
//

#import "QMCallManager.h"
#import "QMCore.h"
#import "QMCallViewController.h"
#import "QMSoundManager.h"
#import "QMPermissions.h"
#import "QMNotification.h"
#import <mach/mach.h>

static const NSTimeInterval kQMAnswerTimeInterval = 60.0f;
static const NSTimeInterval kQMDisconnectTimeInterval = 30.0f;
static const NSTimeInterval kQMDialingTimeInterval = 5.0f;

@interface QMCallManager ()

<
QBRTCClientDelegate
>

@property (weak, nonatomic) QMCore <QMServiceManagerProtocol>*serviceManager;

@property (strong, nonatomic, readwrite) QBRTCSession *session;
@property (assign, nonatomic, readwrite) BOOL hasActiveCall;

@property (strong, nonatomic) NSTimer *soundTimer;
@property (strong, nonatomic, readonly) UIViewController *rootViewController;

@property (strong, nonatomic) QMCallViewController *callViewController;

@end

@implementation QMCallManager

@dynamic serviceManager;
@dynamic rootViewController;

- (void)serviceWillStart {
    
    [QBRTCConfig setAnswerTimeInterval:kQMAnswerTimeInterval];
    [QBRTCConfig setDisconnectTimeInterval:kQMDisconnectTimeInterval];
    [QBRTCConfig setDialingTimeInterval:kQMDialingTimeInterval];
    
    [[QBRTCClient instance] addDelegate:self];
}

#pragma mark - Call managing

- (void)callToUserWithID:(NSUInteger)userID conferenceType:(QBRTCConferenceType)conferenceType {
    
    @weakify(self);
    [self checkPermissionsWithConferenceType:conferenceType completion:^(BOOL granted) {
        
        @strongify(self);
        
        if (!granted) {
            // no permissions
            return;
        }
        
        if (self.session != nil) {
            // session in progress
            return;
        }
        
        self.session = [[QBRTCClient instance] createNewSessionWithOpponents:@[@(userID)]
                                                          withConferenceType:conferenceType];
        
        if (self.session == nil) {
            // failed to create session
            return;
        }
        
        [[QBRTCSoundRouter instance] initialize];
        
        QBRTCSoundRoute soundRoute = conferenceType == QBRTCConferenceTypeVideo ? QBRTCSoundRouteSpeaker : QBRTCSoundRouteReceiver;
        [[QBRTCSoundRouter instance] setCurrentSoundRoute:soundRoute];
        
        [self startPlayingCallingSound];
        
        // instantiating view controller
        QMCallState callState = conferenceType == QBRTCConferenceTypeVideo ? QMCallStateOutgoingVideoCall : QMCallStateOutgoingAudioCall;
        self.callViewController = [QMCallViewController callControllerWithState:callState];
        
        QBUUser *opponentUser = [self.serviceManager.usersService.usersMemoryStorage userWithID:userID];
        NSString *opponentName = opponentUser.fullName ?: [NSString stringWithFormat:@"%tu", userID];
        NSString *pushText = [NSString stringWithFormat:@"%@ %@", opponentName, NSLocalizedString(@"QM_STR_IS_CALLING_YOU", nil)];
        [QMNotification sendPushNotificationToUser:opponentUser withText:pushText];
        
        [self.rootViewController presentViewController:self.callViewController
                                              animated:NO
                                            completion:^{
                                                
                                                [self.session startCall:nil];
                                            }];
    }];
}

#pragma mark - Setters

- (void)setHasActiveCall:(BOOL)hasActiveCall {
    
    if (_hasActiveCall != hasActiveCall) {
        
        _hasActiveCall = hasActiveCall;
        
        if (!hasActiveCall) {
            
            [self.serviceManager.chatManager disconnectFromChatIfNeeded];
        }
    }
}

#pragma mark - Getters

- (UIViewController *)rootViewController {
    
    return [[UIApplication sharedApplication].windows.firstObject rootViewController];
}

- (QBUUser *)opponentUser {
    
    if (self.session == nil) {
        // no active session
        return nil;
    }
    
    NSUInteger opponentID;
    
    NSUInteger initiatorID = [self.session.initiatorID unsignedIntegerValue];
    if (initiatorID == self.serviceManager.currentProfile.userData.ID) {
        
        opponentID = [self.session.opponentsIDs.firstObject unsignedIntegerValue];
    }
    else {
        
        opponentID = initiatorID;
    }
    
    QBUUser *opponentUser = [self.serviceManager.usersService.usersMemoryStorage userWithID:opponentID];
    
    return opponentUser;
}

#pragma mark - QBRTCClientDelegate

- (void)didReceiveNewSession:(QBRTCSession *)session userInfo:(NSDictionary *)__unused userInfo {
    
    if (self.session != nil) {
        // session in progress
        [session rejectCall:nil];
        return;
    }
    
    if (session.initiatorID.unsignedIntegerValue == self.serviceManager.currentProfile.userData.ID) {
        // skipping call from ourselves
        return;
    }
    
    [[QBRTCSoundRouter instance] initialize];
    [[QBRTCSoundRouter instance] setCurrentSoundRoute:QBRTCSoundRouteSpeaker];
    
    self.session = session;
    
    [self startPlayingRingtoneSound];
    
    // initializing controller
    QMCallState callState = session.conferenceType == QBRTCConferenceTypeVideo ? QMCallStateIncomingVideoCall : QMCallStateIncomingAudioCall;
    self.callViewController = [QMCallViewController callControllerWithState:callState];
    
    [self.rootViewController presentViewController:self.callViewController
                                          animated:NO
                                        completion:nil];
}

- (void)session:(QBRTCSession *)session updatedStatsReport:(QBRTCStatsReport *)report forUserID:(NSNumber *)__unused userID {
    
    NSMutableString *result = [NSMutableString string];
    NSString *systemStatsFormat = @"(cpu)%ld%%\n";
    [result appendString:[NSString stringWithFormat:systemStatsFormat,
                          (long)QBRTCGetCpuUsagePercentage()]];
    
    // Connection stats.
    NSString *connStatsFormat = @"CN %@ms | %@->%@/%@ | (s)%@ | (r)%@\n";
    [result appendString:[NSString stringWithFormat:connStatsFormat,
                          report.connectionRoundTripTime,
                          report.localCandidateType, report.remoteCandidateType, report.transportType,
                          report.connectionSendBitrate, report.connectionReceivedBitrate]];
    
    if (session.conferenceType == QBRTCConferenceTypeVideo) {
        
        // Video send stats.
        NSString *videoSendFormat = @"VS (input) %@x%@@%@fps | (sent) %@x%@@%@fps\n"
        "VS (enc) %@/%@ | (sent) %@/%@ | %@ms | %@\n";
        [result appendString:[NSString stringWithFormat:videoSendFormat,
                              report.videoSendInputWidth, report.videoSendInputHeight, report.videoSendInputFps,
                              report.videoSendWidth, report.videoSendHeight, report.videoSendFps,
                              report.actualEncodingBitrate, report.targetEncodingBitrate,
                              report.videoSendBitrate, report.availableSendBandwidth,
                              report.videoSendEncodeMs,
                              report.videoSendCodec]];
        
        // Video receive stats.
        NSString *videoReceiveFormat =
        @"VR (recv) %@x%@@%@fps | (decoded)%@ | (output)%@fps | %@/%@ | %@ms\n";
        [result appendString:[NSString stringWithFormat:videoReceiveFormat,
                              report.videoReceivedWidth, report.videoReceivedHeight, report.videoReceivedFps,
                              report.videoReceivedDecodedFps,
                              report.videoReceivedOutputFps,
                              report.videoReceivedBitrate, report.availableReceiveBandwidth,
                              report.videoReceivedDecodeMs]];
    }
    // Audio send stats.
    NSString *audioSendFormat = @"AS %@ | %@\n";
    [result appendString:[NSString stringWithFormat:audioSendFormat,
                          report.audioSendBitrate, report.audioSendCodec]];
    
    // Audio receive stats.
    NSString *audioReceiveFormat = @"AR %@ | %@ | %@ms | (expandrate)%@";
    [result appendString:[NSString stringWithFormat:audioReceiveFormat,
                          report.audioReceivedBitrate, report.audioReceivedCodec, report.audioReceivedCurrentDelay,
                          report.audioReceivedExpandRate]];
    
    ILog(@"%@", result);
}

- (void)session:(QBRTCSession *)session connectedToUser:(NSNumber *)__unused userID {
    
    if (self.session == session) {
        // stopping calling sounds
        [self stopAllSounds];
    }
}

- (void)sessionDidClose:(QBRTCSession *)session {
    
    if (self.session != session) {
        // may be we rejected some one else call
        // while talking with another person
        return;
    }
    
    [self stopAllSounds];
    
    self.hasActiveCall = NO;
    
    // settings sound router to speaker in order
    // to play end of call sound in it
    [[QBRTCSoundRouter instance] setCurrentSoundRoute:QBRTCSoundRouteSpeaker];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        
        [QMSoundManager playEndOfCallSound];
        [self.delegate callManager:self willCloseCurrentSession:session];
        
        [self.rootViewController dismissViewControllerAnimated:NO completion:^{
            
            if (session.conferenceType == QBRTCConferenceTypeVideo) {
                
                [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleDefault];
            }
            
            self.session = nil;
            self.callViewController = nil;
        }];
    });
}

#pragma mark - ICE servers

- (NSArray *)quickbloxICE {
    
    NSString *password = @"baccb97ba2d92d71e26eb9886da5f1e0";
    NSString *userName = @"quickblox";
    
    NSArray *urls = @[
                      @"turn.quickblox.com",            //USA
                      @"turnsingapore.quickblox.com",   //Singapore
                      @"turnireland.quickblox.com"      //Ireland
                      ];
    
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:urls.count];
    
    for (NSString *url in urls) {
        
        QBRTCICEServer *stunServer = [QBRTCICEServer serverWithURL:[NSString stringWithFormat:@"stun:%@", url]
                                                          username:@""
                                                          password:@""];
        
        
        QBRTCICEServer *turnUDPServer = [QBRTCICEServer serverWithURL:[NSString stringWithFormat:@"turn:%@:3478?transport=udp", url]
                                                             username:userName
                                                             password:password];
        
        QBRTCICEServer *turnTCPServer = [QBRTCICEServer serverWithURL:[NSString stringWithFormat:@"turn:%@:3478?transport=tcp", url]
                                                             username:userName
                                                             password:password];
        
        [result addObjectsFromArray:@[stunServer, turnTCPServer, turnUDPServer]];
    }
    
    return result;
}

#pragma mark - Sound management

- (void)startPlayingCallingSound {
    
    [self stopAllSounds];
    [QMSoundManager playCallingSound];
    self.soundTimer = [NSTimer scheduledTimerWithTimeInterval:[QBRTCConfig dialingTimeInterval]
                                                       target:[QMSoundManager class]
                                                     selector:@selector(playCallingSound)
                                                     userInfo:nil
                                                      repeats:YES];
}

- (void)startPlayingRingtoneSound {
    
    [self stopAllSounds];
    [QMSoundManager playRingtoneSound];
    self.soundTimer = [NSTimer scheduledTimerWithTimeInterval:[QBRTCConfig dialingTimeInterval]
                                                       target:[QMSoundManager class]
                                                     selector:@selector(playRingtoneSound)
                                                     userInfo:nil
                                                      repeats:YES];
}

- (void)stopAllSounds {
    
    if (self.soundTimer != nil) {
        
        [self.soundTimer invalidate];
        self.soundTimer = nil;
    }
    
    [[QMSoundManager instance] stopAllSounds];
}

#pragma mark - Permissions check

- (void)checkPermissionsWithConferenceType:(QBRTCConferenceType)conferenceType completion:(PermissionBlock)completion {
    
    @weakify(self);
    [QMPermissions requestPermissionToMicrophoneWithCompletion:^(BOOL granted) {
        
        @strongify(self);
        if (granted) {
            
            switch (conferenceType) {
                    
                case QBRTCConferenceTypeAudio:
                    
                    if (completion) {
                        
                        completion(granted);
                    }
                    
                    break;
                    
                case QBRTCConferenceTypeVideo: {
                    
                    [QMPermissions requestPermissionToCameraWithCompletion:^(BOOL videoGranted) {
                        
                        if (!videoGranted) {
                            
                            // showing error alert with a suggestion
                            // to go to the settings
                            [self showAlertWithTitle:NSLocalizedString(@"QM_STR_CAMERA_ERROR", nil)
                                             message:NSLocalizedString(@"QM_STR_NO_PERMISSIONS_TO_CAMERA", nil)];
                        }
                        
                        if (completion) {
                            
                            completion(videoGranted);
                        }
                    }];
                    
                    break;
                }
            }
        }
        else {
            
            // showing error alert with a suggestion
            // to go to the settings
            [self showAlertWithTitle:NSLocalizedString(@"QM_STR_MICROPHONE_ERROR", nil)
                             message:NSLocalizedString(@"QM_STR_NO_PERMISSIONS_TO_MICROPHONE", nil)];
            
            if (completion) {
                
                completion(granted);
            }
        }
    }];
}

#pragma mark - Helpers

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    
    UIAlertController *alertController = [UIAlertController
                                          alertControllerWithTitle:title
                                          message:message
                                          preferredStyle:UIAlertControllerStyleAlert];
    
    [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"QM_STR_CANCEL", nil)
                                                        style:UIAlertActionStyleCancel
                                                      handler:^(UIAlertAction * _Nonnull __unused action) {
                                                          
                                                      }]];
    
    [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"QM_STR_SETTINGS", nil)
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction * _Nonnull __unused action) {
                                                          
                                                          [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
                                                      }]];
    
    UIViewController *viewController = [(UITabBarController *)[UIApplication sharedApplication].keyWindow.rootViewController selectedViewController];
    [viewController presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Statistic

NSInteger QBRTCGetCpuUsagePercentage() {
    // Create an array of thread ports for the current task.
    const task_t task = mach_task_self();
    thread_act_array_t thread_array;
    mach_msg_type_number_t thread_count;
    if (task_threads(task, &thread_array, &thread_count) != KERN_SUCCESS) {
        return -1;
    }
    
    // Sum cpu usage from all threads.
    float cpu_usage_percentage = 0;
    thread_basic_info_data_t thread_info_data = {};
    mach_msg_type_number_t thread_info_count;
    for (size_t i = 0; i < thread_count; ++i) {
        thread_info_count = THREAD_BASIC_INFO_COUNT;
        kern_return_t ret = thread_info(thread_array[i],
                                        THREAD_BASIC_INFO,
                                        (thread_info_t)&thread_info_data,
                                        &thread_info_count);
        if (ret == KERN_SUCCESS) {
            cpu_usage_percentage +=
            100.f * (float)thread_info_data.cpu_usage / TH_USAGE_SCALE;
        }
    }
    
    // Dealloc the created array.
    vm_deallocate(task, (vm_address_t)thread_array,
                  sizeof(thread_act_t) * thread_count);
    return lroundf(cpu_usage_percentage);
}

@end
