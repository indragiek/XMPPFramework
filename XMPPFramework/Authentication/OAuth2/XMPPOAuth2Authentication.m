//
//  XMPPOAuth2Authentication.m
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-06-02.
//  Copyright (c) 2013 Indragie Karunaratne. All rights reserved.
//

#import "XMPPOAuth2Authentication.h"
#import "XMPP.h"
#import "XMPPLogging.h"
#import "XMPPInternal.h"
#import "NSData+XMPP.h"
#import "NSXMLElement+XMPP.h"

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

// Log levels: off, error, warn, info, verbose
#if DEBUG
static const int xmppLogLevel = XMPP_LOG_LEVEL_INFO; // | XMPP_LOG_FLAG_TRACE;
#else
static const int xmppLogLevel = XMPP_LOG_LEVEL_WARN;
#endif

@implementation XMPPOAuth2Authentication
{
#if __has_feature(objc_arc_weak)
	__weak XMPPStream *xmppStream;
#else
	__unsafe_unretained XMPPStream *xmppStream;
#endif
	
	NSString *password;
}

+ (NSString *)mechanismName
{
	return @"X-OAUTH2";
}

- (id)initWithStream:(XMPPStream *)stream password:(NSString *)inPassword
{
	if ((self = [super init]))
	{
		xmppStream = stream;
		password = inPassword;
	}
	return self;
}

- (BOOL)start:(NSError **)errPtr
{
	XMPPLogTrace();
	
	NSString *username = [xmppStream.myJID user];
	
	NSString *payload = [NSString stringWithFormat:@"\0%@\0%@", username, password];
	NSString *base64 = [[payload dataUsingEncoding:NSUTF8StringEncoding] base64Encoded];
	
	// <auth xmlns="urn:ietf:params:xml:ns:xmpp-sasl" mechanism="PLAIN">Base-64-Info</auth>
	
	NSXMLElement *auth = [NSXMLElement elementWithName:@"auth" xmlns:@"urn:ietf:params:xml:ns:xmpp-sasl"];
	[auth addAttributeWithName:@"mechanism" stringValue:[self.class mechanismName]];
	[auth addAttributeWithName:@"auth:service" stringValue:@"oauth2"];
	[auth addAttributeWithName:@"xmlns:auth" stringValue:@"http://www.google.com/talk/protocol/auth"];
	[auth setStringValue:base64];
	
	[xmppStream sendAuthElement:auth];
	
	return YES;
}

- (XMPPHandleAuthResponse)handleAuth:(NSXMLElement *)authResponse
{
	XMPPLogTrace();
	
	// We're expecting a success response.
	// If we get anything else we can safely assume it's the equivalent of a failure response.
	
	if ([[authResponse name] isEqualToString:@"success"])
	{
		return XMPP_AUTH_SUCCESS;
	}
	else
	{
		return XMPP_AUTH_FAIL;
	}
}

@end

@implementation XMPPStream (XMPPOAuth2Authentication)

- (BOOL)supportsOAuth2Authentication
{
	return [self supportsAuthenticationMechanism:[XMPPOAuth2Authentication mechanismName]];
}

@end