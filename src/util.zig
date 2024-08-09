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
    for (strings) |string| {
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
    return comptime hashStrings(&names);
}

pub fn getArchetypeIdFromStrings(types: [][]const u8) [Md5.digest_length]u8 {
    stringSort(types);
    return hashStrings(types);
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
    negative_columns: ?[]*const std.AutoHashMap(T, void),
) void {
    var iter = columns[0].keyIterator();
    outer: while (iter.next()) |item_ptr| {
        if (negative_columns) |cols| {
            for (0..cols.len) |i| {
                if (cols[i].contains(item_ptr.*)) {
                    continue :outer;
                }
            }
        }
        if (columns.len == 1) {
            results_ptr.put(item_ptr.*, {}) catch unreachable;
            continue :outer;
        }
        for (1..columns.len) |i| {
            if (columns[i].contains(item_ptr.*) and i == columns.len - 1) {
                results_ptr.put(item_ptr.*, {}) catch unreachable;
            } else {
                continue :outer;
            }
        }
    }
}
