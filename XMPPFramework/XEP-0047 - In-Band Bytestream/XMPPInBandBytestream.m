//
//  XMPPInBandBytestream.m
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-02-11.
//  Copyright (c) 2013 nonatomic. All rights reserved.
//

#import "XMPPInBandBytestream.h"

static NSString* const XMLNSProtocolIBB = @"http://jabber.org/protocol/ibb";
static NSUInteger const XMPPIBBMinimumBlockSize = 4096;
static NSUInteger const XMPPIBBMaximumBlockSize = 65535;

static inline NSUInteger XMPPIBBValidatedBlockSize(NSUInteger size) {
	return MAX(MIN(size, XMPPIBBMaximumBlockSize), XMPPIBBMinimumBlockSize);
}

@implementation XMPPInBandBytestream {
	NSString *_sid;
}

- (id)initOutgoingBytestreamToJID:(XMPPJID *)jid
						elementID:(NSString *)elementID
							 data:(NSData *)data
{
	if ((self = [super initWithDispatchQueue:NULL])) {
		_remoteJID = jid;
		_data = data;
		_blockSize = XMPPIBBMaximumBlockSize;
		_elementID = elementID ?: [xmppStream generateUUID];
		dispatch_async(moduleQueue, ^{
			[self sendOpenIQ];
		});
	}
	return self;
}

- (id)initIncomingBytestreamRequest:(XMPPIQ *)iq
{
	if ((self = [super initWithDispatchQueue:NULL])) {
		_remoteJID = iq.from;
		_elementID = [iq.elementID copy];
		NSXMLElement *open = [NSXMLElement elementWithName:@"open" xmlns:XMLNSProtocolIBB];
		if (!open) return nil;
		_blockSize = XMPPIBBValidatedBlockSize([open attributeUnsignedIntegerValueForName:@"block-size"]);
		// This seems to have no particular purpose... storing it anyways
		_sid = [open attributeStringValueForName:@"sid"];
		// The stanza attribute will be ignored, because this implementation only supports
		// transfer over IQ stanzas. Transferring binary data over message stanzas, despite
		// being an officially documented method, seems like abuse of the protocol. It should
		// seriously be removed from the XEP-0047 spec, considering that there is no reason
		// why a client can use message stanzas but not IQ stanzas to transfer information.
		dispatch_async(moduleQueue, ^{
			[self sendAcceptIQ];
		});
	}
	return self;
}

#pragma mark - Private

- (void)sendOpenIQ
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	NSXMLElement *open = [NSXMLElement elementWithName:@"open" xmlns:XMLNSProtocolIBB];
	[open addAttributeWithName:@"block-size" stringValue:[@(self.blockSize) stringValue]];
	[open addAttributeWithName:@"sid" stringValue:self.elementID];
	[open addAttributeWithName:@"stanza" stringValue:@"iq"];
	XMPPIQ *iq = [XMPPIQ iqWithType:@"set" to:self.remoteJID elementID:self.elementID child:open];
	[xmppStream sendElement:iq];
}

- (void)sendAcceptIQ
{
	
}
@end
