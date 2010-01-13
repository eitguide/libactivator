#import "libactivator.h"

#import <SpringBoard/SpringBoard.h>
#import <CaptainHook/CaptainHook.h>

#include <objc/runtime.h>
#include <sys/stat.h>
#include <notify.h>

NSString * const LAEventModeSpringBoard = @"springboard";
NSString * const LAEventModeApplication = @"application";
NSString * const LAEventModeLockScreen  = @"lockscreen";

CHDeclareClass(SBIconController);

CHConstructor {
	CHLoadLateClass(SBIconController);
}

@implementation LAEvent

@synthesize name = _name;
@synthesize mode = _mode;
@synthesize handled = _handled;

+ (id)eventWithName:(NSString *)name
{
	return [[[self alloc] initWithName:name] autorelease];
}

+ (id)eventWithName:(NSString *)name mode:(NSString *)mode
{
	return [[[self alloc] initWithName:name mode:mode] autorelease];
}

- (id)initWithName:(NSString *)name
{
	if ((self = [super init])) {
		_name = [name copy];
	}
	return self;
}

- (id)initWithName:(NSString *)name mode:(NSString *)mode
{
	if ((self = [super init])) {
		_name = [name copy];
		_mode = [mode copy];
	}
	return self;
}

- (void)dealloc
{
	[_name release];
	[_mode release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%s name=%@ mode=%@ handled=%s %p>", class_getName([self class]), _name, _mode, _handled?"YES":"NO", self];
}

@end

#define ListenerKeyForEventNameAndMode(eventName, eventMode) \
	[NSString stringWithFormat:@"LAEventListener(%@)-%@", (eventMode), (eventName)]

static LAActivator *sharedActivator;

@interface LAActivator ()
- (void)_loadPreferences;
- (void)_savePreferences;
- (void)_reloadPreferences;

- (NSDictionary *)_infoForEventWithName:(NSString *)name;
- (NSDictionary *)_infoForListenerWithName:(NSString *)name;
@end

static void PreferencesChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
	[sharedActivator _reloadPreferences];
}

@implementation LAActivator

#define LoadPreferences() do { if (!_preferences) [self _loadPreferences]; } while(0)

+ (LAActivator *)sharedInstance
{
	return sharedActivator;
}

+ (void)load
{
	sharedActivator = [[LAActivator alloc] init];
}

- (NSString *)settingsFilePath
{
	return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/libactivator.plist"];
}


- (id)init
{
	if ((self = [super init])) {
		// Does not retain values!
		_listeners = (NSMutableDictionary *)CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
		// Register for notification
		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), self, PreferencesChangedCallback, CFSTR("libactivator.preferenceschanged"), NULL, CFNotificationSuspensionBehaviorCoalesce);
	}
	return self;
}

- (void)dealloc
{
	CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), self, CFSTR("libactivator.preferencechanged"), NULL);
	[_preferences release];
	[_listeners release];
	[super dealloc];
}

// Preferences

- (void)_reloadPreferences
{
	if (_suppressReload == 0) {
		[_preferences release];
		_preferences = nil;
	}
}

- (void)_loadPreferences
{
	BOOL shouldResave = NO;
	if (!(_preferences = [[NSMutableDictionary alloc] initWithContentsOfFile:[self settingsFilePath]])) {
		if ((_preferences = [[NSMutableDictionary alloc] initWithContentsOfFile:@"/User/Library/Preferences/libactivator.plist"])) {
			// Load old path
			[[NSFileManager defaultManager] removeItemAtPath:@"/User/Library/Preferences/libactivator.plist" error:NULL];
			shouldResave = YES;
		} else {
			// Create a new preference file
			_preferences = [[NSMutableDictionary alloc] init];
			return;
		}
	}
	// Convert old-style preferences
	for (NSString *eventName in [self availableEventNames]) {
		NSString *oldPref = [@"LAEventListener-" stringByAppendingString:eventName];
		NSString *oldValue = [_preferences objectForKey:oldPref];
		if (oldValue) {
			for (NSString *mode in [self availableEventModes])
				[_preferences setObject:oldValue forKey:ListenerKeyForEventNameAndMode(eventName, mode)];
			[_preferences removeObjectForKey:oldPref];
			shouldResave = YES;
		}
	}
	// Save if necessary
	if (shouldResave)
		[self _savePreferences];
}

