const std = @import("std");
const signal_mod = @import("signal.zig");

pub const background: Context = .background;
pub const todo: Context = .todo;
pub const canceled: Context = .canceled;

const Signal = signal_mod.Signal;
const SignalSource = signal_mod.SignalSource;

pub const ContextError = error{
    Canceled,
    DeadlineExceeded,
};

pub const Context = union(enum) {
    background,
    todo,
    canceled,
    cancel_ctx: *CancelCtx,
    deadline_ctx: *DeadlineCtx,
    value_ctx: *ValueCtx,

    pub fn done(ctx: Context) Signal {
        return switch (ctx) {
            .background, .todo => .{ .inner = .never_fires },
            .canceled => .{ .inner = .already_fired },
            .cancel_ctx => |c| c.state.source.signal(),
            .deadline_ctx => |d| d.state.source.signal(),
            .value_ctx => |v| v.parent.done(),
        };
    }

    pub fn err(ctx: Context, io: std.Io) ?ContextError {
        return switch (ctx) {
            .background, .todo => null,
            .canceled => ContextError.Canceled,
            .cancel_ctx => |c| blk: {
                c.state.mutex.lockUncancelable(io);
                defer c.state.mutex.unlock(io);
                break :blk c.state.cancel_err;
            },
            .deadline_ctx => |d| blk: {
                d.state.mutex.lockUncancelable(io);
                defer d.state.mutex.unlock(io);
                break :blk d.state.cancel_err;
            },
            .value_ctx => |v| v.parent.err(io),
        };
    }

    pub fn deadline(ctx: Context) ?std.Io.Clock.Timestamp {
        return switch (ctx) {
            .background, .todo, .canceled, .cancel_ctx => null,
            .deadline_ctx => |d| d.deadline,
            .value_ctx => |v| v.parent.deadline(),
        };
    }

    pub fn typedValue(ctx: Context, comptime Key: type) ?Key.Value {
        const raw = ctx.rawValue(Key.key) orelse return null;
        return @as(*Key.Value, @ptrCast(@alignCast(raw))).*;
    }

    fn rawValue(ctx: Context, key: *const anyopaque) ?*anyopaque {
        return switch (ctx) {
            .background, .todo => null,
            .canceled => null,
            .cancel_ctx => |c| c.parent.rawValue(key),
            .deadline_ctx => |d| d.parent.rawValue(key),
            .value_ctx => |v| if (v.key == key) v.val else v.parent.rawValue(key),
        };
    }
};

pub const OwnedContext = struct {
    context: Context,

    pub fn deinit(self: OwnedContext, allocator: std.mem.Allocator, io: std.Io) void {
        switch (self.context) {
            .background, .todo, .canceled => {},
            .cancel_ctx => |c| c.deinit(allocator, io),
            .deadline_ctx => |d| d.deinit(allocator, io),
            .value_ctx => |v| v.deinit(allocator),
        }
    }

    pub fn cancel(self: OwnedContext, io: std.Io) void {
        switch (self.context) {
            .background, .todo, .canceled => {},
            .cancel_ctx => |c| c.state.cancel(io, error.Canceled),
            .deadline_ctx => |d| d.state.cancel(io, error.Canceled),
            .value_ctx => {},
        }
    }
};

const CancelState = struct {
    const CancelChild = union(enum) {
        cancel_ctx: *CancelCtx,
        deadline_ctx: *DeadlineCtx,

        fn propagate(child: CancelChild, io: std.Io, reason: ContextError) void {
            switch (child) {
                .cancel_ctx => |c| c.state.cancel(io, reason),
                .deadline_ctx => |d| d.state.cancel(io, reason),
            }
        }
    };

    source: SignalSource,
    cancel_err: ?ContextError,
    mutex: std.Io.Mutex,
    children: std.ArrayListUnmanaged(CancelChild),

    fn init() CancelState {
        return .{
            .source = .{},
            .cancel_err = null,
            .mutex = .init,
            .children = .empty,
        };
    }

    fn deinit(self: *CancelState, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
    }

    fn cancel(self: *CancelState, io: std.Io, reason: ContextError) void {
        // ロック解放後に propagateChildren を呼ぶ。
        // 子の cancel が別の mutex を取得するため、ロック保持中に呼ぶとデッドロックが生じる可能性がある。
        const items = self.acquireCancelLock(io, reason) orelse return;
        propagateChildren(io, items, reason);
        self.source.fire(io);
    }

    fn acquireCancelLock(
        self: *CancelState,
        io: std.Io,
        reason: ContextError,
    ) ?[]const CancelChild {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.cancel_err != null) return null;
        self.cancel_err = reason;
        // cancel_err 設定後は children への追加がなく、slice は安定して参照できる。
        return self.children.items;
    }

    fn propagateChildren(io: std.Io, items: []const CancelChild, reason: ContextError) void {
        for (items) |child| child.propagate(io, reason);
    }
};

