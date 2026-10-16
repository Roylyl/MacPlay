#include <gst/gst.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#include <atomic>
#include <math.h>
#include <deque>
#include <string>
#include "macplay_scroll.h"

static NSWindow *macplayWindow;
static uint32_t mpDisplayID;
static NSScreen *mpSelectedScreen() {
 for(NSScreen *screen in NSScreen.screens) if([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]==mpDisplayID)return screen;
 return NSScreen.screens.firstObject;
}
static double mpAspect = 16.0 / 9.0;
static double mpWidth = 1920, mpHeight = 1080;
static double mpPanelWidth = 1920, mpPanelHeight = 1080;
static bool mpDefaultFullscreen = false;
static bool mpStrictPixels = false;
static bool mpEnteringFullscreen = false;
static bool mpHideAfterFullscreen = false;
static bool mpClosingWindow = false;
static bool mpClosePromptOpen = false;
static bool mpCloseRequested = false;
static int mpWindowAction = 0;
static std::string mpLanguage;

static NSString *mpCloseText(NSString *simplified, NSString *traditional, NSString *english) {
 std::string language=mpLanguage;
 if(language.empty() || language=="system") {
  NSString *preferred=NSLocale.preferredLanguages.firstObject ?: @"en";
  language=preferred.UTF8String;
 }
 if(language.rfind("zh-Hant",0)==0 || language.rfind("zh-TW",0)==0 || language.rfind("zh-HK",0)==0 || language.rfind("zh-MO",0)==0)return traditional;
 if(language.rfind("zh",0)==0)return simplified;
 return english;
}

@interface MacPlayVideoWindow : NSWindow
@end
@implementation MacPlayVideoWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)performClose:(id)sender {
 // AppKit's default performClose requires a standard title-bar close button.
 // Borderless windows still route closing through the disconnect confirmation.
 (void)sender;
 id<NSWindowDelegate> delegate=self.delegate;
 if(![delegate respondsToSelector:@selector(windowShouldClose:)] || [delegate windowShouldClose:self])
  [self close];
}
@end

// GStreamer's Cocoa GL window requests Regular even when rendering into our
// existing view. Keep the receiver an agent application with no extra Dock icon.
@interface MacPlayVideoApplication : NSApplication
@end
@implementation MacPlayVideoApplication
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy {
  if (policy == NSApplicationActivationPolicyRegular)
    policy = NSApplicationActivationPolicyAccessory;
  return [super setActivationPolicy:policy];
}
@end

// Convert the physical screen's safe rectangle into the content view's space.
// Intersecting avoids subtracting the notch twice when AppKit already reserves it.
static NSRect mpUsableBounds(NSView *view) {
  NSRect bounds = view.bounds;
  NSWindow *window = view.window;
  if (!(window.styleMask & NSWindowStyleMaskFullScreen)) return bounds;
  if (@available(macOS 12.0, *)) {
    NSScreen *screen = window.screen;
    if (screen) {
      NSEdgeInsets insets = screen.safeAreaInsets;
      NSRect safeScreen = screen.frame;
      safeScreen.origin.x += insets.left;
      safeScreen.origin.y += insets.bottom;
      safeScreen.size.width -= insets.left + insets.right;
      safeScreen.size.height -= insets.top + insets.bottom;
      // AppKit can already size fullscreen content to the notch-safe rectangle.
      // In that case converting through window coordinates can remove another
      // point because of the fullscreen frame's border offset.
      if (bounds.size.width<=safeScreen.size.width && bounds.size.height<=safeScreen.size.height)
        return bounds;
      NSRect safeWindow = [window convertRectFromScreen:safeScreen];
      bounds = NSIntersectionRect(bounds, [view convertRect:safeWindow fromView:nil]);
    }
  }
  return bounds;
}

static NSRect mpVideoRect(NSView *view, double aspect) {
  NSRect bounds = mpUsableBounds(view);
  if (bounds.size.width <= 0 || bounds.size.height <= 0) return NSZeroRect;
  double width = fmin(bounds.size.width, bounds.size.height * aspect);
  double height = width / aspect;
  return NSMakeRect(bounds.origin.x + (bounds.size.width - width) / 2.0,
                    bounds.origin.y + (bounds.size.height - height) / 2.0,
                    width, height);
}

static void mpSetWindowAspect(double aspect) {
  mpAspect = isfinite(aspect) && aspect > 0 ? aspect : 16.0 / 9.0;
  if (!macplayWindow) return;
  [macplayWindow setContentAspectRatio:NSMakeSize(mpAspect, 1.0)];
  if (macplayWindow.styleMask & NSWindowStyleMaskFullScreen) return;

  if (mpEnteringFullscreen) return;
  NSScreen *screen = mpSelectedScreen();
  if (!screen) return;
  // The desktop's backingScaleFactor can describe a scaled render buffer,
  // not the panel. Map physical video pixels through the physical panel size.
  NSSize fixed = NSMakeSize(mpWidth * screen.frame.size.width / mpPanelWidth,
                            mpHeight * screen.frame.size.height / mpPanelHeight);
  if(!mpStrictPixels) {
    double width=fmin(960.0,fmin(screen.visibleFrame.size.width*0.8,screen.visibleFrame.size.height*0.8*mpAspect));
    fixed=NSMakeSize(width,width/mpAspect);
  }
  [macplayWindow setContentSize:fixed];
  macplayWindow.contentView.needsLayout=YES;
  [macplayWindow.contentView layoutSubtreeIfNeeded];
  NSRect visible = screen.visibleFrame, frame = macplayWindow.frame;
  [macplayWindow setFrameOrigin:NSMakePoint(NSMidX(visible)-frame.size.width/2,
                                           NSMidY(visible)-frame.size.height/2)];
}

