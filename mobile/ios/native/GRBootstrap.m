// gen1recomp iOS native bridge bootstrap.
//
// Runs the Files-app inbox sweep (GRPickerBridge.sweepInbox) every time the
// app becomes active, so ROMs/mods/saves dropped into the app's Documents
// folder land in the LÖVE save directory before the Lua importer rescans.
// Registered from a constructor so no LÖVE/SDL source needs to know about it.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/utsname.h>

static NSString *GRPendingLaunchURI;
static IMP GRApplicationOpenURLOriginal;
static IMP GRApplicationOpenURLLegacyOriginal;
static IMP GRApplicationConfigurationOriginal;
static IMP GRApplicationWillFinishLaunchingOriginal;
static IMP GRApplicationDidFinishLaunchingOriginal;
static IMP GRApplicationSetDelegateOriginal;
static Class GRApplicationDelegateClass;
static IMP GRSceneWillConnectOriginal;
static IMP GRSceneOpenURLContextsOriginal;
static IMP GRSceneSetDelegateOriginal;
static Class GRSceneDelegateClass;
static id GRHingeInteraction;
static __weak UIView *GRHingeView;
static NSInteger GRHingeStatus;
static CGFloat GRHingeAngle;

static void GRInstallApplicationURLHooks(void);
static void GRInstallSceneURLHooksForClass(Class sceneDelegateClass);

static UIWindow *GRActiveWindow(void)
{
    UIWindow *fallback = nil;
    UIWindow *foreground = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        for (UIWindow *window in windowScene.windows) {
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                if (window.isKeyWindow) return window;
                if (!foreground && !window.hidden) foreground = window;
            } else if (!fallback && !window.hidden) {
                fallback = window;
            }
        }
    }
    return foreground ?: fallback;
}

static NSNumber *GRTextScale(void)
{
    UIContentSizeCategory category = UIApplication.sharedApplication.preferredContentSizeCategory;
    if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge]) return @1.8;
    if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraExtraLarge]) return @1.6;
    if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraLarge]) return @1.45;
    if ([category isEqualToString:UIContentSizeCategoryAccessibilityLarge]) return @1.3;
    if ([category isEqualToString:UIContentSizeCategoryAccessibilityMedium]) return @1.2;
    if ([category isEqualToString:UIContentSizeCategoryExtraExtraExtraLarge]) return @1.25;
    if ([category isEqualToString:UIContentSizeCategoryExtraExtraLarge]) return @1.15;
    return @1.0;
}

static void GRAppendReservedRegions(NSMutableArray *regions, UIView *view,
                                    id kind,
                                    NSString *name)
{
    if (@available(iOS 27.1, *)) {
        if (![view respondsToSelector:@selector(reservedRegionsOfKind:)]) return;
        for (id region in [view reservedRegionsOfKind:kind]) {
            CGRect frame = [region frame];
            [regions addObject:@{
                @"kind": name,
                @"x": @(frame.origin.x),
                @"y": @(frame.origin.y),
                @"width": @(frame.size.width),
                @"height": @(frame.size.height),
                @"active": @([region isActive]),
            }];
        }
    }
}

static BOOL GRIsLaunchURL(NSURL *url)
{
    BOOL currentScheme = [url.scheme caseInsensitiveCompare:@"g1rdeluxe"] == NSOrderedSame;
    BOOL legacyScheme = [url.scheme caseInsensitiveCompare:@"gen1recomp++"] == NSOrderedSame;
    return url.scheme.length > 0 && url.host.length > 0
        && (currentScheme || legacyScheme)
        && [url.host caseInsensitiveCompare:@"launch"] == NSOrderedSame;
}

static void GRStoreLaunchURL(NSURL *url)
{
    if (!GRIsLaunchURL(url)) return;
    @synchronized ([UIApplication class]) {
        GRPendingLaunchURI = [url.absoluteString copy];
    }
}

static NSString *GRTakeLaunchURI(void)
{
    @synchronized ([UIApplication class]) {
        NSString *uri = [GRPendingLaunchURI copy];
        GRPendingLaunchURI = nil;
        return uri;
    }
}

static void GRStoreLaunchURLContexts(NSSet *contexts)
{
    for (id context in contexts) {
        if (![context respondsToSelector:@selector(URL)]) continue;
        GRStoreLaunchURL([context URL]);
    }
}