const CancelCtx = struct {
    parent: Context,
    state: CancelState,

    fn deinit(self: *CancelCtx, allocator: std.mem.Allocator, io: std.Io) void {
        self.state.cancel(io, error.Canceled);
        self.state.deinit(allocator);
        allocator.destroy(self);
    }
};

const DeadlineCtx = struct {
    parent: Context,
    state: CancelState,
    deadline: std.Io.Clock.Timestamp,
    timer_thread: ?std.Thread,

    fn deinit(self: *DeadlineCtx, allocator: std.mem.Allocator, io: std.Io) void {
        self.state.cancel(io, error.Canceled);
        if (self.timer_thread) |t| t.join();
        self.state.deinit(allocator);
        allocator.destroy(self);
    }
};

const ValueCtx = struct {
    parent: Context,
    key: *const anyopaque,
    val: *anyopaque,
    val_deinit: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,

    fn deinit(self: *ValueCtx, allocator: std.mem.Allocator) void {
        self.val_deinit(allocator, self.val);
        allocator.destroy(self);
    }
};

const TimerArgs = struct {
    deadline: std.Io.Clock.Timestamp,
    state: *CancelState,
    io: std.Io,
};

pub fn TypedKey(comptime T: type) type {
    return struct {
        pub const Value = T;
        // var にすることで各 TypedKey(T) instantiation に固有のアドレスを確保する。
        // u0（zero-size）だとリンカが複数の定数を同一アドレスにマージする可能性がある。
        var marker: u8 = 0;
        pub const key: *anyopaque = &marker;
    };
}

pub fn withCancel(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: Context,
) error{OutOfMemory}!OwnedContext {
    const ctx = try allocator.create(CancelCtx);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .parent = parent,
        .state = CancelState.init(),
    };

    try registerChild(allocator, io, parent, .{ .cancel_ctx = ctx });

    return .{ .context = .{ .cancel_ctx = ctx } };
}

pub fn withDeadline(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: Context,
    dl: std.Io.Clock.Timestamp,
) (error{OutOfMemory} || std.Thread.SpawnError)!OwnedContext {
    const ctx = try allocator.create(DeadlineCtx);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .parent = parent,
        .state = CancelState.init(),
        .deadline = dl,
        .timer_thread = null,
    };

    if (tryDeadlineFastPath(io, parent, ctx)) return .{ .context = .{ .deadline_ctx = ctx } };

    try spawnTimerAndRegister(allocator, io, parent, ctx);

    return .{ .context = .{ .deadline_ctx = ctx } };
}

pub fn withTimeout(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: Context,
    timeout: std.Io.Clock.Duration,
) (error{OutOfMemory} || std.Thread.SpawnError)!OwnedContext {
    const dl = std.Io.Clock.Timestamp.fromNow(io, timeout);
    return withDeadline(allocator, io, parent, dl);
}

pub fn withTypedValue(
    allocator: std.mem.Allocator,
    parent: Context,
    comptime Key: type,
    val: Key.Value,
) error{OutOfMemory}!OwnedContext {
    const val_ptr = try allocator.create(Key.Value);
    errdefer allocator.destroy(val_ptr);

    val_ptr.* = val;

    const ctx = try allocator.create(ValueCtx);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .parent = parent,
        .key = Key.key,
        .val = @ptrCast(val_ptr),
        .val_deinit = deinitValue(Key.Value),
    };

    return .{ .context = .{ .value_ctx = ctx } };
}

fn deinitValue(comptime T: type) *const fn (std.mem.Allocator, *anyopaque) void {
    return struct {
        fn impl(alloc: std.mem.Allocator, ptr: *anyopaque) void {
            alloc.destroy(@as(*T, @ptrCast(@alignCast(ptr))));
        }
    }.impl;
}

fn tryDeadlineFastPath(io: std.Io, parent: Context, ctx: *DeadlineCtx) bool {
    if (ctx.deadline.durationFromNow(io).raw.nanoseconds > 0) return false;

    const cancel_err: ContextError = parent.err(io) orelse error.DeadlineExceeded;
    ctx.state.cancel(io, cancel_err);

    return true;
}

fn spawnTimerAndRegister(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: Context,
    ctx: *DeadlineCtx,
) (error{OutOfMemory} || std.Thread.SpawnError)!void {
    ctx.timer_thread = try std.Thread.spawn(
        .{},
        timerWorker,
        .{TimerArgs{ .deadline = ctx.deadline, .state = &ctx.state, .io = io }},
    );

    // OOM パス: 呼び出し元にコンテキストは渡らないため cancel_err 不要。タイマースレッドの早期終了のみ目的。
    errdefer {
        ctx.state.source.fire(io);
        if (ctx.timer_thread) |t| {
            t.join();
            ctx.timer_thread = null; // deinit が二重 join しないよう join 済みを示す。
        }
    }

    try registerChild(allocator, io, parent, .{ .deadline_ctx = ctx });
}

