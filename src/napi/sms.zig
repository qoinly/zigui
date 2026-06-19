// SMS: read the stored inbox, or send a message. read needs READ_SMS (distinct from
// broadcast's RECEIVE_SMS, which is for incoming messages); send needs SEND_SMS.
const p = @import("platform.zig");
const impl = p.domain("sms");

// The recent inbox messages as "address\tbody\n..." into buf; null on failure, empty
// when the inbox is empty or READ_SMS is not granted.
pub fn read(buf: []u8) ?[]const u8 {
    if (@hasDecl(impl, "read")) return impl.read(buf);
    p.unsupported("sms.read");
}
// Send an SMS to address. A multi-part body is split into parts by the system; the
// body is capped near 1 KB (longer text is truncated). A no-op when SEND_SMS is not
// granted.
pub fn send(address: []const u8, body: []const u8) void {
    if (@hasDecl(impl, "send")) return impl.send(address, body);
    p.unsupported("sms.send");
}
