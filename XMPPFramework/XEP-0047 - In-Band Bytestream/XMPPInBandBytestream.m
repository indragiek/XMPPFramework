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

#define XMPP_IBB_ASSERT_CORRECT_QUEUE() NSAssert(dispatch_get_specific(_transferQueueTag) != NULL, @"Invoked on incorrect queue");

static inline NSUInteger XMPPIBBValidatedBlockSize(NSUInteger size) {
	return MAX(MIN(size, XMPPIBBMaximumBlockSize), XMPPIBBMinimumBlockSize);
}

@implementation XMPPInBandBytestream {
	NSString *_sid;
	NSUInteger _seq;
	BOOL _transferClosed;
	NSFileHandle *_fileHandle;
	
	dispatch_once_t transferBeganToken;
	dispatch_queue_t _transferQueue;
	void *_transferQueueTag;
	
	dispatch_queue_t _delegateQueue;
	id _delegate;
	
	XMPPStream *_xmppStream;
}

- (id)initOutgoingBytestreamWithStream:(XMPPStream *)stream
								 toJID:(XMPPJID *)jid
							 elementID:(NSString *)elementID
								   sid:(NSString *)sid
							   fileURL:(NSURL *)URL
								 error:(NSError *__autoreleasing *)error
{
	if ((self = [super init])) {
		_fileHandle = [NSFileHandle fileHandleForReadingFromURL:URL error:error];
		if (!_fileHandle) {
			return nil;
		}
		_xmppStream = stream;
		[self commonInit];
		
		_remoteJID = jid;
		_blockSize = XMPPIBBMaximumBlockSize;
		_xmppStream = stream;
		// Generate a unique ID when an elementID is not given
		_elementID = [elementID copy] ?: [_xmppStream generateUUID];
		_sid = [sid copy] ?: _elementID;
		_outgoing = YES;
	}
	return self;
}

- (id)initIncomingBytestreamRequest:(XMPPIQ *)iq withStream:(XMPPStream *)stream
{
	if ((self = [super init])) {
		_xmppStream = stream;
		[self commonInit];
		
		_remoteJID = iq.from;
		_elementID = [iq.elementID copy];
		NSXMLElement *open = [NSXMLElement elementWithName:@"open" xmlns:XMLNSProtocolIBB];
		if (!open) return nil;
		// Validate the block size to ensure that the size is acceptable given
		// the minimum and maximum limits
		_blockSize = XMPPIBBValidatedBlockSize([open attributeUnsignedIntegerValueForName:@"block-size"]);
		// Unique identifier used in close, open, and data elements
		_sid = [open attributeStringValueForName:@"sid"];
		_outgoing = NO;
		// The stanza attribute will be ignored, because this implementation only supports
		// transfer over IQ stanzas. Transferring binary data over message stanzas, despite
		// being an officially documented method, seems like abuse of the protocol. It should
		// seriously be removed from the XEP-0047 spec, considering that there is no reason
		// why a client can use message stanzas but not IQ stanzas to transfer information.
	}
	return self;
}

- (void)commonInit
{
	_transferQueue = dispatch_queue_create("XMPPInBandBytestreamTransferQueue", NULL);
	_transferQueueTag = &_transferQueueTag;
	dispatch_queue_set_specific(_transferQueue, _transferQueueTag, _transferQueueTag, NULL);
	[_xmppStream addDelegate:self delegateQueue:_transferQueue];
}

- (void)dealloc
{
#if !OS_OBJECT_USE_OBJC
	dispatch_release(_delegateQueue);
	dispatch_release(_transferQueue);
#endif
}

- (void)startWithDelegate:(id)aDelegate delegateQueue:(dispatch_queue_t)aDelegateQueue
{
	dispatch_block_t block = ^{
		_delegate = aDelegate;
		_delegateQueue = aDelegateQueue;
#if !OS_OBJECT_USE_OBJC
		dispatch_retain(_delegateQueue);
#endif
		if (self.outgoing) {
			[self sendOpenIQ];
		} else {
			[self sendAcceptIQ];
		}
	};
	if (dispatch_get_specific(_transferQueueTag))
		block();
	else
		dispatch_async(_transferQueue, block);
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
	XMPP_IBB_ASSERT_CORRECT_QUEUE();
	NSXMLElement *error = [iq elementForName:@"error"];
	static NSString *XMLNSXMPPStanzas = @"urn:ietf:params:xml:ns:xmpp-stanzas";
	void (^failWithError)(NSError *) = ^(NSError *error){
		dispatch_async(_delegateQueue, ^{ @autoreleasepool {
			if ([_delegate respondsToSelector:@selector(xmppIBBTransfer:failedWithError:)]) {
				[_delegate xmppIBBTransfer:self failedWithError:error];
			}
		}});
	};
	// The receiver does not support in band bytestreams
	if ([error elementForName:@"service-unavailable" xmlns:XMLNSXMPPStanzas]) {
		failWithError([self.class serviceUnavailableError]);
		return YES;
	// The receiver wants smaller block size
	} else if ([error elementForName:@"resource-constraint" xmlns:XMLNSXMPPStanzas]) {
		// Decrement the block size and try again if possible
		if ([self decrementBlockSize]) {
			[self sendOpenIQ];
		} else {
			// Otherwise the transfer has failed
			failWithError([self.class resourceConstraintError]);
		}
		return YES;
	// Receiver has denied the transfer
	} else if ([error elementForName:@"not-acceptable" xmlns:XMLNSXMPPStanzas]) {
		failWithError([self.class notAcceptableError]);
		return YES;
	}
	return NO;
}