fn timerWorker(args: TimerArgs) void {
    const remaining = args.deadline.durationFromNow(args.io);
    const cancelled_early = args.state.source.waitTimeout(args.io, remaining);
    if (cancelled_early) return;
    args.state.cancel(args.io, error.DeadlineExceeded);
}

fn registerChild(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: Context,
    child: CancelState.CancelChild,
) error{OutOfMemory}!void {
    return switch (parent) {
        .background, .todo => {},
        .canceled => child.propagate(io, error.Canceled),
        .cancel_ctx => |p| try registerToState(allocator, io, &p.state, child),
        .deadline_ctx => |p| try registerToState(allocator, io, &p.state, child),
        .value_ctx => |v| try registerChild(allocator, io, v.parent, child),
    };
}

fn registerToState(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *CancelState,
    child: CancelState.CancelChild,
) error{OutOfMemory}!void {
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);

    if (state.cancel_err) |cerr| {
        // cancel と異なりロック保持中に propagate を呼ぶ。
        // 「すでにキャンセル済みの親に子を登録しようとした」ケースでは、
        // 子の追加とキャンセル判断をアトミックに保つためロックを手放せない。
        // 子の propagate が取るのは子自身の mutex であり、親の mutex を再取得しないためデッドロックは生じない。
        child.propagate(io, cerr);
    } else {
        try state.children.append(allocator, child);
    }
}

// --- canceled ---

test "canceled: 即座にdone" {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), canceled.err(io));
    try std.testing.expect(canceled.done().isFired());
}

// --- Context.done ---

test "Context.done: background/todoは発火しない" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Context,
        expected: bool,
    }{
        .{ .name = "background", .input = background, .expected = false },
        .{ .name = "todo", .input = todo, .expected = false },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        try std.testing.expectEqual(tc.expected, tc.input.done().isFired());
    }
}

test "Context.done: canceledは即座に発火済み" {
    try std.testing.expect(canceled.done().isFired());
}

test "Context.done: cancel_ctxはキャンセル後に発火する" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expect(!r.context.done().isFired());
    r.cancel(io);
    try std.testing.expect(r.context.done().isFired());
}

test "Context.done: deadline_ctxはキャンセル後に発火する" {
    const io = std.testing.io;
    const r = try withTimeout(
        std.testing.allocator,
        io,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expect(!r.context.done().isFired());
    r.cancel(io);
    try std.testing.expect(r.context.done().isFired());
}

test "Context.done: value_ctxは親に委譲する" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { parent: Context, val: u32 },
        expected: bool,
    }{
        .{ .name = "background", .input = .{ .parent = background, .val = 0 }, .expected = false },
        .{ .name = "todo", .input = .{ .parent = todo, .val = 0 }, .expected = false },
        .{ .name = "canceled", .input = .{ .parent = canceled, .val = 0 }, .expected = true },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        const r = try withTypedValue(std.testing.allocator, tc.input.parent, Key, tc.input.val);
        defer r.deinit(std.testing.allocator, io);
        try std.testing.expectEqual(tc.expected, r.context.done().isFired());
    }
}

// --- Context.err ---

test "Context.err: background/todoはnullを返す" {
    const io = std.testing.io;
    const test_cases = [_]struct {
        name: []const u8,
        input: Context,
        expected: ?ContextError,
    }{
        .{ .name = "background", .input = background, .expected = null },
        .{ .name = "todo", .input = todo, .expected = null },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        try std.testing.expectEqual(tc.expected, tc.input.err(io));
    }
}

test "Context.err: canceledはCanceledを返す" {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), canceled.err(io));
}

test "Context.err: cancel_ctxはキャンセル後にエラーを返す" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, null), r.context.err(io));
    r.cancel(io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), r.context.err(io));
}

test "Context.err: deadline_ctxはキャンセル後にエラーを返す" {
    const io = std.testing.io;
    const r = try withTimeout(
        std.testing.allocator,
        io,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, null), r.context.err(io));
    r.cancel(io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), r.context.err(io));
}

test "Context.err: value_ctxは親に委譲する" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const r = try withTypedValue(std.testing.allocator, canceled, Key, 42);
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), r.context.err(io));
}

// --- Context.deadline ---

test "Context.deadline: withDeadlineで設定した値を返す" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 10 * std.time.ns_per_s },
        .clock = .awake,
    };
    const r = try withDeadline(std.testing.allocator, io, background, dl);
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?std.Io.Clock.Timestamp, dl), r.context.deadline());
}

test "Context.deadline: withCancelはnullを返す" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?std.Io.Clock.Timestamp, null), r.context.deadline());
}

test "Context.deadline: background/todo/canceledはnullを返す" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Context,
        expected: ?std.Io.Clock.Timestamp,
    }{
        .{ .name = "background", .input = background, .expected = null },
        .{ .name = "todo", .input = todo, .expected = null },
        .{ .name = "canceled", .input = canceled, .expected = null },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        try std.testing.expectEqual(tc.expected, tc.input.deadline());
    }
}

