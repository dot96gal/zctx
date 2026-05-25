const std = @import("std");
const context_mod = @import("context.zig");
const timer_pool_mod = @import("timer_pool.zig");

const background = context_mod.background;
const canceled = context_mod.canceled;
const Context = context_mod.Context;
const ContextError = context_mod.ContextError;
const CancelState = context_mod.CancelState;
const CancelCtx = context_mod.CancelCtx;
const DeadlineCtx = context_mod.DeadlineCtx;
const ValueCtx = context_mod.ValueCtx;
const TypedKey = context_mod.TypedKey;
const TimerPool = timer_pool_mod.TimerPool;

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
    pool: ?*TimerPool,

    pub fn deinit(self: OwnedDeadlineScope, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.pool) |p| p.unregister(io, &self.deadline_ctx.cancel_state);
        self.deadline_ctx.deinit(allocator, io);
    }

    pub fn context(self: OwnedDeadlineScope) Context {
        return .{ .deadline_ctx = self.deadline_ctx };
    }

    pub fn cancel(self: OwnedDeadlineScope, io: std.Io) void {
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
    pool: *TimerPool,
    parent: Context,
    dl: std.Io.Clock.Timestamp,
) error{OutOfMemory}!OwnedDeadlineScope {
    const ctx = try allocator.create(DeadlineCtx);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .parent = parent,
        .cancel_state = CancelState.init(),
        .deadline = dl,
        .parent_cancel_state = resolveParentState(parent),
    };

    if (tryDeadlineFastPath(io, parent, ctx)) return .{ .deadline_ctx = ctx, .pool = null };

    try pool.register(allocator, io, &ctx.cancel_state, dl);
    // pool.unregister は ctx のメモリ解放（上の errdefer allocator.destroy(ctx)）より
    // 先に実行される必要がある。逆順になると解放済みポインタへのアクセス（UAF）が生じる。
    errdefer pool.unregister(io, &ctx.cancel_state);

    try registerChild(allocator, io, parent, .{ .deadline_ctx = ctx });

    return .{ .deadline_ctx = ctx, .pool = pool };
}

pub fn withTimeout(
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *TimerPool,
    parent: Context,
    timeout: std.Io.Clock.Duration,
) error{OutOfMemory}!OwnedDeadlineScope {
    const dl = std.Io.Clock.Timestamp.fromNow(io, timeout);
    return withDeadline(allocator, io, pool, parent, dl);
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
    // Duration は符号付き i64。0 または負値は deadline 超過済みとして fast-path を適用する。
    if (ctx.deadline.durationFromNow(io).raw.nanoseconds > 0) return false;

    const cancel_err: ContextError = parent.err(io) orelse error.DeadlineExceeded;
    ctx.cancel_state.cancel(io, cancel_err);

    return true;
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
        child.propagate(io, cerr);
    } else {
        try state.children.append(allocator, child);
    }
}

// --- OwnedCancelScope ---

test "OwnedCancelScope: cancel()メソッドを持つ" {
    try std.testing.expect(@hasDecl(OwnedCancelScope, "cancel"));
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

// --- OwnedDeadlineScope ---

test "OwnedDeadlineScope: cancel()メソッドを持つ" {
    try std.testing.expect(@hasDecl(OwnedDeadlineScope, "cancel"));
}

// --- OwnedDeadlineScope.deinit ---

test "OwnedDeadlineScope.deinit: 未来のdeadlineのメモリを解放する" {
    const io = std.testing.io;
    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const scope = try withDeadline(std.testing.allocator, io, pool, background, future);
    scope.deinit(std.testing.allocator, io);
}

test "OwnedDeadlineScope.deinit: 過去のdeadlineはfast-pathでメモリを解放する" {
    const io = std.testing.io;
    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const past: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };
    const scope = try withDeadline(std.testing.allocator, io, pool, background, past);
    scope.deinit(std.testing.allocator, io);
}

// --- OwnedDeadlineScope.context ---

test "OwnedDeadlineScope.context: deadline_ctxを返す" {
    const io = std.testing.io;
    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const scope = try withDeadline(std.testing.allocator, io, pool, background, future);
    defer scope.deinit(std.testing.allocator, io);

    const ctx = scope.context();
    try std.testing.expect(ctx == .deadline_ctx);
    try std.testing.expectEqual(scope.deadline_ctx, ctx.deadline_ctx);
}

// --- OwnedDeadlineScope.cancel ---

test "OwnedDeadlineScope.cancel: cancel後にdoneになり冪等" {
    const io = std.testing.io;
    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 10 * std.time.ns_per_s },
        .clock = .awake,
    };
    const scope = try withDeadline(std.testing.allocator, io, pool, background, dl);
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);
    scope.cancel(io);

    try std.testing.expect(scope.context().done().isFired());
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), scope.context().err(io));
}

// --- OwnedValueScope ---

test "OwnedValueScope: cancel()メソッドを持たない" {
    try std.testing.expect(!@hasDecl(OwnedValueScope, "cancel"));
}

// --- OwnedValueScope.deinit ---

test "OwnedValueScope.deinit: 値とコンテキストのメモリを解放する" {
    const Key = TypedKey(u32);

    const scope = try withTypedValue(std.testing.allocator, background, Key, 42);
    scope.deinit(std.testing.allocator);
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

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const past: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns - 1 },
        .clock = .awake,
    };
    const scope = try withDeadline(std.testing.allocator, io, pool, background, past);
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(
        @as(?ContextError, error.DeadlineExceeded),
        scope.context().err(io),
    );
    try std.testing.expect(scope.context().done().isFired());
}

