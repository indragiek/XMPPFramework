//
//  XMPPSIFileTransfer.m
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-02-05.
//  Copyright (c) 2013 nonatomic. All rights reserved.
//

#import "XMPPSIFileTransfer.h"
#import "NSDate+XMPPDateTimeProfiles.h"
#import "NSData+XMPP.h"

NSString* const XMLNSJabberSI = @"http://jabber.org/protocol/si";
NSString* const XMLNSJabberSIFileTransfer = @"http://jabber.org/protocol/si/profile/file-transfer";
NSString* const XMPPSIProfileSOCKS5Transfer = @"http://jabber.org/protocol/bytestreams";
NSString* const XMPPSIProfileIBBTransfer = @"http://jabber.org/protocol/ibb";

static NSString* const XMLNSJabberFeatureNeg = @"http://jabber.org/protocol/feature-neg";
static NSString* const XMLNSJabberXData = @"jabber:x:data";
static NSString* const XMLNSXMPPStanzas = @"urn:ietf:params:xml:ns:xmpp-stanzas";

static NSArray *_supportedTransferMechanisms = nil;

@implementation XMPPSIFileTransfer {
	NSMutableArray *_offers;
	NSMutableDictionary *_SOCKS5Transfers;
	NSMutableDictionary *_IBBTransfers;
}

+ (void)load
{
	[super load];
	_supportedTransferMechanisms = @[XMPPSIProfileSOCKS5Transfer, XMPPSIProfileIBBTransfer];
}

#pragma mark - Public API

- (void)sendStreamInitiationOfferForFileName:(NSString *)name
										size:(NSUInteger)size
								 description:(NSString *)description
									mimeType:(NSString *)mimeType
										hash:(NSString *)hash
							lastModifiedDate:(NSDate *)date
							   streamMethods:(NSArray *)methods
					  supportsRangedTransfer:(BOOL)supportsRanged
									   toJID:(XMPPJID *)jid
{
	dispatch_block_t block = ^{
		NSXMLElement *si = [NSXMLElement elementWithName:@"si" xmlns:XMLNSJabberSI];
		[si addAttributeWithName:@"id" stringValue:@"a0"];
		[si addAttributeWithName:@"profile" stringValue:XMLNSJabberSIFileTransfer];
		[si addAttributeWithName:@"mime-type" stringValue:mimeType ?: @"application/octet-stream"];
		NSXMLElement *file = [NSXMLElement elementWithName:@"si" xmlns:XMLNSJabberSIFileTransfer];
		[file addAttributeWithName:@"name" stringValue:name];
		[file addAttributeWithName:@"size" stringValue:[@(size) stringValue]];
		if ([hash length]) {
			[file addAttributeWithName:@"hash" stringValue:hash];
		}
		if (date) {
			[file addAttributeWithName:@"date" stringValue:[date xmppDateTimeString]];
		}
		if ([description length]) {
			NSXMLElement *desc = [NSXMLElement elementWithName:@"desc" stringValue:description];
			[file addChild:desc];
		}
		if (supportsRanged) {
			[file addChild:[NSXMLElement elementWithName:@"range"]];
		}
		[si addChild:file];
		NSXMLElement *feature = [NSXMLElement elementWithName:@"feature" stringValue:XMLNSJabberFeatureNeg];
		NSXMLElement *x = [NSXMLElement elementWithName:@"x" xmlns:XMLNSJabberXData];
		[x addAttributeWithName:@"type" stringValue:@"form"];
		NSXMLElement *field = [NSXMLElement elementWithName:@"field"];
		[field addAttributeWithName:@"var" stringValue:@"stream-method"];
		[field addAttributeWithName:@"type" stringValue:@"list-single"];
		for (NSString *method in methods) {
			NSXMLElement *value = [NSXMLElement elementWithName:@"value" stringValue:method];
			NSXMLElement *option = [NSXMLElement elementWithName:@"option"];
			[option addChild:value];
			[field addChild:option];
		}
		[x addChild:field];
		[feature addChild:x];
		[si addChild:feature];
		
		XMPPIQ *offer = [XMPPIQ iqWithType:@"set" to:jid elementID:[NSString stringWithFormat:@"offer%lu", [_offers count]] child:si];
		[_offers addObject:offer];
		[xmppStream sendElement:offer];
	};
	if (dispatch_get_current_queue() == moduleQueue)
		block();
	else
		dispatch_async(moduleQueue, block);
}

