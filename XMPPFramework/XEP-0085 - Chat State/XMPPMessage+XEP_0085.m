#import "XMPPMessage+XEP_0085.h"
#import "NSXMLElement+XMPP.h"


NSString* const XMLNSJabberChatStates = @"http://jabber.org/protocol/chatstates";

@implementation XMPPMessage (XEP_0085)

- (BOOL)hasChatState
{
	return ([[self elementsForXmlns:XMLNSJabberChatStates] count] > 0);
}

- (BOOL)isActiveChatState
{
	return ([self elementForName:@"active" xmlns:XMLNSJabberChatStates] != nil);
}

- (BOOL)isComposingChatState
{
	return ([self elementForName:@"composing" xmlns:XMLNSJabberChatStates] != nil);
}

- (BOOL)isPausedChatState
{
	return ([self elementForName:@"paused" xmlns:XMLNSJabberChatStates] != nil);
}

- (BOOL)isInactiveChatState
{
	return ([self elementForName:@"inactive" xmlns:XMLNSJabberChatStates] != nil);
}

- (BOOL)isGoneChatState
{
	return ([self elementForName:@"gone" xmlns:XMLNSJabberChatStates] != nil);
}


- (void)addActiveChatState
{
	[self addChild:[NSXMLElement elementWithName:@"active" xmlns:XMLNSJabberChatStates]];
}

- (void)addComposingChatState
{
	[self addChild:[NSXMLElement elementWithName:@"composing" xmlns:XMLNSJabberChatStates]];
}

- (void)addPausedChatState
{
	[self addChild:[NSXMLElement elementWithName:@"paused" xmlns:XMLNSJabberChatStates]];
}

- (void)addInactiveChatState
{
	[self addChild:[NSXMLElement elementWithName:@"inactive" xmlns:XMLNSJabberChatStates]];
}

- (void)addGoneChatState
{
	[self addChild:[NSXMLElement elementWithName:@"gone" xmlns:XMLNSJabberChatStates]];
}

@end
