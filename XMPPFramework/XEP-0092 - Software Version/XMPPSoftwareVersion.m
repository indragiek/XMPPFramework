//
//  XMPPSoftwareVersion.m
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-02-05.
//  Copyright (c) 2013 nonatomic. All rights reserved.
//

#import "XMPPSoftwareVersion.h"

static NSString* const XMLNSSoftwareVersion = @"jabber:iq:version";

@implementation XMPPSoftwareVersion {
	NSString *_applicationName;
	NSString *_applicationVersion;
}

#pragma mark - XMPPStream

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	NSXMLElement *query = [iq elementForName:@"query" xmlns:XMLNSSoftwareVersion];
	if (!query) return NO;
	NSString *type = [[query attributeStringValueForName:@"type"] lowercaseString];
	if ([type isEqualToString:@"get"]) {
		[self handleSoftwareVersionRequest:iq];
		return YES;
	}
	return NO;
}

- (void)handleSoftwareVersionRequest:(XMPPIQ *)iq
{
	// This method must be invoked on the moduleQueue
	NSAssert(dispatch_get_current_queue() == moduleQueue, @"Invoked on incorrect queue");
}

#pragma mark - Accessors

- (NSString *)applicationName
{
	__block NSString *result = nil;
	
	dispatch_block_t block = ^{
		result = _applicationName;
	};
	if (dispatch_get_current_queue() == moduleQueue)
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
	if (dispatch_get_current_queue() == moduleQueue)
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
	if (dispatch_get_current_queue() == moduleQueue)
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
	if (dispatch_get_current_queue() == moduleQueue)
		block();
	else
		dispatch_async(moduleQueue, block);
}

@end
