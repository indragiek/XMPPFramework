//
//  XMPPSIFileTransfer.m
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-02-05.
//  Copyright (c) 2013 Indragie Karunaratne. All rights reserved.
//

#import "XMPPSIFileTransfer.h"
#import "NSDate+XMPPDateTimeProfiles.h"
#import "NSData+XMPP.h"
#import "TURNSocket.h"
#import "XMPPInBandBytestream.h"
#import "FileMD5Hash.h"

NSString* const XMLNSJabberSI = @"http://jabber.org/protocol/si";
NSString* const XMLNSJabberSIFileTransfer = @"http://jabber.org/protocol/si/profile/file-transfer";
NSString* const XMPPSIProfileSOCKS5Transfer = @"http://jabber.org/protocol/bytestreams";
NSString* const XMPPSIProfileIBBTransfer = @"http://jabber.org/protocol/ibb";

static NSString* const XMLNSJabberFeatureNeg = @"http://jabber.org/protocol/feature-neg";
static NSString* const XMLNSJabberXData = @"jabber:x:data";
static NSString* const XMLNSXMPPStanzas = @"urn:ietf:params:xml:ns:xmpp-stanzas";

static NSString* const XMPPSIFileTransferErrorDomain = @"XMPPSIFileTransferErrorDomain";
static NSTimeInterval const XMPPSIFileTransferReadTimeout = 10.0;

static NSArray *_supportedTransferMechanisms = nil;

@protocol XMPPSITransferDelegate;
@interface XMPPSITransfer () <GCDAsyncSocketDelegate, TURNSocketDelegate, XMPPInBandBytestreamDelegate>
@property (nonatomic, strong, readwrite) XMPPJID *remoteJID;
@property (nonatomic, copy, readwrite) NSString *streamMethod;
@property (nonatomic, strong, readwrite) NSURL *URL;
@property (nonatomic, assign, readwrite) unsigned long long totalBytes;
@property (nonatomic, assign, readwrite) unsigned long long transferredBytes;
@property (nonatomic, assign, readwrite) BOOL outgoing;
@property (nonatomic, copy, readwrite) NSString *fileName;
@property (nonatomic, copy, readwrite) NSString *fileDescription;
@property (nonatomic, copy, readwrite) NSString *mimeType;
@property (nonatomic, copy, readwrite) NSString *MD5Hash;
@property (nonatomic, copy, readwrite) NSString *uniqueIdentifier;
@property (nonatomic, copy, readwrite) NSString *sid;
@property (nonatomic, strong, readwrite) NSDate *lastModifiedDate;

@property (nonatomic, strong) TURNSocket *socket;
@property (nonatomic, strong) XMPPInBandBytestream *inBandBytestream;
@property (nonatomic, weak) id<XMPPSITransferDelegate> delegate;
@property (nonatomic) dispatch_queue_t delegateQueue;

- (instancetype)initWithDelegateQueue:(dispatch_queue_t)delegateQueue;
- (void)start;
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
	NSMutableSet *_activeTransfers;
}

+ (void)load
{
	_supportedTransferMechanisms = @[XMPPSIProfileIBBTransfer, XMPPSIProfileSOCKS5Transfer];
	[TURNSocket setProxyCandidates:nil];
}

- (id)initWithDispatchQueue:(dispatch_queue_t)queue
{
	if ((self = [super initWithDispatchQueue:queue])) {
		_outgoingTransfers = [NSMutableDictionary dictionary];
		_incomingTransfers = [NSMutableDictionary dictionary];
		_activeTransfers = [NSMutableSet set];
	}
	return self;
}

#pragma mark - Public API

