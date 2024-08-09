const std = @import("std");

pub fn Not(comptime query: anytype) type {
    const query_info = @typeInfo(@TypeOf(query));
    if (query_info != .Struct or !query_info.Struct.is_tuple) @compileError("Negative queries must be a tuple of types");

    const fields = std.meta.fields(@TypeOf(query));
    comptime var types: [fields.len]type = undefined;
    for (0..fields.len) |i| {
        types[i] = query[i];
    }

    const Type = std.builtin.Type;
    comptime var new_fields: [fields.len + 1]Type.StructField = undefined;
    for (0..new_fields.len - 1) |i| {
        new_fields[i] = Type.StructField{
            .type = void,
            .name = @typeName(types[i]),
            .alignment = @alignOf(type),
            .is_comptime = false,
            .default_value = null,
        };
    }
    const str = "not";
    new_fields[new_fields.len - 1] = Type.StructField{
        .type = void,
        .name = str,
        .alignment = @alignOf(@TypeOf(str)),
        .is_comptime = false,
        .default_value = null,
    };

    return @Type(Type{
        .Struct = Type.Struct{
            .fields = &new_fields,
            .is_tuple = false,
            .decls = &[_]Type.Declaration{},
            .layout = .auto,
        },
    });
}