test "Context.deadline: value_ctxは親に委譲する" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 10 * std.time.ns_per_s },
        .clock = .awake,
    };
    const base = try withDeadline(std.testing.allocator, io, background, dl);
    defer base.deinit(std.testing.allocator, io);
    const child = try withTypedValue(std.testing.allocator, base.context, Key, 42);
    defer child.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?std.Io.Clock.Timestamp, dl), child.context.deadline());
}

// --- Context.typedValue ---

test "Context.typedValue: 対応するキーの値を返す" {
    const Key = TypedKey(u32);
    const r = try withTypedValue(std.testing.allocator, background, Key, 42);
    defer r.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(?u32, 42), r.context.typedValue(Key));
}

test "Context.typedValue: 存在しないキーはnullを返す" {
    const Key1 = TypedKey(u32);
    const Key2 = TypedKey(u64);
    const r = try withTypedValue(std.testing.allocator, background, Key1, 42);
    defer r.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(?u64, null), r.context.typedValue(Key2));
}

test "Context.typedValue: background/todo/canceledはnullを返す" {
    const Key = TypedKey(u32);
    const test_cases = [_]struct {
        name: []const u8,
        input: Context,
        expected: ?u32,
    }{
        .{ .name = "background", .input = background, .expected = null },
        .{ .name = "todo", .input = todo, .expected = null },
        .{ .name = "canceled", .input = canceled, .expected = null },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        try std.testing.expectEqual(tc.expected, tc.input.typedValue(Key));
    }
}

// --- Context.rawValue ---

test "Context.rawValue: background/todo/canceledはnullを返す" {
    const Key = TypedKey(u32);
    const test_cases = [_]struct {
        name: []const u8,
        input: Context,
        expected: ?*anyopaque,
    }{
        .{ .name = "background", .input = background, .expected = null },
        .{ .name = "todo", .input = todo, .expected = null },
        .{ .name = "canceled", .input = canceled, .expected = null },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        try std.testing.expectEqual(tc.expected, tc.input.rawValue(Key.key));
    }
}

test "Context.rawValue: cancel_ctxを経由して先祖のvalue_ctxに委譲する" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const base = try withTypedValue(std.testing.allocator, background, Key, 42);
    defer base.deinit(std.testing.allocator, io);
    const child = try withCancel(std.testing.allocator, io, base.context);
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expect(child.context.rawValue(Key.key) != null);
}

test "Context.rawValue: deadline_ctxを経由して先祖のvalue_ctxに委譲する" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const base = try withTypedValue(std.testing.allocator, background, Key, 42);
    defer base.deinit(std.testing.allocator, io);
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const child = try withDeadline(std.testing.allocator, io, base.context, .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    });
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expect(child.context.rawValue(Key.key) != null);
}

// --- OwnedContext.deinit ---

test "OwnedContext.deinit: background/todo/canceledはメモリ解放不要" {
    const io = std.testing.io;
    const test_cases = [_]struct {
        name: []const u8,
        input: OwnedContext,
    }{
        .{ .name = "background", .input = .{ .context = background } },
        .{ .name = "todo", .input = .{ .context = todo } },
        .{ .name = "canceled", .input = .{ .context = canceled } },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        tc.input.deinit(std.testing.allocator, io);
    }
}

test "OwnedContext.deinit: cancel_ctxのメモリを解放する" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    r.deinit(std.testing.allocator, io);
}

test "OwnedContext.deinit: deadline_ctxのメモリを解放する" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const r = try withDeadline(std.testing.allocator, io, background, future);
    r.deinit(std.testing.allocator, io);
}

test "OwnedContext.deinit: value_ctxのメモリを解放する" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const r = try withTypedValue(std.testing.allocator, background, Key, 42);
    r.deinit(std.testing.allocator, io);
}

// --- OwnedContext.cancel ---

test "OwnedContext.cancel: background/todo/canceledはcancel後もdoneの状態が変わらない" {
    const io = std.testing.io;
    const test_cases = [_]struct {
        name: []const u8,
        input: OwnedContext,
        expected: bool,
    }{
        .{ .name = "background", .input = .{ .context = background }, .expected = false },
        .{ .name = "todo", .input = .{ .context = todo }, .expected = false },
        .{ .name = "canceled", .input = .{ .context = canceled }, .expected = true },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        tc.input.cancel(io);
        try std.testing.expectEqual(tc.expected, tc.input.context.done().isFired());
    }
}

test "OwnedContext.cancel: cancel_ctxはcancel後にdoneになり冪等" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    defer r.deinit(std.testing.allocator, io);
    r.cancel(io);
    r.cancel(io);
    try std.testing.expect(r.context.done().isFired());
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), r.context.err(io));
}

test "OwnedContext.cancel: deadline_ctxはcancel後にdoneになり冪等" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 10 * std.time.ns_per_s },
        .clock = .awake,
    };
    const r = try withDeadline(std.testing.allocator, io, background, dl);
    defer r.deinit(std.testing.allocator, io);
    r.cancel(io);
    r.cancel(io);
    try std.testing.expect(r.context.done().isFired());
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), r.context.err(io));
}

