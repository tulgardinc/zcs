const std = @import("std");

/// An interface to interact with the Arraylists without knowing their generics
pub const ComponentList = struct {
    /// Pointer to the arraylist
    ptr: *anyopaque,

    // The folowing functions are all generated when initializing the struct
    // so we can interface with the underlying arraylist without having to know
    // its generic
    deinit_fn: *const fn (std.mem.Allocator, *anyopaque) void,
    append_fn: *const fn (*anyopaque, *const anyopaque) anyerror!void,
    get_fn: *const fn (*anyopaque, usize) *anyopaque,
    getLen_fn: *const fn (*anyopaque) usize,
    remove_fn: *const fn (*anyopaque, usize) void,
    shallowCopy_fn: *const fn (std.mem.Allocator) *anyopaque,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, comptime T: type) !Self {
        const list_ptr = try allocator.create(std.ArrayList(T));
        list_ptr.* = std.ArrayList(T).init(allocator);

        const Methods = Self.GenFn(T);

        return Self{
            .ptr = list_ptr,
            .allocator = allocator,
            .deinit_fn = Methods.deinitFn,
            .append_fn = Methods.appendFn,
            .get_fn = Methods.getFn,
            .getLen_fn = Methods.getLenFn,
            .remove_fn = Methods.removeFn,
            .shallowCopy_fn = Methods.shallowCopyFn,
        };
    }

    pub fn shallowCopy(self: *Self) Self {
        return Self{
            .ptr = self.shallowCopy_fn(self.allocator),
            .allocator = self.allocator,
            .deinit_fn = self.deinit_fn,
            .append_fn = self.append_fn,
            .get_fn = self.get_fn,
            .getLen_fn = self.getLen_fn,
            .remove_fn = self.remove_fn,
            .shallowCopy_fn = self.shallowCopy_fn,
        };
    }

    pub fn deinit(self: *Self) void {
        self.deinit_fn(self.allocator, self.ptr);
    }

    pub fn append(self: *Self, item: *const anyopaque) !void {
        try self.append_fn(self.ptr, item);
    }

    pub fn get(self: *const Self, index: usize) *anyopaque {
        return self.get_fn(self.ptr, index);
    }

    pub fn getLen(self: *const Self) usize {
        return self.getLen_fn(self.ptr);
    }

    pub fn remove(self: *Self, index: usize) void {
        return self.remove_fn(self.ptr, index);
    }

    fn GenFn(comptime T: type) type {
        return struct {
            pub fn deinitFn(allocator: std.mem.Allocator, input_ptr: *anyopaque) void {
                const list_ptr: *std.ArrayList(T) = @ptrCast(@alignCast(input_ptr));
                list_ptr.deinit();
                allocator.destroy(list_ptr);
            }

            pub fn appendFn(input_ptr: *anyopaque, item: *const anyopaque) !void {
                const item_ptr: *const T = @ptrCast(@alignCast(item));
                const list_ptr: *std.ArrayList(T) = @ptrCast(@alignCast(input_ptr));
                try list_ptr.append(item_ptr.*);
            }

            pub fn getFn(input_ptr: *anyopaque, index: usize) *anyopaque {
                const list_ptr: *std.ArrayList(T) = @ptrCast(@alignCast(input_ptr));
                return &list_ptr.items[index];
            }

            pub fn getLenFn(input_ptr: *anyopaque) usize {
                const list_ptr: *std.ArrayList(T) = @ptrCast(@alignCast(input_ptr));
                return list_ptr.items.len;
            }

            pub fn removeFn(input_ptr: *anyopaque, row: usize) void {
                const list_ptr: *std.ArrayList(T) = @ptrCast(@alignCast(input_ptr));
                _ = list_ptr.orderedRemove(row);
            }

            pub fn shallowCopyFn(allocator: std.mem.Allocator) *anyopaque {
                const list_ptr = allocator.create(std.ArrayList(T)) catch unreachable;
                list_ptr.* = std.ArrayList(T).init(allocator);
                return @ptrCast(list_ptr);
            }
        };
    }
};
