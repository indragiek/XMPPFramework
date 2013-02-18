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

@protocol XMPPSITransferDelegate;
@interface XMPPSITransfer () <GCDAsyncSocketDelegate, TURNSocketDelegate, XMPPInBandBytestreamDelegate>
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
@property (nonatomic, strong, readwrite) NSDate *lastModifiedDate;

@property (nonatomic, strong, readwrite) TURNSocket *socket;
@property (nonatomic, strong) XMPPInBandBytestream *inBandBytestream;
@property (nonatomic, weak) id<XMPPSITransferDelegate> delegate;
@end

@protocol XMPPSITransferDelegate <NSObject>
@required
- (void)xmppTransfer:(XMPPSITransfer *)transfer failedWithError:(NSError *)error;
- (void)xmppTransferDidBegin:(XMPPSITransfer *)transfer;
- (void)xmppTransferUpdatedProgress:(XMPPSITransfer *)transfer;
- (void)xmppTransferDidEnd:(XMPPSITransfer *)transfer;
@end

@interface XMPPSIFileTransfer () <XMPPSITransferDelegate>
@end

@implementation XMPPSIFileTransfer {
	NSMutableDictionary *_outgoingTransfers;
	NSMutableDictionary *_incomingTransfers;
	NSMutableArray *_activeTransfers;
}

+ (void)load
{
	[super load];
	_supportedTransferMechanisms = @[XMPPSIProfileIBBTransfer, XMPPSIProfileSOCKS5Transfer];
	[TURNSocket setProxyCandidates:nil];
}

- (id)initWithDispatchQueue:(dispatch_queue_t)queue
{
	if ((self = [super initWithDispatchQueue:queue])) {
		_outgoingTransfers = [NSMutableDictionary dictionary];
		_incomingTransfers = [NSMutableDictionary dictionary];
		_activeTransfers = [NSMutableArray array];
	}
	return self;
}

#pragma mark - Public API

- (XMPPSITransfer *)sendStreamInitiationOfferForFileName:(NSString *)name
												  data:(NSData *)data
										   description:(NSString *)description
											  mimeType:(NSString *)mimeType
									  lastModifiedDate:(NSDate *)date
										 streamMethods:(NSArray *)methods
								supportsRangedTransfer:(BOOL)supportsRanged
												 toJID:(XMPPJID *)jid
{
	NSAssert(data, @"%@ called with nil data", NSStringFromSelector(_cmd));
	__block XMPPSITransfer *transfer = nil;
	dispatch_block_t block = ^{
		NSXMLElement *si = [NSXMLElement elementWithName:@"si" xmlns:XMLNSJabberSI];
		[si addAttributeWithName:@"id" stringValue:@"a0"];
		[si addAttributeWithName:@"profile" stringValue:XMLNSJabberSIFileTransfer];
		[si addAttributeWithName:@"mime-type" stringValue:mimeType ?: @"application/octet-stream"];
		NSXMLElement *file = [NSXMLElement elementWithName:@"file" xmlns:XMLNSJabberSIFileTransfer];
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
		NSXMLElement *feature = [NSXMLElement elementWithName:@"feature" xmlns:XMLNSJabberFeatureNeg];
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
		
		transfer = [XMPPSITransfer new];
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

- (XMPPSITransfer *)sendStreamInitiationOfferForFileName:(NSString *)name
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

- (void)acceptStreamInitiationOfferForTransfer:(XMPPSITransfer *)transfer
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
		NSXMLElement *value = [NSXMLElement elementWithName:@"value" stringValue:transfer.streamMethod];
		[field addChild:value];
		[x addChild:field];
		[feature addChild:x];
		[si addChild:feature];
		
		_incomingTransfers[transfer.uniqueIdentifier] = transfer;
		XMPPIQ *result = [XMPPIQ iqWithType:@"result" to:transfer.remoteJID elementID:transfer.uniqueIdentifier child:si];
		[xmppStream sendElement:result];
	};
	if (dispatch_get_current_queue() == moduleQueue)
		block();
	else
		dispatch_async(moduleQueue, block);
}