- (void)_savePreferences
{
	if (_preferences) {
		_suppressReload++;
		CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)[self settingsFilePath], kCFURLPOSIXPathStyle, NO);
		CFWriteStreamRef stream = CFWriteStreamCreateWithFile(kCFAllocatorDefault, url);
		CFRelease(url);
		CFWriteStreamOpen(stream);
		CFPropertyListWriteToStream((CFPropertyListRef)_preferences, stream, kCFPropertyListBinaryFormat_v1_0, NULL);
		CFWriteStreamClose(stream);
		CFRelease(stream);
		chmod([[self settingsFilePath] UTF8String], S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH);
		notify_post("libactivator.preferenceschanged");
		_suppressReload--;
	}
}

// Sending Events

- (id<LAListener>)listenerForEvent:(LAEvent *)event
{
	return [_listeners objectForKey:[self assignedListenerNameForEvent:event]];
}

- (void)sendEventToListener:(LAEvent *)event
{
	id<LAListener> listener = [self listenerForEvent:event];
	if ([listener respondsToSelector:@selector(activator:receiveEvent:)])
		[listener activator:self receiveEvent:event];
	if ([event isHandled])
		for (id<LAListener> other in [_listeners allValues])
			if (other != listener)
				if ([other respondsToSelector:@selector(activator:otherListenerDidHandleEvent:)])
					[other activator:self otherListenerDidHandleEvent:event];
}

- (void)sendAbortToListener:(LAEvent *)event
{
	id<LAListener> listener = [self listenerForEvent:event];
	if ([listener respondsToSelector:@selector(activator:abortEvent:)])
		[listener activator:self abortEvent:event];
}

// Registration of listeners

- (void)registerListener:(id<LAListener>)listener forName:(NSString *)name
{
	[_listeners setObject:listener forKey:name];
	LoadPreferences();
	NSString *key = [@"LAHasSeenListener-" stringByAppendingString:name];
	if (![[_preferences objectForKey:key] boolValue]) {
		[_preferences setObject:[NSNumber numberWithBool:YES] forKey:key];
		[self _savePreferences];
	}
}

- (void)unregisterListenerWithName:(NSString *)name
{
	[_listeners removeObjectForKey:name];
}

- (BOOL)hasSeenListenerWithName:(NSString *)name
{
	LoadPreferences();
	return [[_preferences objectForKey:[@"LAHasSeenListener-" stringByAppendingString:name]] boolValue];
}

// Setting Assignments

- (BOOL)assignEvent:(LAEvent *)event toListenerWithName:(NSString *)listenerName
{
	LoadPreferences();
	NSString *eventName = [event name];
	NSString *eventMode = [event mode];
	if ([eventMode length])
		[_preferences setObject:listenerName forKey:ListenerKeyForEventNameAndMode(eventName, eventMode)];
	else {
		for (NSString *mode in [self availableEventModes])
			[_preferences setObject:listenerName forKey:ListenerKeyForEventNameAndMode(eventName, mode)];
	}
	// Save Preferences
	[self _savePreferences];
	return YES;
}

- (void)unassignEvent:(LAEvent *)event
{
	LoadPreferences();
	BOOL shouldSave = NO;
	NSString *eventName = [event name];
	NSString *eventMode = [event mode];
	if ([eventMode length]) {
		NSString *prefName = ListenerKeyForEventNameAndMode(eventName, eventMode);
		if ([_preferences objectForKey:prefName]) {
			[_preferences removeObjectForKey:prefName];
			shouldSave = YES;
		}
	} else {
		for (NSString *mode in [self availableEventModes]) {
			NSString *prefName = ListenerKeyForEventNameAndMode(eventName, mode);
			if ([_preferences objectForKey:prefName]) {
				[_preferences removeObjectForKey:prefName];
				shouldSave = YES;
			}
		}
	}
	if (shouldSave)
		[self _savePreferences];
}

// Getting Assignments

- (NSString *)assignedListenerNameForEvent:(LAEvent *)event
{
	LoadPreferences();
	NSString *prefName = ListenerKeyForEventNameAndMode([event name], [event mode] ?: [self currentEventMode]);
	return [_preferences objectForKey:prefName];
}

