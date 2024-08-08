const std = @import("std");

fn compareStrings(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs).compare(std.math.CompareOperator.lt);
}
pub fn stringSort(strings: [][]const u8) void {
    std.mem.sort([]const u8, strings, {}, compareStrings);
}

const Md5 = std.crypto.hash.Md5;
pub fn hashStrings(strings: [][]const u8) [Md5.digest_length]u8 {
    var hasher = Md5.init(.{});
    inline for (strings) |string| {
        hasher.update(string);
    }
    var hash: [Md5.digest_length]u8 = undefined;
    hasher.final(&hash);
    return hash;
}

pub fn getArchetypeId(comptime types: anytype) [Md5.digest_length]u8 {
    comptime var names: [types.len][]const u8 = undefined;
    inline for (types, 0..) |T, i| {
        names[i] = @typeName(T);
    }
    stringSort(&names);
    return hashStrings(&names);
}

pub fn getCompnentId(comptime T: type) [Md5.digest_length]u8 {
    const name = @typeName(T);
    var hash: [Md5.digest_length]u8 = undefined;
    Md5.hash(name, &hash, .{});
    return hash;
}

pub fn setIntersect(
    comptime T: type,
    results_ptr: *std.AutoHashMap(T, void),
    columns: []*const std.AutoHashMap(T, void),
) void {
    var iter = columns[0].keyIterator();
    outer: while (iter.next()) |item_ptr| {
        for (1..columns.len) |i| {
            if (columns[i].contains(item_ptr.*) and i == columns.len - 1) {
                results_ptr.put(item_ptr.*, {}) catch unreachable;
            } else {
                continue :outer;
            }
        }
    }
}

test "set intersect" {
    const allocator = std.testing.allocator;
    var set1 = std.AutoHashMap(usize, void).init(allocator);
    defer set1.deinit();
    try set1.put(0, {});
    try set1.put(5, {});
    try set1.put(10, {});
    try set1.put(20, {});
    var set2 = std.AutoHashMap(usize, void).init(allocator);
    defer set2.deinit();
    try set2.put(15, {});
    try set2.put(23, {});
    try set2.put(10, {});
    try set2.put(0, {});
    try set2.put(100, {});
    try set2.put(54, {});
    var set3 = std.AutoHashMap(usize, void).init(allocator);
    defer set3.deinit();
    try set3.put(23, {});
    try set3.put(10, {});
    try set3.put(0, {});
    try set3.put(100, {});
    var results = std.AutoHashMap(usize, void).init(allocator);
    defer results.deinit();

    var columns = allocator.alloc(*std.AutoHashMap(usize, void), 3) catch unreachable;
    defer allocator.free(columns);
    columns[0] = &set1;
    columns[1] = &set2;
    columns[2] = &set3;

    setIntersect(
        usize,
        &results,
        columns,
    );

    var iter = results.keyIterator();
    var i: usize = 0;
    while (iter.next()) |item| {
        switch (i) {
            0 => try std.testing.expect(item.* == 0),
            1 => try std.testing.expect(item.* == 10),
            else => unreachable,
        }
        i += 1;
    }
}
