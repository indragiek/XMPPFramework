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
#import "TURNSocket.h"
#import "XMPPInBandBytestream.h"

NSString* const XMLNSJabberSI = @"http://jabber.org/protocol/si";
NSString* const XMLNSJabberSIFileTransfer = @"http://jabber.org/protocol/si/profile/file-transfer";
NSString* const XMPPSIProfileSOCKS5Transfer = @"http://jabber.org/protocol/bytestreams";
NSString* const XMPPSIProfileIBBTransfer = @"http://jabber.org/protocol/ibb";

static NSString* const XMLNSJabberFeatureNeg = @"http://jabber.org/protocol/feature-neg";
static NSString* const XMLNSJabberXData = @"jabber:x:data";
static NSString* const XMLNSXMPPStanzas = @"urn:ietf:params:xml:ns:xmpp-stanzas";

static NSString* const XMPPSIFileTransferErrorDomain = @"XMPPSIFileTransferErrorDomain";

static NSArray *_supportedTransferMechanisms = nil;

@protocol XMPPTransferDelegate;
@interface XMPPTransfer () <GCDAsyncSocketDelegate, TURNSocketDelegate, XMPPInBandBytestreamDelegate>
@property (nonatomic, strong, readwrite) XMPPJID *remoteJID;
@property (nonatomic, copy, readwrite) NSString *streamMethod;
@property (nonatomic, strong, readwrite) NSData *data;
@property (nonatomic, assign, readwrite) NSRange dataRange;
@property (nonatomic, assign, readwrite) unsigned long long totalBytes;
@property (nonatomic, assign, readwrite) unsigned long long transferredBytes;
@property (nonatomic, assign, readwrite) BOOL outgoing;
@property (nonatomic, copy, readwrite) NSString *fileName;
@property (nonatomic, copy, readwrite) NSString *fileDescription;
@property (nonatomic, copy, readwrite) NSString *mimeType;
@property (nonatomic, copy, readwrite) NSString *MD5Hash;
@property (nonatomic, copy, readwrite) NSString *uniqueIdentifier;

@property (nonatomic, strong, readwrite) TURNSocket *socket;
@property (nonatomic, strong) XMPPInBandBytestream *inBandBytestream;
@property (nonatomic, weak) id<XMPPTransferDelegate> delegate;
@end

@protocol XMPPTransferDelegate <NSObject>
@required
- (void)xmppTransfer:(XMPPTransfer *)transfer failedWithError:(NSError *)error;
- (void)xmppTransferDidBegin:(XMPPTransfer *)transfer;
- (void)xmppTransferUpdatedProgress:(XMPPTransfer *)transfer;
- (void)xmppTransferDidEnd:(XMPPTransfer *)transfer;
@end

@interface XMPPSIFileTransfer () <XMPPTransferDelegate>
@end

@implementation XMPPSIFileTransfer {
	NSMutableDictionary *_outgoingTransfers;
	NSMutableDictionary *_incomingTransfers;
}

+ (void)load
{
	[super load];
	_supportedTransferMechanisms = @[XMPPSIProfileSOCKS5Transfer, XMPPSIProfileIBBTransfer];
}

- (id)initWithDispatchQueue:(dispatch_queue_t)queue
{
	if ((self = [super initWithDispatchQueue:queue])) {
		_outgoingTransfers = [NSMutableDictionary dictionary];
		_incomingTransfers = [NSMutableDictionary dictionary];
	}
	return self;
}

#pragma mark - Public API

