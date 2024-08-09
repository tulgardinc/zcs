const std = @import("std");
const Archetype = @import("archetype.zig").Archetype;
const ComponentList = @import("component_list.zig").ComponentList;
const System = @import("system.zig").System;
const util = @import("util.zig");
const Not = @import("not.zig").Not;

const ArchetypeSet = std.AutoHashMap(*Archetype, void);

pub const EntityId = struct { id: usize };

pub const ZCS = struct {
    allocator: std.mem.Allocator,
    entity_count: usize = 0,

    /// Lookup archetypes by the hash of component ids
    archetype_index: std.StringHashMap(*Archetype),

    /// Lookup the archetype and the row withing the archetype of entity
    entity_records: std.AutoHashMap(usize, EntityRecord),

    /// Lookup archetypes that hold a component
    component_to_archetype: std.StringHashMap(ArchetypeSet),

    /// List of systems
    systems: std.ArrayList(System),

    /// Maps each archetype to an other based on an added or removed component
    // archetype_add_map: std.AutoHashMap(*Archetype, std.StringHashMap(*Archetype)),
    // archetype_remove_map: std.AutoHashMap(*Archetype, std.StringHashMap(*Archetype)),

    const EntityRecord = struct {
        row: usize,
        archetype: *Archetype,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const archetype_index = std.StringHashMap(*Archetype).init(allocator);
        const entity_records = std.AutoHashMap(usize, EntityRecord).init(allocator);
        const component_to_archetype = std.StringHashMap(ArchetypeSet).init(allocator);
        const systems = std.ArrayList(System).init(allocator);

        return Self{
            .archetype_index = archetype_index,
            .entity_records = entity_records,
            .component_to_archetype = component_to_archetype,
            .allocator = allocator,
            .systems = systems,
        };
    }

    pub fn deinit(self: *Self) void {
        var arch_iter = self.archetype_index.valueIterator();
        while (arch_iter.next()) |arch_ptr_ptr| {
            arch_ptr_ptr.*.deinit();
            self.allocator.destroy(arch_ptr_ptr.*);
        }
        self.archetype_index.deinit();
        self.entity_records.deinit();
        var arch_set_iter = self.component_to_archetype.valueIterator();
        while (arch_set_iter.next()) |arch_set_ptr| {
            arch_set_ptr.deinit();
        }
        self.component_to_archetype.deinit();
        self.systems.deinit();
    }

    /// Adds a compnent to an entitiy
    pub fn add_component_to_entity(self: *Self, entity_id: usize, component: anytype) !void {
        // This is done by copying the compnents of the entity into a new archetype
        // that holds an extra set of compnents

        // The type of the new component
        const new_comp_type = @TypeOf(component);
        // The id of the new component
        const new_comp_id = @typeName(new_comp_type);

        // The record for the entity
        var record_ptr: *EntityRecord = self.entity_records.getPtr(entity_id).?;
        const src_arch_ptr = record_ptr.archetype;
        const old_row = record_ptr.row;

        var src_comps = std.StringHashMap(*anyopaque).init(self.allocator);
        defer src_comps.deinit();
        try src_arch_ptr.getEntity(old_row, &src_comps);

        // Get the component ids of the target archetype
        var target_component_ids = try self.allocator.alloc(
            []const u8,
            src_arch_ptr.components_map.count() + 1,
        );
        defer self.allocator.free(target_component_ids);
        try src_arch_ptr.getComponentIds(target_component_ids);
        target_component_ids[target_component_ids.len - 1] = new_comp_id;

        // Get the id of the target archetype from hash of component ids
        const target_arch_id = util.getArchetypeIdFromStrings(target_component_ids);
        const target_arch_ptr = self.archetype_index.get(&target_arch_id) orelse blk: {
            // If a matching archetype doesn't exist, create it by shallow copying
            // the current one and adding an extra component list
            const temp_arch_ptr = try self.allocator.create(Archetype);
            temp_arch_ptr.* = src_arch_ptr.shallowCopy();
            const new_list = try ComponentList.init(self.allocator, new_comp_type);
            try temp_arch_ptr.components_map.put(new_comp_id, new_list);

            // Update the archetype index with the new archetype
            try self.archetype_index.put(&target_arch_id, temp_arch_ptr);
            // Add the new archetype to the component to archetype map
            // Create the entry for the component if it doesn't exist
            if (self.component_to_archetype.getPtr(new_comp_id)) |set| {
                try set.put(temp_arch_ptr, {});
            } else {
                var new_set = ArchetypeSet.init(self.allocator);
                try new_set.put(temp_arch_ptr, {});
                try self.component_to_archetype.put(new_comp_id, new_set);
            }

            // Fix the component to archetype map for the old components
            var src_key_iter = src_comps.keyIterator();
            while (src_key_iter.next()) |key| {
                // We do not map for EntityId component
                if (std.mem.eql(u8, key.*, Archetype.entity_id_key)) continue;
                try self.component_to_archetype.getPtr(key.*).?.put(temp_arch_ptr, {});
            }
            break :blk temp_arch_ptr;
        };

        // Move the existing components from the source map to the target map by copying
        var src_entry_iter = src_arch_ptr.components_map.iterator();
        while (src_entry_iter.next()) |entry| {
            const comp_ptr = entry.value_ptr.*.get(old_row);
            try target_arch_ptr.components_map.getPtr(entry.key_ptr.*).?.append(comp_ptr);
            entry.value_ptr.*.remove(old_row);
            // Because we do swap remove update the row index for the element that filled in the
            // place of the removed entity (if such an enitity exists)
            const id_list = src_arch_ptr.components_map.get(Archetype.entity_id_key).?;
            if (id_list.getLen() > 0) {
                const filled_entity_id: *EntityId = @ptrCast(@alignCast(id_list.get(old_row)));
                self.entity_records.getPtr(filled_entity_id.id).?.row = old_row;
            }
        }

        // Add the new component to the relevant component list
        try target_arch_ptr.components_map.getPtr(new_comp_id).?.append(@constCast(@ptrCast(&component)));

        // Update the entity record
        const new_row = target_arch_ptr.entityCount() - 1;
        record_ptr.row = new_row;
        record_ptr.archetype = target_arch_ptr;
    }

    /// Removes a compnent from an entitiy
    pub fn remove_component_from_entity(self: *Self, entity_id: usize, component: anytype) !void {
        // This is done by copying the compnents of the entity into a new archetype
        // that does not hold a sepcific set of components

        // The type of the new component
        const remove_comp_type = @TypeOf(component);
        // The id of the new component
        const remove_comp_id = @typeName(remove_comp_type);

        // The record for the entity
        var record_ptr: *EntityRecord = self.entity_records.getPtr(entity_id).?;
        const src_arch_ptr = record_ptr.archetype;
        const old_row = record_ptr.row;

        // Get the component ids of the target archetype
        var target_component_ids = std.ArrayList([]const u8).init(self.allocator);
        defer target_component_ids.deinit();
        var src_key_iter = src_arch_ptr.components_map.keyIterator();
        while (src_key_iter.next()) |key| {
            if (std.mem.eql(u8, key.*, remove_comp_id)) continue;
            try target_component_ids.append(key.*);
        }

        // Get the id of the target archetype from hash of component ids
        const target_arch_id = util.getArchetypeIdFromStrings(target_component_ids.items);
        const target_arch_ptr = self.archetype_index.get(&target_arch_id) orelse blk: {
            // If a matching archetype doesn't exist, create it by shallow copying
            // the current one while skipping the component list for the removed component
            const temp_arch_ptr = try self.allocator.create(Archetype);
            temp_arch_ptr.* = src_arch_ptr.shallowCopy();
            _ = temp_arch_ptr.components_map.remove(remove_comp_id);

            // Update the archetype index with the new archetype
            try self.archetype_index.put(&target_arch_id, temp_arch_ptr);

            // Fix the component to archetype map for the old components by pointing to the new
            // archetype
            src_key_iter = src_arch_ptr.components_map.keyIterator();
            while (src_key_iter.next()) |key| {
                // We do not map for EntityId component
                if (std.mem.eql(u8, key.*, Archetype.entity_id_key)) continue;
                // We do not want to map to the removed component
                if (std.mem.eql(u8, key.*, remove_comp_id)) continue;
                try self.component_to_archetype.getPtr(key.*).?.put(temp_arch_ptr, {});
            }

            break :blk temp_arch_ptr;
        };

        // Move the existing components from the source map to the target map by copying
        var src_entry_iter = src_arch_ptr.components_map.iterator();
        while (src_entry_iter.next()) |entry| {
            // Remove the removed component without copying to the new archetype
            if (std.mem.eql(u8, entry.key_ptr.*, remove_comp_id)) {
                entry.value_ptr.*.remove(old_row);
                continue;
            }
            const comp_ptr = entry.value_ptr.*.get(old_row);
            try target_arch_ptr.components_map.getPtr(entry.key_ptr.*).?.append(comp_ptr);
            entry.value_ptr.*.remove(old_row);
            // Because we do swap remove update the row index for the element that filled in the
            // place of the removed entity (if such an enitity exists)
            const id_list = src_arch_ptr.components_map.get(Archetype.entity_id_key).?;
            if (id_list.getLen() > 0) {
                const filled_entity_id: *EntityId = @ptrCast(@alignCast(id_list.get(old_row)));
                self.entity_records.getPtr(filled_entity_id.id).?.row = old_row;
            }
        }

        // Update the entity record
        const new_row = target_arch_ptr.entityCount() - 1;
        record_ptr.row = new_row;
        record_ptr.archetype = target_arch_ptr;
    }

    /// Creates an entity from a collection of components and returns its id
    pub fn createEntity(self: *Self, comptime components: anytype) !usize {
        // set the entity id and the count
        self.entity_count += 1;
        const entity_id = self.entity_count;

        // Check if the type of the input is correct
        const input_type = @TypeOf(components);
        const type_info = @typeInfo(input_type);
        if (type_info != .Struct or !type_info.Struct.is_tuple) {
            @compileError("Wrong type of components input");
        }

        // Get the type array from the input
        const fields = type_info.Struct.fields;

        const types: [fields.len]type = comptime blk: {
            var temp: [fields.len]type = undefined;
            for (fields, 0..) |field, i| {
                temp[i] = field.type;
            }
            break :blk temp;
        };
        const types_for_hash = comptime blk: {
            var temp: [fields.len + 1]type = undefined;
            for (fields, 0..) |field, i| {
                temp[i] = field.type;
            }
            temp[fields.len] = EntityId;
            break :blk temp;
        };
        const type_names = comptime blk: {
            var temp: [fields.len][]const u8 = undefined;
            for (fields, 0..) |field, i| {
                temp[i] = @typeName(field.type);
            }
            break :blk temp;
        };

        // Get the archetype id
        const archetype_id = comptime util.getArchetypeId(types_for_hash);

        // Get archetype from map if exists
        var arch_ptr = self.archetype_index.get(&archetype_id);

        // If archetype doesn't exist creat it
        if (arch_ptr == null) {
            arch_ptr = try self.allocator.create(Archetype);
            const arch = try Archetype.init(self.allocator, types);
            arch_ptr.?.* = arch;

            // Update the component to archetype map
            for (type_names) |name| {
                if (self.component_to_archetype.getPtr(name)) |set| {
                    // If set exists for component just add to set
                    try set.put(arch_ptr.?, {});
                } else {
                    // Else create a set and add to it
                    var new_set = ArchetypeSet.init(self.allocator);
                    try new_set.put(arch_ptr.?, {});
                    try self.component_to_archetype.put(name, new_set);
                }
            }

            // Update archetype index
            try self.archetype_index.put(&archetype_id, arch_ptr.?);
        }

        // Add entity to Archetype
        const row = try arch_ptr.?.addEntity(entity_id, components);

        // Add the entity to the records
        try self.entity_records.put(entity_id, EntityRecord{
            .archetype = arch_ptr.?,
            .row = row,
        });

        return entity_id;
    }

    pub fn registerSystem(self: *Self, comptime func: anytype) void {
        const sys = System.init(func);
        self.systems.append(sys) catch unreachable;
    }

    fn debugPrintALlComponents(self: *Self) void {
        var key_iter = self.component_to_archetype.keyIterator();
        while (key_iter.next()) |key| {
            std.debug.print("components: {s}\n", .{key.*});
        }
    }

    pub fn runSystems(self: *Self) !void {
        outer: for (self.systems.items) |sys| {
            const param_keys = sys.param_keys;
            const exclusion_keys = sys.exclusion_keys;

            if (param_keys.len == 0) {
                sys.run(&[_]*anyopaque{});
                continue;
            }

            var columns = std.ArrayList(*ArchetypeSet).init(self.allocator);
            defer columns.deinit();

            for (param_keys) |key| {
                if (std.mem.eql(u8, key, Archetype.entity_id_key)) continue;
                if (std.mem.eql(u8, key, "Not")) continue;
                if (self.component_to_archetype.getPtr(key)) |set| {
                    try columns.append(set);
                } else {
                    continue :outer;
                }
            }

            var negative_input_list = std.ArrayList(*ArchetypeSet).init(self.allocator);
            defer negative_input_list.deinit();
            if (exclusion_keys) |query_keys| {
                for (query_keys) |key| {
                    if (self.component_to_archetype.getPtr(key)) |set| {
                        try negative_input_list.append(set);
                    }
                }
            }
            const negative_input: ?[]*const ArchetypeSet = if (negative_input_list.items.len == 0) null else negative_input_list.items;

            var query_results = ArchetypeSet.init(self.allocator);
            defer query_results.deinit();
            util.setIntersect(
                *Archetype,
                &query_results,
                columns.items,
                negative_input,
            );
            var result_iter = query_results.keyIterator();

            while (result_iter.next()) |arch_ptr| {
                for (0..arch_ptr.*.entityCount()) |row| {
                    var fn_params = self.allocator.alloc(*anyopaque, param_keys.len) catch unreachable;
                    defer self.allocator.free(fn_params);
                    for (param_keys, 0..) |key, i| {
                        if (std.mem.eql(u8, key, "Not")) {
                            fn_params[i] = undefined;
                            continue;
                        }
                        fn_params[i] = arch_ptr.*.components_map.get(key).?.get(row);
                    }
                    sys.run(fn_params);
                }
            }
        }
    }

    pub fn entity_query(self: *Self, result_list_ptr: *std.ArrayList(usize), comptime query: anytype, comptime exclude: anytype) !void {
        const query_info = @typeInfo(@TypeOf(query));
        const exclude_info = @typeInfo(@TypeOf(exclude));

        if (query_info != .Struct or !query_info.Struct.is_tuple) @compileError("A query has to be a tuple of types");
        if (exclude_info != .Struct or !query_info.Struct.is_tuple) @compileError("A query has to be a tuple of types");

        const fields = query_info.Struct.fields;
        const comp_ids = comptime blk: {
            var temp: [fields.len][]const u8 = undefined;
            for (0..temp.len) |i| {
                temp[i] = @typeName(query[i]);
            }
            break :blk temp;
        };

        var columns: [comp_ids.len]*ArchetypeSet = undefined;
        for (0..columns.len) |i| {
            if (self.component_to_archetype.getPtr(comp_ids[i])) |set| {
                columns[i] = set;
            } else {
                return;
            }
        }

        const exclude_fields = exclude_info.Struct.fields;
        const exclude_ids = comptime blk: {
            var temp: [exclude_fields.len][]const u8 = undefined;
            for (0..temp.len) |i| {
                temp[i] = @typeName(exclude[i]);
            }
            break :blk temp;
        };

        var exclude_columns: [exclude_ids.len]*ArchetypeSet = undefined;
        for (0..exclude_columns.len) |i| {
            if (self.component_to_archetype.getPtr(exclude_ids[i])) |set| {
                exclude_columns[i] = set;
            } else {
                return;
            }
        }

        var intersect_result_set = ArchetypeSet.init(self.allocator);
        defer intersect_result_set.deinit();
        util.setIntersect(
            *Archetype,
            &intersect_result_set,
            &columns,
            &exclude_columns,
        );

        var result_iter = intersect_result_set.keyIterator();
        while (result_iter.next()) |arch_ptr_ptr| {
            const id_list = arch_ptr_ptr.*.components_map.get(Archetype.entity_id_key).?;
            const len = id_list.getLen();
            for (0..len) |i| {
                const e_id: *EntityId = @ptrCast(@alignCast(id_list.get(i)));
                try result_list_ptr.append(e_id.id);
            }
        }
    }
};

