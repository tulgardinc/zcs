const std = @import("std");
const EntityId = @import("zcs.zig").EntityId;
const Not = @import("not.zig").Not;

/// Describes an individual system that executes operations on components.
/// This struct takes a function that receives pointers to compnents as parameters
/// and stores it in a way that can be ran by the ZCS struct.
pub const System = struct {
    /// Pointer to the generated run function
    run_fn: *const fn ([]*anyopaque) void,
    /// List of type names corrseponding to the parameters of the system
    param_keys: []const []const u8,
    exclusion_keys: ?[]const []const u8,

    const Self = @This();

    pub fn init(comptime func: anytype) Self {
        const parameters = comptime handleParameters(func);
        const Methods = GenFn(func);

        return Self{
            .run_fn = Methods.run,
            .param_keys = parameters.param_keys,
            .exclusion_keys = parameters.exclusion_keys,
        };
    }

    /// Runs the system with given parameter array
    pub fn run(self: *const Self, params: []*anyopaque) void {
        self.run_fn(params);
    }

    const ParamReturnType = struct {
        param_keys: []const []const u8,
        exclusion_keys: ?[]const []const u8,
    };

    fn handleParameters(comptime func: anytype) ParamReturnType {
        const T = @TypeOf(func);
        const func_info = @typeInfo(T);

        if (func_info != .Fn) @compileError("Systems must be created with functions");

        const args = std.meta.ArgsTuple(T);

        const Type = std.builtin.Type;
        // Get inputs of the function as a tuple
        const input_fields: []const Type.StructField = std.meta.fields(args);

        comptime var exclusion_keys: ?[]const []const u8 = null;

        comptime var param_keys: []const []const u8 = &.{};

        comptime var exclusion_index: usize = 0;

        inline for (input_fields, 0..) |field, i| {
            const field_info = @typeInfo(field.type);
            if (field_info == .Struct and @hasField(field.type, "not")) outer: {
                const not_fields = field_info.Struct.fields;
                comptime var temp_negatives: []const []const u8 = &.{};
                inline for (not_fields) |not_field| {
                    if (not_field.type != void) {
                        break :outer;
                    }
                    if (std.mem.eql(u8, not_field.name, "not")) continue;
                    temp_negatives = temp_negatives ++ .{not_field.name};
                }
                exclusion_keys = temp_negatives;
                exclusion_index = i;
                param_keys = param_keys ++ .{"Not"};
                continue;
            }
            if (field_info != .Pointer) @compileError("System parameters have to be pointers");
            if (field.type == *EntityId) @compileError("EntityId parameter must be of type const pointer");

            const name = @typeName(field_info.Pointer.child);
            param_keys = param_keys ++ .{name};
        }

        return ParamReturnType{
            .param_keys = param_keys,
            .exclusion_keys = exclusion_keys,
        };
    }

    /// Generates the run function
    fn GenFn(comptime func: anytype) type {
        return struct {
            pub fn run(params: []*anyopaque) void {
                const T = @TypeOf(func);
                const args = std.meta.ArgsTuple(T);

                const input_fields: []const std.builtin.Type.StructField = std.meta.fields(args);

                comptime var types: [input_fields.len]type = undefined;
                inline for (input_fields, 0..) |input_field, i| {
                    types[i] = input_field.type;
                }

                var param_tuple: std.meta.Tuple(&types) = undefined;
                inline for (&param_tuple, types, params) |*param, ItemTypePtr, item_ptr| {
                    const type_info = @typeInfo(ItemTypePtr);
                    if (type_info != .Pointer) {
                        param.* = undefined;
                        continue;
                    }
                    const casted_item_ptr: ItemTypePtr = @ptrCast(@alignCast(item_ptr));
                    param.* = casted_item_ptr;
                }

                @call(.auto, func, param_tuple);
            }
        };
    }
};

const Num = struct {
    value: usize = 0,
};

fn testFn(num: *Num) void {
    num.value += 1;
    //std.debug.print("value: {d}\n", .{num.value});
}

test "main" {
    const allocator = std.testing.allocator;
    var sys = System.init(testFn);

    const num_ptr = try allocator.create(Num);
    defer allocator.destroy(num_ptr);
    num_ptr.* = Num{ .value = 0 };

    var param_arr = [_]*anyopaque{@ptrCast(num_ptr)};

    sys.run(&param_arr);
    sys.run(&param_arr);
    sys.run(&param_arr);

    try std.testing.expect(num_ptr.value == 3);
}

fn noParamTest() void {
    std.debug.print("ran\n", .{});
}

test "system no argument" {
    var sys = System.init(noParamTest);
    sys.run(&[_]*anyopaque{});
}
