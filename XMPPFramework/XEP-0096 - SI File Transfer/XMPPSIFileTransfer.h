//
//  XMPPSIFileTransfer.h
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-02-05.
//  Copyright (c) 2013 nonatomic. All rights reserved.
//

#import "XMPP.h"
#import "TURNSocket.h"

extern NSString* const XMLNSJabberSI; // @"http://jabber.org/protocol/si"
extern NSString* const XMLNSJabberSIFileTransfer; // @"http://jabber.org/protocol/si/profile/file-transfer"

extern NSString* const XMPPSIProfileSOCKS5Transfer; // @"http://jabber.org/protocol/bytestreams"
extern NSString* const XMPPSIProfileIBBTransfer; // @"http://jabber.org/protocol/ibb"

@class XMPPTransfer;
/*
 * Implementation of XEP-0095 Stream Initiation for initiating a data stream between
 * two XMPP entities, and XEP-0096, which uses stream initiation for the purpose of
 * file transfer.
 */
@interface XMPPSIFileTransfer : XMPPModule

#pragma mark - Sending

/*
 * Sends an IQ get request to the given JID with an <si> element containing information
 * about the file being transferred, as well as the available stream methods to transfer
 * the file data. 
 *
 * name - The name of the file (required)
 * size - The file size in bytes (required)
 * description - An extended description of the file (optional)
 * mimeType - The MIME type of the file (optional)
 * hash - The MD5 hash of the file (optional)
 * lastModifiedDate - The date when the file was last modified (optional)
 * streamMethods - Array of stream methods that the file transfer will support. Some possible values:
 *		http://jabber.org/protocol/bytestreams - SOCKS5 Bytestream (XEP-0065)
 *		http://jabber.org/protocol/ibb - In Band Bytestream (XEP-0047)
 * supportsRangedTransfer - Whether the receiver can request a specific range of the file
 * jid - The target JID to send the offer to
 * 
 * Returns an XMPPTransfer object representing this stream initiation offer.
 */
- (XMPPTransfer *)sendStreamInitiationOfferForFileName:(NSString *)name
												  data:(NSData *)data
										   description:(NSString *)description
											  mimeType:(NSString *)mimeType
									  lastModifiedDate:(NSDate *)date
										 streamMethods:(NSArray *)methods
								supportsRangedTransfer:(BOOL)supportsRanged
												 toJID:(XMPPJID *)jid;

/*
 * Convenience method for sending a stream initiation offer for the most common use case
 * Fills in the hash & size automatically, and passes the default stream methods supported by 
 * this class (XMPPSIProfileSOCKS5Transfer and XMPPSIProfileIBBTransfer) and YES for supportsRangedTransfer
 *
 * Returns an XMPPTransfer object representing this stream initiation offer.
 */
- (XMPPTransfer *)sendStreamInitiationOfferForFileName:(NSString *)name
												  data:(NSData *)data
											  mimeType:(NSString *)mimeType
												 toJID:(XMPPJID *)jid;

#pragma mark - Receiving

/*
 * Convenience method for extracting an array of stream method strings
 * from a received stream initiation offer IQ
 * Returns nil if the element is not of a valid structure
 */
+ (NSArray *)extractStreamMethodsFromIQ:(XMPPIQ *)iq;

/*
 Accepts the specified stream initiation offer
 */
- (void)acceptStreamInitiationOffer:(XMPPIQ *)offer withStreamMethod:(NSString *)method;

/*
 Rejects the specified stream initiation offer
 */
- (void)rejectStreamInitiationOffer:(XMPPIQ *)offer;
@end

@protocol XMPPSIFileTransferDelegate <NSObject>
/*
 * Called when another XMPP entity sends a stream initiation offer
 */
- (void)xmppSIFileTransferReceivedStreamInitiationOffer:(XMPPIQ *)offer;

/*
 * Called when the XMPP stream has successfully sent a stream initiation offer
 */
- (void)xmppSIFileTransferDidSendOfferForTransfer:(XMPPTransfer *)transfer;

/*
 * Called when either an outgoing or incoming file transfer begins
 */
- (void)xmppSIFileTransferDidBegin:(XMPPTransfer *)transfer;

/*
 * Called when a file transfer completes. (If this is an incoming transfer, this means
 * that you can now access the data property to retrieve the downloaded file data).
 */
- (void)xmppSIFileTransferDidEnd:(XMPPTransfer *)transfer;

/*
 * Called when the specified file transfer fails with error information if available
 */
- (void)xmppSIFileTransferFailed:(XMPPTransfer *)transfer withError:(NSError *)error;

/*
 * Called to inform the delegate of the progress of the file transfer operation. The totalBytes
 * and transferredBytes properties of XMPPTransfer (which are also KVO observable) can be used
 * to determine the percentage completion of the transfer).
 */
- (void)xmppSIFileTransferUpdatedProgress:(XMPPTransfer *)transfer;
@end

/*
 * Class that represents an XMPP file transfer via XMPPSIFileTransfer
 */
@interface XMPPTransfer : NSObject <GCDAsyncSocketDelegate, TURNSocketDelegate>
/*
 * The stream transfer method being used to transfer the file
 */
@property (nonatomic, copy, readonly) NSString *streamMethod;
/*
 * Socket that is used for SOCKS5 bytestreams. Returns nil if the SOCKS5 transfer mechanism is not being used
 */
@property (nonatomic, strong, readonly) TURNSocket *socket;
/*
 * The remote JID that the transfer is with
 */
@property (nonatomic, strong, readonly) XMPPJID *remoteJID;
/*
 * The data being transferred (either written or received). 
 * If this is an incoming transfer, data will be nil until the transfer has completed
 */
@property (nonatomic, strong, readonly) NSData *data;
/*
 * The range of the data being transferred. Returns NSZeroRange if all of the data is being transferred.
 */
@property (nonatomic, assign, readonly) NSRange dataRange;
/*
 * The total number of bytes to transfer. KVO observable.
 */
@property (nonatomic, assign, readonly) unsigned long long totalBytes;
/*
 * The number of bytes already transferred. KVO observable.
 */
@property (nonatomic, assign, readonly) unsigned long long transferredBytes;
/*
 * YES if the transfer is an outgoing transfer, NO if the transfer is an incoming transfer
 */
@property (nonatomic, assign, readonly) BOOL outgoing;
/*
 * The name of the file being transferred
 */
@property (nonatomic, copy, readonly) NSString *fileName;
/*
 * An optional extended description of the file being transferred
 */
@property (nonatomic, copy, readonly) NSString *fileDescription;
/*
 * The MIME type of the file being transferred
 */
@property (nonatomic, copy, readonly) NSString *mimeType;
/*
 * The MD5 hash of the file being transferred
 */
@property (nonatomic, copy, readonly) NSString *MD5Hash;
/*
 * The unique identifier for this file transfer (used as the elementID in incoming and outgoing
 * XMPPIQ stanzas)
 */
@property (nonatomic, copy, readonly) NSString *uniqueIdentifier;
@end