test "OwnedContext.cancel: value_ctxはcancel後もdoneでない" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const r = try withTypedValue(std.testing.allocator, background, Key, 42);
    defer r.deinit(std.testing.allocator, io);
    r.cancel(io);
    r.cancel(io);
    try std.testing.expect(!r.context.done().isFired());
}

// --- CancelState.CancelChild.propagate ---

test "CancelState.CancelChild.propagate: cancel_ctxブランチに伝播する" {
    const io = std.testing.io;
    var child_ctx = CancelCtx{ .parent = background, .state = CancelState.init() };
    defer child_ctx.state.deinit(std.testing.allocator);

    const child: CancelState.CancelChild = .{ .cancel_ctx = &child_ctx };
    child.propagate(io, error.Canceled);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child_ctx.state.cancel_err);
}

test "CancelState.CancelChild.propagate: deadline_ctxブランチに伝播する" {
    const io = std.testing.io;
    var child_ctx: DeadlineCtx = .{
        .parent = background,
        .state = CancelState.init(),
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
    };
    defer child_ctx.state.deinit(std.testing.allocator);

    const child: CancelState.CancelChild = .{ .deadline_ctx = &child_ctx };
    child.propagate(io, error.Canceled);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child_ctx.state.cancel_err);
}

// --- CancelState.init ---

test "CancelState.init: 初期状態を正しく生成する" {
    var state = CancelState.init();
    try std.testing.expectEqual(@as(?ContextError, null), state.cancel_err);
    try std.testing.expectEqual(@as(usize, 0), state.children.items.len);
    try std.testing.expect(!state.source.signal().isFired());
}

// --- CancelState.deinit ---

test "CancelState.deinit: childrenのメモリを解放する" {
    var state = CancelState.init();
    var child_ctx = CancelCtx{ .parent = background, .state = CancelState.init() };
    defer child_ctx.state.deinit(std.testing.allocator);
    try state.children.append(std.testing.allocator, .{ .cancel_ctx = &child_ctx });
    state.deinit(std.testing.allocator);
}

// --- CancelState.cancel ---

test "CancelState.cancel: cancel_errを設定しシグナルを発火する" {
    const io = std.testing.io;
    var state = CancelState.init();
    state.cancel(io, error.Canceled);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), state.cancel_err);
    try std.testing.expect(state.source.signal().isFired());
}

test "CancelState.cancel: 冪等性（二度呼んでも最初の理由を保持する）" {
    const io = std.testing.io;
    var state = CancelState.init();
    state.cancel(io, error.Canceled);
    state.cancel(io, error.DeadlineExceeded);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), state.cancel_err);
}

test "CancelState.cancel: 子コンテキストに伝播する" {
    const io = std.testing.io;

    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = background,
        .state = CancelState.init(),
    };
    defer child.deinit(std.testing.allocator, io);

    {
        var parent_state = CancelState.init();
        defer parent_state.deinit(std.testing.allocator);
        try parent_state.children.append(std.testing.allocator, .{ .cancel_ctx = child });
        parent_state.cancel(io, error.Canceled);
        try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.state.cancel_err);
    }
}

test "CancelState.cancel: deadline_ctx子コンテキストに伝播する" {
    const io = std.testing.io;

    const child = try std.testing.allocator.create(DeadlineCtx);
    child.* = .{
        .parent = background,
        .state = CancelState.init(),
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
    };
    defer child.deinit(std.testing.allocator, io);

    {
        var parent_state = CancelState.init();
        defer parent_state.deinit(std.testing.allocator);
        try parent_state.children.append(std.testing.allocator, .{ .deadline_ctx = child });
        parent_state.cancel(io, error.Canceled);
        try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.state.cancel_err);
    }
}

// --- CancelState.acquireCancelLock ---

test "CancelState.acquireCancelLock: 未キャンセル時にchildrenを返す" {
    const io = std.testing.io;
    var state = CancelState.init();
    defer state.deinit(std.testing.allocator);

    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = background,
        .state = CancelState.init(),
    };
    defer child.deinit(std.testing.allocator, io);
    try state.children.append(std.testing.allocator, .{ .cancel_ctx = child });

    const result = state.acquireCancelLock(io, error.Canceled);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), state.cancel_err);
}

test "CancelState.acquireCancelLock: キャンセル済み時にnullを返す" {
    const io = std.testing.io;
    var state = CancelState.init();
    state.cancel(io, error.Canceled);

    const result = state.acquireCancelLock(io, error.DeadlineExceeded);
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), state.cancel_err);
}

// --- CancelState.propagateChildren ---

test "CancelState.propagateChildren: cancel_ctx子コンテキストに伝播する" {
    const io = std.testing.io;

    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = background,
        .state = CancelState.init(),
    };
    defer child.deinit(std.testing.allocator, io);

    const items = [_]CancelState.CancelChild{.{ .cancel_ctx = child }};
    CancelState.propagateChildren(io, &items, error.Canceled);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.state.cancel_err);
}