static void mpLogWindow() {
  NSView *view = macplayWindow.contentView;
  NSRect video = mpVideoRect(view, mpAspect);
  NSLog(@"[MacPlay window] fullscreen=%d movable=%d resizable=%d content=%.3fx%.3f video=%.3fx%.3f pixels=%.0fx%.0f panel=%.0fx%.0f",
        !!(macplayWindow.styleMask & NSWindowStyleMaskFullScreen), macplayWindow.isMovable,
        !!(macplayWindow.styleMask & NSWindowStyleMaskResizable), view.bounds.size.width,
        view.bounds.size.height, video.size.width, video.size.height,
        mpWidth, mpHeight, mpPanelWidth, mpPanelHeight);
}

@interface MacPlayWindowDelegate : NSObject <NSWindowDelegate>
@end
@implementation MacPlayWindowDelegate
- (void)applicationDidBecomeActive:(NSNotification *)notification {
 (void)notification;
 if(!macplayWindow.isVisible || mpClosingWindow)return;
 // Activation is asynchronous; assign keyboard focus after it completes.
 [macplayWindow makeKeyWindow];
 [macplayWindow makeFirstResponder:macplayWindow.contentView];
 macplayWindow.contentView.needsLayout=YES;
 [macplayWindow.contentView layoutSubtreeIfNeeded];
 [macplayWindow.contentView setNeedsDisplay:YES];
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
 (void)notification;macplayWindow.contentView.needsLayout=YES;
}
- (void)windowDidResignKey:(NSNotification *)notification {
 (void)notification;macplayWindow.contentView.needsLayout=YES;
 [macplayWindow.contentView layoutSubtreeIfNeeded];
}
- (BOOL)windowShouldClose:(NSWindow *)window {
 if(mpClosingWindow)return YES;
 if(mpClosePromptOpen || mpCloseRequested)return NO;
 mpClosePromptOpen=true;
 NSAlert *alert=[NSAlert new];
 alert.alertStyle=NSAlertStyleInformational;
 alert.messageText=mpCloseText(@"您确定要断开与iPhone的连接吗？",@"您確定要中斷與iPhone的連線嗎？",@"Disconnect from iPhone?");
 alert.informativeText=mpCloseText(@"断开后将关闭CarPlay画面，并停止接收。",@"中斷後將關閉CarPlay畫面，並停止接收。",@"This closes the CarPlay window and stops reception.");
 [alert addButtonWithTitle:mpCloseText(@"断开连接",@"中斷連線",@"Disconnect")];
 [alert addButtonWithTitle:mpCloseText(@"取消",@"取消",@"Cancel")];
 alert.buttons[0].keyEquivalent=@"";
 alert.buttons[1].keyEquivalent=@"\r";
 [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
  if(window!=macplayWindow)return;
  mpClosePromptOpen=false;
  if(mpClosingWindow)return;
  if(result==NSAlertFirstButtonReturn) {mpCloseRequested=true;mpWindowAction=1;}
 }];
 return NO;
}
- (void)windowDidEnterFullScreen:(NSNotification *)notification {
  (void)notification; mpEnteringFullscreen = false; mpLogWindow();
}
- (void)windowDidFailToEnterFullScreen:(NSWindow *)window {
  (void)window; mpEnteringFullscreen = false;
  NSLog(@"[MacPlay window] failed to enter fullscreen");
}
- (void)windowDidExitFullScreen:(NSNotification *)notification {
  (void)notification; mpSetWindowAspect(mpAspect); mpLogWindow();
  if (mpHideAfterFullscreen) {mpHideAfterFullscreen=false;[macplayWindow orderOut:nil];}
}
@end
static MacPlayWindowDelegate *mpWindowDelegate;

// Layer-hosted GStreamer views need an explicit initial Retina contentsScale;
// waiting only for a backing-properties change can leave a 1x render surface.
static void mpApplyRenderScale(NSView *view) {
  static NSHashTable *loggedLayers;
  if ([view.layer isKindOfClass:[CAOpenGLLayer class]] && view.window) {
    CGFloat scale=view.window.backingScaleFactor;
    CGFloat old=view.layer.contentsScale;
    if (scale>0 && fabs(old-scale)>0.001) {
      view.layer.contentsScale=scale;
      [view setWantsBestResolutionOpenGLSurface:YES];
      [view setNeedsDisplay:YES];
      NSLog(@"[MacPlay render] contentsScale %.3f -> %.3f",old,scale);
    }
    if (!loggedLayers) loggedLayers=[[NSHashTable alloc] initWithOptions:NSPointerFunctionsWeakMemory capacity:8];
    if (![loggedLayers containsObject:view.layer]) {
      [loggedLayers addObject:view.layer];
      NSLog(@"[MacPlay render] contentsScale=%.3f surface=%.0fx%.0f",
            view.layer.contentsScale,view.bounds.size.width*view.layer.contentsScale,
            view.bounds.size.height*view.layer.contentsScale);
    }
  }
  for (NSView *child in view.subviews) mpApplyRenderScale(child);
}

// GStreamer's Cocoa sink invalidates its NSView from the streaming thread.
// AppKit can then race its visible-rectangle cache against a window resize.
// Keep this adapter on GstGLNSView only, installed before the sink starts.
@interface MacPlayGLRedrawRequest : NSObject {
@public
  std::atomic<bool> pending;
  std::atomic<bool> needsDisplay;
}
@end
@implementation MacPlayGLRedrawRequest
- (instancetype)init {
  if ((self = [super init])) { pending.store(false); needsDisplay.store(false); }
  return self;
}
@end