- (XMPPSITransfer *)sendStreamInitiationOfferForFileURL:(NSURL *)URL
											description:(NSString *)description
										  streamMethods:(NSArray *)methods
												  toJID:(XMPPJID *)jid
												  error:(NSError **)error;
{
	NSAssert(URL, @"%@ called with nil URL", NSStringFromSelector(_cmd));
	__block XMPPSITransfer *transfer = nil;
	dispatch_block_t block = ^{
		NSString *identifier = [xmppStream generateUUID];
		NSXMLElement *si = [NSXMLElement elementWithName:@"si" xmlns:XMLNSJabberSI];
		[si addAttributeWithName:@"id" stringValue:identifier];
		[si addAttributeWithName:@"profile" stringValue:XMLNSJabberSIFileTransfer];
		
		CFStringRef UTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)URL.pathExtension, NULL);
		NSString *mimeType = (__bridge_transfer NSString *)UTTypeCopyPreferredTagWithClass(UTI, kUTTagClassMIMEType);
		CFRelease(UTI);
		[si addAttributeWithName:@"mime-type" stringValue:mimeType ?: @"application/octet-stream"];
		
		NSXMLElement *file = [NSXMLElement elementWithName:@"file" xmlns:XMLNSJabberSIFileTransfer];
		NSString *fileName = URL.lastPathComponent ?: @"untitled";
		[file addAttributeWithName:@"name" stringValue:fileName];
		
		NSString *hash = (__bridge_transfer NSString *)FileMD5HashCreateWithPath((__bridge CFStringRef)URL.path, FileHashDefaultChunkSizeForReadingData);
		[file addAttributeWithName:@"hash" stringValue:hash];
		
		NSNumber *fileSize = nil;
		if (![URL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:error]) {
			return;
		}
		[file addAttributeWithName:@"size" stringValue:[fileSize stringValue]];
		
		NSDate *lastModifiedDate = nil;
		if (![URL getResourceValue:&lastModifiedDate forKey:NSURLAttributeModificationDateKey error:error]) {
			return;
		}
		if (lastModifiedDate) {
			[file addAttributeWithName:@"date" stringValue:[lastModifiedDate xmppDateTimeString]];
		}
		
		if ([description length]) {
			NSXMLElement *desc = [NSXMLElement elementWithName:@"desc" stringValue:description];
			[file addChild:desc];
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
		
		// Create a copy of the file in a temporary location so deleting
		// it while it's being transferred won't do anything.
		NSString *tempPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:fileName.pathExtension];
		NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
		if (![[NSFileManager defaultManager] copyItemAtURL:URL toURL:tempURL error:error]) {
			return;
		}
		
		XMPPIQ *offer = [XMPPIQ iqWithType:@"set" to:jid elementID:identifier child:si];
		[xmppStream sendElement:offer];
		
		transfer = [[XMPPSITransfer alloc] initWithDelegateQueue:moduleQueue];
		transfer.fileName = fileName;
		transfer.URL = tempURL;
		transfer.fileDescription = description;
		transfer.mimeType = mimeType;
		transfer.totalBytes = fileSize.unsignedLongLongValue;
		transfer.MD5Hash = hash;
		transfer.uniqueIdentifier = identifier;
		transfer.sid = identifier;
		transfer.outgoing = YES;
		transfer.remoteJID = jid;
		transfer.delegate = self;
		_outgoingTransfers[identifier] = transfer;
	};
	if (dispatch_get_specific(moduleQueueTag))
		block();
	else
		dispatch_sync(moduleQueue, block);
	return transfer;
}

- (XMPPSITransfer *)sendStreamInitiationOfferForFileURL:(NSURL *)URL
												  toJID:(XMPPJID *)jid
												  error:(NSError *__autoreleasing *)error
{
	return [self sendStreamInitiationOfferForFileURL:URL description:nil streamMethods:@[XMPPSIProfileSOCKS5Transfer, XMPPSIProfileIBBTransfer] toJID:jid error:error];
}

- (void)acceptStreamInitiationOfferForTransfer:(XMPPSITransfer *)transfer
{
	dispatch_block_t block = ^{
		NSXMLElement *si = [NSXMLElement elementWithName:@"si" xmlns:XMLNSJabberSI];
		[si addAttributeWithName:@"id" stringValue:transfer.sid];
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
		
		_incomingTransfers[transfer.sid] = transfer;
		XMPPIQ *result = [XMPPIQ iqWithType:@"result" to:transfer.remoteJID elementID:transfer.uniqueIdentifier child:si];
		[xmppStream sendElement:result];
	};
	if (dispatch_get_specific(moduleQueueTag))
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
	if (dispatch_get_specific(moduleQueueTag))
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
		} else {
			NSXMLElement *query = [iq elementForName:@"query" xmlns:XMPPSIProfileSOCKS5Transfer];
			NSXMLElement *open = [iq elementForName:@"open" xmlns:XMPPSIProfileIBBTransfer];
			NSString *sid = [query ?: open attributeStringValueForName:@"sid"];
			if (sid) {
				XMPPSITransfer *transfer = _incomingTransfers[sid];
				if (transfer) {
					if (query) {
						[self handleTURNRequest:iq forTransfer:transfer];
						return YES;
					} else if (open) {
						[self handleIBBRequest:iq forTransfer:transfer];
						return YES;
					}
				}
			}
		}
	} else if ([iq.type isEqualToString:@"result"]) {
		if (iq.elementID && _outgoingTransfers[iq.elementID]) {
			[self handleStreamInitiationResult:iq];
			return YES;
		}
	} else if ([iq.type isEqualToString:@"error"]) {
		__block XMPPSITransfer *transfer = nil;
		[_outgoingTransfers enumerateKeysAndObjectsUsingBlock:^(NSString *key, XMPPSITransfer *outgoing, BOOL *stop) {
			if ([key isEqualToString:iq.elementID]) {
				transfer = outgoing;
				*stop = YES;
			}
		}];
		if (transfer) {
			[self handleError:iq forTransfer:transfer];
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
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[multicastDelegate xmppSIFileTransfer:self transferDidBegin:transfer];
}

- (void)xmppTransferUpdatedProgress:(XMPPSITransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
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
	if (!transfer.sid) return;
	[_activeTransfers removeObject:transfer];
	[_outgoingTransfers removeObjectForKey:transfer.sid];
	[_incomingTransfers removeObjectForKey:transfer.sid];
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
	[_outgoingTransfers removeObjectForKey:transfer.sid];
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
														sid:transfer.sid
											  directConnection:YES];
	transfer.socket = socket;
	[transfer start];
}

