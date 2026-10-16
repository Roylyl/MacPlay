#include <gst/app/gstappsrc.h>
#include <gst/video/videooverlay.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <unistd.h>

#ifndef MACPLAY_WINDOW_SOURCE
#define MACPLAY_WINDOW_SOURCE "gst_video_mac.mm"
#endif
#include MACPLAY_WINDOW_SOURCE

static std::atomic<unsigned> drawCount{0};
static std::atomic<unsigned> offMainDrawCount{0};
#if !MACPLAY_RESIZE_BASELINE
static std::atomic<unsigned> forwardedRedraws{0};
static std::atomic<unsigned> offMainRedraws{0};
static std::atomic<NSView *> observedView{nil};
static void (*originalRedraw)(id, SEL, BOOL);
static void observeRedraw(id view, SEL selector, BOOL needed) {
  if (needed && view == observedView.load()) ++forwardedRedraws;
  if (![NSThread isMainThread]) ++offMainRedraws;
  originalRedraw(view, selector, needed);
}
#endif

static gboolean countDraw(GstElement *, gpointer, GstSample *, gpointer) {
  ++drawCount;
  if (![NSThread isMainThread]) ++offMainDrawCount;
  return FALSE;
}

static void require(bool condition, const char *message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(1);
  }
}

static void checkBus(GstBus *bus) {
  GstMessage *message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
  if (!message) return;
  GError *error = nullptr;
  gchar *debug = nullptr;
  gst_message_parse_error(message, &error, &debug);
  std::fprintf(stderr, "GStreamer: %s\n%s\n", error->message, debug ?: "");
  g_clear_error(&error);
  g_free(debug);
  gst_message_unref(message);
  std::exit(1);
}