const Position = struct {
    x: usize = 0,
    y: usize = 0,
    z: usize = 0,
};

const Velocity = struct {
    dx: usize = 1,
    dy: usize = 1,
    dz: usize = 1,
};

const Useless = struct {};

fn testSystem(id: *const EntityId, pos: *Position, vel: *Velocity) void {
    pos.x += vel.dx;
    pos.y += vel.dy;
    pos.z += vel.dz;

    std.debug.print("id: {d}, position: {any}\n", .{ id.id, pos });
}

test "zcs" {
    const allocator = std.testing.allocator;
    var zcs = ZCS.init(allocator);
    defer zcs.deinit();

    const position = Position{};
    const acceleration = Velocity{};
    const useless = Useless{};

    const id = try zcs.createEntity(.{position});
    try zcs.add_component_to_entity(id, acceleration);
    try zcs.add_component_to_entity(id, useless);

    try zcs.remove_component_from_entity(id, Useless);

    zcs.registerSystem(testSystem);

    try zcs.runSystems();
    try zcs.runSystems();
    try zcs.runSystems();
    try zcs.runSystems();
}

test "query" {
    const allocator = std.testing.allocator;
    var zcs = ZCS.init(allocator);
    defer zcs.deinit();

    const position = Position{};
    const acceleration = Velocity{};

    _ = try zcs.createEntity(.{ position, acceleration });
    _ = try zcs.createEntity(.{ position, acceleration });
    _ = try zcs.createEntity(.{ position, acceleration });

    var query_results = std.ArrayList(usize).init(allocator);
    defer query_results.deinit();
    try zcs.entity_query(&query_results, .{ Position, Velocity }, .{});

    try std.testing.expect(query_results.items.len == 3);
    try std.testing.expect(query_results.items[0] == 1);
    try std.testing.expect(query_results.items[1] == 2);
    try std.testing.expect(query_results.items[2] == 3);
}

