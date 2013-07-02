//
//  XMPPFacebookOwnMessage.m
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 7/1/2013.
//  Copyright (c) 2013 nonatomic. All rights reserved.
//

#import "XMPPFacebookOwnMessage.h"

static NSString * const XMPPFacebookOwnMessageXMLNS = @"http://www.facebook.com/xmpp/messages";

@implementation XMPPFacebookOwnMessage {
	NSMutableArray *_sentMessages;
}

#pragma mark - Initialization

- (id)initWithDispatchQueue:(dispatch_queue_t)queue
{
	if ((self = [super initWithDispatchQueue:queue])) {
		_sentMessages = [NSMutableArray array];
	}
	return self;
}

#pragma mark - XMPPStreamDelegate

// This is implemented as a hotfix for the issue described here:
// https://developers.facebook.com/bugs/158576054322746/
//
// The fix is to keep track of sent Facebook messages and check the body & JID
// in -xmppStream:didReceiveIQ: to determine whether it was something that was
// already sent. An expiry is set to remove the message if an own-message IQ
// isn't received in a certain amount of time.
// 
- (void)xmppStream:(XMPPStream *)sender didSendMessage:(XMPPMessage *)message
{
	XMPPJID *to = message.to;
	if ([to.domain isEqualToString:@"chat.facebook.com"] && message.body.length) {
		[_sentMessages addObject:message];
		[NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(expiryTimerFired:) userInfo:message repeats:NO];
	}
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	NSXMLElement *ownMessage = [iq elementForName:@"own-message" xmlns:XMPPFacebookOwnMessageXMLNS];
	if (ownMessage) {
		NSString *sent = [ownMessage attributeStringValueForName:@"self"];
		if ([sent isEqualToString:@"false"]) {
			NSString *toStr = [ownMessage attributeStringValueForName:@"to"];
			NSString *body = [[ownMessage elementForName:@"body"] stringValue];
			XMPPMessage *originalMessage = nil;
			for (XMPPMessage *message in _sentMessages) {
				if ([message.to.full isEqualToString:toStr] && [message.body isEqualToString:body]) {
					originalMessage = message;
					break;
				}
			}
			if (!originalMessage) {
				XMPPMessage *message = [XMPPMessage messageWithType:@"chat" elementID:iq.elementID];
				if (toStr.length) {
					message.to = [XMPPJID jidWithString:toStr];
				}
				message.body = body;
				[multicastDelegate xmppFacebookOwnMessage:self receivedSentMessage:message];
			} else {
				[_sentMessages removeObject:originalMessage];
			}
			
		}
		return YES;
	}
	return NO;
}

#pragma mark - NSTimer

- (void)expiryTimerFired:(NSTimer *)timer
{
	[_sentMessages removeObject:timer.userInfo];
}
		 
@end
