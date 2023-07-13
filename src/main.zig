const std = @import("std");

pub const nameBuilderState = struct {
    fn hashRawName(name: []const u8) u64 {
        return std.hash_map.hashString(name);
    }

    const InsertContext = struct {
        msg: []const u8,
        fullName: []const u8,

        pub fn hash(self: @This(), ptr: u14) u64 {
            if (ptr >= self.msg.len) {
                // Hash map is growing, but the current name hasn't been inserted yet to self.msg;
                const offset = @as(usize, @intCast(ptr)) - self.msg.len;
                return hashRawName(self.fullName[offset..]);
            }

            var h = std.hash.Wyhash.init(0);
            var offset: usize = ptr;
            while (true) {
                if (self.msg[offset] == 0xC0) {
                    offset = @as(u14, @truncate(std.mem.readInt(u16, self.msg[offset..][0..2], .Big)));
                }
                std.debug.assert(self.msg[offset] & 0xC0 == 0);
                if (self.msg[offset] == 0) {
                    h.update(&[_]u8{0});
                    return h.final();
                }
                const length = self.msg[offset] + 1;
                h.update(self.msg[offset..][0..length]);
                offset += length;
            }
        }
        pub fn eql(_: @This(), v1: u14, v2: u14) bool {
            return v1 == v2;
        }
    };

    const GetContext = struct {
        msg: []const u8,
        pub fn hash(_: @This(), val: []const u8) u64 {
            return hashRawName(val);
        }
        pub fn eql(self: @This(), val: []const u8, val2: u14) bool {
            if (val2 >= self.msg.len) {
                return false;
            }

            var valOffset: u8 = 0;
            var val2Offset: u16 = val2;

            while (true) {
                if (self.msg[val2Offset] == 0xC0) {
                    val2Offset = @as(u14, @truncate(std.mem.readInt(u16, self.msg[val2Offset..][0..2], .Big)));
                }

                std.debug.assert(self.msg[val2Offset] & 0xC0 == 0);

                const labelLength = val[valOffset];

                if (labelLength != self.msg[val2Offset]) {
                    return false;
                }

                if (labelLength == 0) {
                    return true;
                }

                valOffset += 1;
                val2Offset += 1;
                if (!std.mem.eql(u8, val[valOffset..][0..labelLength], self.msg[val2Offset..][0..labelLength])) {
                    return false;
                }
                valOffset += labelLength;
                val2Offset += labelLength;
            }
        }
    };

    map: std.HashMapUnmanaged(u14, void, InsertContext, std.hash_map.default_max_load_percentage) = .{},

    fn isValidRawName(name: []const u8) bool {
        if (name.len > 255) return false;
        var i: usize = 0;
        while (i < name.len) : (i += name[i] + 1) {
            const length = name[i];
            if (length >= 64) return false;
            if (length == 0) {
                if (i + 1 == name.len) {
                    return true;
                }
                return false;
            }
        }
        return false;
    }

    pub fn compress(self: *@This(), msg: *std.ArrayList(u8), name: []const u8) !void {
        std.debug.assert(isValidRawName(name));

        var i: usize = 0;
        while (name[i] != 0) : (i += name[i] + 1) {
            const newPtr = msg.items.len + i;
            if (newPtr <= std.math.maxInt(u14)) {
                const res = try self.map.getOrPutContextAdapted(msg.allocator, name[i..], GetContext{ .msg = msg.items }, .{ .msg = msg.items, .fullName = name });
                if (res.found_existing) {
                    var p: [2]u8 = undefined;
                    std.mem.writeIntBig(u16, &p, @as(u16, @intCast(res.key_ptr.*)) | 0xC000);
                    try msg.appendSlice(name[0..i]);
                    return msg.appendSlice(&p);
                }
                res.key_ptr.* = @intCast(newPtr);
            } else {
                if (self.map.getKeyAdapted(name[i..], GetContext{ .msg = msg.items })) |ptr| {
                    var p: [2]u8 = undefined;
                    std.mem.writeIntBig(u16, &p, @as(u16, @intCast(ptr)) | 0xC000);
                    try msg.appendSlice(name[0..i]);
                    return msg.appendSlice(&p);
                }
            }
        }

        return msg.appendSlice(name);
    }
};

test "compress" {
    const ally = std.testing.allocator;

    var msg = std.ArrayList(u8).init(ally);
    defer msg.deinit();

    var n = nameBuilderState{};
    defer n.map.deinit(ally);
    try n.compress(&msg, &[_]u8{ 3, 'w', 'w', 'w', 2, 'c', 'o', 0 });
    try n.compress(&msg, &[_]u8{ 2, 'c', 'o', 0 });
    try n.compress(&msg, &[_]u8{ 3, 'w', 'w', 'w', 2, 'c', 'o', 0 });

    try std.testing.expectEqualSlices(u8, &[_]u8{
        3, 'w', 'w', 'w', 2, 'c', 'o', 0, 0xC0, 4, 0xC0, 0,
    }, msg.items);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const ally = gpa.allocator();

    const n = 5000000;

    var timer = try std.time.Timer.start();
    const start = timer.lap();

    var msg = try std.ArrayList(u8).initCapacity(ally, 128);
    defer msg.deinit();

    var nb = nameBuilderState{};
    defer nb.map.deinit(ally);

    for (0..n) |_| {
        msg.clearRetainingCapacity();
        nb.map.clearRetainingCapacity();

        try nb.compress(&msg, &[_]u8{ 3, 'c', 'o', 'm', 0 });
        try nb.compress(&msg, &[_]u8{ 3, 'c', 'o', 'm', 0 });
        try nb.compress(&msg, &[_]u8{ 3, 'w', 'w', 'w', 3, 'c', 'o', 'm', 0 });

        for (0..32) |i| {
            try nb.compress(&msg, &[_]u8{ 3, 'w', 'w', @intCast(i), 3, 'c', 'o', 'm', 7, 'e', 'x', 'a', 'm', 'p', @intCast(i), 'e', 0 });
        }
    }

    const end = timer.read();

    const elapsed = end - start;

    std.log.err("{}: total: {} ns, per iteration: {} ns, {} iterations per second\n", .{ n, elapsed, elapsed / n, std.time.ns_per_s / (elapsed / n) });
}
