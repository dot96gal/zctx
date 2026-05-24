const std = @import("std");
const context_mod = @import("context.zig");

const background = context_mod.background;
const canceled = context_mod.canceled;
const Context = context_mod.Context;
const ContextError = context_mod.ContextError;
const CancelState = context_mod.CancelState;
const CancelCtx = context_mod.CancelCtx;
const DeadlineCtx = context_mod.DeadlineCtx;
const ValueCtx = context_mod.ValueCtx;
const TypedKey = context_mod.TypedKey;

pub const OwnedCancelScope = struct {
    cancel_ctx: *CancelCtx,

    pub fn deinit(self: OwnedCancelScope, allocator: std.mem.Allocator, io: std.Io) void {
        self.cancel_ctx.deinit(allocator, io);
    }

    pub fn context(self: OwnedCancelScope) Context {
        return .{ .cancel_ctx = self.cancel_ctx };
    }

    pub fn cancel(self: OwnedCancelScope, io: std.Io) void {
        self.cancel_ctx.cancel_state.cancel(io, error.Canceled);
    }
};

pub const OwnedDeadlineScope = struct {
    deadline_ctx: *DeadlineCtx,

    pub fn deinit(self: OwnedDeadlineScope, allocator: std.mem.Allocator, io: std.Io) void {
        self.deadline_ctx.deinit(allocator, io);
    }

    pub fn context(self: OwnedDeadlineScope) Context {
        return .{ .deadline_ctx = self.deadline_ctx };
    }

    pub fn cancel(self: OwnedDeadlineScope, io: std.Io) void {
        // 明示的なユーザーキャンセルは Canceled を設定する。DeadlineExceeded はタイマーが設定する。
        self.deadline_ctx.cancel_state.cancel(io, error.Canceled);
    }
};

pub const OwnedValueScope = struct {
    value_ctx: *ValueCtx,

    pub fn deinit(self: OwnedValueScope, allocator: std.mem.Allocator) void {
        self.value_ctx.deinit(allocator);
    }

    pub fn context(self: OwnedValueScope) Context {
        return .{ .value_ctx = self.value_ctx };
    }
};

const TimerArgs = struct {
    cancel_state: *CancelState,
    io: std.Io,
    deadline: std.Io.Clock.Timestamp,
};

pub fn withCancel(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: Context,
) error{OutOfMemory}!OwnedCancelScope {
    const ctx = try allocator.create(CancelCtx);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .parent = parent,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = resolveParentState(parent),
    };

    try registerChild(allocator, io, parent, .{ .cancel_ctx = ctx });

    return .{ .cancel_ctx = ctx };
}

pub fn withDeadline(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: Context,
    dl: std.Io.Clock.Timestamp,
) (error{OutOfMemory} || std.Thread.SpawnError)!OwnedDeadlineScope {
    const ctx = try allocator.create(DeadlineCtx);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .parent = parent,
        .cancel_state = CancelState.init(),
        .deadline = dl,
        .timer_thread = null,
        .parent_cancel_state = resolveParentState(parent),
    };

    if (tryDeadlineFastPath(io, parent, ctx)) return .{ .deadline_ctx = ctx };

    try spawnTimerAndRegister(allocator, io, parent, ctx);

    return .{ .deadline_ctx = ctx };
}

pub fn withTimeout(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: Context,
    timeout: std.Io.Clock.Duration,
) (error{OutOfMemory} || std.Thread.SpawnError)!OwnedDeadlineScope {
    const dl = std.Io.Clock.Timestamp.fromNow(io, timeout);
    return withDeadline(allocator, io, parent, dl);
}

pub fn withTypedValue(
    allocator: std.mem.Allocator,
    parent: Context,
    comptime Key: type,
    val: Key.Value,
) error{OutOfMemory}!OwnedValueScope {
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

    return .{ .value_ctx = ctx };
}

fn resolveParentState(parent: Context) ?*CancelState {
    return switch (parent) {
        .background, .todo, .canceled => null,
        .cancel_ctx => |p| &p.cancel_state,
        .deadline_ctx => |p| &p.cancel_state,
        .value_ctx => |v| resolveParentState(v.parent),
    };
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
    ctx.cancel_state.cancel(io, cancel_err);

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
        .{TimerArgs{ .cancel_state = &ctx.cancel_state, .io = io, .deadline = ctx.deadline }},
    );

    // OOM パス: 呼び出し元にコンテキストは渡らないため cancel_err 不要。タイマースレッドの早期終了のみ目的。
    errdefer {
        ctx.cancel_state.source.fire(io);
        if (ctx.timer_thread) |t| {
            t.join();
            ctx.timer_thread = null; // deinit が二重 join しないよう join 済みを示す。
        }
    }

    try registerChild(allocator, io, parent, .{ .deadline_ctx = ctx });
}

