const std = @import("std");
const Archetype = @import("archetype.zig").Archetype;
const ComponentList = @import("archetype.zig").ComponentList;
const System = @import("system.zig").System;
const util = @import("util.zig");

const ArchetypeSet = std.AutoHashMap(*Archetype, void);
pub const ZCS = struct {
    allocator: std.mem.Allocator,
    entity_count: usize = 0,

    archetype_index: std.StringHashMap(*Archetype),

    entity_records: std.AutoHashMap(usize, EntityRecord),

    component_to_archetype: std.StringHashMap(ArchetypeSet),

    systems: std.ArrayList(System),

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

    /// Creates an entity from a collection of components and returns its id
    pub fn createEntity(self: *Self, comptime components: anytype) !usize {
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
        const type_names: [fields.len][]const u8 = comptime blk: {
            var temp: [fields.len][]const u8 = undefined;
            for (fields, 0..) |field, i| {
                temp[i] = @typeName(field.type);
            }
            break :blk temp;
        };

        // Get the archetype id
        const archetype_id = comptime blk: {
            break :blk util.getArchetypeId(types);
        };

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
        const row = try arch_ptr.?.addEntity(components);

        // Add the entity to the records
        self.entity_count += 1;
        const entity_id = self.entity_count;
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
                const key_parsed = key[1..];
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
                for (0..arch_ptr.*.count()) |row| {
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

fn testSystem(pos: *Position, accel: *Velocity) void {
    pos.x += accel.dx;
    pos.y += accel.dy;
    pos.z += accel.dz;

    std.debug.print("position: {any}\n", .{pos});
}

test "zcs" {
    const allocator = std.testing.allocator;
    var zcs = ZCS.init(allocator);
    defer zcs.deinit();

    const position = Position{};
    const acceleration = Velocity{};

    _ = try zcs.createEntity(.{ position, acceleration });

    zcs.registerSystem(testSystem);

    zcs.runSystems();
    zcs.runSystems();
    zcs.runSystems();
    zcs.runSystems();
}