int main(int argc, char **argv) {
  // A broken redraw dispatch must fail instead of leaving a test process behind.
  alarm(30);
  @autoreleasepool {
    gst_init(&argc, &argv);
    macplay_configure_window(1280, 720, 3456, 2234, false, false);
    unsigned resized = 0;
    for (unsigned cycle = 0; cycle < 3; ++cycle) {
      NSView *parent = (NSView *)macplay_prepare_window(16.0 / 9.0);
      require(parent.window != nil, "create test window");
      // Keep AppKit's render surface live without showing or activating a window.
      parent.window.alphaValue = 0;
      [parent.window orderWindow:NSWindowBelow relativeTo:0];
      void *clip = nullptr;
      GError *error = nullptr;
      GstElement *pipeline = gst_parse_launch(
          "appsrc name=frames is-live=true format=time max-buffers=3 leaky-type=downstream "
          "caps=video/x-raw,format=RGBA,width=640,height=360,framerate=120/1 "
          "! glupload ! glcolorconvert ! glimagesink name=renderer sync=false qos=false", &error);
      require(pipeline && !error, error ? error->message : "create render pipeline");
      GstElement *source = gst_bin_get_by_name(GST_BIN(pipeline), "frames");
      GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "renderer");
      GstBus *bus = gst_element_get_bus(pipeline);
      // Match Player: load the renderer before installing its Cocoa view adapter.
      guintptr handle = livi_attach_view((guintptr)parent, &clip);
#if !MACPLAY_RESIZE_BASELINE
      if (!originalRedraw) {
        originalRedraw = mpGLSetNeedsDisplay;
        require(originalRedraw != nullptr, "install render-thread adapter before playback");
        mpGLSetNeedsDisplay = observeRedraw;
      }
#endif
      require(g_signal_lookup("client-draw", G_OBJECT_TYPE(sink)) != 0,
              "renderer must expose its real drawing callback");
      g_signal_connect(sink, "client-draw", G_CALLBACK(countDraw), nullptr);
      gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(sink), handle);
      require(gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE,
              "start render pipeline");
      std::atomic<bool> feeding{true};
      std::thread producer([&] {
        unsigned frame = 0;
        while (feeding.load()) {
          GstBuffer *buffer = gst_buffer_new_allocate(nullptr, 640 * 360 * 4, nullptr);
          GstMapInfo mapped;
          if (gst_buffer_map(buffer, &mapped, GST_MAP_WRITE)) {
            std::memset(mapped.data, 40 + (frame % 180), mapped.size);
            gst_buffer_unmap(buffer, &mapped);
          }
          GST_BUFFER_PTS(buffer) = gst_util_uint64_scale(frame++, GST_SECOND, 120);
          GST_BUFFER_DURATION(buffer) = GST_SECOND / 120;
          if (gst_app_src_push_buffer(GST_APP_SRC(source), buffer) != GST_FLOW_OK) break;
          std::this_thread::sleep_for(std::chrono::milliseconds(4));
        }
      });
      unsigned initialDraws = drawCount.load();
      CFTimeInterval started = CACurrentMediaTime();
      while (CACurrentMediaTime() - started < 4.0) {
        @autoreleasepool {
          unsigned step = resized++;
          CGFloat width = 320 + (step * 197) % 1000;
          [parent.window setContentSize:NSMakeSize(width, width * 9 / 16)];
          parent.needsLayout = YES;
          [parent layoutSubtreeIfNeeded];
          if (step % 17 == 0) [parent viewDidChangeBackingProperties];
          // Read the same cached geometry that triggered the original assertion.
          (void)parent.visibleRect;
          macplay_pump();
          checkBus(bus);
        }
      }
      feeding.store(false);
      producer.join();
      std::fprintf(stderr, "cycle=%u draws=%u off-main=%u resize=%u\n", cycle,
                   drawCount.load() - initialDraws, offMainDrawCount.load(), resized);
      // A transparent background window is compositor-throttled; require real
      // progress without treating its presentation rate as a visible-window FPS.
      require(drawCount.load() > initialDraws + 5, "actual video frames must keep drawing during resize");
      require(parent.window.alphaValue == 0 && !parent.window.isKeyWindow,
              "stress test must not display or focus the window");
      NSView *renderView = [[((NSView *)handle).subviews firstObject] retain];
      require(renderView != nil, "GStreamer must have attached its actual render view");
#if !MACPLAY_RESIZE_BASELINE
      for (unsigned drain = 0; drain < 10; ++drain) macplay_pump();
      // Exercise the real GstGLNSView override separately from compositor and
      // pipeline teardown, which legitimately perform their own invalidations.
      NSView *probe = [[NSClassFromString(@"GstGLNSView") alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
      [parent addSubview:probe];
      macplay_pump();
      observedView.store(probe);
      unsigned beforeBurst = forwardedRedraws.load();
      std::thread burst([&] {
        for (unsigned request = 0; request < 1000; ++request) {
          [probe setNeedsDisplay:YES];
          [probe setNeedsDisplayInRect:NSMakeRect(0, 0, 1, 1)];
        }
      });
      burst.join();
      require(forwardedRedraws.load() == beforeBurst, "worker must not call AppKit redraw directly");
      macplay_pump();
      require(forwardedRedraws.load() - beforeBurst == 1,
              "coalesce a burst instead of queuing thousands of redraws");
      std::thread pending([&] { [probe setNeedsDisplay:YES]; });
      pending.join();
      [probe removeFromSuperview];
      unsigned beforeDrain = forwardedRedraws.load();
      for (unsigned drain = 0; drain < 10; ++drain) macplay_pump();
      require(forwardedRedraws.load() == beforeDrain, "discard redraw queued before view detachment");
      observedView.store(nil);
      [probe release];
      std::thread finalFrame([&] { [renderView setNeedsDisplay:YES]; });
      finalFrame.join();
#endif
      // Stop with queued redraws, then remove the view before draining the main queue.
      gst_element_set_state(pipeline, GST_STATE_NULL);
      livi_remove_view(clip);
      require(renderView.window == nil, "stopped render view must be detached");
      gst_object_unref(bus);
      gst_object_unref(sink);
      gst_object_unref(source);
      gst_object_unref(pipeline);
      for (unsigned drain = 0; drain < 10; ++drain) macplay_pump();
      [renderView release];
    }
    // Closing must cancel input timers and discard touches from the old window.
    MacPlayInputView *closingView=(MacPlayInputView *)macplayWindow.contentView;
    NSTimer *scrollTimer=[NSTimer scheduledTimerWithTimeInterval:0.15 target:closingView
                         selector:@selector(finishScroll) userInfo:nil repeats:NO];
    [closingView setValue:scrollTimer forKey:@"scrollTimer"];
    mpQueue(0.5, 0.5, 1);
    macplay_close_window();
    require(!scrollTimer.isValid, "closing a window must invalidate its scroll timer");
    require(mpInputs.empty(), "closing a window must discard queued input");
    macplay_prepare_window(16.0 / 9.0);
    macplay_pump();
    require(mpInputs.empty(), "old input must not enter a replacement window");
    macplay_close_window();
    std::printf("resize=%u draws=%u off-main-draws=%u cycles=3\n",
                resized, drawCount.load(), offMainDrawCount.load());
    require(offMainDrawCount.load() == 0, "Cocoa render callbacks must run on the main thread");
#if !MACPLAY_RESIZE_BASELINE
    require(offMainRedraws.load() == 0, "all original AppKit redraw calls must run on the main thread");
#endif
    require(resized > 300, "exercise repeated resize");
    gst_deinit();
    alarm(0);
  }
  return 0;
}