static void GRStoreLaunchOptions(NSDictionary *options)
{
    if (![options isKindOfClass:[NSDictionary class]]) return;
    GRStoreLaunchURL(options[UIApplicationLaunchOptionsURLKey]);
    NSDictionary *activities = options[UIApplicationLaunchOptionsUserActivityDictionaryKey];
    if (![activities isKindOfClass:[NSDictionary class]]) return;
    for (id activity in activities.allValues) {
        if (![activity respondsToSelector:@selector(webpageURL)]) continue;
        GRStoreLaunchURL([activity webpageURL]);
    }
}

static void GRInstallHingeInteraction(UIView *view)
{
    if (!view) return;
    if (@available(iOS 27.1, *)) {
        if (GRHingeView == view && GRHingeInteraction) return;
        if (GRHingeView && GRHingeInteraction) {
            [GRHingeView removeInteraction:GRHingeInteraction];
        }
        GRHingeView = view;
        GRHingeStatus = 0;
        GRHingeAngle = 0;
        GRHingeInteraction = [[UIHingeInteraction alloc]
            initWithUpdateHandler:^(UIHingeInteraction *interaction,
                                     UIHingeInteractionUpdate *update) {
            UIHinge *hinge = update.hinge;
            @synchronized ([UIApplication class]) {
                GRHingeStatus = hinge ? hinge.status : 0;
                GRHingeAngle = hinge ? hinge.angle : 0;
            }
        }];
        [view addInteraction:GRHingeInteraction];
    }
}

static BOOL GRApplicationOpenURL(id self, SEL selector,
                                 UIApplication *application, NSURL *url,
                                 NSDictionary *options)
{
    GRStoreLaunchURL(url);
    if (GRApplicationOpenURLOriginal) {
        typedef BOOL (*GROpenURL)(id, SEL, UIApplication *, NSURL *, NSDictionary *);
        return ((GROpenURL)GRApplicationOpenURLOriginal)(self, selector,
                                                         application, url, options);
    }
    return YES;
}

static BOOL GRApplicationOpenURLLegacy(id self, SEL selector,
                                       UIApplication *application, NSURL *url,
                                       NSString *sourceApplication,
                                       id annotation)
{
    GRStoreLaunchURL(url);
    if (GRApplicationOpenURLLegacyOriginal) {
        typedef BOOL (*GROpenURLLegacy)(id, SEL, UIApplication *, NSURL *, NSString *, id);
        return ((GROpenURLLegacy)GRApplicationOpenURLLegacyOriginal)(
            self, selector, application, url, sourceApplication, annotation);
    }
    return YES;
}

static BOOL GRApplicationWillFinishLaunching(id self, SEL selector,
                                             UIApplication *application,
                                             NSDictionary *options)
{
    GRStoreLaunchOptions(options);
    if (GRApplicationWillFinishLaunchingOriginal) {
        typedef BOOL (*GRWillFinishLaunching)(id, SEL, UIApplication *, NSDictionary *);
        return ((GRWillFinishLaunching)GRApplicationWillFinishLaunchingOriginal)(
            self, selector, application, options);
    }
    return YES;
}

static BOOL GRApplicationDidFinishLaunching(id self, SEL selector,
                                            UIApplication *application,
                                            NSDictionary *options)
{
    GRStoreLaunchOptions(options);
    if (GRApplicationDidFinishLaunchingOriginal) {
        typedef BOOL (*GRDidFinishLaunching)(id, SEL, UIApplication *, NSDictionary *);
        return ((GRDidFinishLaunching)GRApplicationDidFinishLaunchingOriginal)(
            self, selector, application, options);
    }
    return YES;
}

static id GRApplicationConfiguration(id self, SEL selector,
                                     UIApplication *application,
                                     id session, id options)
{
    if ([options respondsToSelector:@selector(URLContexts)]) {
        GRStoreLaunchURLContexts([options URLContexts]);
    }
    if (GRApplicationConfigurationOriginal) {
        typedef id (*GRConfiguration)(id, SEL, UIApplication *, id, id);
        return ((GRConfiguration)GRApplicationConfigurationOriginal)(
            self, selector, application, session, options);
    }
    return nil;
}

static void GRSceneWillConnect(id self, SEL selector, id scene,
                               id session, id options)
{
    if ([options respondsToSelector:@selector(URLContexts)]) {
        GRStoreLaunchURLContexts([options URLContexts]);
    }
    if (GRSceneWillConnectOriginal) {
        typedef void (*GRWillConnect)(id, SEL, id, id, id);
        ((GRWillConnect)GRSceneWillConnectOriginal)(
            self, selector, scene, session, options);
    }
}