- (void)sendStreamInitiationOfferForFileName:(NSString *)name
										data:(NSData *)data
									mimeType:(NSString *)mimeType
									   toJID:(XMPPJID *)jid
{
	[self sendStreamInitiationOfferForFileName:name
										  size:[data length]
								   description:nil
									  mimeType:mimeType
										  hash:[data md5String]
							  lastModifiedDate:nil
								 streamMethods:_supportedTransferMechanisms
						supportsRangedTransfer:YES
										 toJID:jid];
}

- (void)acceptStreamInitiationOffer:(XMPPIQ *)offer withStreamMethod:(NSString *)method
{
	dispatch_block_t block = ^{
		NSXMLElement *si = [NSXMLElement elementWithName:@"si" xmlns:XMLNSJabberSI];
		NSXMLElement *file = [NSXMLElement elementWithName:@"file" xmlns:XMLNSJabberSIFileTransfer];
		[si addChild:file];
		NSXMLElement *feature = [NSXMLElement elementWithName:@"feature" xmlns:XMLNSJabberFeatureNeg];
		NSXMLElement *x = [NSXMLElement elementWithName:@"x" xmlns:XMLNSJabberXData];
		[x addAttributeWithName:@"type" stringValue:@"submit"];
		NSXMLElement *field = [NSXMLElement elementWithName:@"field"];
		[field addAttributeWithName:@"var" stringValue:@"stream-method"];
		NSXMLElement *value = [NSXMLElement elementWithName:@"value" stringValue:method];
		[field addChild:value];
		[x addChild:field];
		[feature addChild:x];
		[si addChild:feature];
		
		XMPPIQ *result = [XMPPIQ iqWithType:@"result" to:offer.from elementID:offer.elementID child:si];
		[xmppStream sendElement:result];
	};
	if (dispatch_get_current_queue() == moduleQueue)
		block();
	else
		dispatch_async(moduleQueue, block);
}

- (void)rejectStreamInitiationOffer:(XMPPIQ *)offer
{
	dispatch_block_t block = ^{
		NSXMLElement *error = [NSXMLElement elementWithName:@"error"];
		[error addAttributeWithName:@"code" stringValue:@"403"];
		[error addAttributeWithName:@"type" stringValue:@"cancel"];
		NSXMLElement *forbidden = [NSXMLElement elementWithName:@"forbidden" xmlns:XMLNSXMPPStanzas];
		NSXMLElement *text = [NSXMLElement elementWithName:@"text" xmlns:XMLNSXMPPStanzas];
		[text setStringValue:@"Offer Declined"];
		[error addChild:forbidden];
		[error addChild:text];
		XMPPIQ *errorIQ = [XMPPIQ iqWithType:@"error" to:offer.from elementID:offer.elementID child:error];
		[xmppStream sendElement:errorIQ];
	};
	if (dispatch_get_current_queue() == moduleQueue)
		block();
	else
		dispatch_async(moduleQueue, block);
}

- (void)beginTransferForStreamInitiationResult:(XMPPIQ *)result data:(NSData *)data
{
	dispatch_block_t block = ^{
		
	};
	if (dispatch_get_current_queue() == moduleQueue)
		block();
	else
		dispatch_async(moduleQueue, block);
}

#pragma mark - XMPPStreamDelegate

- (void)xmppStream:(XMPPStream *)sender didSendIQ:(XMPPIQ *)iq
{
	if ([_offers containsObject:iq]) {
		[multicastDelegate xmppSIFileTransferDidSendOffer:iq];
	}
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	// Received a stream initiation offer
	if ([iq.type isEqualToString:@"set"]) {
		if ([iq elementForName:@"si" xmlns:XMLNSJabberSI]) {
			[self handleStreamInitiationOffer:iq];
			return YES;
		}
	}
	return NO;
}