- (void)beginIBBOutgoingTransfer:(XMPPSITransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	NSError *error = nil;
	XMPPInBandBytestream *bytestream = [[XMPPInBandBytestream alloc] initOutgoingBytestreamWithStream:xmppStream toJID:transfer.remoteJID elementID:transfer.uniqueIdentifier sid:transfer.sid fileURL:transfer.URL error:&error];
	if (!bytestream) {
		[self transferFailed:transfer error:error];
		return;
	}
	transfer.inBandBytestream = bytestream;
	[transfer start];
}

- (void)handleStreamInitiationResult:(XMPPIQ *)iq
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	XMPPSITransfer *transfer = _outgoingTransfers[iq.elementID];
	if (transfer) {
		NSArray *streamMethods = [self.class extractStreamMethodsFromIQ:iq];
		if ([streamMethods count]) {
			NSString *method = streamMethods[0];
			if ([_supportedTransferMechanisms containsObject:method]) {
				transfer.streamMethod = streamMethods[0];
				XMPPIQ *result = [XMPPIQ iqWithType:@"result" to:iq.from elementID:iq.elementID];
				[xmppStream sendElement:result];
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
			XMPPSITransfer *transfer = [[XMPPSITransfer alloc] initWithDelegateQueue:moduleQueue];
			if ([streamMethods containsObject:XMPPSIProfileSOCKS5Transfer]) {
				transfer.streamMethod = XMPPSIProfileSOCKS5Transfer;
			} else {
				transfer.streamMethod = XMPPSIProfileIBBTransfer;
			}
			transfer.delegate = self;
			transfer.remoteJID = iq.from;
			transfer.uniqueIdentifier = iq.elementID;
			transfer.sid = [si attributeStringValueForName:@"id"];
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

- (void)handleTURNRequest:(XMPPIQ *)iq forTransfer:(XMPPSITransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[_activeTransfers addObject:transfer];
	[_incomingTransfers removeObjectForKey:iq.elementID];
	TURNSocket *socket = [[TURNSocket alloc] initWithStream:xmppStream incomingTURNRequest:iq];
	transfer.socket = socket;
	[transfer start];
}

- (void)handleIBBRequest:(XMPPIQ *)iq forTransfer:(XMPPSITransfer *)transfer
{
	XMPP_MODULE_ASSERT_CORRECT_QUEUE();
	[_activeTransfers addObject:transfer];
	[_incomingTransfers removeObjectForKey:iq.elementID];
	XMPPInBandBytestream *bytestream = [[XMPPInBandBytestream alloc] initIncomingBytestreamRequest:iq withStream:xmppStream];
	transfer.inBandBytestream = bytestream;
	[transfer start];
}

- (void)handleError:(XMPPIQ *)iq forTransfer:(XMPPSITransfer *)transfer
{
	NSXMLElement *error = [iq elementForName:@"error"];
	NSString *errorCode = [error attributeStringValueForName:@"code"];
	BOOL handledError = NO;
	if ([errorCode isEqualToString:@"400"]) {
		if ([error elementForName:@"no-valid-streams" xmlns:XMLNSJabberSI]) {
			[self transferFailed:transfer error:[self.class noValidStreamsError]];
			handledError = YES;
		} else if ([error elementForName:@"bad-profile" xmlns:XMLNSJabberSI]) {
			[self transferFailed:transfer error:[self.class noValidStreamsError]];
			handledError = YES;
		}
	} else if ([errorCode isEqualToString:@"403"]) {
		[self transferFailed:transfer error:[self.class offerDeclinedError]];
		handledError = YES;
	}
	if (!handledError) {
		[self transferFailed:transfer error:[self.class genericTransferFailedError]];
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
	return [NSError errorWithDomain:XMPPSIFileTransferErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey : @"Remote peer did not respond with supported transfer mechanism."}];
}

+ (NSError *)profileNotUnderstoodError
{
	return [NSError errorWithDomain:XMPPSIFileTransferErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey : @"Transfer profile not understood."}];
}

+ (NSError *)offerDeclinedError
{
	return [NSError errorWithDomain:XMPPSIFileTransferErrorDomain code:403 userInfo:@{NSLocalizedDescriptionKey : @"Transfer offer declined."}];
}

+ (NSError *)genericTransferFailedError
{
	return [NSError errorWithDomain:XMPPSIFileTransferErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"File transfer failed."}];
}
@end

#define XMPPSITransferReadBlockSize 4096

@implementation XMPPSITransfer {
	GCDAsyncSocket *_asyncSocket;
	BOOL _transferComplete;
	NSError *_transferError;
	dispatch_queue_t _transferCallbackQueue;
	NSFileHandle *_fileHandle;
	double _remainingBytesForCurrentWrite;
}

#pragma mark - Initializers

- (instancetype)initWithDelegateQueue:(dispatch_queue_t)delegateQueue
{
	if ((self = [super init])) {
		_delegateQueue = delegateQueue;
#if !OS_OBJECT_USE_OBJC
		dispatch_retain(_delegateQueue);
#endif
		_transferCallbackQueue = dispatch_queue_create("XMPPSITransferCallbackQueue", NULL);
	}
	return self;
}

- (void)dealloc
{
#if !OS_OBJECT_USE_OBJC
	dispatch_release(_delegateQueue);
	dispatch_release(_transferCallbackQueue);
#endif
}

- (void)start
{
	NSError *error = nil;
	if (self.outgoing) {
		_fileHandle = [NSFileHandle fileHandleForReadingFromURL:self.URL error:&error];
	} else {
		NSString *writePath = [NSTemporaryDirectory() stringByAppendingPathComponent:self.fileName];
		self.URL = [NSURL fileURLWithPath:writePath];
		
		[NSFileManager.defaultManager createFileAtPath:self.URL.path contents:nil attributes:nil];
		_fileHandle = [NSFileHandle fileHandleForWritingToURL:self.URL error:&error];
	}
	if (!_fileHandle) {
		[self delegateTransferFailedWithError:error];
		return;
	}
	if (self.inBandBytestream) {
		[self.inBandBytestream startWithDelegate:self delegateQueue:_transferCallbackQueue];
	}
	if (self.socket) {
		[self.socket startWithDelegate:self delegateQueue:_transferCallbackQueue];
	}
}

#pragma mark - NSObject

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@:%p URL:%@ streamMethod:%@ socket:%@ remoteJID:%@  totalBytes:%llu transferredBytes:%llu outgoing:%d fileName:%@ fileDescription:%@ mimeType:%@ MD5Hash:%@ uniqueIdentifier:%@>", NSStringFromClass(self.class), self, self.URL, self.streamMethod, self.socket, self.remoteJID, self.totalBytes, self.transferredBytes, self.outgoing, self.fileName, self.fileDescription, self.mimeType, self.MD5Hash, self.uniqueIdentifier];
}

