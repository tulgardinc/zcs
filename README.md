# ZCS (Zig-ECS)
A dead simple entity component system written in Zig.

This is currently just a toy project.
## Example
```zig
// define components
struct Position {
    x: usize = 0,
    y: usize = 0,
    z: usize = 0,
}

struct Velocity {
    dx: usize = 1,
    dy: usize = 1,
    dz: usize = 1,
}

// define systems
fn movementSystem(pos: *Position, vel: *Velocity) void {
    pos.x += vel.dx;
    pos.y += vel.dy;
    pos.z += vel.dz;
}

// register the entities/systems and run the game loop
pub fn main() !void {
    zcs = ZCS.init(alloc);

    _ = zcs.addEntity(Position {}, Velocity {});

    try zcs.registerSystem(movementSystem);

    while (true) {
        try zcs.runSystems();
    }
}
```

## Future Plans
- [x] Ability to add and remove components from entites.
- [x] Ability to remove entities.
- [x] Support for `*const` pointers in system component queries.
- [ ] Ability to query components.
- [ ] Negative queries in systems.
- [ ] Running systems in parallel.
    - [ ] Ability to add groups that determine the run order of systems.
