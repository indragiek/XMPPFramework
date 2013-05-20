#import "XMPPMessage+XEP_0085.h"
#import "NSXMLElement+XMPP.h"

NSString * const XMLNSJabberChatStates = @"http://jabber.org/protocol/chatstates";

static NSString * const XMPPChatStateActive = @"active";
static NSString * const XMPPChatStateComposing = @"composing";
static NSString * const XMPPChatStatePaused = @"paused";
static NSString * const XMPPChatStateInactive = @"inactive";
static NSString * const XMPPChatStateGone = @"gone";

static NSArray *_prefixes = nil;
static NSArray *_permittedElementList = nil;

@implementation XMPPMessage (XEP_0085)

+ (void)load
{
	[super load];
	_prefixes = @[@"", @"cha:"];
	NSArray *elements = @[XMPPChatStateActive, XMPPChatStateComposing, XMPPChatStatePaused, XMPPChatStateInactive, XMPPChatStateGone];
	
	NSMutableArray *permitted = [NSMutableArray arrayWithCapacity:elements.count * _prefixes.count];
	[elements enumerateObjectsUsingBlock:^(NSString *element, NSUInteger idx, BOOL *stop) {
		[_prefixes enumerateObjectsUsingBlock:^(NSString *prefix, NSUInteger idx1, BOOL *stop1) {
			[permitted addObject:[prefix stringByAppendingString:element]];
		}];
	}];
	_permittedElementList = permitted;
}

- (BOOL)hasChatState
{
	__block BOOL hasChatState = NO;
	[self.children enumerateObjectsUsingBlock:^(NSXMLNode *node, NSUInteger idx, BOOL *stop) {
		if ([node isKindOfClass:[NSXMLElement class]]) {
			NSXMLElement *element = (NSXMLElement *)node;
			if ([_permittedElementList containsObject:element.name]) {
				hasChatState = YES;
				*stop = YES;
			}
		}
	}];
	return hasChatState;
}

- (BOOL)isActiveChatState
{
	return [self hasChatStateElementsForName:XMPPChatStateActive];
}

- (BOOL)isComposingChatState
{
	return [self hasChatStateElementsForName:XMPPChatStateComposing];
}

- (BOOL)isPausedChatState
{
	return [self hasChatStateElementsForName:XMPPChatStatePaused];
}

- (BOOL)isInactiveChatState
{
	return [self hasChatStateElementsForName:XMPPChatStateInactive];
}

- (BOOL)isGoneChatState
{
	return [self hasChatStateElementsForName:XMPPChatStateGone];
}

- (void)addActiveChatState
{
	[self addChatStateElementsForName:XMPPChatStateActive];
}

- (void)addComposingChatState
{
	[self addChatStateElementsForName:XMPPChatStateComposing];
}

- (void)addPausedChatState
{
	[self addChatStateElementsForName:XMPPChatStatePaused];
}

- (void)addInactiveChatState
{
	[self addChatStateElementsForName:XMPPChatStateInactive];
}

- (void)addGoneChatState
{
	[self addChatStateElementsForName:XMPPChatStateGone];
}

#pragma mark - Private

- (BOOL)hasChatStateElementsForName:(NSString *)name
{
	__block BOOL hasChatState = NO;
	[_prefixes enumerateObjectsUsingBlock:^(NSString *prefix, NSUInteger idx, BOOL *stop) {
		NSString *elementName = [prefix stringByAppendingString:name];
		if ([self elementForName:elementName xmlns:XMLNSJabberChatStates]) {
			hasChatState = YES;
			*stop = YES;
		}
	}];
	return hasChatState;
}

- (void)addChatStateElementsForName:(NSString *)name
{
	[_prefixes enumerateObjectsUsingBlock:^(NSString *prefix, NSUInteger idx, BOOL *stop) {
		NSString *elementName = [prefix stringByAppendingString:name];
		NSXMLElement *child = [NSXMLElement elementWithName:elementName xmlns:XMLNSJabberChatStates];
		[self addChild:child];
	}];
}

@end