- (void)handleReceivedDataIQ:(XMPPIQ *)iq
{
	XMPP_IBB_ASSERT_CORRECT_QUEUE();
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		[self delegateIBBTransferDidBegin];
	});
	NSXMLElement *data = [iq elementForName:@"data" xmlns:XMLNSProtocolIBB];
	NSString *base64String = data.stringValue;
	if ([base64String length]) {
		NSData *base64Data = [base64String dataUsingEncoding:NSASCIIStringEncoding];
		NSData *decodedData = [base64Data base64Decoded];
		dispatch_async(_delegateQueue, ^{ @autoreleasepool {
			if ([_delegate respondsToSelector:@selector(xmppIBBTransfer:didReadData:)]) {
				[_delegate xmppIBBTransfer:self didReadData:decodedData];
			}
		}});
	}
	[self sendAcceptIQ];
}

- (void)handleCloseIQ:(XMPPIQ *)iq
{
	XMPP_IBB_ASSERT_CORRECT_QUEUE();
	_transferClosed = YES;
	[self sendAcceptIQ];
	[self delegateIBBTransferDidEnd];
}

// Returns YES if the block size has been decremented without hitting the minimum limit
// This method cuts the block size in half in the case that the receiver has requested
// a smaller block size
- (BOOL)decrementBlockSize
{
	XMPP_IBB_ASSERT_CORRECT_QUEUE();
	_blockSize = _blockSize / 2;
	return (_blockSize > XMPPIBBMinimumBlockSize);
}

- (void)sendOpenIQ
{
	XMPP_IBB_ASSERT_CORRECT_QUEUE();
	NSXMLElement *open = [NSXMLElement elementWithName:@"open" xmlns:XMLNSProtocolIBB];
	[open addAttributeWithName:@"block-size" stringValue:[@(self.blockSize) stringValue]];
	[open addAttributeWithName:@"sid" stringValue:self.sid];
	[open addAttributeWithName:@"stanza" stringValue:@"iq"];
	XMPPIQ *iq = [XMPPIQ iqWithType:@"set" to:self.remoteJID elementID:self.elementID child:open];
	[_xmppStream sendElement:iq];
}

- (void)sendAcceptIQ
{
	XMPP_IBB_ASSERT_CORRECT_QUEUE();
	XMPPIQ *iq = [XMPPIQ iqWithType:@"result" to:self.remoteJID elementID:self.elementID];
	[_xmppStream sendElement:iq];
}

- (void)sendDataIQ
{
	XMPP_IBB_ASSERT_CORRECT_QUEUE();
	// Ignore subsequent calls to this method once the transfer has been closed
	if (_transferClosed) return;
	// Call the delegate the first time some data is about to be transferred
	// to inform it that the transfer has started
	dispatch_once(&transferBeganToken, ^{
		[self delegateIBBTransferDidBegin];
	});
	NSData *fileData = [_fileHandle readDataOfLength:self.blockSize];
	if (fileData) {
		NSXMLElement *data = [NSXMLElement elementWithName:@"data" xmlns:XMLNSProtocolIBB];
		[data addAttributeWithName:@"seq" stringValue:[@(_seq) stringValue]];
		[data addAttributeWithName:@"sid" stringValue:self.sid];
		data.stringValue = [fileData base64Encoded];
		XMPPIQ *iq = [XMPPIQ iqWithType:@"set" to:self.remoteJID elementID:self.elementID child:data];
		[_xmppStream sendElement:iq];
		_seq++;
		if (_seq > XMPPIBBMaximumBlockSize) {
			// When seq hits the maximum limit of 65535, it needs to be reset
			_seq = 0;
		}
		dispatch_async(_delegateQueue, ^{ @autoreleasepool {
			if ([_delegate respondsToSelector:@selector(xmppIBBTransfer:didWriteDataOfLength:)]) {
				[_delegate xmppIBBTransfer:self didWriteDataOfLength:fileData.length];
			}
		}});
	} else {
		[self sendCloseIQ];
	}
}

- (void)sendCloseIQ
{
	XMPP_IBB_ASSERT_CORRECT_QUEUE();
	NSXMLElement *close = [NSXMLElement elementWithName:@"close" xmlns:XMLNSProtocolIBB];
	[close addAttributeWithName:@"sid" stringValue:self.sid];
	XMPPIQ *iq = [XMPPIQ iqWithType:@"set" to:self.remoteJID elementID:self.elementID child:close];
	[_xmppStream sendElement:iq];
	[self delegateIBBTransferDidEnd];
	_transferClosed = YES;
}

#pragma mark - Delegate

- (void)delegateIBBTransferDidBegin
{
	dispatch_async(_delegateQueue, ^{ @autoreleasepool {
		if ([_delegate respondsToSelector:@selector(xmppIBBTransferDidBegin:)]) {
			[_delegate xmppIBBTransferDidBegin:self];
		}
	}});
}

- (void)delegateIBBTransferDidEnd
{
	dispatch_async(_delegateQueue, ^{ @autoreleasepool {
		if ([_delegate respondsToSelector:@selector(xmppIBBTransferDidEnd:)]) {
			[_delegate xmppIBBTransferDidBegin:self];
		}
	}});
}
@end
