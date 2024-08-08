const std = @import("std");
const util = @import("zcs/util.zig");

/// Creates a hashmap that maps a type to an object of type
const TypeMap = struct {
    map: std.StringHashMap([]u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .map = std.StringHashMap([]u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var val_iter = self.map.valueIterator();
        while (val_iter.next()) |val| {
            self.allocator.free(val.*);
        }
        self.map.deinit();
    }

    pub fn add(self: *Self, comptime item: anytype) !void {
        const comp_id = @typeName(@TypeOf(item));
        const bytes = try self.allocator.alloc(u8, @sizeOf(@TypeOf(item)));
        @memcpy(bytes, std.mem.asBytes(&item));
        try self.map.put(comp_id, bytes);
    }

    pub fn get(self: *Self, comptime T: type) !*T {
        const comp_id = @typeName(T);
        const bytes = self.map.get(comp_id).?;
        return @as(*T, @ptrCast(@alignCast(bytes)));
    }
};