- (XMPPTransfer *)sendStreamInitiationOfferForFileName:(NSString *)name
												  data:(NSData *)data
										   description:(NSString *)description
											  mimeType:(NSString *)mimeType
									  lastModifiedDate:(NSDate *)date
										 streamMethods:(NSArray *)methods
								supportsRangedTransfer:(BOOL)supportsRanged
												 toJID:(XMPPJID *)jid
{
	NSAssert(data, @"%@ called with nil data", NSStringFromSelector(_cmd));
	__block XMPPTransfer *transfer = nil;
	dispatch_block_t block = ^{
		NSXMLElement *si = [NSXMLElement elementWithName:@"si" xmlns:XMLNSJabberSI];
		[si addAttributeWithName:@"id" stringValue:@"a0"];
		[si addAttributeWithName:@"profile" stringValue:XMLNSJabberSIFileTransfer];
		[si addAttributeWithName:@"mime-type" stringValue:mimeType ?: @"application/octet-stream"];
		NSXMLElement *file = [NSXMLElement elementWithName:@"si" xmlns:XMLNSJabberSIFileTransfer];
		[file addAttributeWithName:@"name" stringValue:name ?: @"untitled"];
		NSString *hash = [data md5String];
		NSUInteger length = [data length];
		[file addAttributeWithName:@"size" stringValue:[@(length) stringValue]];
		[file addAttributeWithName:@"hash" stringValue:hash];
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
		
		NSString *identifier = [xmppStream generateUUID];
		XMPPIQ *offer = [XMPPIQ iqWithType:@"set" to:jid elementID:identifier child:si];
		[xmppStream sendElement:offer];
		
		transfer = [XMPPTransfer new];
		transfer.fileName = name;
		transfer.data = data;
		transfer.fileDescription = description;
		transfer.mimeType = mimeType;
		transfer.totalBytes = length;
		transfer.MD5Hash = hash;
		transfer.uniqueIdentifier = identifier;
		transfer.outgoing = YES;
		transfer.remoteJID = jid;
		transfer.delegate = self;
		_outgoingTransfers[identifier] = transfer;
	};
	if (dispatch_get_current_queue() == moduleQueue)
		block();
	else
		dispatch_sync(moduleQueue, block);
	return transfer;
}

- (XMPPTransfer *)sendStreamInitiationOfferForFileName:(NSString *)name
												  data:(NSData *)data
											  mimeType:(NSString *)mimeType
												 toJID:(XMPPJID *)jid
{
	return [self sendStreamInitiationOfferForFileName:name
												 data:data
										  description:nil
											 mimeType:mimeType
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

#pragma mark - XMPPStreamDelegate

- (void)xmppStream:(XMPPStream *)sender didSendIQ:(XMPPIQ *)iq
{
	if ([iq.type isEqualToString:@"set"] && [iq elementForName:@"si" xmlns:XMLNSJabberSI] && iq.elementID) {
		XMPPTransfer *transfer = _outgoingTransfers[iq.elementID];
		if (transfer) {
			[multicastDelegate xmppSIFileTransferDidSendOfferForTransfer:transfer];
		}
	}
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	NSXMLElement *si = [iq elementForName:@"si" xmlns:XMLNSJabberSI];
	if (si) {
		// Received a stream initiation offer
		if ([iq.type isEqualToString:@"set"]) {
			[self handleStreamInitiationOffer:iq];
			return YES;
		}
		// Received a stream initiation result
		if ([iq.type isEqualToString:@"result"] && iq.elementID) {
			if (iq.elementID && _outgoingTransfers[iq.elementID]) {
				[self handleStreamInitiationResult:iq];
				return YES;
			}
		}
	}
	return NO;
}

#pragma mark - XMPPTransferDelegate

- (void)xmppTransfer:(XMPPTransfer *)transfer failedWithError:(NSError *)error
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[self transferFailed:transfer error:error];
}

- (void)xmppTransferDidBegin:(XMPPTransfer *)transfer
{
	[multicastDelegate xmppSIFileTransferDidBegin:transfer];
}

- (void)xmppTransferUpdatedProgress:(XMPPTransfer *)transfer
{
	[multicastDelegate xmppSIFileTransferUpdatedProgress:transfer];
}

- (void)xmppTransferDidEnd:(XMPPTransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[self removeTransfer:transfer];
	[multicastDelegate xmppSIFileTransferDidEnd:transfer];
}

#pragma mark - Private

- (void)removeTransfer:(XMPPTransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	if (!transfer.uniqueIdentifier) return;
	[_outgoingTransfers removeObjectForKey:transfer.uniqueIdentifier];
	[_incomingTransfers removeObjectForKey:transfer.uniqueIdentifier];
}

- (void)transferFailed:(XMPPTransfer *)transfer error:(NSError *)error
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[self removeTransfer:transfer];
	[multicastDelegate xmppSIFileTransferFailed:transfer withError:error];
}

