//
//  XMPPSoftwareVersion.m
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-02-05.
//  Copyright (c) 2013 Indragie Karunaratne. All rights reserved.
//

#import "XMPPSoftwareVersion.h"

NSString* const XMLNSJabberIQVersion = @"jabber:iq:version";

@implementation XMPPSoftwareVersion {
	NSString *_applicationName;
	NSString *_applicationVersion;
}

#pragma mark - XMPPStream

/*
 * Check for incoming requests for jabber:iq:version and respond to them
 */
- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	NSXMLElement *query = [iq elementForName:@"query" xmlns:XMLNSJabberIQVersion];
	if (!query) return NO;
	NSString *type = [[query attributeStringValueForName:@"type"] lowercaseString];
	if ([type isEqualToString:@"get"]) {
		[self handleSoftwareVersionRequest:iq];
		return YES;
	}
	return NO;
}

/*
 Sends an IQ result stanza containing application and operating system version information
 */
- (void)handleSoftwareVersionRequest:(XMPPIQ *)iq
{
	// This method must be invoked on the moduleQueue
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	NSXMLElement *query = [NSXMLElement elementWithName:@"query" xmlns:XMLNSJabberIQVersion];
	if ([self.applicationName length]) {
		NSXMLElement *name = [NSXMLElement elementWithName:@"name" stringValue:self.applicationName];
		[query addChild:name];
	}
	if ([self.applicationVersion length]) {
		NSXMLElement *version = [NSXMLElement elementWithName:@"version" stringValue:self.applicationVersion];
		[query addChild:version];
	}
	NSString *osVersion = [[NSProcessInfo processInfo] operatingSystemVersionString];
	NSString *operatingSystem = [NSString stringWithFormat:@"Mac OS X %@", osVersion];
	NSXMLElement *os = [NSXMLElement elementWithName:@"os" stringValue:operatingSystem];
	[query addChild:os];
	XMPPIQ *response = [XMPPIQ iqWithType:@"result" to:iq.from elementID:iq.elementID child:query];
	[xmppStream sendElement:response];
}

#pragma mark - Accessors

- (NSString *)applicationName
{
	__block NSString *result = nil;
	
	dispatch_block_t block = ^{
		result = _applicationName;
	};
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_sync(moduleQueue, block);
	return result;
}

- (void)setApplicationName:(NSString *)applicationName
{
	dispatch_block_t block = ^{
		_applicationName = [applicationName copy];
	};
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_async(moduleQueue, block);
}

- (NSString *)applicationVersion;
{
	__block NSString *result = nil;
	
	dispatch_block_t block = ^{
		result = _applicationVersion;
	};
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_sync(moduleQueue, block);
	return result;
}

- (void)setApplicationVersion:(NSString *)applicationVersion
{
	dispatch_block_t block = ^{
		_applicationVersion = [applicationVersion copy];
	};
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_async(moduleQueue, block);
}

@end