static void (*mpGLSetNeedsDisplay)(id, SEL, BOOL);
static void (*mpGLSetNeedsDisplayInRect)(id, SEL, NSRect);
static char mpGLRedrawRequestKey;

static void mpQueueGLRedraw(NSView *view, BOOL needsDisplay) {
  MacPlayGLRedrawRequest *request;
  @synchronized (view) {
    request = objc_getAssociatedObject(view, &mpGLRedrawRequestKey);
    if (!request) {
      request = [[MacPlayGLRedrawRequest alloc] init];
      objc_setAssociatedObject(view, &mpGLRedrawRequestKey, request, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      [request release];
    }
    request->needsDisplay.store(needsDisplay);
    if (request->pending.exchange(true)) return;
  }
  // Never wait for the main thread: it can be stopping this same pipeline.
  // The copied block retains both objects until the pending redraw completes.
  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL display;
    @synchronized (view) {
      display = request->needsDisplay.load();
      request->pending.store(false);
    }
    if (!view.window) return;
    [CATransaction begin];
    mpGLSetNeedsDisplay(view, @selector(setNeedsDisplay:), display);
    [CATransaction commit];
  });
}

static void mpGLNeedsDisplay(NSView *view, SEL selector, BOOL needsDisplay) {
  if ([NSThread isMainThread]) mpGLSetNeedsDisplay(view, selector, needsDisplay);
  else mpQueueGLRedraw(view, needsDisplay);
}

static void mpGLNeedsDisplayInRect(NSView *view, SEL selector, NSRect rect) {
  if ([NSThread isMainThread]) mpGLSetNeedsDisplayInRect(view, selector, rect);
  else mpQueueGLRedraw(view, YES);
}

static void mpInstallGLMainThreadRedraw() {
  static bool installed = false;
  if (installed) return;
  NSCAssert(NSThread.isMainThread, @"Install the GL view adapter on the main thread");
  Class viewClass = NSClassFromString(@"GstGLNSView");
  if (!viewClass) return;
  SEL display = @selector(setNeedsDisplay:), rect = @selector(setNeedsDisplayInRect:);
  Method displayMethod = class_getInstanceMethod(viewClass, display);
  Method rectMethod = class_getInstanceMethod(viewClass, rect);
  mpGLSetNeedsDisplay = (void (*)(id, SEL, BOOL))method_getImplementation(displayMethod);
  mpGLSetNeedsDisplayInRect = (void (*)(id, SEL, NSRect))method_getImplementation(rectMethod);
  class_replaceMethod(viewClass, display, (IMP)mpGLNeedsDisplay, method_getTypeEncoding(displayMethod));
  class_replaceMethod(viewClass, rect, (IMP)mpGLNeedsDisplayInRect, method_getTypeEncoding(rectMethod));
  installed = true;
}

@interface MacPlayRenderHostView : NSView
@end
@implementation MacPlayRenderHostView
- (void)didAddSubview:(NSView *)subview {
  mpInstallGLMainThreadRedraw();
  [super didAddSubview:subview];mpApplyRenderScale(subview);
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];mpApplyRenderScale(self);
}
- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];mpApplyRenderScale(self);
}
@end

extern "C" void macplay_select_display(uint32_t id) {mpDisplayID=id;}
extern "C" void macplay_set_language(const char *language) {mpLanguage=language ?: "";}
extern "C" int macplay_take_window_action() {int action=mpWindowAction;mpWindowAction=0;return action;}
extern "C" void macplay_configure_window(double width, double height,
    double panelWidth, double panelHeight, bool fullscreen, bool strict) {
  if (!isfinite(width) || !isfinite(height) || !isfinite(panelWidth) ||
      !isfinite(panelHeight) || width <= 0 || height <= 0 ||
      panelWidth <= 0 || panelHeight <= 0) return;
  mpWidth=width; mpHeight=height; mpPanelWidth=panelWidth; mpPanelHeight=panelHeight;
  mpDefaultFullscreen=fullscreen;mpStrictPixels=strict;
  mpSetWindowAspect(width/height);
}

#ifndef MACPLAY_WINDOW_STANDALONE
// Clip view: sized to the content rectangle
@interface LIVIClipView : NSView {
@public
  NSView* _gl;  // the GL sink's render target (child view)
  double _cropL, _cropT, _visW, _visH, _tierW, _tierH;  // content region in tier px
@private
  BOOL _relayoutPending;
  BOOL _inLiveResize;
  BOOL _userHidden;
}
- (void)relayout;
- (void)setUserHidden:(BOOL)hidden;
@end

@implementation LIVIClipView
- (NSView*)hitTest:(NSPoint)point {
  return nil;
}

- (void)relayout {
  NSView* sv = [self superview];
  if (!sv) return;
  NSRect available = mpUsableBounds(sv);
  const double ww = available.size.width;
  const double wh = available.size.height;
  if (ww <= 0 || wh <= 0) return;

  // No content region yet: fill the window, child fills the clip view.
  if (_visW <= 0 || _visH <= 0 || _tierW <= 0 || _tierH <= 0) {
    [self setFrame:available];
    [_gl setFrame:self.bounds];
    return;
  }

  // Contain the content AR into the window; the clip view IS that content rect.
  const double scale = fmin(ww / _visW, wh / _visH);
  const double cdw = _visW * scale;
  const double cdh = _visH * scale;
  [self setFrame:NSMakeRect(available.origin.x + (ww - cdw) / 2.0,
                           available.origin.y + (wh - cdh) / 2.0, cdw, cdh)];

  [_gl setFrame:NSMakeRect(-_cropL * scale, -_cropT * scale, _tierW * scale, _tierH * scale)];
  mpApplyRenderScale(_gl);
}

