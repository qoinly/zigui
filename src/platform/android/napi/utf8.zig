// A byte-boundary helper for the android string bridges. The napi domains copy a
// Java string into a fixed scratch buffer and may cut it at the cap; cutting mid
// codepoint would hand a torn UTF-8 sequence across the JNI / glyph-atlas boundary.
// Pure (std only) so the host test build can exercise it without the android tree.

const std = @import("std");

// The largest length <= `n` that does not split a UTF-8 codepoint: back off while
// the byte at the cut is a continuation byte (10xxxxxx). `n` is an end index into
// `span` (n <= span.len); a cut at span.len or at 0 already sits on a boundary.
pub fn floor(span: []const u8, n: usize) usize {
    std.debug.assert(n <= span.len);
    var m = n;
    while (m > 0 and m < span.len and (span[m] & 0xc0) == 0x80) m -= 1;
    std.debug.assert(m <= n); // the back-off only ever shrinks the cut
    return m;
}

test floor {
    const t = std.testing;
    // ASCII never moves; a cut at the end or at 0 is already on a boundary.
    try t.expectEqual(@as(usize, 3), floor("abc", 3));
    try t.expectEqual(@as(usize, 2), floor("abc", 2));
    try t.expectEqual(@as(usize, 0), floor("abc", 0));
    // A 2-byte run C3 A9: a cut at len holds, a cut between the bytes backs off.
    try t.expectEqual(@as(usize, 2), floor("\xc3\xa9", 2));
    try t.expectEqual(@as(usize, 0), floor("\xc3\xa9", 1));
    // A 3-byte run E2 82 AC: cutting anywhere inside it backs off to its lead.
    try t.expectEqual(@as(usize, 0), floor("\xe2\x82\xac", 1));
    try t.expectEqual(@as(usize, 0), floor("\xe2\x82\xac", 2));
    try t.expectEqual(@as(usize, 3), floor("\xe2\x82\xac", 3));
    // 'a' then the 3-byte run: cuts inside the run land just after the 'a'.
    try t.expectEqual(@as(usize, 1), floor("a\xe2\x82\xac", 1));
    try t.expectEqual(@as(usize, 1), floor("a\xe2\x82\xac", 2));
    try t.expectEqual(@as(usize, 1), floor("a\xe2\x82\xac", 3));
    try t.expectEqual(@as(usize, 4), floor("a\xe2\x82\xac", 4));
}
