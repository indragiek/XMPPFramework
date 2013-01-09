//
//  XMPPServiceDiscovery.m
//  FlamingoXMPP
//
//  Created by Indragie Karunaratne on 2013-01-08.
//  Copyright (c) 2013 Indragie Karunaratne. All rights reserved.
//

#import "XMPPServiceDiscovery.h"
#import "NSXMLElement+XMPP.h"
#import "XMPPStream.h"
#import "XMPPJID.h"

static NSString* const XMPPServiceDiscoveryIQID = @"service-info";
static NSString* const XMPPServiceDiscoveryErrorDomain = @"XMPPServiceDiscoveryErrorDomain";

@implementation XMPPServiceDiscovery

#pragma mark - Public API

- (void)requestServiceInformation
{
	XMPPIQ *get = [XMPPIQ iqWithType:@"get"];
	
	[get addAttributeWithName:@"from" stringValue:[self.xmppStream.myJID description]];
	[get addAttributeWithName:@"to" stringValue:self.xmppStream.hostName];
	[get addAttributeWithName:@"id" stringValue:XMPPServiceDiscoveryIQID];
	NSXMLElement *query = [NSXMLElement elementWithName:@"query" xmlns:@"http://jabber.org/protocol/disco#info"];
	[get addChild:query];
	[self.xmppStream sendElement:get];
}

#pragma mark - Delegate Callbacks

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	if (![[iq attributeStringValueForName:@"id"] isEqualToString:XMPPServiceDiscoveryIQID])
		return NO;
	if ([iq isResultIQ]) {
		if ([multicastDelegate respondsToSelector:@selector(xmppServiceDiscovery:requestReturnedResult:)])
			[multicastDelegate xmppServiceDiscovery:self requestReturnedResult:iq];
		return YES;
	}
	if ([iq isErrorIQ]) {
		NSXMLElement *errorElement = [iq childErrorElement];
		if ([errorElement childCount]) {
			NSString *errorReason, *errorDescription = nil;
			NSXMLElement *suberrorElement = (NSXMLElement *)[errorElement childAtIndex:0];
			if ([suberrorElement.name isEqualToString:@"item-not-found"]) {
				errorDescription = @"Item not found.";
				errorReason = @"JID of the specified target entity does not exist.";
			} else if ([suberrorElement.name isEqualToString:@"service-unavailable"]) {
				errorDescription = @"Service unavailable.";
				errorReason = @"The service does not support service discovery.";
			}
			NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:2];
			if (errorReason) userInfo[NSLocalizedFailureReasonErrorKey] = errorReason;
			if (errorDescription) userInfo[NSLocalizedDescriptionKey] = errorDescription;
			NSError *error = [NSError errorWithDomain:XMPPServiceDiscoveryErrorDomain
												 code:0 userInfo:userInfo];
			if ([multicastDelegate respondsToSelector:@selector(xmppServiceDiscovery:requestFailedWithError:)])
				[multicastDelegate xmppServiceDiscovery:self requestFailedWithError:error];
			return YES;
		}
	}
	return NO;
}

@end
