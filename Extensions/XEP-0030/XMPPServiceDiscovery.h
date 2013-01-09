//
//  XMPPServiceDiscovery.h
//  FlamingoXMPP
//
//  Created by Indragie Karunaratne on 2013-01-08.
//  Copyright (c) 2013 Indragie Karunaratne. All rights reserved.
//

#import "XMPPModule.h"
#import "XMPPIQ.h"

/*
 Basic implementation of XEP-0030 <http://xmpp.org/extensions/xep-0030.html> to retrieve
 information about what features an XMPP host supports. 
 
 This is not a complete implementation of XEP-0030. It only supports info retrieval
 (http://jabber.org/protocol/disco#info) and does not support querying specific
 JIDs, conference rooms, or nodes.
 */
@interface XMPPServiceDiscovery : XMPPModule
/*
 Sends an IQ GET stanza from the current XMPPStream JID to currently connected host.
 On success, the xmppServiceDiscovery:requestReturnedResult: method wil be called with
 an IQ stanza containing the features that the server supports.
 
 On failure, the xmppServiceDiscovery:requestFailedWithError: method will be called with
 an NSError object describing the issue.
 */
- (void)requestServiceInformation;
@end

@protocol XMPPServiceDiscoveryDelegate <NSObject>
@optional
/*
 Called when service information is successfully retrieved
 */
- (void)xmppServiceDiscovery:(XMPPServiceDiscovery *)discovery requestReturnedResult:(XMPPIQ *)result;
/*
 Called when the service information request fails. 
 */
- (void)xmppServiceDiscovery:(XMPPServiceDiscovery *)discovery requestFailedWithError:(NSError *)error;
@end