static void GRSceneOpenURLContexts(id self, SEL selector, id scene,
                                   NSSet *contexts)
{
    GRStoreLaunchURLContexts(contexts);
    if (GRSceneOpenURLContextsOriginal) {
        typedef void (*GROpenURLContexts)(id, SEL, id, NSSet *);
        ((GROpenURLContexts)GRSceneOpenURLContextsOriginal)(
            self, selector, scene, contexts);
    }
}

static void GRApplicationSetDelegate(id self, SEL selector, id delegate)
{
    typedef void (*GRSetDelegate)(id, SEL, id);
    ((GRSetDelegate)GRApplicationSetDelegateOriginal)(self, selector, delegate);
    GRInstallApplicationURLHooks();
    if (delegate) GRInstallSceneURLHooksForClass([delegate class]);
}

static void GRSceneSetDelegate(id self, SEL selector, id delegate)
{
    typedef void (*GRSetDelegate)(id, SEL, id);
    ((GRSetDelegate)GRSceneSetDelegateOriginal)(self, selector, delegate);
    if (delegate) GRInstallSceneURLHooksForClass([delegate class]);
}

static void GRInstallDelegateURLHooks(void)
{
    Method applicationSetDelegate = class_getInstanceMethod(
        [UIApplication class], @selector(setDelegate:));
    if (applicationSetDelegate && !GRApplicationSetDelegateOriginal) {
        GRApplicationSetDelegateOriginal = method_getImplementation(applicationSetDelegate);
        method_setImplementation(applicationSetDelegate, (IMP)GRApplicationSetDelegate);
    }

    Method sceneSetDelegate = class_getInstanceMethod([UIScene class], @selector(setDelegate:));
    if (sceneSetDelegate && !GRSceneSetDelegateOriginal) {
        GRSceneSetDelegateOriginal = method_getImplementation(sceneSetDelegate);
        method_setImplementation(sceneSetDelegate, (IMP)GRSceneSetDelegate);
    }
}

static void GRInstallSceneURLHooksForClass(Class sceneDelegateClass)
{
    if (!sceneDelegateClass || sceneDelegateClass == GRSceneDelegateClass) return;
    SEL willConnect = @selector(scene:willConnectToSession:options:);
    SEL openURLContexts = @selector(scene:openURLContexts:);
    Method willConnectMethod = class_getInstanceMethod(sceneDelegateClass, willConnect);
    Method openURLContextsMethod = class_getInstanceMethod(sceneDelegateClass, openURLContexts);

    GRSceneDelegateClass = sceneDelegateClass;
    GRSceneWillConnectOriginal = willConnectMethod
        ? method_getImplementation(willConnectMethod) : NULL;
    GRSceneOpenURLContextsOriginal = openURLContextsMethod
        ? method_getImplementation(openURLContextsMethod) : NULL;

    if (willConnectMethod) {
        if (!class_addMethod(sceneDelegateClass, willConnect,
                             (IMP)GRSceneWillConnect,
                             method_getTypeEncoding(willConnectMethod))) {
            method_setImplementation(willConnectMethod, (IMP)GRSceneWillConnect);
        }
    } else {
        class_addMethod(sceneDelegateClass, willConnect,
                        (IMP)GRSceneWillConnect, "v@:@@@");
    }
    if (openURLContextsMethod) {
        if (!class_addMethod(sceneDelegateClass, openURLContexts,
                             (IMP)GRSceneOpenURLContexts,
                             method_getTypeEncoding(openURLContextsMethod))) {
            method_setImplementation(openURLContextsMethod,
                                     (IMP)GRSceneOpenURLContexts);
        }
    } else {
        class_addMethod(sceneDelegateClass, openURLContexts,
                        (IMP)GRSceneOpenURLContexts, "v@:@@");
    }
}

static void GRInstallSceneURLHooks(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        id delegate = scene.delegate;
        if (delegate) GRInstallSceneURLHooksForClass([delegate class]);
    }
}