- (NSArray *)eventsAssignedToListenerWithName:(NSString *)listenerName
{
	NSArray *events = [self availableEventNames];
	NSMutableArray *result = [NSMutableArray array];
	LoadPreferences();
	for (NSString *eventMode in [self availableEventModes]) {
		for (NSString *eventName in events) {
			NSString *prefName = ListenerKeyForEventNameAndMode(eventName, eventMode);
			NSString *assignedListener = [_preferences objectForKey:prefName];
			if ([assignedListener isEqualToString:listenerName])
				[result addObject:[LAEvent eventWithName:eventName mode:eventMode]];
		}
	}
	return result;
}

// Events

- (NSArray *)availableEventNames
{
	// TODO: Possibly cache this
	NSMutableArray *result = [NSMutableArray array];
	for (NSString *fileName in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/Library/Activator/Events" error:NULL])
		if (![fileName hasPrefix:@"."])
			[result addObject:fileName];
	return result;
}

- (NSDictionary *)_infoForEventWithName:(NSString *)name
{
	// TODO: Possibly cache this
	return [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"/Library/Activator/Events/%@/Info.plist", name]];
}

- (BOOL)eventWithNameIsHidden:(NSString *)name
{
	return [[[self _infoForEventWithName:name] objectForKey:@"hidden"] boolValue];
}

// Listeners

- (NSArray *)availableListenerNames
{
	NSMutableArray *result = [NSMutableArray array];
	for (NSString *fileName in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/Library/Activator/Listeners" error:NULL])
		if (![fileName hasPrefix:@"."])
			[result addObject:fileName];
	return result;
}

- (NSDictionary *)_infoForListenerWithName:(NSString *)name
{
	return [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"/Library/Activator/Listeners/%@/Info.plist", name]];
}

- (BOOL)listenerWithNameRequiresAssignment:(NSString *)name
{
	return [[[self _infoForListenerWithName:name] objectForKey:@"requires-event"] boolValue];
}

- (NSArray *)compatibleEventModesForListenerWithName:(NSString *)name;
{
	NSArray *setting = [[self _infoForListenerWithName:name] objectForKey:@"compatible-modes"];
	return setting ?: [self availableEventModes];
}

- (UIImage *)iconForListenerName:(NSString *)listenerName
{
	return [UIImage imageWithContentsOfFile:[NSString stringWithFormat:@"/Library/Activator/Listeners/%@/Icon.png", listenerName]];
}

- (UIImage *)smallIconForListenerName:(NSString *)listenerName
{
	return [UIImage imageWithContentsOfFile:[NSString stringWithFormat:@"/Library/Activator/Listeners/%@/Icon-small.png", listenerName]];
}


// Event Modes

- (NSArray *)availableEventModes
{
	return [NSArray arrayWithObjects:LAEventModeSpringBoard, LAEventModeApplication, LAEventModeLockScreen, nil];
}

- (NSString *)currentEventMode
{
	if ([(SpringBoard *)[UIApplication sharedApplication] isLocked])
		return LAEventModeLockScreen;
	if ([[CHSharedInstance(SBIconController) contentView] window])
		return LAEventModeSpringBoard;
	return LAEventModeApplication;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%s listeners=%@ %p>", class_getName([self class]), _listeners, self];
}

@end

@implementation LAActivator (Localization)

- (NSString *)localizedTitleForEventMode:(NSString *)eventMode
{
	if ([eventMode isEqualToString:LAEventModeSpringBoard])
		return @"At SpringBoard";
	if ([eventMode isEqualToString:LAEventModeApplication])
		return @"In Application";
	if ([eventMode isEqualToString:LAEventModeLockScreen])
		return @"At Lock Screen";
	return @"Anywhere";
}

- (NSString *)localizedTitleForEventName:(NSString *)eventName
{	
	return [[self _infoForEventWithName:eventName] objectForKey:@"title"] ?: eventName;
}

- (NSString *)localizedTitleForListenerName:(NSString *)listenerName
{
	return [[self _infoForListenerWithName:listenerName] objectForKey:@"title"] ?: listenerName;
}

- (NSString *)localizedGroupForEventName:(NSString *)eventName
{
	return [[self _infoForEventWithName:eventName] objectForKey:@"group"];
}

- (NSString *)localizedDescriptionForEventName:(NSString *)eventName
{
	return [[self _infoForEventWithName:eventName] objectForKey:@"description"];
}

- (NSString *)localizedDescriptionForListenerName:(NSString *)listenerName
{
	return [[self _infoForListenerWithName:listenerName] objectForKey:@"description"];
}

@end
