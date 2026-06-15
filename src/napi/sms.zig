// Reading stored SMS from the device inbox. read yields the recent messages as
// "address\tbody\n..."; it needs the READ_SMS runtime permission (empty when not
// granted, distinct from broadcast's RECEIVE_SMS, which is for incoming messages).
const p = @import("platform.zig");
const impl = p.domain("sms");

// The recent inbox messages as "address\tbody\n..." into buf; null on failure, empty
// when the inbox is empty or READ_SMS is not granted.
pub fn read(buf: []u8) ?[]const u8 {
    if (@hasDecl(impl, "read")) return impl.read(buf);
    p.unsupported("sms.read");
}