fn timerWorker(args: TimerArgs) void {
    const remaining = args.deadline.durationFromNow(args.io);

    const cancelled_early = args.cancel_state.source.waitTimeout(args.io, remaining);
    if (cancelled_early) return;

    args.cancel_state.cancel(args.io, error.DeadlineExceeded);
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
        .cancel_ctx => |p| try registerToState(allocator, io, &p.cancel_state, child),
        .deadline_ctx => |p| try registerToState(allocator, io, &p.cancel_state, child),
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
        // キャンセル済みの場合のみロック保持中に propagate を呼ぶ。子の propagate は子自身の mutex を取るため安全。
        child.propagate(io, cerr);
    } else {
        try state.children.append(allocator, child);
    }
}

// --- OwnedCancelScope.deinit ---

test "OwnedCancelScope.deinit: cancel_ctxのメモリを解放する" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    scope.deinit(std.testing.allocator, io);
}

// --- OwnedCancelScope.context ---

test "OwnedCancelScope.context: cancel_ctxを返す" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    const ctx = scope.context();
    try std.testing.expect(ctx == .cancel_ctx);
    try std.testing.expectEqual(scope.cancel_ctx, ctx.cancel_ctx);
}

// --- OwnedCancelScope.cancel ---

test "OwnedCancelScope.cancel: cancel後にdoneになり冪等" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);
    scope.cancel(io);

    try std.testing.expect(scope.context().done().isFired());
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), scope.context().err(io));
}

// --- OwnedCancelScope ---

test "OwnedCancelScope: cancel()メソッドを持つ" {
    try std.testing.expect(@hasDecl(OwnedCancelScope, "cancel"));
}

// --- OwnedDeadlineScope.deinit ---

test "OwnedDeadlineScope.deinit: deadline_ctxのメモリを解放する" {
    const io = std.testing.io;

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const scope = try withDeadline(std.testing.allocator, io, background, future);
    scope.deinit(std.testing.allocator, io);
}

test "OwnedDeadlineScope.deinit: timer_threadがnullのときメモリを解放する" {
    const io = std.testing.io;

    const past: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };
    const scope = try withDeadline(std.testing.allocator, io, background, past);
    scope.deinit(std.testing.allocator, io);
}

// --- OwnedDeadlineScope.context ---

test "OwnedDeadlineScope.context: deadline_ctxを返す" {
    const io = std.testing.io;

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const scope = try withDeadline(std.testing.allocator, io, background, future);
    defer scope.deinit(std.testing.allocator, io);

    const ctx = scope.context();
    try std.testing.expect(ctx == .deadline_ctx);
    try std.testing.expectEqual(scope.deadline_ctx, ctx.deadline_ctx);
}

// --- OwnedDeadlineScope.cancel ---

test "OwnedDeadlineScope.cancel: cancel後にdoneになり冪等" {
    const io = std.testing.io;

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 10 * std.time.ns_per_s },
        .clock = .awake,
    };
    const scope = try withDeadline(std.testing.allocator, io, background, dl);
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);
    scope.cancel(io);

    try std.testing.expect(scope.context().done().isFired());
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), scope.context().err(io));
}

// --- OwnedDeadlineScope ---

test "OwnedDeadlineScope: cancel()メソッドを持つ" {
    try std.testing.expect(@hasDecl(OwnedDeadlineScope, "cancel"));
}

// --- OwnedValueScope.deinit ---

test "OwnedValueScope.deinit: 値とコンテキストのメモリを解放する" {
    const Key = TypedKey(u32);

    const scope = try withTypedValue(std.testing.allocator, background, Key, 42);
    scope.deinit(std.testing.allocator);
}

// --- OwnedValueScope ---

test "OwnedValueScope: cancel()メソッドを持たない" {
    try std.testing.expect(!@hasDecl(OwnedValueScope, "cancel"));
}

// --- withCancel ---

test "withCancel: 初期状態はdoneでない" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?ContextError, null), scope.context().err(io));
}

test "withCancel: cancel後はdone" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), scope.context().err(io));
}

test "withCancel: cancel後にdone()が発火する" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expect(!scope.context().done().isFired());
    scope.cancel(io);
    try std.testing.expect(scope.context().done().isFired());
}

test "withCancel: cancelはidempotent" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);
    scope.cancel(io);
}

test "withCancel: 親cancelが子に伝播する" {
    const io = std.testing.io;

    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withCancel(std.testing.allocator, io, parent.context());
    defer child.deinit(std.testing.allocator, io);

    parent.cancel(io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context().err(io));
}