- (void)superviewResized:(NSNotification*)note {
  (void)note;
  // Keep the video canvas and input coordinates aligned during live resizing.
  if (_relayoutPending) return;
  _relayoutPending = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_relayoutPending = NO;
    [self relayout];
  });
}

// Logical visibility (cluster shown/hidden)
- (void)setUserHidden:(BOOL)hidden {
  _userHidden = hidden;
  if (!_inLiveResize) [self setHidden:hidden];
}

- (void)windowWillStartLiveResize:(NSNotification*)note {
  (void)note;
  _inLiveResize = YES;
  [self relayout];
}

- (void)windowDidEndLiveResize:(NSNotification*)note {
  (void)note;
  _inLiveResize = NO;
  [self setHidden:_userHidden];
  [self relayout];
}
@end

extern "C" guintptr livi_attach_view(guintptr parent, void** outView) {
  mpInstallGLMainThreadRedraw();
  *outView = nullptr;
  NSView* p = (NSView*)(void*)parent;
  if (!p) return parent;

  LIVIClipView* clip = [[LIVIClipView alloc] initWithFrame:[p bounds]];
  clip->_gl = nullptr;
  clip->_cropL = clip->_cropT = clip->_visW = clip->_visH = clip->_tierW = clip->_tierH = 0;
  [clip setWantsLayer:YES];
  clip.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
  clip.layer.masksToBounds = YES;
  [p addSubview:clip positioned:NSWindowBelow relativeTo:nil];

  NSView* gl = [[MacPlayRenderHostView alloc] initWithFrame:[clip bounds]];
  [gl setWantsLayer:YES];
  [clip addSubview:gl];
  clip->_gl = gl;

  // Re-lay-out whenever the window (content view) resizes.
  [p setPostsFrameChangedNotifications:YES];
  [[NSNotificationCenter defaultCenter] addObserver:clip
                                           selector:@selector(superviewResized:)
                                               name:NSViewFrameDidChangeNotification
                                             object:p];

  // Suspend the plane during an interactive window drag-resize
  NSWindow* win = [p window];
  if (win) {
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:clip
           selector:@selector(windowWillStartLiveResize:)
               name:NSWindowWillStartLiveResizeNotification
             object:win];
    [nc addObserver:clip
           selector:@selector(windowDidEndLiveResize:)
               name:NSWindowDidEndLiveResizeNotification
             object:win];
    for (NSNotificationName name in @[NSWindowDidEnterFullScreenNotification,
                                      NSWindowDidExitFullScreenNotification,
                                      NSWindowDidChangeScreenNotification])
      [nc addObserver:clip selector:@selector(superviewResized:) name:name object:win];
    [nc addObserver:clip selector:@selector(superviewResized:)
                name:NSApplicationDidChangeScreenParametersNotification object:nil];
  }

  *outView = (void*)clip;       // tracked view
  return (guintptr)(void*)gl;   // the GL sink renders into the child
}

// Set the content region (crop) and re-lay-out
extern "C" void livi_set_content_region(void* view, void* sink, double cropL,
    double cropT, double visW, double visH, double tierW, double tierH) {
  (void)sink;
  if (!view) return;
  LIVIClipView* clip = (LIVIClipView*)view;
  clip->_cropL = cropL;
  clip->_cropT = cropT;
  clip->_visW = visW;
  clip->_visH = visH;
  clip->_tierW = tierW;
  clip->_tierH = tierH;
  if (clip.window == macplayWindow && visW > 0 && visH > 0)
    mpSetWindowAspect(visW / visH);
  [clip relayout];
}

extern "C" void livi_remove_view(void* view) {
  if (!view) return;
  NSView* v = (NSView*)view;
  [[NSNotificationCenter defaultCenter] removeObserver:v];
  [v removeFromSuperview];
}

extern "C" void livi_set_view_hidden(void* view, bool hidden) {
  if (!view) return;
  NSView* v = (NSView*)view;
  if ([v isKindOfClass:[LIVIClipView class]]) {
    [(LIVIClipView*)v setUserHidden:hidden];
    return;
  }
  [v setHidden:hidden];
}

extern "C" void livi_set_backdrop(guintptr parent, double r, double g, double b) {
  NSView* p = (NSView*)(void*)parent;
  if (!p) return;
  [p setWantsLayer:YES];
  if (!p.layer) return;
  NSColor* col = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
  p.layer.backgroundColor = col.CGColor;
}
#endif