#pragma mark - TURNSocketDelegate

- (void)turnSocket:(TURNSocket *)sender didSucceed:(GCDAsyncSocket *)socket
{
	[self delegateTransferDidBegin];
	_asyncSocket = socket;
	[_asyncSocket setDelegate:self delegateQueue:_transferCallbackQueue];
	if (self.outgoing) {
		[self writeBytesToSocket];
	} else {
		[self readBytesFromSocket];
	}
}

- (void)turnSocketDidFail:(TURNSocket *)sender
{
	[self delegateTransferFailedWithError:[self.class turnSocketFailedError]];
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
	if (_transferComplete) {
		[self delegateTransferDidEnd];
	} else {
		[self delegateTransferFailedWithError:_transferError ?: (err ?: [self.class asyncSocketDisconnectedError])];
	}
}

- (void)socket:(GCDAsyncSocket *)sock didWritePartialDataOfLength:(NSUInteger)partialLength tag:(long)tag
{
	[self incrementTransferredBytesBy:partialLength];
	_remainingBytesForCurrentWrite -= partialLength;
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
	if (_remainingBytesForCurrentWrite) {
		[self incrementTransferredBytesBy:_remainingBytesForCurrentWrite];
		_remainingBytesForCurrentWrite = 0;
	}
	
	if (!_transferComplete && ![self writeBytesToSocket]) {
		_transferComplete = YES;
		[_fileHandle closeFile];
		[_asyncSocket disconnectAfterReadingAndWriting];
	}
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    [self incrementTransferredBytesBy:[data length]];
	[_fileHandle writeData:data];
    if (self.transferredBytes == self.totalBytes) {
		if ([self.MD5Hash length]) {
			NSString *MD5 = [(__bridge_transfer NSString *)FileMD5HashCreateWithPath((__bridge CFStringRef)self.URL.path, FileHashDefaultChunkSizeForReadingData) lowercaseString];
			if (![self.MD5Hash.lowercaseString isEqualToString:MD5]) {
				_transferError = [self.class hashMismatchError];
			} else {
				_transferComplete = YES;
			}
		} else {
			_transferComplete = YES;
		}
        [sock disconnect];
		[_fileHandle closeFile];
    } else {
        [self readBytesFromSocket];
    }
}