- (void)rejectOfferForTransfer:(XMPPSITransfer *)transfer
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
		XMPPIQ *errorIQ = [XMPPIQ iqWithType:@"error" to:transfer.remoteJID elementID:transfer.uniqueIdentifier child:error];
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
		XMPPSITransfer *transfer = _outgoingTransfers[iq.elementID];
		if (transfer) {
			[multicastDelegate xmppSIFileTransfer:self didSendOfferForTransfer:transfer];
		}
	}
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	if ([iq.type isEqualToString:@"set"]) {
		// Received a stream initiation offer
		if ([iq elementForName:@"si" xmlns:XMLNSJabberSI]) {
			[self handleStreamInitiationOffer:iq];
			return YES;
		// Incoming TURN request
		} else if ([iq elementForName:@"query" xmlns:XMPPSIProfileSOCKS5Transfer]
					&& iq.elementID
					&& _incomingTransfers[iq.elementID]) {
			[self handleTURNRequest:iq];
			return YES;
		// Incoming In-Band Bytestream Request
		} else if ([iq elementForName:@"open" xmlns:XMPPSIProfileIBBTransfer]
				   && iq.elementID
				   && _incomingTransfers[iq.elementID]) {
			[self handleIBBRequest:iq];
			return YES;
		}
	} else if ([iq.type isEqualToString:@"result"]) {
		if (iq.elementID && _outgoingTransfers[iq.elementID]) {
			[self handleStreamInitiationResult:iq];
			return YES;
		}
	}
	return NO;
}

#pragma mark - XMPPSITransferDelegate

- (void)xmppTransfer:(XMPPSITransfer *)transfer failedWithError:(NSError *)error
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[self transferFailed:transfer error:error];
}

- (void)xmppTransferDidBegin:(XMPPSITransfer *)transfer
{
	[multicastDelegate xmppSIFileTransfer:self transferDidBegin:transfer];
}

- (void)xmppTransferUpdatedProgress:(XMPPSITransfer *)transfer
{
	[multicastDelegate xmppSIFileTransfer:self transferUpdatedProgress:transfer];
}

- (void)xmppTransferDidEnd:(XMPPSITransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[self removeTransfer:transfer];
	[multicastDelegate xmppSIFileTransfer:self transferDidEnd:transfer];
}

#pragma mark - Private

- (void)removeTransfer:(XMPPSITransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	if (!transfer.uniqueIdentifier) return;
	if (transfer.inBandBytestream) {
		[transfer.inBandBytestream deactivate];
	}
	[_activeTransfers removeObject:transfer];
	[_outgoingTransfers removeObjectForKey:transfer.uniqueIdentifier];
	[_incomingTransfers removeObjectForKey:transfer.uniqueIdentifier];
}

- (void)transferFailed:(XMPPSITransfer *)transfer error:(NSError *)error
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[self removeTransfer:transfer];
	[multicastDelegate xmppSIFileTransfer:self tranferFailed:transfer withError:error];
}

- (void)transferDidBegin:(XMPPSITransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[multicastDelegate xmppSIFileTransfer:self transferDidBegin:transfer];
}

- (void)beginOutgoingTransfer:(XMPPSITransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[_activeTransfers addObject:transfer];
	[_outgoingTransfers removeObjectForKey:transfer.uniqueIdentifier];
	if ([transfer.streamMethod isEqualToString:XMPPSIProfileSOCKS5Transfer]) {
		[self beginSOCKS5OutgoingTransfer:transfer];
	} else if ([transfer.streamMethod isEqualToString:XMPPSIProfileIBBTransfer]) {
		[self beginIBBOutgoingTransfer:transfer];
	}
}

- (void)beginSOCKS5OutgoingTransfer:(XMPPSITransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	TURNSocket *socket = [[TURNSocket alloc] initWithStream:xmppStream
													  toJID:transfer.remoteJID
												  elementID:transfer.uniqueIdentifier
											  directConnection:YES];
	transfer.socket = socket;
	[socket startWithDelegate:transfer delegateQueue:moduleQueue];
}

- (void)beginIBBOutgoingTransfer:(XMPPSITransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	XMPPInBandBytestream *bytestream = [[XMPPInBandBytestream alloc] initOutgoingBytestreamToJID:transfer.remoteJID elementID:transfer.uniqueIdentifier data:transfer.data];
	[bytestream activate:xmppStream];
	transfer.inBandBytestream = bytestream;
	[bytestream addDelegate:transfer delegateQueue:moduleQueue];
	[bytestream start];
}

