const std = @import("std");

/// An interface to interact with the Arraylists without knowing their generics
const ComponentList = struct {
    /// Pointer to the arraylist
    ptr: *anyopaque,

    // The folowing functions are all generated when initializing the struct
    // so we can interface with the underlying arraylist without having to know
    // its generic
    deinit_fn: *const fn (std.mem.Allocator, *anyopaque) void,
    append_fn: *const fn (*anyopaque, *anyopaque) anyerror!void,
    get_fn: *const fn (*anyopaque, usize) *anyopaque,
    getLen_fn: *const fn (*anyopaque) usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, comptime T: type) !Self {
        const list_ptr = try allocator.create(std.ArrayList(T));
        list_ptr.* = std.ArrayList(T).init(allocator);

        const functions = Self.GenFn(T);

        return Self{
            .ptr = list_ptr,
            .allocator = allocator,
            .deinit_fn = functions.deinitFn,
            .append_fn = functions.appendFn,
            .get_fn = functions.getFn,
            .getLen_fn = functions.getLenFn,
        };
    }

    pub fn deinit(self: *Self) void {
        self.deinit_fn(self.allocator, self.ptr);
    }

    pub fn append(self: *Self, item: *anyopaque) !void {
        try self.append_fn(self.ptr, item);
    }

    pub fn get(self: Self, index: usize) *anyopaque {
        return self.get_fn(self.ptr, index);
    }

    pub fn getLen(self: Self) usize {
        return self.getLen_fn(self.ptr);
    }

    fn GenFn(comptime T: type) type {
        return struct {
            pub fn deinitFn(allocator: std.mem.Allocator, input_ptr: *anyopaque) void {
                const list_ptr: *std.ArrayList(T) = @ptrCast(@alignCast(input_ptr));
                list_ptr.deinit();
                allocator.destroy(list_ptr);
            }

            pub fn appendFn(input_ptr: *anyopaque, item: *anyopaque) !void {
                const item_ptr: *T = @ptrCast(@alignCast(item));
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
        };
    }
};

/// Holds components associated with a archetype
pub const Archetype = struct {
    /// Maps component ids to component lists
    components_map: std.StringHashMap(ComponentList),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, comptime types: anytype) !Self {
        //if (@typeInfo(@TypeOf(types)) != .Array) @compileError("Wrong type of argument");

        var comp_map = std.StringHashMap(ComponentList).init(allocator);

        // Genereate component lists
        inline for (types) |T| {
            const comp_id = @typeName(T);
            const comp_list = try ComponentList.init(allocator, T);
            try comp_map.put(comp_id, comp_list);
        }

        return Self{
            .components_map = comp_map,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var val_iter = self.components_map.valueIterator();
        while (val_iter.next()) |val| {
            val.deinit();
        }
        self.components_map.deinit();
    }

    pub fn count(self: *Self) usize {
        var iter = self.components_map.valueIterator();
        const first_list = iter.next() orelse return 0;
        return first_list.getLen();
    }

    pub fn addEntity(self: *Self, comptime components: anytype) !usize {
        // Get type info
        const input_type = @TypeOf(components);
        const type_info = @typeInfo(input_type);
        if (type_info != .Struct or !type_info.Struct.is_tuple) {
            @compileError("Wrong type of components input");
        }

        // Add components to the arrays
        const fields = type_info.Struct.fields;
        inline for (fields) |field| {
            const comp_id = @typeName(field.type);
            var item = @field(components, field.name);
            try self.components_map.getPtr(comp_id).?.append(@ptrCast(&item));
        }

        return self.count();
    }
};

test "component list" {
    const allocator = std.testing.allocator;
    var comp_list = try ComponentList.init(allocator, usize);
    defer comp_list.deinit();

    var num: usize = 0;
    var num1: usize = 1;
    var num2: usize = 2;

    try comp_list.append(@ptrCast(&num));
    try comp_list.append(@ptrCast(&num1));
    try comp_list.append(@ptrCast(&num2));

    const val: *usize = @ptrCast(@alignCast(comp_list.get(2)));
    try std.testing.expect(val.* == 2);
}

test "archetype" {
    const allocator = std.testing.allocator;

    const type_arr: []const type = &.{ usize, bool };
    var arch = try Archetype.init(
        allocator,
        type_arr,
    );
    defer arch.deinit();

    const num: usize = 0;

    _ = try arch.addEntity(.{ num, false });
    _ = try arch.addEntity(.{ num, false });
    _ = try arch.addEntity(.{ num, false });

    const val: *usize = @ptrCast(@alignCast(arch.components_map.get("usize").?.get(0)));
    try std.testing.expect(val.* == 0);
}
