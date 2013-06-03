//
//  XMPPFramework.h
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-01-13.
//  Copyright (c) 2013 nonatomic. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <XMPPFramework/XMPP.h>
#import <XMPPFramework/XMPPAutoPing.h>
#import <XMPPFramework/XMPPPing.h>
#import <XMPPFramework/XMPPPresence+XEP_0153.h>
#import <XMPPFramework/XMPPMessage+XEP_0085.h>
#import <XMPPFramework/XMPPMessage+XEP_0071.h>
#import <XMPPFramework/XMPPvCardTempModule.h>
#import <XMPPFramework/XMPPvCardTemp.h>
#import <XMPPFramework/XMPPRoster.h>
#import <XMPPFramework/XMPPRosterMemoryStorage.h>
#import <XMPPFramework/XMPPCapabilities.h>
#import <XMPPFramework/XMPPCapabilitiesCoreDataStorage.h>
#import <XMPPFramework/XMPPSoftwareVersion.h>
#import <XMPPFramework/XMPPSIFileTransfer.h>
#import <XMPPFramework/TURNSocket.h>
#import <XMPPFramework/XMPPInBandBytestream.h>
#import <XMPPFramework/XMPPReconnect.h>

// Authentication
#import <XMPPFramework/XMPPPlainAuthentication.h>
#import <XMPPFramework/XMPPOAuth2Authentication.h>
#import <XMPPFramework/XMPPXFacebookPlatformAuthentication.h>
#import <XMPPFramework/XMPPDeprecatedDigestAuthentication.h>
#import <XMPPFramework/XMPPDeprecatedPlainAuthentication.h>
#import <XMPPFramework/XMPPDigestMD5Authentication.h>

// Logging
#import <XMPPFramework/DDAbstractDatabaseLogger.h>
#import <XMPPFramework/DDASLLogger.h>
#import <XMPPFramework/DDLog.h>
#import <XMPPFramework/DDTTYLogger.h>
#import <XMPPFramework/DDFileLogger.h>
#import <XMPPFramework/DispatchQueueLogFormatter.h>