test "withDeadline: 未来のdeadlineは初期状態がdoneでない" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const scope = try withDeadline(std.testing.allocator, io, pool, background, future);
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expect(!scope.context().done().isFired());
}

test "withDeadline: 親がキャンセル済みのfast-pathはCanceled" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const parent = try withCancel(std.testing.allocator, io, background);
    parent.cancel(io);
    defer parent.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const past: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns - 1 },
        .clock = .awake,
    };
    const child = try withDeadline(std.testing.allocator, io, pool, parent.context(), past);
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context().err(io));
}

test "withDeadline: pool.registerのOutOfMemoryでリークなし" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

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
        withDeadline(alloc, io, pool, parent.context(), future),
    );
}

test "withDeadline: registerChildのOutOfMemoryでリークなし" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const alloc = failing.allocator();

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };

    try std.testing.expectError(
        error.OutOfMemory,
        withDeadline(alloc, io, pool, parent.context(), future),
    );
}

test "withDeadline: 子deinit後に親cancelしてもクラッシュしない" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const parent = try withDeadline(std.testing.allocator, io, pool, background, future);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withCancel(std.testing.allocator, io, parent.context());
    child.deinit(std.testing.allocator, io);

    parent.cancel(io);
}

// --- withTimeout ---

test "withTimeout: 期限到達でDeadlineExceeded" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const scope = try withTimeout(
        std.testing.allocator,
        io,
        pool,
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

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const scope = try withTimeout(
        std.testing.allocator,
        io,
        pool,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?ContextError, null), scope.context().err(io));
}

test "withTimeout: 期限前にcancel → Canceled" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const scope = try withTimeout(
        std.testing.allocator,
        io,
        pool,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), scope.context().err(io));
}

test "withTimeout: cancel後にdone()が発火する" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const scope = try withTimeout(
        std.testing.allocator,
        io,
        pool,
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

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const scope = try withTimeout(
        std.testing.allocator,
        io,
        pool,
        background,
        .{ .raw = .{ .nanoseconds = 60 * std.time.ns_per_s }, .clock = .awake },
    );
    scope.cancel(io);
    scope.deinit(std.testing.allocator, io);
}

test "withTimeout: pool.registerのOutOfMemoryでリークなし" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const alloc = failing.allocator();

    try std.testing.expectError(
        error.OutOfMemory,
        withTimeout(
            alloc,
            io,
            pool,
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

// --- resolveParentState ---

test "resolveParentState: background/todo/canceledはnullを返す" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Context,
        expected: ?*CancelState,
    }{
        .{ .name = "background", .input = background, .expected = null },
        .{ .name = "todo", .input = context_mod.todo, .expected = null },
        .{ .name = "canceled", .input = canceled, .expected = null },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        try std.testing.expectEqual(tc.expected, resolveParentState(tc.input));
    }
}

test "resolveParentState: cancel_ctx/deadline_ctxは対応するCancelStateを返す" {
    const io = std.testing.io;

    const cancel_ctx = try std.testing.allocator.create(CancelCtx);
    cancel_ctx.* = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer cancel_ctx.deinit(std.testing.allocator, io);

    const deadline_ctx = try std.testing.allocator.create(DeadlineCtx);
    deadline_ctx.* = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
    };
    defer deadline_ctx.deinit(std.testing.allocator, io);

    const test_cases = [_]struct {
        name: []const u8,
        input: Context,
        expected: *CancelState,
    }{
        .{
            .name = "cancel_ctx",
            .input = .{ .cancel_ctx = cancel_ctx },
            .expected = &cancel_ctx.cancel_state,
        },
        .{
            .name = "deadline_ctx",
            .input = .{ .deadline_ctx = deadline_ctx },
            .expected = &deadline_ctx.cancel_state,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});
        const result = resolveParentState(tc.input);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(tc.expected, result.?);
    }
}

test "resolveParentState: value_ctxはcancel_ctx親のCancelStateを返す" {
    const io = std.testing.io;

    const cancel_ctx = try std.testing.allocator.create(CancelCtx);
    cancel_ctx.* = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer cancel_ctx.deinit(std.testing.allocator, io);

    const val = try std.testing.allocator.create(u8);
    val.* = 0;
    const dummy_key: u8 = 0;
    const value_ctx = try std.testing.allocator.create(ValueCtx);
    value_ctx.* = .{
        .parent = .{ .cancel_ctx = cancel_ctx },
        .key = &dummy_key,
        .val = val,
        .val_deinit = deinitValue(u8),
    };
    defer value_ctx.deinit(std.testing.allocator);

    const result = resolveParentState(.{ .value_ctx = value_ctx });
    try std.testing.expect(result != null);
    try std.testing.expectEqual(&cancel_ctx.cancel_state, result.?);
}

test "resolveParentState: value_ctxはbackground親のときnullを返す" {
    const val = try std.testing.allocator.create(u8);
    val.* = 0;
    const dummy_key: u8 = 0;
    const value_ctx = try std.testing.allocator.create(ValueCtx);
    value_ctx.* = .{
        .parent = background,
        .key = &dummy_key,
        .val = val,
        .val_deinit = deinitValue(u8),
    };
    defer value_ctx.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        @as(?*CancelState, null),
        resolveParentState(.{ .value_ctx = value_ctx }),
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
        .parent_cancel_state = null,
    };
    defer ctx.deinit(std.testing.allocator, io);

    try std.testing.expect(!tryDeadlineFastPath(io, background, ctx));
    try std.testing.expectEqual(@as(?ContextError, null), ctx.cancel_state.cancel_err);
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

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const parent = try withDeadline(std.testing.allocator, io, pool, background, future);
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