static void GRInstallApplicationURLHooks(void)
{
    id delegate = UIApplication.sharedApplication.delegate;
    Class delegateClass = delegate ? [delegate class] : Nil;
    if (!delegateClass || delegateClass == GRApplicationDelegateClass) return;
    GRApplicationDelegateClass = delegateClass;
    GRApplicationOpenURLOriginal = NULL;
    GRApplicationOpenURLLegacyOriginal = NULL;
    GRApplicationConfigurationOriginal = NULL;
    GRApplicationWillFinishLaunchingOriginal = NULL;
    GRApplicationDidFinishLaunchingOriginal = NULL;

    SEL willFinish = @selector(application:willFinishLaunchingWithOptions:);
    Method willFinishMethod = class_getInstanceMethod(delegateClass, willFinish);
    if (willFinishMethod) {
        GRApplicationWillFinishLaunchingOriginal = method_getImplementation(willFinishMethod);
        if (!class_addMethod(delegateClass, willFinish, (IMP)GRApplicationWillFinishLaunching,
                             method_getTypeEncoding(willFinishMethod))) {
            method_setImplementation(willFinishMethod, (IMP)GRApplicationWillFinishLaunching);
        }
    } else {
        class_addMethod(delegateClass, willFinish, (IMP)GRApplicationWillFinishLaunching,
                        "c@:@@");
    }

    SEL didFinish = @selector(application:didFinishLaunchingWithOptions:);
    Method didFinishMethod = class_getInstanceMethod(delegateClass, didFinish);
    if (didFinishMethod) {
        GRApplicationDidFinishLaunchingOriginal = method_getImplementation(didFinishMethod);
        if (!class_addMethod(delegateClass, didFinish, (IMP)GRApplicationDidFinishLaunching,
                             method_getTypeEncoding(didFinishMethod))) {
            method_setImplementation(didFinishMethod, (IMP)GRApplicationDidFinishLaunching);
        }
    } else {
        class_addMethod(delegateClass, didFinish, (IMP)GRApplicationDidFinishLaunching,
                        "c@:@@");
    }

    SEL openURL = @selector(application:openURL:options:);
    Method openURLMethod = class_getInstanceMethod(delegateClass, openURL);
    if (openURLMethod) {
        GRApplicationOpenURLOriginal = method_getImplementation(openURLMethod);
        if (!class_addMethod(delegateClass, openURL, (IMP)GRApplicationOpenURL,
                             method_getTypeEncoding(openURLMethod))) {
            method_setImplementation(openURLMethod, (IMP)GRApplicationOpenURL);
        }
    } else {
        class_addMethod(delegateClass, openURL, (IMP)GRApplicationOpenURL,
                         "c@:@@@");
    }

    SEL configuration = @selector(application:configurationForConnectingSceneSession:options:);
    Method configurationMethod = class_getInstanceMethod(delegateClass, configuration);
    if (configurationMethod) {
        GRApplicationConfigurationOriginal = method_getImplementation(configurationMethod);
        if (!class_addMethod(delegateClass, configuration,
                             (IMP)GRApplicationConfiguration,
                             method_getTypeEncoding(configurationMethod))) {
            method_setImplementation(configurationMethod,
                                     (IMP)GRApplicationConfiguration);
        }
    }

    SEL legacyOpenURL = @selector(application:openURL:sourceApplication:annotation:);
    Method legacyMethod = class_getInstanceMethod(delegateClass, legacyOpenURL);
    if (legacyMethod) {
        GRApplicationOpenURLLegacyOriginal = method_getImplementation(legacyMethod);
        if (!class_addMethod(delegateClass, legacyOpenURL,
                             (IMP)GRApplicationOpenURLLegacy,
                             method_getTypeEncoding(legacyMethod))) {
            method_setImplementation(legacyMethod, (IMP)GRApplicationOpenURLLegacy);
        }
    }
}

@interface NSURL (GRWebClipDataURL)
- (BOOL)safari_isHTTPFamilyURL;
@end

@implementation NSURL (GRWebClipDataURL)
- (BOOL)safari_isHTTPFamilyURL
{
    return YES;
}
@end

@interface GRDeviceBridge : NSObject
+ (NSString *)deviceModel;
+ (NSString *)launchURI;
+ (NSString *)windowMetricsJSON;
@end

@implementation GRDeviceBridge
+ (NSString *)deviceModel
{
#if TARGET_OS_SIMULATOR
    NSString *simulatorModel = NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"];
    if (simulatorModel.length > 0) return simulatorModel;
#endif
    struct utsname systemInfo;
    if (uname(&systemInfo) == 0) {
        NSString *model = [NSString stringWithUTF8String:systemInfo.machine];
        if (model.length > 0) return model;
    }
    return @"";
}

+ (NSString *)launchURI
{
    return GRTakeLaunchURI() ?: @"";
}