test "CancelState.propagateChildren: deadline_ctx子コンテキストに伝播する" {
    const io = std.testing.io;

    const child = try std.testing.allocator.create(DeadlineCtx);
    child.* = .{
        .parent = background,
        .state = CancelState.init(),
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
    };
    defer child.deinit(std.testing.allocator, io);

    const items = [_]CancelState.CancelChild{.{ .deadline_ctx = child }};
    CancelState.propagateChildren(io, &items, error.Canceled);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.state.cancel_err);
}

// --- CancelCtx.deinit ---

test "CancelCtx.deinit: メモリを解放する" {
    const io = std.testing.io;
    const ctx = try std.testing.allocator.create(CancelCtx);
    ctx.* = .{
        .parent = background,
        .state = CancelState.init(),
    };
    ctx.deinit(std.testing.allocator, io);
}

// --- DeadlineCtx.deinit ---

test "DeadlineCtx.deinit: timer_threadがnullのときメモリを解放する" {
    const io = std.testing.io;
    const past: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };
    const r = try withDeadline(std.testing.allocator, io, background, past);
    r.deinit(std.testing.allocator, io);
}

test "DeadlineCtx.deinit: timer_threadをjoinしてメモリを解放する" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const r = try withDeadline(std.testing.allocator, io, background, future);
    r.deinit(std.testing.allocator, io);
}

// --- ValueCtx.deinit ---

test "ValueCtx.deinit: 値とコンテキストのメモリを解放する" {
    const Key = TypedKey(u32);
    const r = try withTypedValue(std.testing.allocator, background, Key, 42);
    r.deinit(std.testing.allocator, std.testing.io);
}

// --- TypedKey ---

test "TypedKey: 型ごとに固有のキーを返す" {
    const K1 = TypedKey(u32);
    const K2 = TypedKey(u64);
    try std.testing.expect(K1.key != K2.key);
}

// --- withCancel ---

test "withCancel: 初期状態はdoneでない" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, null), r.context.err(io));
}

test "withCancel: cancel後はdone" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    defer r.deinit(std.testing.allocator, io);
    r.cancel(io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), r.context.err(io));
}

test "withCancel: cancelはidempotent" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    defer r.deinit(std.testing.allocator, io);
    r.cancel(io);
    r.cancel(io);
}

test "withCancel: cancelなしでdeinitしてもリークなし" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    r.deinit(std.testing.allocator, io);
}

test "withCancel: 親cancelが子に伝播する" {
    const io = std.testing.io;
    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);
    const child = try withCancel(std.testing.allocator, io, parent.context);
    defer child.deinit(std.testing.allocator, io);

    parent.cancel(io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context.err(io));
}

test "withCancel: 子cancelは親に影響しない" {
    const io = std.testing.io;
    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);
    const child = try withCancel(std.testing.allocator, io, parent.context);
    defer child.deinit(std.testing.allocator, io);

    child.cancel(io);
    try std.testing.expectEqual(@as(?ContextError, null), parent.context.err(io));
}

test "withCancel: キャンセル済み親から作った子は即座にdone" {
    const io = std.testing.io;
    const parent = try withCancel(std.testing.allocator, io, background);
    parent.cancel(io);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withCancel(std.testing.allocator, io, parent.context);
    defer child.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context.err(io));
}

test "withCancel: canceledを親にすると即座にdone" {
    const io = std.testing.io;
    const child = try withCancel(std.testing.allocator, io, canceled);
    defer child.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context.err(io));
}

test "withCancel: done().waitTimeout は未キャンセルならfalseを返す" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    defer r.deinit(std.testing.allocator, io);
    const fired = r.context.done().waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
    );
    try std.testing.expect(!fired);
}

test "withCancel: done().waitTimeout はcancel後にtrueを返す" {
    const io = std.testing.io;
    const r = try withCancel(std.testing.allocator, io, background);
    defer r.deinit(std.testing.allocator, io);
    r.cancel(io);
    const fired = r.context.done().waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 1 * std.time.ns_per_s }, .clock = .awake },
    );
    try std.testing.expect(fired);
}

test "withCancel: registerChildのOutOfMemoryでリークなし" {
    const io = std.testing.io;
    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const alloc = failing.allocator();

    try std.testing.expectError(
        error.OutOfMemory,
        withCancel(alloc, io, parent.context),
    );
}

// --- withDeadline ---

test "withDeadline: 過去のdeadlineは即座にDeadlineExceeded（fast-path）" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const past: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns - 1 },
        .clock = .awake,
    };
    const r = try withDeadline(std.testing.allocator, io, background, past);
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, error.DeadlineExceeded), r.context.err(io));
    try std.testing.expect(r.context.done().isFired());
}

test "withDeadline: 未来のdeadlineは初期状態がdoneでない" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const r = try withDeadline(std.testing.allocator, io, background, future);
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expect(!r.context.done().isFired());
}

