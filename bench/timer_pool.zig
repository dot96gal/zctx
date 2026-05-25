const std = @import("std");
const zctx = @import("zctx");

const runs = 10;
const ns_per_ms = std.time.ns_per_ms;

pub fn main(env: std.process.Init) !void {
    const allocator = env.gpa;
    const io = env.io;

    const pool = try zctx.TimerPool.init(allocator, io);
    defer pool.deinit(allocator, io);

    const ns_10 = try measure(allocator, io, pool, 10);
    const ns_100 = try measure(allocator, io, pool, 100);
    const ns_1000 = try measure(allocator, io, pool, 1000);
    const ns_10000 = try measure(allocator, io, pool, 10000);

    var out_buf: [512]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &out_buf);
    const stdout = &file_writer.interface;
    try stdout.print("N=10      min={d:.3}ms\n", .{@as(f64, @floatFromInt(ns_10)) / ns_per_ms});
    try stdout.print("N=100     min={d:.3}ms\n", .{@as(f64, @floatFromInt(ns_100)) / ns_per_ms});
    try stdout.print("N=1000    min={d:.3}ms\n", .{@as(f64, @floatFromInt(ns_1000)) / ns_per_ms});
    try stdout.print("N=10000   min={d:.3}ms\n", .{@as(f64, @floatFromInt(ns_10000)) / ns_per_ms});
    try stdout.flush();
}

fn measure(
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *zctx.TimerPool,
    comptime n: usize,
) !u64 {
    var min_ns: u64 = std.math.maxInt(u64);
    const timeout: std.Io.Clock.Duration = .{
        .raw = .{ .nanoseconds = 60 * std.time.ns_per_s },
        .clock = .awake,
    };

    for (0..runs) |_| {
        const t0 = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;

        var scopes: [n]?zctx.OwnedDeadlineScope = .{null} ** n;
        errdefer for (&scopes) |*s| {
            if (s.*) |*scope| {
                scope.cancel(io);
                scope.deinit(allocator, io);
            }
        };

        for (0..n) |i| {
            scopes[i] = try zctx.withTimeout(allocator, io, pool, zctx.background, timeout);
        }
        for (&scopes) |*s| {
            if (s.*) |*scope| {
                scope.cancel(io);
                scope.deinit(allocator, io);
            }
        }

        const elapsed: u64 = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - t0);
        if (elapsed < min_ns) min_ns = elapsed;
    }

    return min_ns;
}