- (void)transferDidBegin:(XMPPTransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[multicastDelegate xmppSIFileTransferDidBegin:transfer];
}

- (void)beginOutgoingTransfer:(XMPPTransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	if ([transfer.streamMethod isEqualToString:XMPPSIProfileSOCKS5Transfer]) {
		[self beginSOCKS5OutgoingTransfer:transfer];
	} else if ([transfer.streamMethod isEqualToString:XMPPSIProfileIBBTransfer]) {
		[self beginIBBOutgoingTransfer:transfer];
	}
}

- (void)beginSOCKS5OutgoingTransfer:(XMPPTransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	TURNSocket *socket = [[TURNSocket alloc] initWithStream:xmppStream toJID:transfer.remoteJID elementID:transfer.uniqueIdentifier];
	transfer.socket = socket;
	[socket startWithDelegate:transfer delegateQueue:moduleQueue];
}

- (void)beginIBBOutgoingTransfer:(XMPPTransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	XMPPInBandBytestream *bytestream = [[XMPPInBandBytestream alloc] initOutgoingBytestreamToJID:transfer.remoteJID elementID:transfer.uniqueIdentifier data:transfer.data];
	transfer.inBandBytestream = bytestream;
	[bytestream addDelegate:transfer delegateQueue:moduleQueue];
	[bytestream start];
}

- (void)handleStreamInitiationResult:(XMPPIQ *)iq
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	NSXMLElement *si = [iq elementForName:@"si" xmlns:XMLNSJabberSI];
	XMPPTransfer *transfer = _outgoingTransfers[iq.elementID];
	if (transfer) {
		NSArray *streamMethods = [self.class extractStreamMethodsFromIQ:iq];
		if ([streamMethods count]) {
			NSString *method = streamMethods[0];
			if ([_supportedTransferMechanisms containsObject:method]) {
				transfer.streamMethod = streamMethods[0];
				NSXMLElement *file = [si elementForName:@"file" xmlns:XMLNSJabberSIFileTransfer];
				NSXMLElement *range = [file elementForName:@"range"];
				if (range) {
					NSUInteger offset = [range attributeUnsignedIntegerValueForName:@"offset"];
					NSUInteger length = [range attributeUnsignedIntegerValueForName:@"length"];
					if (offset && !length) {
						length = transfer.totalBytes - offset;
					}
					if (offset || length) {
						transfer.dataRange = NSMakeRange(offset, length);
					}
				}
				[self beginOutgoingTransfer:transfer];
			} else {
				[self sendNoValidStreamsErrorForIQ:iq];
				[self transferFailed:transfer error:[self.class noValidStreamsError]];
			}
		} else {
			[self sendNoValidStreamsErrorForIQ:iq];
			[self transferFailed:transfer error:[self.class noValidStreamsError]];
		}
	}
}

- (void)handleStreamInitiationOffer:(XMPPIQ *)iq
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
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
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	NSXMLElement *error = [self.class badRequestErrorElement];
	NSXMLElement *badProfile = [NSXMLElement elementWithName:@"bad-profile" xmlns:XMLNSJabberSI];
	[error addChild:badProfile];
	XMPPIQ *errorIQ = [XMPPIQ iqWithType:@"error" to:iq.from elementID:iq.elementID child:error];
	[xmppStream sendElement:errorIQ];
}

- (void)sendNoValidStreamsErrorForIQ:(XMPPIQ *)iq
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
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
			NSString *method = nil;
			if ([child.name isEqualToString:@"option"]) {
				method = [[child elementForName:@"value"] stringValue];
			} else if ([child.name isEqualToString:@"value"]) {
				method = [child stringValue];
			}
			if ([method length]) {
				[streamMethods addObject:method];
			}
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

