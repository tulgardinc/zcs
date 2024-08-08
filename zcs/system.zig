const std = @import("std");

/// Describes an individual system that executes operations on components.
/// This struct takes a function that receives pointers to compnents as parameters
/// and stores it in a way that can be ran by the ZCS struct.
pub const System = struct {
    /// Pointer to the generated run function
    run_fn: *const fn ([]*anyopaque) void,
    /// List of type names corrseponding to the parameters of the system
    param_keys: []const []const u8,

    const Self = @This();

    pub fn init(comptime func: anytype) Self {
        const Methods = GenFn(func);
        const keys = comptime genTypeNames(func);
        return Self{
            .run_fn = Methods.run,
            .param_keys = keys,
        };
    }

    /// Runs the system with given parameter array
    pub fn run(self: *const Self, params: []*anyopaque) void {
        self.run_fn(params);
    }

    /// Generates the type names for the parameters
    fn genTypeNames(comptime func: anytype) []const []const u8 {
        const T = @TypeOf(func);
        const args = std.meta.ArgsTuple(T);

        const Type = std.builtin.Type;
        // Get inputs of the function as a tuple
        const input_fields: []const Type.StructField = std.meta.fields(args);

        // Extract the parameter names from the tuple
        const parameter_type_names = comptime blk: {
            var temp: [input_fields.len][]const u8 = undefined;
            for (input_fields, 0..) |input_field, i| {
                temp[i] = @typeName(input_field.type);
            }
            break :blk temp;
        };

        return &parameter_type_names;
    }

    /// Generates teh run function
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