// MacPlay's standalone AppKit video surface; no browser or HTML UI.
struct MPInput { double x,y; int down; };
static std::deque<MPInput> mpInputs;
static void mpQueue(double x,double y,int down) {mpInputs.push_back({x,y,down});}
// Draw the whole button so AppKit's detached title-bar cells can't cover glyphs.
@interface MacPlayTrafficLightButton : NSButton {
 NSWindowButton _kind;
 BOOL _showsHoverSymbol;
}
@property BOOL showsHoverSymbol;
- (instancetype)initWithFrame:(NSRect)frame kind:(NSWindowButton)kind;
@end
@implementation MacPlayTrafficLightButton
- (instancetype)initWithFrame:(NSRect)frame kind:(NSWindowButton)kind {
 if((self=[super initWithFrame:frame])) {
  _kind=kind;self.bordered=NO;self.title=@"";
  [self setButtonType:NSButtonTypeMomentaryPushIn];
  self.wantsLayer=YES;
 }
 return self;
}
- (BOOL)showsHoverSymbol {return _showsHoverSymbol;}
- (void)setShowsHoverSymbol:(BOOL)value {
 if(_showsHoverSymbol==value)return;
 _showsHoverSymbol=value;self.needsDisplay=YES;
}
- (void)setEnabled:(BOOL)value {[super setEnabled:value];self.needsDisplay=YES;}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {(void)event;return YES;}
- (void)drawRect:(NSRect)dirtyRect {
 (void)dirtyRect;
 NSColor *color=_kind==NSWindowCloseButton ?
  [NSColor colorWithSRGBRed:1 green:95.0/255 blue:87.0/255 alpha:1] :
  [NSColor colorWithSRGBRed:254.0/255 green:188.0/255 blue:46.0/255 alpha:1];
 if(!self.enabled)color=[NSColor colorWithWhite:0.5 alpha:0.6];
 else if(self.cell.isHighlighted)color=[color blendedColorWithFraction:0.18 ofColor:NSColor.blackColor];
 NSBezierPath *circle=[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(self.bounds,0.5,0.5)];
 [color setFill];[circle fill];
 [[NSColor colorWithWhite:0 alpha:0.15] setStroke];circle.lineWidth=0.5;[circle stroke];
 if(!_showsHoverSymbol || !self.enabled)return;
 [[NSColor colorWithWhite:0.12 alpha:0.9] setStroke];
 NSBezierPath *symbol=[NSBezierPath bezierPath];
 symbol.lineWidth=1.2;symbol.lineCapStyle=NSLineCapStyleRound;
 CGFloat x=NSMidX(self.bounds),y=NSMidY(self.bounds),r=2.6;
 if(_kind==NSWindowCloseButton) {
  [symbol moveToPoint:NSMakePoint(x-r,y-r)];[symbol lineToPoint:NSMakePoint(x+r,y+r)];
  [symbol moveToPoint:NSMakePoint(x-r,y+r)];[symbol lineToPoint:NSMakePoint(x+r,y-r)];
 } else {
  [symbol moveToPoint:NSMakePoint(x-3,y)];[symbol lineToPoint:NSMakePoint(x+3,y)];
 }
 [symbol stroke];
}
@end

