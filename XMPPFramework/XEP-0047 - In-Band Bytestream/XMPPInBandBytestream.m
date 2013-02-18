//
//  XMPPInBandBytestream.m
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-02-11.
//  Copyright (c) 2013 nonatomic. All rights reserved.
//

#import "XMPPInBandBytestream.h"
#import "NSData+XMPP.h"

static NSString* const XMLNSProtocolIBB = @"http://jabber.org/protocol/ibb";
static NSUInteger const XMPPIBBMinimumBlockSize = 4096;
static NSUInteger const XMPPIBBMaximumBlockSize = 65535;

static NSString* const XMPPIBBErrorDomain = @"XMPPInBandBytestreamErrorDomain";

static inline NSUInteger XMPPIBBValidatedBlockSize(NSUInteger size) {
	return MAX(MIN(size, XMPPIBBMaximumBlockSize), XMPPIBBMinimumBlockSize);
}

@implementation XMPPInBandBytestream {
	NSString *_sid;
	NSUInteger _seq;
	NSUInteger _byteOffset;
	BOOL _transferClosed;
	NSMutableData *_receivedData;
}

- (id)initOutgoingBytestreamToJID:(XMPPJID *)jid
						elementID:(NSString *)elementID
							 data:(NSData *)data
{
	if ((self = [super initWithDispatchQueue:NULL])) {
		_remoteJID = jid;
		_data = data;
		_blockSize = XMPPIBBMaximumBlockSize;
		// Generate a unique ID when an elementID is not given
		_elementID = elementID ?: [xmppStream generateUUID];
		_sid = _elementID;
		_byteOffset = 0;
		_outgoing = YES;
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
		// Validate the block size to ensure that the size is acceptable given
		// the minimum and maximum limits
		_blockSize = XMPPIBBValidatedBlockSize([open attributeUnsignedIntegerValueForName:@"block-size"]);
		// Unique identifier used in close, open, and data elements
		_sid = [open attributeStringValueForName:@"sid"];
		_byteOffset = 0;
		// NSMutableData for concatenating received chunks of data
		_receivedData = [NSMutableData data];
		_outgoing = NO;
		// The stanza attribute will be ignored, because this implementation only supports
		// transfer over IQ stanzas. Transferring binary data over message stanzas, despite
		// being an officially documented method, seems like abuse of the protocol. It should
		// seriously be removed from the XEP-0047 spec, considering that there is no reason
		// why a client can use message stanzas but not IQ stanzas to transfer information.
	}
	return self;
}

- (void)start
{
	dispatch_block_t block = ^{
		if (self.outgoing) {
			[self sendOpenIQ];
		} else {
			[self sendAcceptIQ];
		}
	};
	if (dispatch_get_current_queue() == moduleQueue)
		block();
	else
		dispatch_async(moduleQueue, block);
}

#pragma mark - XMPPStreamDelegate

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	// Filter out IQ elements pertaining to this transfer
	if ([iq.elementID isEqualToString:self.elementID]) {
		if ([iq.type isEqualToString:@"error"]) {
			return [self handleErrorIQ:iq];
			// Result is send when the receiver has accepted the transfer
			// and wants us to begin sending the data
		} else if ([iq.type isEqualToString:@"result"]) {
			[self sendDataIQ];
			return YES;
		} else if ([iq.type isEqualToString:@"set"]) {
			// Data sent by the remote peer
			if ([iq elementForName:@"data" xmlns:XMLNSProtocolIBB]) {
				[self handleReceivedDataIQ:iq];
				return YES;
			// Remote peer has closed the connection, indicating that the transfer is complete
			} else if ([iq elementForName:@"close" xmlns:XMLNSProtocolIBB]) {
				[self handleCloseIQ:iq];
				return YES;
			}
		}
	}
	return NO;
}

#pragma mark - Errors

+ (NSError *)serviceUnavailableError
{
	return [NSError errorWithDomain:XMPPIBBErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"The receiver does not support in band bytestreams."}];
}

+ (NSError *)notAcceptableError
{
	return [NSError errorWithDomain:XMPPIBBErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"The receiver has rejected the transfer."}];
}

+ (NSError *)resourceConstraintError
{
	return [NSError errorWithDomain:XMPPIBBErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"The receiver has requested a block size that is too small."}];
}

#pragma mark - Private

