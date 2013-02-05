//
//  XMPPSoftwareVersion.h
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-02-05.
//  Copyright (c) 2013 nonatomic. All rights reserved.
//

#import <XMPPFramework/XMPPFramework.h>

/* 
 * Module that handles queries for jabber:iq:version
 * and returns software and operating system version information
 */
@interface XMPPSoftwareVersion : XMPPModule
@property (nonatomic, copy) NSString *applicationName;
@property (nonatomic, copy) NSString *applicationVersion;
@end