#pragma mark - Private

- (void)handleStreamInitiationOffer:(XMPPIQ *)iq
{
	NSXMLElement *si = [iq elementForName:@"si" xmlns:XMLNSJabberSI];
	if ([[si attributeStringValueForName:@"profile"] isEqualToString:XMLNSJabberSIFileTransfer]) {
		// Check for valid file name and file size
		NSXMLElement *file = [si elementForName:@"file" xmlns:XMLNSJabberSIFileTransfer];
		if (![[file attributeStringValueForName:@"name"] length] || ![file attributeIntegerValueForName:@"size"]) {
			[self sendProfileNotUnderstoodErrorForIQ:iq];
		}
		NSArray *streamMethods = [self.class extractStreamMethodsFromIQ:iq];
		__block BOOL hasSupportedStreamMethod = NO;
		[streamMethods enumerateObjectsUsingBlock:^(NSString *method, NSUInteger idx, BOOL *stop) {
			if ([_supportedTransferMechanisms containsObject:method]) {
				hasSupportedStreamMethod = YES;
				*stop = YES;
			}
		}];
		if (hasSupportedStreamMethod) {
			[multicastDelegate xmppSIFileTransferReceivedStreamInitiationOffer:iq];
		} else {
			[self sendNoValidStreamsErrorForIQ:iq];
		}
	} else {
		[self sendProfileNotUnderstoodErrorForIQ:iq];
	}
}

- (void)sendProfileNotUnderstoodErrorForIQ:(XMPPIQ *)iq
{
	NSXMLElement *error = [self.class badRequestErrorElement];
	NSXMLElement *badProfile = [NSXMLElement elementWithName:@"bad-profile" xmlns:XMLNSJabberSI];
	[error addChild:badProfile];
	XMPPIQ *errorIQ = [XMPPIQ iqWithType:@"error" to:iq.from elementID:iq.elementID child:error];
	[xmppStream sendElement:errorIQ];
}

- (void)sendNoValidStreamsErrorForIQ:(XMPPIQ *)iq
{
	NSXMLElement *error = [self.class badRequestErrorElement];
	NSXMLElement *noValidStreams = [NSXMLElement elementWithName:@"no-valid-streams" xmlns:XMLNSJabberSI];
	[error addChild:noValidStreams];
	XMPPIQ *errorIQ = [XMPPIQ iqWithType:@"error" to:iq.from elementID:iq.elementID child:error];
	[xmppStream sendElement:errorIQ];
}

+ (NSArray *)extractStreamMethodsFromIQ:(XMPPIQ *)iq
{
	NSXMLElement *si = [iq elementForName:@"si"];
	NSXMLElement *feature = [si elementForName:@"feature" xmlns:XMLNSJabberFeatureNeg];
	NSXMLElement *x = [feature elementForName:@"x" xmlns:XMLNSJabberXData];
	NSXMLElement *field = [x elementForName:@"field"];
	if ([[field attributeStringValueForName:@"var"] isEqualToString:@"stream-method"]) {
		NSMutableArray *streamMethods = [NSMutableArray array];
		[field.children enumerateObjectsUsingBlock:^(NSXMLElement *child, NSUInteger idx, BOOL *stop) {
			NSXMLElement *value = [child elementForName:@"value"];
			NSString *valueString = [value stringValue];
			if ([valueString length])
				[streamMethods addObject:valueString];
		}];
		return streamMethods;
	}
	return nil;
}

+ (NSXMLElement *)badRequestErrorElement
{
	NSXMLElement *error = [NSXMLElement elementWithName:@"error"];
	[error addAttributeWithName:@"code" stringValue:@"400"];
	[error addAttributeWithName:@"type" stringValue:@"cancel"];
	NSXMLElement *badRequest = [NSXMLElement elementWithName:@"bad-request" xmlns:XMLNSXMPPStanzas];
	[error addChild:badRequest];
	return error;
}
@end
