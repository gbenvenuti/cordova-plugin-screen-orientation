/*
The MIT License (MIT)

Copyright (c) 2014

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
 */
#import "YoikScreenOrientation.h"
#import <objc/runtime.h>

static char * const kOrientationLockKey = "orientationLock";
static char * const kOrienatationKey = "orientation";

@implementation YoikScreenOrientation

+ (void)load
{
    [super load];
    [self changeImplementationForClass:NSClassFromString(@"CDVViewController") selector:@selector(shouldAutorotate) to:@selector(yoki_shouldAutorotate)];
    [self changeImplementationForClass:NSClassFromString(@"CDVViewController") selector:@selector(supportedInterfaceOrientations) to:@selector(yoki_supportedInterfaceOrientations)];
}

#pragma mark - Utils

+ (void)changeImplementationForClass:(Class)srcClass selector:(SEL)srcSelector to:(SEL)toSelector
{
    Method original = class_getInstanceMethod(srcClass, srcSelector);
    Method yoki = class_getInstanceMethod(self.class, toSelector);
    
    method_exchangeImplementations(original, yoki);
}

- (UIInterfaceOrientation)interfaceOrientationForArguments:(NSArray *)arguments
{
    if (arguments.count < 2)
        return UIInterfaceOrientationUnknown;
    if (![arguments[0] isEqualToString:@"set"])
        return UIInterfaceOrientationUnknown;
    if ([arguments[1] isEqualToString:@"unlocked"] || [arguments[1] isEqualToString:@"locked"])
        return UIInterfaceOrientationUnknown;
    
    if ([arguments[1] isEqualToString:@"portait"] || [arguments[1] isEqualToString:@"portrait-primary"]) {
        return UIInterfaceOrientationPortrait;
    }
    else if ([arguments[1] isEqualToString:@"portrait-secondary"]) {
        return UIInterfaceOrientationPortraitUpsideDown;
    }
    else if ([arguments[1] isEqualToString:@"landscape-secondary"]) {
        return UIInterfaceOrientationLandscapeRight;
    }
    else if ([arguments[1] isEqualToString:@"landscape-primary"] || [arguments[1] isEqualToString:@"landscape"]) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    else {
        return UIInterfaceOrientationUnknown;
    }
}

- (void)setIsScreenUnlocked:(BOOL)isScreenUnlocked
{
    objc_setAssociatedObject([UIApplication sharedApplication], kOrientationLockKey, @(isScreenUnlocked), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)setSupportedInterfaceOrientations:(NSInteger)supportedInterfaceOrientations
{
    supportedInterfaceOrientations = supportedInterfaceOrientations == UIInterfaceOrientationUnknown ? UIInterfaceOrientationMaskAll : supportedInterfaceOrientations;
    objc_setAssociatedObject([UIApplication sharedApplication], kOrienatationKey, @(supportedInterfaceOrientations), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Swizzle methods

- (BOOL)yoki_shouldAutorotate
{
    NSNumber *value = objc_getAssociatedObject([UIApplication sharedApplication], kOrientationLockKey);
    if (!value)
        return YES;
    else
        return value.boolValue;
}

- (NSUInteger)yoki_supportedInterfaceOrientations
{
    NSNumber *value = objc_getAssociatedObject([UIApplication sharedApplication], kOrientationLockKey);
    NSNumber *orientation = objc_getAssociatedObject([UIApplication sharedApplication], kOrienatationKey);
    UIInterfaceOrientation io = orientation.integerValue;
    if (!value || value.boolValue)
        return UIInterfaceOrientationMaskAll;
    else {
        return io;
    }
}

#pragma mark - Logic

-(void)screenOrientation:(CDVInvokedUrlCommand *)command
{
    NSArray* arguments = command.arguments;
    NSString* orientationIn = [arguments objectAtIndex:1];

    // grab the device orientation so we can pass it back to the js side.
    NSString *orientation;
    UIInterfaceOrientation interfaceOrientation = [self interfaceOrientationForArguments:arguments];
    switch ([[UIDevice currentDevice] orientation]) {
        case UIDeviceOrientationLandscapeLeft:
            orientation = @"landscape-secondary";
            break;
        case UIDeviceOrientationLandscapeRight:
            orientation = @"landscape-primary";
            break;
        case UIDeviceOrientationPortrait:
            orientation = @"portrait-primary";
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            orientation = @"portrait-secondary";
            break;
        default:
            orientation = @"portait";
            break;
    }
    
    if (interfaceOrientation != UIInterfaceOrientationUnknown) {
        NSNumber *value = [NSNumber numberWithInt:interfaceOrientation == UIInterfaceOrientationUnknown ? UIInterfaceOrientationPortrait : interfaceOrientation];
        [[UIDevice currentDevice] setValue:value forKey:@"orientation"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            objc_setAssociatedObject([UIApplication sharedApplication], kOrientationLockKey, @(interfaceOrientation == UIInterfaceOrientationUnknown ? YES : NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
    }

    if ([orientationIn isEqual: @"unlocked"]) {
        orientationIn = orientation;
        [self setIsScreenUnlocked:YES];
    }

    // we send the result prior to the view controller presentation so that the JS side
    // is ready for the unlock call.
    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
        messageAsDictionary:@{@"device":orientation}];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];

    // SEE https://github.com/Adlotto/cordova-plugin-recheck-screen-orientation
    // HACK: Force rotate by changing the view hierarchy. Present modal view then dismiss it immediately
    // This has been changed substantially since iOS8 broke it...
    ForcedViewController *vc = [[ForcedViewController alloc] init];
    vc.calledWith = orientationIn;

    // backgound should be transparent as it is briefly visible
    // prior to closing.
    vc.view.backgroundColor = [UIColor clearColor];
    // vc.view.alpha = 0.0;
    vc.view.opaque = YES;

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
    // This stops us getting the black application background flash, iOS8
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
#endif
//    [self.viewController presentViewController:vc animated:NO completion:nil];
}

@end

@implementation ForcedViewController

- (NSUInteger) supportedInterfaceOrientations
{
    if ([self.calledWith rangeOfString:@"portrait"].location != NSNotFound) {
        return UIInterfaceOrientationMaskPortrait;
    } else if([self.calledWith rangeOfString:@"landscape"].location != NSNotFound) {
        return UIInterfaceOrientationMaskLandscape;
    }
    return UIInterfaceOrientationMaskAll;
}
@end