// A compact floating title bar leaves the video at its original pixel size.
@interface MacPlayFloatingTitleBar : NSView {
 NSView *_controls;
}
@property(readonly) NSView *controls;
@end
@implementation MacPlayFloatingTitleBar
- (instancetype)initWithFrame:(NSRect)frame {
 if((self=[super initWithFrame:frame])) {
  // Use system appearance and untinted native glass.
  _controls=[[NSView alloc] initWithFrame:self.bounds];
  _controls.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  #if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
  if(@available(macOS 26.0,*)) {
   NSGlassEffectView *glass=[[NSGlassEffectView alloc] initWithFrame:self.bounds];
   glass.style=NSGlassEffectViewStyleClear;

   glass.cornerRadius=18;
   glass.contentView=_controls;
   glass.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
   [self addSubview:glass];
  } else
  #endif
  {
   NSVisualEffectView *background=[[NSVisualEffectView alloc] initWithFrame:self.bounds];
   background.material=NSVisualEffectMaterialHUDWindow;
   background.blendingMode=NSVisualEffectBlendingModeWithinWindow;
   background.state=NSVisualEffectStateActive;
   background.wantsLayer=YES;background.layer.cornerRadius=18;
   background.layer.masksToBounds=YES;
   background.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
   [self addSubview:background];[self addSubview:_controls];
  }
 }
 return self;
}
- (NSView *)controls {return _controls;}
- (NSView *)hitTest:(NSPoint)point {
 NSView *hit=[super hitTest:point];
 if(!hit)return nil;
 for(NSView *view=hit;view && view!=self;view=view.superview)
  if([view isKindOfClass:NSButton.class])return view;
 return self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {return YES;}
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (void)mouseDown:(NSEvent *)event {
 if (!(self.window.styleMask & NSWindowStyleMaskFullScreen))
  [self.window performWindowDragWithEvent:event];
}
// Never bubble the release, drag or scroll back to the CarPlay input surface.
- (void)mouseUp:(NSEvent *)event {(void)event;}
- (void)mouseDragged:(NSEvent *)event {(void)event;}
- (void)scrollWheel:(NSEvent *)event {(void)event;}
@end

@interface MacPlayInputView : NSView {
 MPScrollGesture _scroll;
 NSTimer *_scrollTimer;
 BOOL _pointerDown;
 BOOL _hasPointerActivity;
 CFTimeInterval _edgeHoverStart, _exitHoverStart;
 MacPlayFloatingTitleBar *_titleBar;
 NSTrackingArea *_titleTracking;
 MacPlayTrafficLightButton *_closeButton;
 MacPlayTrafficLightButton *_minimizeButton;
 CAShapeLayer *_cornerMask;
}
- (void)updateFloatingTitleBar;
- (void)updateFloatingTitleBarForPoint:(NSPoint)point;
@end
@implementation MacPlayInputView
- (instancetype)initWithFrame:(NSRect)frame {
 if ((self=[super initWithFrame:frame])) {
  self.wantsLayer=YES;
  _titleBar=[[MacPlayFloatingTitleBar alloc] initWithFrame:NSMakeRect(0,0,300,36)];
  _titleBar.hidden=YES;
  MacPlayTrafficLightButton *close=[[MacPlayTrafficLightButton alloc] initWithFrame:NSMakeRect(12,11,14,14) kind:NSWindowCloseButton];
  _closeButton=close;
  close.target=self;close.action=@selector(closeFloatingWindow:);
  close.frame=NSMakeRect(12,11,14,14);
  close.toolTip=mpCloseText(@"关闭",@"關閉",@"Close");
  [_titleBar.controls addSubview:close];
  _minimizeButton=[[MacPlayTrafficLightButton alloc] initWithFrame:NSMakeRect(34,11,14,14) kind:NSWindowMiniaturizeButton];
  _minimizeButton.target=self;_minimizeButton.action=@selector(minimizeFloatingWindow:);
  _minimizeButton.frame=NSMakeRect(34,11,14,14);
  _minimizeButton.toolTip=mpCloseText(@"最小化",@"最小化",@"Minimize");
  [_titleBar.controls addSubview:_minimizeButton];
  NSTextField *title=[NSTextField labelWithString:@"MacPlay · CarPlay"];
  title.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
  title.textColor=NSColor.labelColor;
  title.alignment=NSTextAlignmentCenter;
  title.frame=NSMakeRect(58,9,184,18);
  title.autoresizingMask=NSViewWidthSizable;
  [_titleBar.controls addSubview:title];
  [self addSubview:_titleBar positioned:NSWindowAbove relativeTo:nil];
 }
 return self;
}
- (void)didAddSubview:(NSView *)subview {
 [super didAddSubview:subview];self.needsLayout=YES;
}
- (BOOL)pointIsInFloatingTitleBar:(NSPoint)point {
 return !_titleBar.hidden && NSPointInRect(point,_titleBar.frame);
}
- (NSView *)hitTest:(NSPoint)point {
 NSPoint local=[self convertPoint:point fromView:self.superview];
 if(!NSPointInRect(local,self.bounds))return nil;
 if([self pointIsInFloatingTitleBar:local]) {
  NSView *hit=[_titleBar hitTest:local];
  return hit ?: _titleBar;
 }
 // Video renderer subviews must not steal input or title-bar releases.
 return self;
}
- (void)closeFloatingWindow:(id)sender { [self.window performClose:sender]; }
- (void)minimizeFloatingWindow:(id)sender { [self.window miniaturize:sender]; }
- (void)layout {
 [super layout];
 CGFloat width=fmin(300, fmax(0,self.bounds.size.width-20));
 _titleBar.frame=NSMakeRect((self.bounds.size.width-width)/2,
                          self.bounds.size.height-46,width,36);
 // Empirical radius for a 960x360-point CarPlay window at Retina 2x.
 // This is not an Apple standard; other sizes and scales need visual validation.
 CGFloat radius=(self.window.styleMask & NSWindowStyleMaskFullScreen) ? 0 : 28;
 self.layer.cornerRadius=0; // One explicit path owns the four corners.
 self.layer.masksToBounds=YES;
 // Mask the complete composited video surface with one shared four-corner path.
 if(!_cornerMask)_cornerMask=[CAShapeLayer layer];
 CAShapeLayer *mask=_cornerMask;
 mask.frame=self.bounds;
 mask.contentsScale=self.window.backingScaleFactor ?: 1;
 CGPathRef path=CGPathCreateWithRoundedRect(self.bounds,radius,radius,nullptr);
 mask.path=path;
 self.layer.mask=mask;
 CGPathRelease(path);
 [self.window invalidateShadow];
 [self updateFloatingTitleBar];
}
- (void)viewDidChangeBackingProperties {
 [super viewDidChangeBackingProperties];
 self.needsLayout=YES;
 [self layoutSubtreeIfNeeded];
}
- (void)updateTrackingAreas {
 [super updateTrackingAreas];
 if(_titleTracking)[self removeTrackingArea:_titleTracking];
 _titleTracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect
    options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect
    owner:self userInfo:nil];
 [self addTrackingArea:_titleTracking];
}
- (void)updateFloatingTitleBar {
 // Do not expose inactive glass or gray window controls during presentation.
 // The initial pointer position alone should not reveal the toolbar.
 if(!_hasPointerActivity || !self.window.isKeyWindow || !NSApp.isActive) {
  _titleBar.hidden=YES;_edgeHoverStart=0;_exitHoverStart=0;_closeButton.showsHoverSymbol=NO;_minimizeButton.showsHoverSymbol=NO;return;
 }
 NSPoint point=[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
 [self updateFloatingTitleBarForPoint:point];
}
- (void)updateFloatingTitleBarForPoint:(NSPoint)point {
 CFTimeInterval now=CACurrentMediaTime();
 BOOL inside=NSPointInRect(point,self.bounds);
 BOOL edge=inside && point.y>=NSMaxY(self.bounds)-12;
 // Preserve a bridge from the edge down to the floating controls.
 BOOL bridge=inside && point.x>=NSMinX(_titleBar.frame) && point.x<=NSMaxX(_titleBar.frame) && point.y>=NSMinY(_titleBar.frame);
 BOOL show=!_titleBar.hidden;
 if(_pointerDown){show=NO;_edgeHoverStart=0;_exitHoverStart=0;}
 else if(!show){
  _exitHoverStart=0;
  if(edge){if(!_edgeHoverStart)_edgeHoverStart=now;if(now-_edgeHoverStart>=0.2){show=YES;_edgeHoverStart=0;}}
  else _edgeHoverStart=0;
 }else{
  _edgeHoverStart=0;
  if(edge||bridge)_exitHoverStart=0;
  else{if(!_exitHoverStart)_exitHoverStart=now;if(now-_exitHoverStart>=0.2){show=NO;_exitHoverStart=0;}}
 }
 if(self.window.attachedSheet)show=YES;
 _titleBar.hidden=!show;
 _minimizeButton.enabled=!(self.window.styleMask & NSWindowStyleMaskFullScreen);
 NSPoint controlsPoint=[_titleBar.controls convertPoint:point fromView:self];
 BOOL buttonHover=show && NSPointInRect(controlsPoint,NSMakeRect(6,5,50,26));
 _closeButton.showsHoverSymbol=buttonHover;
 _minimizeButton.showsHoverSymbol=buttonHover;
}
- (void)mouseMoved:(NSEvent *)event { (void)event;_hasPointerActivity=YES;[self updateFloatingTitleBar]; }
- (void)mouseEntered:(NSEvent *)event { (void)event;[self updateFloatingTitleBar]; }
- (void)mouseExited:(NSEvent *)event { (void)event;[self updateFloatingTitleBar]; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)finishScroll {
 [_scrollTimer invalidate];_scrollTimer=nil;
 if(_scroll.active){mpQueue(_scroll.x,_scroll.y,0);_scroll.end();}
}
- (void)releaseInput:(NSNotification *)note {
 (void)note;[self finishScroll];
 if(_pointerDown){mpQueue(_scroll.x,_scroll.y,0);_pointerDown=NO;}
}
- (void)record:(NSEvent *)event down:(int)down {
 [self finishScroll];
 NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
 if(down==0 && !_pointerDown)return;
 if(!_pointerDown && [self pointIsInFloatingTitleBar:p])return;
 NSRect video=mpVideoRect(self,mpAspect);
 if(video.size.width<=0||video.size.height<=0)return;
 double x=(p.x-video.origin.x)/video.size.width,y=1-(p.y-video.origin.y)/video.size.height;
 if(!_pointerDown&&(x<0||x>1||y<0||y>1))return;
 x=MPScrollGesture::clamp(x);y=MPScrollGesture::clamp(y);
 _scroll.x=x;_scroll.y=y;_pointerDown=down==1;mpQueue(x,y,down);
}
- (void)mouseDown:(NSEvent *)event { _edgeHoverStart=0;_exitHoverStart=0;[self record:event down:1];[self updateFloatingTitleBar]; }
- (void)mouseDragged:(NSEvent *)event { [self record:event down:1]; }
- (void)mouseUp:(NSEvent *)event { [self record:event down:0]; }
- (void)scrollWheel:(NSEvent *)event {
 NSPoint pointer=[self convertPoint:event.locationInWindow fromView:nil];
 if([self pointIsInFloatingTitleBar:pointer]) {[self finishScroll];return;}
 if(_pointerDown)return;
 // CarPlay supplies its own fling after release; do not replay macOS momentum.
 if(event.momentumPhase!=NSEventPhaseNone){[self finishScroll];return;}
 if(event.phase & (NSEventPhaseEnded|NSEventPhaseCancelled)){[self finishScroll];return;}
 NSRect video=mpVideoRect(self,mpAspect);
 if(video.size.width<=0||video.size.height<=0)return;
 double dx=event.scrollingDeltaX,dy=event.scrollingDeltaY;
 if(!event.hasPreciseScrollingDeltas){dx*=12;dy*=12;}
 if(dx==0&&dy==0)return;
 if(!_scroll.active){
  NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
  double x=(p.x-video.origin.x)/video.size.width,y=1-(p.y-video.origin.y)/video.size.height;
  if(!_scroll.begin(x,y))return;
  mpQueue(_scroll.x,_scroll.y,1);
 }
 // CarPlay touch coordinates increase downwards; preserve NSEvent vertical direction.
 _scroll.scroll(dx,dy,video.size.width,video.size.height);
 mpQueue(_scroll.x,_scroll.y,1);
 [_scrollTimer invalidate];
 _scrollTimer=[NSTimer scheduledTimerWithTimeInterval:0.15 target:self selector:@selector(finishScroll) userInfo:nil repeats:NO];
}
- (void)keyDown:(NSEvent *)event {
 if(event.modifierFlags & NSEventModifierFlagCommand) {
  NSString *key=event.charactersIgnoringModifiers.lowercaseString;
  if([key isEqualToString:@"w"]) {[self.window performClose:nil];return;}
  if([key isEqualToString:@"m"] && !(self.window.styleMask & NSWindowStyleMaskFullScreen)) {[self.window miniaturize:nil];return;}
 }
 if(event.keyCode==53) {
  [self releaseInput:nil];
  if(macplayWindow.styleMask & NSWindowStyleMaskFullScreen) {
   mpHideAfterFullscreen=true;[macplayWindow toggleFullScreen:nil];
  } else [macplayWindow orderOut:nil];
 }
}
@end
extern "C" void macplay_close_window() {
 mpClosingWindow=true;
 if(macplayWindow){
  MacPlayInputView *view=(MacPlayInputView *)macplayWindow.contentView;
  [view releaseInput:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:view];
  if(NSWindow *sheet=macplayWindow.attachedSheet){[NSApp endSheet:sheet returnCode:NSModalResponseCancel];[sheet orderOut:nil];}
  [[NSNotificationCenter defaultCenter] removeObserver:mpWindowDelegate];
  [macplayWindow setDelegate:nil];[macplayWindow orderOut:nil];[macplayWindow close];macplayWindow=nil;mpWindowDelegate=nil;
 }
 mpInputs.clear();
 mpWindowAction=0;mpCloseRequested=false;mpClosePromptOpen=false;
 mpEnteringFullscreen=false;mpHideAfterFullscreen=false;
}

static uintptr_t mpWindow(double aspect, bool present) {
 [MacPlayVideoApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
 if(!macplayWindow || fabs(mpAspect-aspect)>0.0001)mpSetWindowAspect(aspect);
 if(!macplayWindow) {
  mpClosingWindow=false;
  NSWindowStyleMask style=NSWindowStyleMaskBorderless|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable;
  if(!mpStrictPixels&&!mpDefaultFullscreen)style|=NSWindowStyleMaskResizable;
  macplayWindow=[[MacPlayVideoWindow alloc] initWithContentRect:NSMakeRect(0,0,1100,1100/mpAspect) styleMask:style backing:NSBackingStoreBuffered defer:NO];
  [macplayWindow setReleasedWhenClosed:NO]; [macplayWindow setTitle:@"MacPlay · CarPlay"];
  macplayWindow.opaque=NO;macplayWindow.backgroundColor=NSColor.clearColor;
  macplayWindow.hasShadow=YES;macplayWindow.acceptsMouseMovedEvents=YES;
  [macplayWindow setContentMinSize:NSMakeSize(320,320/mpAspect)];
  [macplayWindow setMovable:!mpDefaultFullscreen]; [macplayWindow setMovableByWindowBackground:NO];
  [macplayWindow setCollectionBehavior:mpDefaultFullscreen ? NSWindowCollectionBehaviorFullScreenPrimary : NSWindowCollectionBehaviorFullScreenNone];
  mpWindowDelegate=[MacPlayWindowDelegate new]; [macplayWindow setDelegate:mpWindowDelegate];
  [[NSNotificationCenter defaultCenter] addObserver:mpWindowDelegate selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
  MacPlayInputView *view=[[MacPlayInputView alloc] initWithFrame:macplayWindow.contentView.bounds];
  [view setWantsLayer:YES];view.layer.backgroundColor=CGColorGetConstantColor(kCGColorBlack);
  view.layer.cornerRadius=0;view.layer.masksToBounds=YES;
  [macplayWindow setContentView:view];
  if(NSScreen *screen=mpSelectedScreen()) [macplayWindow setFrameOrigin:screen.frame.origin];
  mpSetWindowAspect(mpAspect);
  [[NSNotificationCenter defaultCenter] addObserver:view selector:@selector(releaseInput:) name:NSWindowDidResignKeyNotification object:macplayWindow];
 }
 if(!present)return (uintptr_t)macplayWindow.contentView;
 if(macplayWindow.isMiniaturized) [macplayWindow deminiaturize:nil];
 [NSApp activate];
 [macplayWindow makeKeyAndOrderFront:nil];
 [macplayWindow makeFirstResponder:macplayWindow.contentView];
 NSWindow *presentedWindow=macplayWindow;
 dispatch_async(dispatch_get_main_queue(), ^{
  if(macplayWindow==presentedWindow && presentedWindow.isVisible && NSApp.isActive) {
   [presentedWindow makeKeyWindow];
   [presentedWindow makeFirstResponder:presentedWindow.contentView];
  }
 });
 // Accessory receivers have no Dock activation of their own. Order this normal-level
 // window across processes once per show request; never make it permanently floating.
 [macplayWindow orderFrontRegardless];
 if(mpDefaultFullscreen && !(macplayWindow.styleMask & NSWindowStyleMaskFullScreen) && !mpEnteringFullscreen) {
  mpEnteringFullscreen=true;
  dispatch_async(dispatch_get_main_queue(), ^{
   if(macplayWindow!=presentedWindow || mpClosingWindow)return;
   if(presentedWindow.isVisible)[presentedWindow toggleFullScreen:nil];
   else mpEnteringFullscreen=false;
  });
 } else if(!mpEnteringFullscreen) mpLogWindow();
 return (uintptr_t)macplayWindow.contentView;
}
extern "C" uintptr_t macplay_prepare_window(double aspect) {return mpWindow(aspect,false);}
extern "C" uintptr_t macplay_window(double aspect) {return mpWindow(aspect,true);}
extern "C" void macplay_pump() {
 @autoreleasepool {
  // Also cover an NSApplication created by another library before our subclass.
  if (macplayWindow && NSApp.activationPolicy != NSApplicationActivationPolicyAccessory)
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  NSEvent *event;
  while((event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.001,true);
  // Poll the actual pointer position: glass/button tracking areas may consume
  // hover events before the input surface gets a mouseMoved notification.
  if(macplayWindow)[(MacPlayInputView *)macplayWindow.contentView updateFloatingTitleBar];
  [NSApp updateWindows];
 }
}
extern "C" int macplay_input(double *x,double *y,int *down) {
 if(mpInputs.empty())return 0;MPInput e=mpInputs.front();mpInputs.pop_front();
 *x=e.x;*y=e.y;*down=e.down;return 1;
}

// Authorization completion never starts capture. The current session decides
// whether the grant is still relevant when polling on the main thread.
extern "C" int macplay_microphone_permission() {
 static std::atomic<bool> requested{false};
 auto status=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
 if(status==AVAuthorizationStatusAuthorized)return 1;
 if(status==AVAuthorizationStatusDenied||status==AVAuthorizationStatusRestricted)return 0;
 if(!requested.exchange(true)) {
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted){(void)granted;requested.store(false);}];
 }
 return 2;
}