- (void)handleStreamInitiationResult:(XMPPIQ *)iq
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	NSXMLElement *si = [iq elementForName:@"si" xmlns:XMLNSJabberSI];
	XMPPSITransfer *transfer = _outgoingTransfers[iq.elementID];
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
		NSString *fileName = [file attributeStringValueForName:@"name"];
		NSUInteger fileSize = [file attributeUnsignedIntegerValueForName:@"size"];
		if (![fileName length] || !fileSize) {
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
			XMPPSITransfer *transfer = [XMPPSITransfer new];
			if ([streamMethods containsObject:XMPPSIProfileSOCKS5Transfer]) {
				transfer.streamMethod = XMPPSIProfileSOCKS5Transfer;
			} else {
				transfer.streamMethod = XMPPSIProfileIBBTransfer;
			}
			transfer.delegate = self;
			transfer.remoteJID = iq.from;
			transfer.uniqueIdentifier = iq.elementID;
			transfer.totalBytes = fileSize;
			transfer.outgoing = NO;
			transfer.fileName = fileName;
			transfer.fileDescription = [[file elementForName:@"desc"] stringValue];
			transfer.mimeType = [si attributeStringValueForName:@"mime-type"];
			transfer.MD5Hash = [file attributeStringValueForName:@"hash"];
			NSString *dateString = [file attributeStringValueForName:@"date"] ;
			if ([dateString length]) {
				transfer.lastModifiedDate = [NSDate dateWithXmppDateTimeString:dateString];
			}
			[multicastDelegate xmppSIFileTransfer:self receivedOfferForTransfer:transfer];
		} else {
			[self sendNoValidStreamsErrorForIQ:iq];
		}
	} else {
		[self sendProfileNotUnderstoodErrorForIQ:iq];
	}
}

- (void)handleTURNRequest:(XMPPIQ *)iq
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	XMPPSITransfer *transfer = _incomingTransfers[iq.elementID];
	[_activeTransfers addObject:transfer];
	[_incomingTransfers removeObjectForKey:iq.elementID];
	TURNSocket *socket = [[TURNSocket alloc] initWithStream:xmppStream incomingTURNRequest:iq];
	transfer.socket = socket;
	[socket startWithDelegate:transfer delegateQueue:moduleQueue];
}

- (void)handleIBBRequest:(XMPPIQ *)iq
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	XMPPSITransfer *transfer = _incomingTransfers[iq.elementID];
	[_activeTransfers addObject:transfer];
	[_incomingTransfers removeObjectForKey:iq.elementID];
	XMPPInBandBytestream *bytestream = [[XMPPInBandBytestream alloc] initIncomingBytestreamRequest:iq];
	transfer.inBandBytestream = bytestream;
	[bytestream activate:xmppStream];
	[bytestream addDelegate:transfer delegateQueue:moduleQueue];
	[bytestream start];
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
	NSXMLElement *si = [iq elementForName:@"si" xmlns:XMLNSJabberSI];
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

@implementation XMPPSITransfer {
	GCDAsyncSocket *_asyncSocket;
	BOOL _wroteData;
}

#pragma mark - NSObject

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@:%p streamMethod:%@ socket:%@ remoteJID:%@ dataRange:%@ totalBytes:%llu transferredBytes:%llu outgoing:%d fileName:%@ fileDescription:%@ mimeType:%@ MD5Hash:%@ uniqueIdentifier:%@>", NSStringFromClass(self.class), self, self.streamMethod, self.socket, self.remoteJID, NSStringFromRange(self.dataRange), self.totalBytes, self.transferredBytes, self.outgoing, self.fileName, self.fileDescription, self.mimeType, self.MD5Hash, self.uniqueIdentifier];
}

#pragma mark - TURNSocketDelegate

- (void)turnSocket:(TURNSocket *)sender didSucceed:(GCDAsyncSocket *)socket
{
	[self.delegate xmppTransferDidBegin:self];
	_asyncSocket = socket;
	[_asyncSocket setDelegate:self];
	[_asyncSocket setDelegateQueue:dispatch_get_current_queue()];
	if (self.outgoing) {
		// -1 timeout means no time out. See GCDAsyncSocket docs for more information.
		[_asyncSocket writeData:self.data withTimeout:-1 tag:0];
	} else {
		[_asyncSocket readDataWithTimeout:-1 tag:0];
	}
}

- (void)turnSocketDidFail:(TURNSocket *)sender
{
	[self.delegate xmppTransfer:self failedWithError:[self.class turnSocketFailedError]];
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
	if (_wroteData) {
		[self.delegate xmppTransferDidEnd:self];
	} else {
		[self.delegate xmppTransfer:self failedWithError:err ?: [self.class asyncSocketDisconnectedError]];
	}
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
	_wroteData = YES;
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
	self.data = stream.data;
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