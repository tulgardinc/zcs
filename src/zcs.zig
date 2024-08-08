const std = @import("std");
const Archetype = @import("archetype.zig").Archetype;
const ComponentList = @import("component_list.zig").ComponentList;
const System = @import("system.zig").System;
const util = @import("util.zig");

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
        const row = record_ptr.row;

        // Get the component ids of the target archetype
        var target_component_ids = try self.allocator.alloc(
            []const u8,
            src_arch_ptr.components_map.count() + 1,
        );
        defer self.allocator.free(target_component_ids);
        var src_key_iter = src_arch_ptr.components_map.keyIterator();
        var index: usize = 0;
        while (src_key_iter.next()) |key_ptr| {
            target_component_ids[index] = key_ptr.*;
            index += 1;
        }
        target_component_ids[target_component_ids.len - 1] = new_comp_id;

        // Get the id of the target archetype from hash of component ids
        const target_arch_id = util.getArchetypeIdFromStrings(target_component_ids);
        const target_arch_ptr = self.archetype_index.get(&target_arch_id) orelse blk: {
            // If a matching archetype doesn't exist, create it by shallow copying
            // the current one and adding an extra component list
            const temp_arch_ptr = try self.allocator.create(Archetype);
            //temp_arch_ptr.* = src_arch_ptr.initArchetypeWithExtraComponent(component);
            temp_arch_ptr.* = src_arch_ptr.shallowCopy();
            const new_list = try ComponentList.init(self.allocator, new_comp_type);
            try temp_arch_ptr.components_map.put(new_comp_id, new_list);

            try self.archetype_index.put(&target_arch_id, temp_arch_ptr);
            if (self.component_to_archetype.getPtr(new_comp_id)) |set| {
                try set.put(temp_arch_ptr, {});
            } else {
                var new_set = ArchetypeSet.init(self.allocator);
                try new_set.put(temp_arch_ptr, {});
                try self.component_to_archetype.put(new_comp_id, new_set);
            }

            break :blk temp_arch_ptr;
        };

        // fix the component map for the old components
        src_key_iter = src_arch_ptr.components_map.keyIterator();
        while (src_key_iter.next()) |key| {
            if (std.mem.eql(u8, key.*, Archetype.entity_id_key)) continue;
            try self.component_to_archetype.getPtr(key.*).?.put(target_arch_ptr, {});
        }

        // Move the existing components from the source map to the target map by copying
        var src_entry_iter = src_arch_ptr.components_map.iterator();
        while (src_entry_iter.next()) |entry| {
            const comp_ptr = entry.value_ptr.*.get(row);
            try target_arch_ptr.components_map.getPtr(entry.key_ptr.*).?.append(comp_ptr);
            entry.value_ptr.*.remove(row);
        }

        // Add the new component to the relevant component list
        try target_arch_ptr.components_map.getPtr(new_comp_id).?.append(@constCast(@ptrCast(&component)));

        // Update the entity record
        const new_row = target_arch_ptr.entityCount() - 1;
        record_ptr.row = new_row;
    }

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

    pub fn runSystems(self: *Self) void {
        for (self.systems.items) |sys| {
            const param_keys = sys.param_keys;
            if (param_keys.len == 0) {
                sys.run(&[_]*anyopaque{});
                continue;
            }
            var columns = self.allocator.alloc(*ArchetypeSet, param_keys.len) catch unreachable;
            defer self.allocator.free(columns);

            for (param_keys, 0..) |key, i| {
                // this needs to be made more robost (*const)
                const key_parsed = if (key[0] == '*') key[1..] else key;
                columns[i] = self.component_to_archetype.getPtr(key_parsed).?;
            }
            var query_results = ArchetypeSet.init(self.allocator);
            defer query_results.deinit();
            util.setIntersect(
                *Archetype,
                &query_results,
                columns,
            );
            var result_iter = query_results.keyIterator();
            while (result_iter.next()) |arch_ptr| {
                for (0..arch_ptr.*.entityCount()) |row| {
                    var fn_params = self.allocator.alloc(*anyopaque, param_keys.len) catch unreachable;
                    defer self.allocator.free(fn_params);
                    for (param_keys, 0..) |key, i| {
                        const key_parsed = key[1..];
                        fn_params[i] = arch_ptr.*.components_map.get(key_parsed).?.get(row);
                    }
                    sys.run(fn_params);
                }
            }
        }
    }
};

//
// THE ROW INDEXES WILL BREAK WHEN REMOVING COMPONENTS ON ADD COMPONENT CALL
//

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

// TODO: Fix entity id as special value
fn testSystem(id: EntityId, pos: *Position, accel: *Velocity) void {
    pos.x += accel.dx;
    pos.y += accel.dy;
    pos.z += accel.dz;

    std.debug.print("id: {d}, position: {any}\n", .{ id, pos });
}

test "zcs" {
    const allocator = std.testing.allocator;
    var zcs = ZCS.init(allocator);
    defer zcs.deinit();

    const position = Position{};
    const acceleration = Velocity{};

    const id = try zcs.createEntity(.{position});
    try zcs.add_component_to_entity(id, acceleration);

    zcs.registerSystem(testSystem);

    zcs.runSystems();
    zcs.runSystems();
    zcs.runSystems();
    zcs.runSystems();
}
