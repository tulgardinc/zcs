const std = @import("std");
const ComponentList = @import("component_list.zig").ComponentList;
const EntityId = @import("zcs.zig").EntityId;

/// Holds components associated with a archetype
pub const Archetype = struct {
    /// Maps component ids to component lists
    components_map: std.StringHashMap(ComponentList),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub const entity_id_key = @typeName(EntityId);

    pub fn init(allocator: std.mem.Allocator, comptime types: anytype) !Self {
        //if (@typeInfo(@TypeOf(types)) != .Array) @compileError("Wrong type of argument");

        var comp_map = std.StringHashMap(ComponentList).init(allocator);

        // Genereate component lists
        // Add the ids component
        const id_list = try ComponentList.init(allocator, EntityId);
        try comp_map.put(entity_id_key, id_list);
        // Add the rest of the components
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

    pub fn shallowCopy(self: *Self) Self {
        var iter = self.components_map.iterator();
        var new_components_map = std.StringHashMap(ComponentList).init(self.allocator);
        while (iter.next()) |entry| {
            const new_list = entry.value_ptr.*.shallowCopy();
            new_components_map.put(entry.key_ptr.*, new_list) catch unreachable;
        }

        return Self{
            .components_map = new_components_map,
            .allocator = self.allocator,
        };
    }

    pub fn removeEntity(self: *Self, row: usize) void {
        var entry_iter = self.components_map.iterator();
        while (entry_iter.next()) |entry| {
            self.components_map.get(entry.key_ptr.*).?.remove(row);
        }
    }

    pub fn getEntity(self: *Self, row: usize, result_map: *std.StringHashMap(*anyopaque)) !void {
        var entry_iter = self.components_map.iterator();
        while (entry_iter.next()) |entry| {
            const comp = entry.value_ptr.get(row);
            try result_map.put(entry.key_ptr.*, comp);
        }
    }

    pub fn addEntityRuntime(self: *Self, components: std.StringHashMap(*anyopaque)) !usize {
        // TODO: error to make input and comp map same size with same keys
        if (components.count() != self.components_map.count()) return error.WrongInputSize;
        var entry_iter = components.iterator();
        while (entry_iter.next()) |entry| {
            if (!self.components_map.contains(entry.key_ptr.*)) return error.WrongInputKeys;
            try self.components_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return self.entityCount() - 1;
    }

    pub fn getComponentIds(self: *Self, ids: [][]const u8) !void {
        var key_iter = self.components_map.keyIterator();
        var i: usize = 0;
        while (key_iter.next()) |key| {
            ids[i] = key.*;
            i += 1;
        }
    }

    /// Returns the amount of entities in the archetype
    pub fn entityCount(self: *Self) usize {
        return self.components_map.get(entity_id_key).?.getLen();
    }

    pub fn addEntity(self: *Self, id: usize, comptime components: anytype) !usize {
        // Get type info
        const input_type = @TypeOf(components);
        const type_info = @typeInfo(input_type);
        if (type_info != .Struct or !type_info.Struct.is_tuple) {
            @compileError("Wrong type of components input");
        }

        // Add the entity id
        var id_comp = EntityId{ .id = id };
        try self.components_map.getPtr(entity_id_key).?.append(&id_comp);

        // Add components to the arrays
        const fields = type_info.Struct.fields;
        inline for (fields) |field| {
            const comp_id = @typeName(field.type);
            var item = @field(components, field.name);
            try self.components_map.getPtr(comp_id).?.append(@ptrCast(&item));
        }

        return self.entityCount() - 1;
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

    _ = try arch.addEntity(0, .{ num, false });
    _ = try arch.addEntity(1, .{ num, false });
    _ = try arch.addEntity(2, .{ num, false });

    const val: *usize = @ptrCast(@alignCast(arch.components_map.get("usize").?.get(0)));
    try std.testing.expect(val.* == 0);
}