+ (NSError *)noValidStreamsError
{
	return [NSError errorWithDomain:XMPPSIFileTransferErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Remote peer did not respond with supported transfer mechanism"}];
}
@end

@implementation XMPPTransfer

#pragma mark - NSObject

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@:%p streamMethod:%@ socket:%@ remoteJID:%@ dataRange:%@ totalBytes:%llu transferredBytes:%llu outgoing:%d fileName:%@ fileDescription:%@ mimeType:%@ MD5Hash:%@ uniqueIdentifier:%@>", NSStringFromClass(self.class), self, self.streamMethod, self.socket, self.remoteJID, NSStringFromRange(self.dataRange), self.totalBytes, self.transferredBytes, self.outgoing, self.fileName, self.fileDescription, self.mimeType, self.MD5Hash, self.uniqueIdentifier];
}

#pragma mark - TURNSocketDelegate

- (void)turnSocket:(TURNSocket *)sender didSucceed:(GCDAsyncSocket *)socket
{
	[self.delegate xmppTransferDidBegin:self];
	[socket setDelegate:self];
	[socket setDelegateQueue:dispatch_get_current_queue()];
	if (self.outgoing) {
		// -1 timeout means no time out. See GCDAsyncSocket docs for more information.
		[socket writeData:self.data withTimeout:-1 tag:0];
	} else {
		[socket readDataWithTimeout:-1 tag:0];
	}
}

- (void)turnSocketDidFail:(TURNSocket *)sender
{
	[self.delegate xmppTransfer:self failedWithError:[self.class turnSocketFailedError]];
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
	[self.delegate xmppTransfer:self failedWithError:err ?: [self.class asyncSocketDisconnectedError]];
}

- (void)socket:(GCDAsyncSocket *)sock didWritePartialDataOfLength:(NSUInteger)partialLength tag:(long)tag
{
	[self incrementTransferredBytesBy:partialLength];
}

- (void)socket:(GCDAsyncSocket *)sock didReadPartialDataOfLength:(NSUInteger)partialLength tag:(long)tag
{
	[self incrementTransferredBytesBy:partialLength];
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
	[self.delegate xmppTransferDidEnd:self];
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
	self.data = data;
	[self.delegate xmppTransferDidEnd:self];
}

#pragma mark -XMPPInBandBytestreamDelegate

- (void)xmppIBBTransferDidBegin:(XMPPInBandBytestream *)stream
{
	[self.delegate xmppTransferDidBegin:self];
}

- (void)xmppIBBTransfer:(XMPPInBandBytestream *)stream didWriteDataOfLength:(NSUInteger)length
{
	[self incrementTransferredBytesBy:length];
}

- (void)xmppIBBTransfer:(XMPPInBandBytestream *)stream didReadDataOfLength:(NSUInteger)length
{
	[self incrementTransferredBytesBy:length];
}

- (void)xmppIBBTransfer:(XMPPInBandBytestream *)stream failedWithError:(NSError *)error
{
	[self.delegate xmppTransfer:self failedWithError:error];
}

- (void)xmppIBBTransferDidEnd:(XMPPInBandBytestream *)stream
{
	[self.delegate xmppTransferDidEnd:self];
}

#pragma mark - Private

- (void)incrementTransferredBytesBy:(unsigned long long)length
{
	unsigned long long transferred = self.transferredBytes;
	transferred += length;
	self.transferredBytes = transferred;
	[self.delegate xmppTransferUpdatedProgress:self];
}

+ (NSError *)turnSocketFailedError
{
	return [NSError errorWithDomain:XMPPSIFileTransferErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Socket failed to connect to remote peer."}];
}

+ (NSError *)asyncSocketDisconnectedError
{
	return [NSError errorWithDomain:XMPPSIFileTransferErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Socket disconnected."}];
}
@end