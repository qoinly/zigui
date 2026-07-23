// @cImport rejected: macOS 26.4 SDK uses _Nonnull on array decay
// (e.g. `CGPoint positions[_Nonnull]`), which Zig translate-c does
// not handle. Hand-declared subset only.

const objc = @import("objc.zig");

pub const CGFloat = objc.CGFloat;

pub const CFIndex = isize;
pub const CFTypeRef = ?*anyopaque;
pub const CFAllocatorRef = ?*anyopaque;
pub const CFStringRef = ?*anyopaque;
pub const CFDictionaryRef = ?*anyopaque;
pub const CFArrayRef = ?*anyopaque;
pub const CFAttributedStringRef = ?*anyopaque;
pub const CFNumberRef = ?*anyopaque;
pub const CFURLRef = ?*anyopaque;
pub const CFErrorRef = ?*anyopaque;
pub const CTFontManagerScope = u32;
pub const kCTFontManagerScopeProcess: CTFontManagerScope = 1;
pub const CTFontRef = ?*anyopaque;
pub const CTRunRef = ?*anyopaque;
pub const CTLineRef = ?*anyopaque;
pub const CTFontDescriptorRef = ?*anyopaque;
pub const CGColorSpaceRef = ?*anyopaque;
pub const CGContextRef = ?*anyopaque;

pub const CFStringEncoding = u32;
pub const CFNumberType = c_long;
pub const kCFNumberIntType: CFNumberType = 9;
pub const CTFontUIFontType = u32;
pub const CTFontOrientation = u32;

pub const Boolean = u8;

pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;
pub const kCFNumberFloat64Type: CFNumberType = 6;
pub const kCTFontUIFontSystem: CTFontUIFontType = 2;
pub const kCTFontOrientationDefault: CTFontOrientation = 0;

pub const CGGlyph = u16;

pub const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

pub const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

pub const CFRange = extern struct {
    location: CFIndex,
    length: CFIndex,
};

pub extern "CoreFoundation" const kCFTypeDictionaryKeyCallBacks: anyopaque;
pub extern "CoreFoundation" const kCFTypeDictionaryValueCallBacks: anyopaque;

pub extern "CoreText" const kCTFontAttributeName: CFStringRef;
pub extern "CoreText" const kCTLigatureAttributeName: CFStringRef;
pub extern "CoreText" const kCTFontTraitsAttribute: CFStringRef;
pub extern "CoreText" const kCTFontWeightTrait: CFStringRef;

pub extern "CoreFoundation" fn CFRelease(cf: CFTypeRef) void;
pub extern "CoreFoundation" fn CFRetain(cf: CFTypeRef) CFTypeRef;

pub extern "CoreFoundation" fn CFStringCreateWithBytes(
    alloc: CFAllocatorRef,
    bytes: [*]const u8,
    length: CFIndex,
    encoding: CFStringEncoding,
    is_external: Boolean,
) CFStringRef;

pub extern "CoreFoundation" fn CFStringGetCString(
    str: CFStringRef,
    buffer: [*]u8,
    buffer_size: CFIndex,
    encoding: CFStringEncoding,
) Boolean;

pub extern "CoreFoundation" fn CFDictionaryCreate(
    alloc: CFAllocatorRef,
    keys: [*]?*const anyopaque,
    values: [*]?*const anyopaque,
    num_values: CFIndex,
    key_callbacks: *const anyopaque,
    value_callbacks: *const anyopaque,
) CFDictionaryRef;

pub extern "CoreFoundation" fn CFDictionaryGetValue(
    dict: CFDictionaryRef,
    key: ?*const anyopaque,
) ?*const anyopaque;

pub extern "CoreFoundation" fn CFArrayGetCount(arr: CFArrayRef) CFIndex;
pub extern "CoreFoundation" fn CFArrayGetValueAtIndex(
    arr: CFArrayRef,
    idx: CFIndex,
) ?*const anyopaque;

pub extern "CoreFoundation" fn CFAttributedStringCreate(
    alloc: CFAllocatorRef,
    str: CFStringRef,
    attrs: CFDictionaryRef,
) CFAttributedStringRef;

pub extern "CoreFoundation" fn CFNumberCreate(
    alloc: CFAllocatorRef,
    type_: CFNumberType,
    value_ptr: *const anyopaque,
) CFNumberRef;

pub extern "CoreFoundation" fn CFURLCreateFromFileSystemRepresentation(
    alloc: CFAllocatorRef,
    buffer: [*]const u8,
    buf_len: CFIndex,
    is_directory: Boolean,
) CFURLRef;
pub extern "CoreText" fn CTFontManagerRegisterFontsForURL(
    font_url: CFURLRef,
    scope: CTFontManagerScope,
    err: ?*CFErrorRef,
) Boolean;

pub extern "CoreText" fn CTFontCreateWithName(
    name: CFStringRef,
    size: CGFloat,
    matrix: ?*const anyopaque,
) CTFontRef;
pub extern "CoreText" fn CTFontCreateUIFontForLanguage(
    ui_type: CTFontUIFontType,
    size: CGFloat,
    lang: CFStringRef,
) CTFontRef;
pub extern "CoreText" fn CTFontCreateCopyWithAttributes(
    font: CTFontRef,
    size: CGFloat,
    matrix: ?*const anyopaque,
    descriptor: CTFontDescriptorRef,
) CTFontRef;
pub extern "CoreText" fn CTFontCopyPostScriptName(font: CTFontRef) CFStringRef;
pub extern "CoreText" fn CTFontGetUnitsPerEm(font: CTFontRef) c_uint;
pub extern "CoreText" fn CTFontGetAscent(font: CTFontRef) CGFloat;
pub extern "CoreText" fn CTFontGetDescent(font: CTFontRef) CGFloat;
pub extern "CoreText" fn CTFontGetLeading(font: CTFontRef) CGFloat;
pub extern "CoreText" fn CTFontGetCapHeight(font: CTFontRef) CGFloat;
pub extern "CoreText" fn CTFontGetXHeight(font: CTFontRef) CGFloat;
pub extern "CoreText" fn CTFontGetSize(font: CTFontRef) CGFloat;