#pragma mark -XMPPInBandBytestreamDelegate

- (void)xmppIBBTransferDidBegin:(XMPPInBandBytestream *)stream
{
	[self delegateTransferDidBegin];
}

- (void)xmppIBBTransfer:(XMPPInBandBytestream *)stream didWriteDataOfLength:(NSUInteger)length
{
	[self incrementTransferredBytesBy:length];
}

- (void)xmppIBBTransfer:(XMPPInBandBytestream *)stream didReadData:(NSData *)data
{
	[self incrementTransferredBytesBy:data.length];
	[_fileHandle writeData:data];
}

- (void)xmppIBBTransfer:(XMPPInBandBytestream *)stream failedWithError:(NSError *)error
{
	[self delegateTransferFailedWithError:error];
}

- (void)xmppIBBTransferDidEnd:(XMPPInBandBytestream *)stream
{
	[_fileHandle closeFile];
	[self.delegate xmppTransferDidEnd:self];
}

#pragma mark - Delegate Methods

- (void)delegateTransferDidBegin
{
	dispatch_async(_delegateQueue, ^{ @autoreleasepool {
		if ([_delegate respondsToSelector:@selector(xmppTransferDidBegin:)]) {
			[_delegate xmppTransferDidBegin:self];
		}
	}});
}

- (void)delegateTransferDidEnd
{
	dispatch_async(_delegateQueue, ^{ @autoreleasepool {
		if ([_delegate respondsToSelector:@selector(xmppTransferDidEnd:)]) {
			[_delegate xmppTransferDidEnd:self];
		}
	}});
}

- (void)delegateTransferFailedWithError:(NSError *)error
{
	dispatch_async(_delegateQueue, ^{ @autoreleasepool {
		if ([_delegate respondsToSelector:@selector(xmppTransfer:failedWithError:)]) {
			[_delegate xmppTransfer:self failedWithError:error];
		}
	}});
}

#pragma mark - Private

- (BOOL)writeBytesToSocket
{
	NSData *data = [_fileHandle readDataOfLength:XMPPSITransferReadBlockSize];
	NSUInteger length = [data length];
	if (length) {
		_remainingBytesForCurrentWrite = length;
		[_asyncSocket writeData:data withTimeout:-1 tag:length];
		return YES;
	}
	return NO;
}

- (void)readBytesFromSocket
{
	[_asyncSocket readDataWithTimeout:XMPPSIFileTransferReadTimeout tag:0];
}

- (void)incrementTransferredBytesBy:(unsigned long long)length
{
	unsigned long long transferred = self.transferredBytes;
	transferred += length;
	self.transferredBytes = transferred;
	dispatch_async(_delegateQueue, ^{ @autoreleasepool {
		if ([_delegate respondsToSelector:@selector(xmppTransferUpdatedProgress:)]) {
			[_delegate xmppTransferUpdatedProgress:self];
		}
	}});
}

+ (NSError *)turnSocketFailedError
{
	return [NSError errorWithDomain:XMPPSIFileTransferErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Socket failed to connect to remote peer."}];
}

+ (NSError *)asyncSocketDisconnectedError
{
	return [NSError errorWithDomain:XMPPSIFileTransferErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Socket disconnected."}];
}

+ (NSError *)hashMismatchError
{
	return [NSError errorWithDomain:XMPPSIFileTransferErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: @"Expected file hash does not match the hash of the received data."}];
}
@end