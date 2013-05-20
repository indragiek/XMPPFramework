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
	for (NSString *element in elements) {
		for (NSString *prefix in _prefixes) {
			[permitted addObject:[prefix stringByAppendingString:element]];
		}
	}
	_permittedElementList = permitted;
}

- (BOOL)hasChatState
{
	for (NSXMLNode *node in self.children) {
		if ([node isKindOfClass:[NSXMLElement class]]) {
			NSXMLElement *element = (NSXMLElement *)node;
			if ([_permittedElementList containsObject:element.name]) {
				return YES;
			}
		}
	}
	return NO;
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
	for (NSString *prefix in _prefixes) {
		NSString *elementName = [prefix stringByAppendingString:name];
		if ([self elementForName:elementName xmlns:XMLNSJabberChatStates]) {
			return YES;
		}
	}
	return NO;
}

- (void)addChatStateElementsForName:(NSString *)name
{
	for (NSString *prefix in _prefixes) {
		NSString *elementName = [prefix stringByAppendingString:name];
		NSXMLElement *child = [NSXMLElement elementWithName:elementName xmlns:XMLNSJabberChatStates];
		[self addChild:child];
	}
}

@end
