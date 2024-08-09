# ZCS (Zig-ECS)
A dead simple entity component system written in Zig.

This is currently just a toy project.
## Example
```zig
// define components
const Position = struct {
    x: usize = 0,
    y: usize = 0,
    z: usize = 0,
}

const Velocity = struct {
    dx: usize = 1,
    dy: usize = 1,
    dz: usize = 1,
}

const Useless = struct {};

// define systems
fn movementSystem(pos: *Position, vel: *const Velocity, _: Not(.{Useless})) void {
    pos.x += vel.dx;
    pos.y += vel.dy;
    pos.z += vel.dz;
}

// register the entities/systems and run the game loop
pub fn main() !void {
    zcs = ZCS.init(alloc);

    const id = zcs.createEntity(.{ Position {} });
    zcs.add_component_to_entity(id, Velocity {});

    try zcs.registerSystem(movementSystem);

    while (true) {
        try zcs.runSystems();
    }
}
```

## Features
- [x] Ability to add and remove components from entites.
- [x] Ability to remove entities.
- [x] Support for `*const` pointers in system component queries.
- [x] Ability to query entities from component types.
    - [ ] Entity queries with exclusion.
- [x] System queries with exclusion.
- [ ] Running systems in parallel.
    - [ ] Ability to add groups that determine the run order of systems.