- (BOOL)handleErrorIQ:(XMPPIQ *)iq
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	NSXMLElement *error = [iq elementForName:@"error"];
	static NSString *XMLNSXMPPStanzas = @"urn:ietf:params:xml:ns:xmpp-stanzas";
	// The receiver does not support in band bytestreams
	if ([error elementForName:@"service-unavailable" xmlns:XMLNSXMPPStanzas]) {
		[multicastDelegate xmppIBBTransfer:self failedWithError:[self.class serviceUnavailableError]];
		return YES;
	// The receiver wants smaller block size
	} else if ([error elementForName:@"resource-constraint" xmlns:XMLNSXMPPStanzas]) {
		// Decrement the block size and try again if possible
		if ([self decrementBlockSize]) {
			[self sendOpenIQ];
		} else {
			// Otherwise the transfer has failed
			[multicastDelegate xmppIBBTransfer:self failedWithError:[self.class resourceConstraintError]];
		}
		return YES;
	// Receiver has denied the transfer
	} else if ([error elementForName:@"not-acceptable" xmlns:XMLNSXMPPStanzas]) {
		[multicastDelegate xmppIBBTransfer:self failedWithError:[self.class notAcceptableError]];
		return YES;
	}
	return NO;
}

- (void)handleReceivedDataIQ:(XMPPIQ *)iq
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		[multicastDelegate xmppIBBTransferDidBegin:self];
	});
	NSXMLElement *data = [iq elementForName:@"data" xmlns:XMLNSProtocolIBB];
	NSString *base64String = data.stringValue;
	if ([base64String length]) {
		NSData *base64Data = [base64String dataUsingEncoding:NSASCIIStringEncoding];
		NSData *decodedData = [base64Data base64Decoded];
		[_receivedData appendData:decodedData];
		[multicastDelegate xmppIBBTransfer:self didReadDataOfLength:[decodedData length]];
	}
	[self sendAcceptIQ];
}

- (void)handleCloseIQ:(XMPPIQ *)iq
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	_data = _receivedData;
	_receivedData = nil;
	_transferClosed = YES;
	[self sendAcceptIQ];
	[multicastDelegate xmppIBBTransferDidEnd:self];
}

// Returns YES if the block size has been decremented without hitting the minimum limit
// This method cuts the block size in half in the case that the receiver has requested
// a smaller block size
- (BOOL)decrementBlockSize
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	_blockSize = _blockSize / 2;
	return (_blockSize > XMPPIBBMinimumBlockSize);
}

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
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	XMPPIQ *iq = [XMPPIQ iqWithType:@"result" to:self.remoteJID elementID:self.elementID];
	[xmppStream sendElement:iq];
}

- (void)sendDataIQ
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	// Ignore subsequent calls to this method once the transfer has been closed
	if (_transferClosed) return;
	// Call the delegate the first time some data is about to be transferred
	// to inform it that the transfer has started
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		[multicastDelegate xmppIBBTransferDidBegin:self];
	});
	NSRange dataRange = NSMakeRange(_byteOffset, self.blockSize);
	NSUInteger length = [self.data length];
	if (NSMaxRange(dataRange) > length) {
		dataRange = NSMakeRange(_byteOffset, length - _byteOffset);
	}
	if (dataRange.length) {
		NSXMLElement *data = [NSXMLElement elementWithName:@"data" xmlns:XMLNSProtocolIBB];
		[data addAttributeWithName:@"seq" stringValue:[@(_seq) stringValue]];
		[data addAttributeWithName:@"sid" stringValue:_sid];
		NSData *subdata = [self.data subdataWithRange:dataRange];
		data.stringValue = [subdata base64Encoded];
		XMPPIQ *iq = [XMPPIQ iqWithType:@"set" to:self.remoteJID elementID:self.elementID child:data];
		[xmppStream sendElement:iq];
		_byteOffset += dataRange.length;
		_seq++;
		if (_seq > XMPPIBBMaximumBlockSize) {
			// When seq hits the maximum limit of 65535, it needs to be reset
			_seq = 0;
		}
		[multicastDelegate xmppIBBTransfer:self didWriteDataOfLength:dataRange.length];
	} else {
		// No more data left to transfer, close the session
		[self sendCloseIQ];
	}
}

- (void)sendCloseIQ
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	NSXMLElement *close = [NSXMLElement elementWithName:@"close" xmlns:XMLNSProtocolIBB];
	[close addAttributeWithName:@"sid" stringValue:_sid];
	XMPPIQ *iq = [XMPPIQ iqWithType:@"set" to:self.remoteJID elementID:self.elementID child:close];
	[xmppStream sendElement:iq];
	[multicastDelegate xmppIBBTransferDidEnd:self];
	_transferClosed = YES;
}
@end
