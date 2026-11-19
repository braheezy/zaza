pub fn main() void {
    _ = @sizeOf(Cpu);
}

const Cpu = @import("cpu.zig");

test {
    _ = Cpu;
}