pub extern "CoreText" fn CTLineCreateWithAttributedString(
    attr_str: CFAttributedStringRef,
) CTLineRef;
pub extern "CoreText" fn CTLineGetTypographicBounds(
    line: CTLineRef,
    ascent: *CGFloat,
    descent: *CGFloat,
    leading: *CGFloat,
) f64;
pub extern "CoreText" fn CTLineGetGlyphRuns(line: CTLineRef) CFArrayRef;
// Tight ink rect in baseline-relative, y-up coords (origin.y = ink bottom vs
// baseline, can be negative for descenders). Pass a null context.
pub extern "CoreText" fn CTLineGetImageBounds(
    line: CTLineRef,
    context: CGContextRef,
) CGRect;

pub extern "CoreText" fn CTRunGetGlyphCount(run: CTRunRef) CFIndex;
pub extern "CoreText" fn CTRunGetAttributes(run: CTRunRef) CFDictionaryRef;
pub extern "CoreText" fn CTRunGetGlyphs(run: CTRunRef, range: CFRange, buffer: [*]CGGlyph) void;
pub extern "CoreText" fn CTRunGetPositions(run: CTRunRef, range: CFRange, buffer: [*]CGPoint) void;
pub extern "CoreText" fn CTRunGetStringIndices(
    run: CTRunRef,
    range: CFRange,
    buffer: [*]CFIndex,
) void;

pub extern "CoreText" fn CTFontGetBoundingRectsForGlyphs(
    font: CTFontRef,
    orientation: CTFontOrientation,
    glyphs: [*]const CGGlyph,
    bounding_rects: [*]CGRect,
    count: CFIndex,
) CGRect;

pub extern "CoreText" fn CTFontDrawGlyphs(
    font: CTFontRef,
    glyphs: [*]const CGGlyph,
    positions: [*]const CGPoint,
    count: usize,
    context: CGContextRef,
) void;

pub extern "CoreText" fn CTFontDescriptorCreateWithAttributes(
    attributes: CFDictionaryRef,
) CTFontDescriptorRef;

pub extern "CoreGraphics" fn CGColorSpaceCreateDeviceGray() CGColorSpaceRef;
pub extern "CoreGraphics" fn CGColorSpaceRelease(cs: CGColorSpaceRef) void;
pub extern "CoreGraphics" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    color_space: CGColorSpaceRef,
    bitmap_info: u32,
) CGContextRef;
pub extern "CoreGraphics" fn CGContextRelease(ctx: CGContextRef) void;
pub extern "CoreGraphics" fn CGContextSetGrayFillColor(
    ctx: CGContextRef,
    gray: CGFloat,
    alpha: CGFloat,
) void;
pub extern "CoreGraphics" fn CGContextSetAllowsAntialiasing(
    ctx: CGContextRef,
    allows: Boolean,
) void;
pub extern "CoreGraphics" fn CGContextSetShouldAntialias(ctx: CGContextRef, should: Boolean) void;
pub extern "CoreGraphics" fn CGContextSetAllowsFontSubpixelPositioning(
    ctx: CGContextRef,
    allows: Boolean,
) void;
pub extern "CoreGraphics" fn CGContextSetShouldSubpixelPositionFonts(
    ctx: CGContextRef,
    should: Boolean,
) void;
pub extern "CoreGraphics" fn CGContextSetShouldSmoothFonts(ctx: CGContextRef, should: Boolean) void;

pub const CGImageRef = ?*anyopaque;

pub const kCGImageAlphaOnly: u32 = 7;
pub const kCGImageAlphaPremultipliedLast: u32 = 1;
pub const kCGBitmapByteOrder32Big: u32 = 4 << 12;

pub extern "CoreGraphics" fn CGContextDrawImage(
    ctx: CGContextRef,
    rect: CGRect,
    image: CGImageRef,
) void;
pub extern "CoreGraphics" fn CGContextScaleCTM(ctx: CGContextRef, sx: CGFloat, sy: CGFloat) void;
pub extern "CoreGraphics" fn CGContextTranslateCTM(
    ctx: CGContextRef,
    tx: CGFloat,
    ty: CGFloat,
) void;
pub extern "CoreGraphics" fn CGContextClearRect(ctx: CGContextRef, rect: CGRect) void;
pub extern "CoreGraphics" fn CGImageGetWidth(image: CGImageRef) usize;
pub extern "CoreGraphics" fn CGImageGetHeight(image: CGImageRef) usize;
pub extern "CoreGraphics" fn CGColorSpaceCreateDeviceRGB() CGColorSpaceRef;

pub const CTFontSymbolicTraits = u32;
pub const kCTFontTraitColorGlyphs: CTFontSymbolicTraits = 1 << 13; // the font renders color bitmaps (emoji)
pub extern "CoreText" fn CTFontGetSymbolicTraits(font: CTFontRef) CTFontSymbolicTraits;