fn testSystemNegative(id: *const EntityId, pos: *Position, vel: *Velocity, _: Not(.{Useless})) void {
    pos.x += vel.dx;
    pos.y += vel.dy;
    pos.z += vel.dz;

    std.debug.print("id: {d}, position: {any}\n", .{ id.id, pos });
}

test "negative system query" {
    const allocator = std.testing.allocator;
    var zcs = ZCS.init(allocator);
    defer zcs.deinit();

    const position = Position{};
    const acceleration = Velocity{};
    const useless = Useless{};

    _ = try zcs.createEntity(.{ position, acceleration, useless });
    _ = try zcs.createEntity(.{ position, acceleration, useless });
    _ = try zcs.createEntity(.{ position, acceleration });
    _ = try zcs.createEntity(.{ position, acceleration });

    zcs.registerSystem(testSystemNegative);

    try zcs.runSystems();
}

test "negative query" {
    const allocator = std.testing.allocator;
    var zcs = ZCS.init(allocator);
    defer zcs.deinit();

    const position = Position{};
    const acceleration = Velocity{};
    const useless = Useless{};

    _ = try zcs.createEntity(.{ position, acceleration, useless });
    _ = try zcs.createEntity(.{ position, acceleration, useless });
    _ = try zcs.createEntity(.{ position, acceleration });
    _ = try zcs.createEntity(.{ position, acceleration });

    var results = std.ArrayList(usize).init(allocator);
    defer results.deinit();

    try zcs.entity_query(&results, .{Position}, .{Useless});

    try std.testing.expect(results.items[0] == 3);
    try std.testing.expect(results.items[1] == 4);

    try zcs.runSystems();
}
