//
//  XMPPSIFileTransfer.h
//  XMPPFramework
//
//  Created by Indragie Karunaratne on 2013-02-05.
//  Copyright (c) 2013 nonatomic. All rights reserved.
//

#import <XMPPFramework/XMPPFramework.h>

extern NSString* const XMLNSJabberSI; // @"http://jabber.org/protocol/si"
extern NSString* const XMLNSJabberSIFileTransfer; // @"http://jabber.org/protocol/si/profile/file-transfer"

extern NSString* const XMPPSIProfileSOCKS5Transfer; // @"http://jabber.org/protocol/bytestreams"
extern NSString* const XMPPSIProfileIBBTransfer; // @"http://jabber.org/protocol/ibb"

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
 */
- (void)sendStreamInitiationOfferForFileName:(NSString *)name
										size:(NSUInteger)size
								 description:(NSString *)description
									mimeType:(NSString *)mimeType
										hash:(NSString *)hash
							lastModifiedDate:(NSDate *)date
							   streamMethods:(NSArray *)methods
					  supportsRangedTransfer:(BOOL)supportsRanged
									   toJID:(XMPPJID *)jid;

/*
 * Convenience method for sending a stream initiation offer for the most common use case
 * Fills in the hash & size automatically, and passes the default stream methods supported by 
 * this class (XMPPSIProfileSOCKS5Transfer and XMPPSIProfileIBBTransfer) and YES for supportsRangedTransfer
 */
- (void)sendStreamInitiationOfferForFileName:(NSString *)name
										data:(NSData *)data
									mimeType:(NSString *)mimeType
									   toJID:(XMPPJID *)jid;


/*
 Begins the data transfer for an XMPP entity that has accepted a sent stream initiation offer
 */
- (void)beginTransferForStreamInitiationResult:(XMPPIQ *)result data:(NSData *)data;

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
- (void)xmppSIFileTransferDidSendOffer:(XMPPIQ *)offer;

/*
 * Called when the remote XMPP entity accepts your stream initiation offer
 */
- (void)xmppSIFileTransferStreamInitiationOffer:(XMPPIQ *)offer acceptedWithResult:(XMPPIQ *)result;
@end