test "withDeadline: 親がキャンセル済みのfast-pathはCanceled" {
    const io = std.testing.io;
    const parent = try withCancel(std.testing.allocator, io, background);
    parent.cancel(io);
    defer parent.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const past: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns - 1 },
        .clock = .awake,
    };
    const child = try withDeadline(std.testing.allocator, io, parent.context, past);
    defer child.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context.err(io));
}

test "withDeadline: registerChildのOutOfMemoryでスレッドリークなし" {
    const io = std.testing.io;
    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const alloc = failing.allocator();

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    try std.testing.expectError(
        error.OutOfMemory,
        withDeadline(alloc, io, parent.context, future),
    );
}

// --- withTimeout ---

test "withTimeout: 期限到達でDeadlineExceeded" {
    const io = std.testing.io;
    const r = try withTimeout(
        std.testing.allocator,
        io,
        background,
        .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
    );
    defer r.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, error.DeadlineExceeded), r.context.err(io));
    try std.testing.expect(r.context.done().isFired());
}

test "withTimeout: 期限前にcancel → Canceled" {
    const io = std.testing.io;
    const r = try withTimeout(
        std.testing.allocator,
        io,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    defer r.deinit(std.testing.allocator, io);

    r.cancel(io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), r.context.err(io));
}

test "withTimeout: cancel後にdeinitしてもブロックしない" {
    const io = std.testing.io;
    const r = try withTimeout(
        std.testing.allocator,
        io,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    r.cancel(io);
    r.deinit(std.testing.allocator, io);
}

test "withTimeout: registerChildのOutOfMemoryでスレッドリークなし" {
    const io = std.testing.io;
    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const alloc = failing.allocator();

    try std.testing.expectError(
        error.OutOfMemory,
        withTimeout(
            alloc,
            io,
            parent.context,
            .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
        ),
    );
}

// --- withTypedValue ---

test "withTypedValue: 対応するキーの値を返す" {
    const Key = TypedKey(u32);
    const r = try withTypedValue(std.testing.allocator, background, Key, 42);
    defer r.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(?u32, 42), r.context.typedValue(Key));
}

test "withTypedValue: 親チェーンを辿って値を返す" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const base = try withTypedValue(std.testing.allocator, background, Key, 42);
    defer base.deinit(std.testing.allocator, io);
    const child = try withCancel(std.testing.allocator, io, base.context);
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?u32, 42), child.context.typedValue(Key));
}

test "withTypedValue: キーが違えばnullを返す" {
    const Key1 = TypedKey(u32);
    const Key2 = TypedKey(u64);
    const r = try withTypedValue(std.testing.allocator, background, Key1, 42);
    defer r.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(?u64, null), r.context.typedValue(Key2));
}

test "withTypedValue: cancelは何もしない（value_ctxはキャンセル機構を持たない）" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const r = try withTypedValue(std.testing.allocator, background, Key, 42);
    defer r.deinit(std.testing.allocator, io);
    r.cancel(io);
    try std.testing.expect(!r.context.done().isFired());
    try std.testing.expectEqual(@as(?u32, 42), r.context.typedValue(Key));
}

test "withTypedValue: val_ptrのOutOfMemoryでリークなし" {
    const Key = TypedKey(u32);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();

    try std.testing.expectError(
        error.OutOfMemory,
        withTypedValue(alloc, background, Key, 42),
    );
}

test "withTypedValue: ctxのOutOfMemoryでリークなし" {
    const Key = TypedKey(u32);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const alloc = failing.allocator();

    try std.testing.expectError(
        error.OutOfMemory,
        withTypedValue(alloc, background, Key, 42),
    );
}

// --- deinitValue ---

test "deinitValue: 型に対応するデストラクタ関数を返す" {
    const ptr = try std.testing.allocator.create(u32);
    ptr.* = 42;
    const deinit_fn = deinitValue(u32);
    deinit_fn(std.testing.allocator, ptr);
}

// --- tryDeadlineFastPath ---

test "tryDeadlineFastPath: deadlineが現在時刻以前ならDeadlineExceeded" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = now_ns }, .clock = .awake };
    const ctx = try std.testing.allocator.create(DeadlineCtx);
    ctx.* = .{
        .parent = background,
        .state = CancelState.init(),
        .deadline = dl,
        .timer_thread = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    try std.testing.expect(tryDeadlineFastPath(io, background, ctx));
    try std.testing.expectEqual(@as(?ContextError, error.DeadlineExceeded), ctx.state.cancel_err);
}

test "tryDeadlineFastPath: 親がキャンセル済みならCanceledを引き継ぐ" {
    const io = std.testing.io;
    const parent = try withCancel(std.testing.allocator, io, background);
    parent.cancel(io);
    defer parent.deinit(std.testing.allocator, io);
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = now_ns }, .clock = .awake };
    const ctx = try std.testing.allocator.create(DeadlineCtx);
    ctx.* = .{
        .parent = parent.context,
        .state = CancelState.init(),
        .deadline = dl,
        .timer_thread = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    try std.testing.expect(tryDeadlineFastPath(io, parent.context, ctx));
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), ctx.state.cancel_err);
}