test "withCancel: 子cancelは親に影響しない" {
    const io = std.testing.io;

    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withCancel(std.testing.allocator, io, parent.context());
    defer child.deinit(std.testing.allocator, io);

    child.cancel(io);

    try std.testing.expectEqual(@as(?ContextError, null), parent.context().err(io));
}

test "withCancel: キャンセル済み親から作った子は即座にdone" {
    const io = std.testing.io;

    const parent = try withCancel(std.testing.allocator, io, background);
    parent.cancel(io);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withCancel(std.testing.allocator, io, parent.context());
    defer child.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context().err(io));
}

test "withCancel: canceledを親にすると即座にdone" {
    const io = std.testing.io;

    const child = try withCancel(std.testing.allocator, io, canceled);
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context().err(io));
}

test "withCancel: done().waitTimeout は未キャンセルならfalseを返す" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);
    const fired = scope.context().done().waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
    );

    try std.testing.expect(!fired);
}

test "withCancel: done().waitTimeout はcancel後にtrueを返す" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);

    const fired = scope.context().done().waitTimeout(
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
        withCancel(alloc, io, parent.context()),
    );
}

test "withCancel: 子deinit後に親cancelしてもクラッシュしない" {
    const io = std.testing.io;

    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withCancel(std.testing.allocator, io, parent.context());
    child.deinit(std.testing.allocator, io);

    parent.cancel(io);
}

test "withCancel: 子deinit後に親のchildren数が減る" {
    const io = std.testing.io;

    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    const child1 = try withCancel(std.testing.allocator, io, parent.context());
    child1.deinit(std.testing.allocator, io);

    const child2 = try withCancel(std.testing.allocator, io, parent.context());
    defer child2.deinit(std.testing.allocator, io);

    parent.cancel(io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child2.context().err(io));
}

test "withCancel: 複数子のうち一つdeinitしても他には伝播される" {
    const io = std.testing.io;

    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    const child1 = try withCancel(std.testing.allocator, io, parent.context());
    const child2 = try withCancel(std.testing.allocator, io, parent.context());
    defer child2.deinit(std.testing.allocator, io);

    child1.deinit(std.testing.allocator, io);

    parent.cancel(io);

    try std.testing.expect(child2.context().done().isFired());
}

// --- withDeadline ---

test "withDeadline: 過去のdeadlineは即座にDeadlineExceeded（fast-path）" {
    const io = std.testing.io;

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const past: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns - 1 },
        .clock = .awake,
    };
    const scope = try withDeadline(std.testing.allocator, io, background, past);
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(
        @as(?ContextError, error.DeadlineExceeded),
        scope.context().err(io),
    );
    try std.testing.expect(scope.context().done().isFired());
}

test "withDeadline: 未来のdeadlineは初期状態がdoneでない" {
    const io = std.testing.io;

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const scope = try withDeadline(std.testing.allocator, io, background, future);
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expect(!scope.context().done().isFired());
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
    const child = try withDeadline(std.testing.allocator, io, parent.context(), past);
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context().err(io));
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
        withDeadline(alloc, io, parent.context(), future),
    );
}

test "withDeadline: 子deinit後に親cancelしてもクラッシュしない" {
    const io = std.testing.io;

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const parent = try withDeadline(std.testing.allocator, io, background, future);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withCancel(std.testing.allocator, io, parent.context());
    child.deinit(std.testing.allocator, io);

    parent.cancel(io);
}

// --- withTimeout ---

test "withTimeout: 期限到達でDeadlineExceeded" {
    const io = std.testing.io;

    const scope = try withTimeout(
        std.testing.allocator,
        io,
        background,
        .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
    );
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(
        @as(?ContextError, error.DeadlineExceeded),
        scope.context().err(io),
    );
    try std.testing.expect(scope.context().done().isFired());
}

test "withTimeout: cancel前のerr()はnull" {
    const io = std.testing.io;

    const scope = try withTimeout(
        std.testing.allocator,
        io,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?ContextError, null), scope.context().err(io));
}

test "withTimeout: 期限前にcancel → Canceled" {
    const io = std.testing.io;

    const scope = try withTimeout(
        std.testing.allocator,
        io,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), scope.context().err(io));
}

test "withTimeout: cancel後にdone()が発火する" {
    const io = std.testing.io;

    const scope = try withTimeout(
        std.testing.allocator,
        io,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expect(!scope.context().done().isFired());
    scope.cancel(io);
    try std.testing.expect(scope.context().done().isFired());
}

test "withTimeout: cancel後にdeinitしてもブロックしない" {
    const io = std.testing.io;

    const scope = try withTimeout(
        std.testing.allocator,
        io,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    scope.cancel(io);
    scope.deinit(std.testing.allocator, io);
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
            parent.context(),
            .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
        ),
    );
}