+ (NSString *)windowMetricsJSON
{
    UIWindow *window = GRActiveWindow();
    UIWindowScene *scene = window.windowScene;
    UIView *view = window.rootViewController.view;
    if (!view) return @"{}";
    GRInstallHingeInteraction(view);
    CGRect bounds = view.bounds;
    UIEdgeInsets insets = view.safeAreaInsets;
    UITraitCollection *traits = scene.traitCollection ?: view.traitCollection;
    CGFloat scale = scene.screen.nativeScale;
    if (scale <= 0) scale = window.screen.nativeScale;
    if (scale <= 0) scale = 1.0;
    NSString *verticalBarEdge = @"unspecified";
    NSInteger hingeStatus = 0;
    CGFloat hingeAngle = 0;
    @synchronized ([UIApplication class]) {
        hingeStatus = GRHingeStatus;
        hingeAngle = GRHingeAngle;
    }
    if (@available(iOS 27.1, *)) {
        if (traits.verticalBarEdge == UIVerticalBarEdgeLeading) {
            verticalBarEdge = @"leading";
        } else if (traits.verticalBarEdge == UIVerticalBarEdgeTrailing) {
            verticalBarEdge = @"trailing";
        }
    }
    NSString *hingeStatusName = @"unknown";
    if (hingeStatus == 1) {
        hingeStatusName = @"closed";
    } else if (hingeStatus == 2) {
        hingeStatusName = @"partiallyOpen";
    } else if (hingeStatus == 3) {
        hingeStatusName = @"fullyOpen";
    }
    NSMutableArray *regions = [NSMutableArray array];
    if (@available(iOS 27.1, *)) {
        GRAppendReservedRegions(regions, view,
                                [UIViewReservedRegionKind divisionRegionKind],
                                @"division");
        GRAppendReservedRegions(regions, view,
                                [UIViewReservedRegionKind occlusionRegionKind],
                                @"occlusion");
    }
    NSDictionary *metrics = @{
        @"width": @(bounds.size.width),
        @"height": @(bounds.size.height),
        @"pixelWidth": @(bounds.size.width * scale),
        @"pixelHeight": @(bounds.size.height * scale),
        @"dpiX": @(scale),
        @"dpiY": @(scale),
        @"safe": @{
            @"left": @(insets.left),
            @"top": @(insets.top),
            @"right": @(insets.right),
            @"bottom": @(insets.bottom),
        },
        @"horizontalClass": traits.horizontalSizeClass == UIUserInterfaceSizeClassCompact
            ? @"compact" : @"regular",
        @"verticalClass": traits.verticalSizeClass == UIUserInterfaceSizeClassCompact
            ? @"compact" : @"regular",
        @"textScale": GRTextScale(),
        @"verticalBarEdge": verticalBarEdge,
        @"hinge": @{
            @"status": hingeStatusName,
            @"angle": @(hingeAngle),
        },
        @"scene": scene.session.persistentIdentifier ?: @"",
        @"regions": regions,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:metrics options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}
@end

__attribute__((constructor))
static void GRBootstrapInstall(void)
{
    GRInstallDelegateURLHooks();
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidFinishLaunchingNotification
                         object:nil
                          queue:[NSOperationQueue mainQueue]
                     usingBlock:^(NSNotification *note) {
        GRStoreLaunchOptions(note.userInfo);
        GRInstallApplicationURLHooks();
        GRInstallSceneURLHooks();
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                         object:nil
                          queue:[NSOperationQueue mainQueue]
                     usingBlock:^(NSNotification *note) {
        GRInstallApplicationURLHooks();
        GRInstallSceneURLHooks();
    }];
    [center addObserverForName:UISceneWillConnectNotification
                         object:nil
                          queue:[NSOperationQueue mainQueue]
                     usingBlock:^(NSNotification *note) {
        GRInstallSceneURLHooks();
        id scene = note.object;
        id delegate = [scene respondsToSelector:@selector(delegate)]
            ? [scene delegate] : nil;
        if (delegate) GRInstallSceneURLHooksForClass([delegate class]);
    }];
    [center addObserverForName:UISceneDidActivateNotification
                         object:nil
                          queue:[NSOperationQueue mainQueue]
                     usingBlock:^(NSNotification *note) {
        GRInstallSceneURLHooks();
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        GRInstallApplicationURLHooks();
        GRInstallSceneURLHooks();
    });
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                    queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        Class bridge = NSClassFromString(@"GRPickerBridge");
        if ([bridge respondsToSelector:@selector(preparePublicDocuments)]) {
            [bridge performSelector:@selector(preparePublicDocuments)];
        }
        if ([bridge respondsToSelector:@selector(sweepInbox)]) {
            [bridge performSelector:@selector(sweepInbox)];
        }
    }];
}