test "tryDeadlineFastPath: deadlineが現在時刻より未来ならfalseを返す" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const ctx = try std.testing.allocator.create(DeadlineCtx);
    ctx.* = .{
        .parent = background,
        .state = CancelState.init(),
        .deadline = dl,
        .timer_thread = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    try std.testing.expect(!tryDeadlineFastPath(io, background, ctx));
    try std.testing.expectEqual(@as(?ContextError, null), ctx.state.cancel_err);
}

// --- spawnTimerAndRegister ---

test "spawnTimerAndRegister: スレッドを起動し子を登録する" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    const ctx = try std.testing.allocator.create(DeadlineCtx);
    ctx.* = .{
        .parent = parent.context,
        .state = CancelState.init(),
        .deadline = .{
            .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
            .clock = .awake,
        },
        .timer_thread = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    try spawnTimerAndRegister(std.testing.allocator, io, parent.context, ctx);
    try std.testing.expect(ctx.timer_thread != null);
    parent.cancel(io);
}

test "spawnTimerAndRegister: registerChildのOutOfMemoryでスレッドリークなし" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    const ctx = try std.testing.allocator.create(DeadlineCtx);
    ctx.* = .{
        .parent = parent.context,
        .state = CancelState.init(),
        .deadline = .{
            .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
            .clock = .awake,
        },
        .timer_thread = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        spawnTimerAndRegister(failing.allocator(), io, parent.context, ctx),
    );
}

// --- timerWorker ---

test "timerWorker: durationFromNowが非正なとき即座にDeadlineExceededにする" {
    const io = std.testing.io;
    var state = CancelState.init();
    defer state.deinit(std.testing.allocator);

    timerWorker(.{
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .state = &state,
        .io = io,
    });

    try std.testing.expectEqual(@as(?ContextError, error.DeadlineExceeded), state.cancel_err);
}

test "timerWorker: waitTimeoutがtrueのとき早期リターンしDeadlineExceededにならない" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    var state = CancelState.init();
    defer state.deinit(std.testing.allocator);

    state.source.fire(io);
    timerWorker(.{
        .deadline = .{
            .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
            .clock = .awake,
        },
        .state = &state,
        .io = io,
    });

    try std.testing.expectEqual(@as(?ContextError, null), state.cancel_err);
}

// --- registerChild ---

test "registerChild: backgroundは子を追加しない" {
    const io = std.testing.io;
    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = background,
        .state = CancelState.init(),
    };
    defer child.deinit(std.testing.allocator, io);

    try registerChild(std.testing.allocator, io, background, .{ .cancel_ctx = child });
    try std.testing.expectEqual(@as(?ContextError, null), child.state.cancel_err);
}

test "registerChild: canceledは即座に伝播する" {
    const io = std.testing.io;
    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = canceled,
        .state = CancelState.init(),
    };
    defer child.deinit(std.testing.allocator, io);

    try registerChild(std.testing.allocator, io, canceled, .{ .cancel_ctx = child });
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.state.cancel_err);
}

test "registerChild: deadline_ctxは子を登録する" {
    const io = std.testing.io;
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const parent = try withDeadline(std.testing.allocator, io, background, future);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withCancel(std.testing.allocator, io, parent.context);
    defer child.deinit(std.testing.allocator, io);

    parent.cancel(io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context.err(io));
}

test "registerChild: value_ctxは親に委譲する" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const value_parent = try withTypedValue(std.testing.allocator, canceled, Key, 42);
    defer value_parent.deinit(std.testing.allocator, io);

    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = background,
        .state = CancelState.init(),
    };
    defer child.deinit(std.testing.allocator, io);

    try registerChild(std.testing.allocator, io, value_parent.context, .{ .cancel_ctx = child });
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.state.cancel_err);
}

// --- registerToState ---

test "registerToState: 未キャンセルなら子を登録する" {
    const io = std.testing.io;
    var parent_state = CancelState.init();
    defer parent_state.deinit(std.testing.allocator);

    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = background,
        .state = CancelState.init(),
    };
    defer child.deinit(std.testing.allocator, io);

    try registerToState(std.testing.allocator, io, &parent_state, .{ .cancel_ctx = child });
    try std.testing.expectEqual(@as(usize, 1), parent_state.children.items.len);

    parent_state.cancel(io, error.Canceled);
}

test "registerToState: キャンセル済みなら即座に子へ伝播する" {
    const io = std.testing.io;
    var parent_state = CancelState.init();
    parent_state.cancel(io, error.Canceled);

    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = background,
        .state = CancelState.init(),
    };
    defer child.deinit(std.testing.allocator, io);

    try registerToState(std.testing.allocator, io, &parent_state, .{ .cancel_ctx = child });
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.state.cancel_err);
}