// --- withTypedValue ---

test "withTypedValue: 対応するキーの値を返す" {
    const Key = TypedKey(u32);

    const scope = try withTypedValue(std.testing.allocator, background, Key, 42);
    defer scope.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, 42), scope.context().typedValue(Key));
}

test "withTypedValue: 親チェーンを辿って値を返す" {
    const io = std.testing.io;

    const Key = TypedKey(u32);

    const base = try withTypedValue(std.testing.allocator, background, Key, 42);
    defer base.deinit(std.testing.allocator);

    const child = try withCancel(std.testing.allocator, io, base.context());
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?u32, 42), child.context().typedValue(Key));
}

test "withTypedValue: キーが違えばnullを返す" {
    const Key1 = TypedKey(u32);
    const Key2 = TypedKey(u64);

    const scope = try withTypedValue(std.testing.allocator, background, Key1, 42);
    defer scope.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u64, null), scope.context().typedValue(Key2));
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
        .cancel_state = CancelState.init(),
        .deadline = dl,
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    try std.testing.expect(tryDeadlineFastPath(io, background, ctx));
    try std.testing.expectEqual(
        @as(?ContextError, error.DeadlineExceeded),
        ctx.cancel_state.cancel_err,
    );
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
        .parent = parent.context(),
        .cancel_state = CancelState.init(),
        .deadline = dl,
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    try std.testing.expect(tryDeadlineFastPath(io, parent.context(), ctx));
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), ctx.cancel_state.cancel_err);
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
        .cancel_state = CancelState.init(),
        .deadline = dl,
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    try std.testing.expect(!tryDeadlineFastPath(io, background, ctx));
    try std.testing.expectEqual(@as(?ContextError, null), ctx.cancel_state.cancel_err);
}

// --- spawnTimerAndRegister ---

test "spawnTimerAndRegister: スレッドを起動し子を登録する" {
    const io = std.testing.io;

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    const ctx = try std.testing.allocator.create(DeadlineCtx);
    ctx.* = .{
        .parent = parent.context(),
        .cancel_state = CancelState.init(),
        .deadline = .{
            .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
            .clock = .awake,
        },
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    try spawnTimerAndRegister(std.testing.allocator, io, parent.context(), ctx);
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
        .parent = parent.context(),
        .cancel_state = CancelState.init(),
        .deadline = .{
            .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
            .clock = .awake,
        },
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        spawnTimerAndRegister(failing.allocator(), io, parent.context(), ctx),
    );
}

// --- timerWorker ---

test "timerWorker: durationFromNowが非正なとき即座にDeadlineExceededにする" {
    const io = std.testing.io;

    var state = CancelState.init();
    defer state.deinit(std.testing.allocator);

    timerWorker(.{
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .cancel_state = &state,
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
        .cancel_state = &state,
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
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer child.deinit(std.testing.allocator, io);

    try registerChild(std.testing.allocator, io, background, .{ .cancel_ctx = child });

    try std.testing.expectEqual(@as(?ContextError, null), child.cancel_state.cancel_err);
}

test "registerChild: canceledは即座に伝播する" {
    const io = std.testing.io;

    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = canceled,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer child.deinit(std.testing.allocator, io);

    try registerChild(std.testing.allocator, io, canceled, .{ .cancel_ctx = child });

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.cancel_state.cancel_err);
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

    const child = try withCancel(std.testing.allocator, io, parent.context());
    defer child.deinit(std.testing.allocator, io);

    parent.cancel(io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context().err(io));
}

test "registerChild: value_ctxは親に委譲する" {
    const io = std.testing.io;

    const Key = TypedKey(u32);

    const value_parent = try withTypedValue(std.testing.allocator, canceled, Key, 42);
    defer value_parent.deinit(std.testing.allocator);

    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer child.deinit(std.testing.allocator, io);

    try registerChild(std.testing.allocator, io, value_parent.context(), .{ .cancel_ctx = child });

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.cancel_state.cancel_err);
}

// --- registerToState ---

test "registerToState: 未キャンセルなら子を登録する" {
    const io = std.testing.io;

    var parent_state = CancelState.init();
    defer parent_state.deinit(std.testing.allocator);

    const child = try std.testing.allocator.create(CancelCtx);
    child.* = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
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
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer child.deinit(std.testing.allocator, io);

    try registerToState(std.testing.allocator, io, &parent_state, .{ .cancel_ctx = child });
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.cancel_state.cancel_err);
}
