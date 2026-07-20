# External frames

A `frame` node draws a GPU texture you own - a decoded video frame, a remote
screen, a camera feed - and fits it into the layout like any other node. zigui
imports the texture as NV12, does the YUV->RGB in the shader, and never reads the
pixels itself.

You bring the decoder, the network, and the buffer pool; zigui just draws what you
hand it. `examples/frame_demo.zig` is a full producer.

## FrameSource

A `FrameSource` passes frames from your decode thread to zigui's render thread. It
holds a lock-free triple buffer: the decoder publishes the latest frame, the
renderer takes the newest and drops the rest. Neither side waits on the other.

```zig
var source = zigui.FrameSource.init(zigui.renderer_handle());
defer source.deinit();
```

| Method | Thread | What it does |
|---|---|---|
| `init(renderer)` | render | create it over the backend renderer (`renderer_handle()`) |
| `submit_surface(pixel_buffer, meta)` | decode | publish the newest frame; drops any unread one |
| `acquire()` | render | take the newest frame for this draw (`?Current`), or null |
| `deinit()` | render | release the source and its textures |

`renderer_handle()` returns the backend renderer, and only works inside a render
pass. `pixel_buffer` is the platform texture your decoder fills - a `CVPixelBuffer`
(IOSurface-backed NV12) on macOS, a `zigui.FrameSurface` on Windows and Linux. All
three import a producer's GPU texture zero-copy (IOSurface on macOS, dmabuf on
Linux, a same-device or shared NT-handle texture on Windows); a Windows
decode-only array falls back to a GPU-side copy.

## The node

```zig
fn render(f: *zigui.Frame, app: *App) *zigui.Node {
    return zigui.frame(&app.source, .{ .fit = .contain });
}
```

| `FrameOpts` | Type | Default | Meaning |
|---|---|---|---|
| `fit` | `FrameFit` | `.contain` | how the source maps into the node rect |
| `opacity` | `f32` | `1.0` | blend factor |

| `FrameFit` | Meaning |
|---|---|
| `.contain` | scale to fit, keep aspect (letterbox) |
| `.cover` | scale to fill, keep aspect (crop) |
| `.fill` | stretch to the rect, ignore aspect |
| `.native` | 1:1 source pixels, centered |

## Static images

A `frame` is for *live* pixels. For a decoded still - a PNG or baseline JPEG
bundled with the app, an avatar, an icon sheet - use an `ImageSource` and the
`image` node. It uploads one texture once, drops the CPU copy, and (unlike
`frame`) does **not** keep the render loop animating - a still needs no repaint.

```zig
const App = struct { logo: zigui.ImageSource };

// once, at startup (App owns it; it must not move after the first draw):
app.logo = try zigui.ImageSource.decode(gpa, @embedFile("logo.png"));
defer app.logo.deinit();

// in the view:
zigui.image(&app.logo, .{ .fit = .contain })
```

The decoders are pure Zig, no C dependency (PNG and baseline JPEG).

| `ImageSource` method | What it does |
|---|---|
| `decode(gpa, bytes) !ImageSource` | decode PNG / baseline JPEG bytes into an image source |
| `init_rgba(gpa, rgba, width, height) !ImageSource` | take already-decoded 8-bit RGBA (`width*height*4`); the input is not retained |
| `dims() [2]f32` | source pixel size |
| `deinit()` | free the CPU copy and destroy the GPU texture (call when off-screen) |

`image(source, opts)` takes the same `FrameOpts` (`fit`, `opacity`) and `FrameFit`
values as `frame` above; it fills its cell (`grow` 1) and letterboxes per `fit`
(default `.contain`). The texture is owned by `source`; the node only references
it. Already have raw pixels from your own decoder? Skip `decode` and hand them to
`init_rgba`.

## Colorspace

`submit_surface` takes a `FrameMeta` so the YUV->RGB matrix is built once per format
change, not per pixel.

```zig
source.submit_surface(pixel_buffer, .{ .colorspace = .bt709, .range = .limited });
```

| `FrameMeta` | Type | Default |
|---|---|---|
| `colorspace` | `bt601` \| `bt709` \| `bt2020` | `bt709` |
| `range` | `limited` \| `full` | `limited` |

## Threading

The decode thread calls `submit_surface` as fast as it decodes; the render thread
calls `acquire` once a frame. A slow display never backs up the decoder, and a fast
decoder never starves the display - the extra frames are just dropped.
