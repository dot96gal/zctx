const std = @import("std");
const context_mod = @import("context.zig");
const timer_pool_mod = @import("timer_pool.zig");

const background = context_mod.background;
const canceled = context_mod.canceled;
const todo = context_mod.todo;
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
        // pool.unregister で TimerPool への参照を除去してから deadline_ctx を解放する（UAF 防止）。
        // pool が null の場合は fast-path（deadline が過去）で TimerPool に未登録。
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

// 生成系 API（withCancel / withDeadline / withTimeout）のエラー集合。
// ContextDepthExceeded はキャンセル木の深さが上限に達した場合に返す（CancelState.childDepth 参照）。
pub const ScopeError = error{ OutOfMemory, ContextDepthExceeded };

pub fn withCancel(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: Context,
) ScopeError!OwnedCancelScope {
    const parent_state = resolveParentState(parent);
    const depth = try CancelState.childDepth(parent_state);

    const ctx = try allocator.create(CancelCtx);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .parent = parent,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = parent_state,
    };
    ctx.cancel_state.depth = depth;

    try registerChild(allocator, io, parent, .{ .cancel_ctx = ctx });

    return .{ .cancel_ctx = ctx };
}

pub fn withDeadline(
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *TimerPool,
    parent: Context,
    dl: std.Io.Clock.Timestamp,
) ScopeError!OwnedDeadlineScope {
    const parent_state = resolveParentState(parent);
    const depth = try CancelState.childDepth(parent_state);

    const ctx = try allocator.create(DeadlineCtx);
    errdefer allocator.destroy(ctx);

    // 親の deadline が指定値より早ければ親を採用する（Go context の min-deadline セマンティクス）。
    const effective_dl = if (parent.deadline()) |pd|
        if (pd.compare(.lt, dl)) pd else dl
    else
        dl;

    if (cancelIfDeadlineExpired(io, parent, effective_dl)) |cancel_err| {
        ctx.* = .{
            .parent = parent,
            .cancel_state = CancelState.init(),
            .deadline = effective_dl,
            .parent_cancel_state = null,
        };
        ctx.cancel_state.depth = depth;
        ctx.cancel_state.cancel(io, cancel_err);
        return .{ .deadline_ctx = ctx, .pool = null };
    }

    ctx.* = .{
        .parent = parent,
        .cancel_state = CancelState.init(),
        .deadline = effective_dl,
        .parent_cancel_state = parent_state,
    };
    ctx.cancel_state.depth = depth;
    try pool.register(allocator, io, &ctx.cancel_state, effective_dl);
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
) ScopeError!OwnedDeadlineScope {
    const dl = std.Io.Clock.Timestamp.fromNow(io, timeout);
    return withDeadline(allocator, io, pool, parent, dl);
}

pub fn withTypedValue(
    allocator: std.mem.Allocator,
    parent: Context,
    comptime Key: type,
    val: Key.Value,
) error{OutOfMemory}!OwnedValueScope {
    if (comptime !isValidTypedKey(Key)) @compileError("Key must be created with TypedKey(T)");

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

// TypedKey として使用可能な構造かを確認する（一意性は TypedKey(T) で生成した型のみが保証する）
fn isValidTypedKey(comptime Key: type) bool {
    if (!@hasDecl(Key, "Value") or
        @TypeOf(Key.Value) != type or
        !@hasDecl(Key, "key") or
        @TypeOf(Key.key) != *anyopaque)
    {
        return false;
    }
    return true;
}

fn resolveParentState(parent: Context) ?*CancelState {
    var current = parent;
    while (true) {
        switch (current) {
            .background, .todo, .canceled => return null,
            .cancel_ctx => |p| return &p.cancel_state,
            .deadline_ctx => |p| return &p.cancel_state,
            .value_ctx => |v| current = v.parent,
        }
    }
}

fn deinitValue(comptime T: type) *const fn (std.mem.Allocator, *anyopaque) void {
    return struct {
        fn impl(alloc: std.mem.Allocator, ptr: *anyopaque) void {
            alloc.destroy(@as(*T, @ptrCast(@alignCast(ptr))));
        }
    }.impl;
}

// Duration は符号付き i64。0 または負値は deadline 超過済みとして fast-path を適用する。
fn cancelIfDeadlineExpired(io: std.Io, parent: Context, dl: std.Io.Clock.Timestamp) ?ContextError {
    if (dl.durationFromNow(io).raw.nanoseconds > 0) return null;
    return parent.err(io) orelse error.DeadlineExceeded;
}

fn registerChild(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: Context,
    child: CancelState.CancelChild,
) error{OutOfMemory}!void {
    var current = parent;
    while (true) {
        switch (current) {
            .background, .todo => return,
            .canceled => return child.propagate(io, error.Canceled),
            .cancel_ctx => |p| return try registerToState(allocator, io, &p.cancel_state, child),
            .deadline_ctx => |p| return try registerToState(allocator, io, &p.cancel_state, child),
            .value_ctx => |v| current = v.parent,
        }
    }
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

test "OwnedCancelScope.cancel: cancel後にsignalが発火し冪等" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);
    scope.cancel(io);

    try std.testing.expect(scope.context().signal().isFired());
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), scope.context().err(io));
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

test "OwnedDeadlineScope.cancel: cancel後にsignalが発火し冪等" {
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

    try std.testing.expect(scope.context().signal().isFired());
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), scope.context().err(io));
}

// --- OwnedValueScope.deinit ---

test "OwnedValueScope.deinit: 値とコンテキストのメモリを解放する" {
    const Key = TypedKey(u32);

    const scope = try withTypedValue(std.testing.allocator, background, Key, 42);
    scope.deinit(std.testing.allocator);
}

// --- withCancel ---

test "withCancel: 初期状態はsignal未発火" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?ContextError, null), scope.context().err(io));
}

test "withCancel: cancel後はsignal発火済み" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), scope.context().err(io));
}

test "withCancel: cancel後にsignal()が発火する" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    try std.testing.expect(!scope.context().signal().isFired());
    scope.cancel(io);
    try std.testing.expect(scope.context().signal().isFired());
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

test "withCancel: キャンセル済み親から作った子は即座にsignal発火済み" {
    const io = std.testing.io;

    const parent = try withCancel(std.testing.allocator, io, background);
    parent.cancel(io);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withCancel(std.testing.allocator, io, parent.context());
    defer child.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context().err(io));
}

test "withCancel: canceledを親にすると即座にsignal発火済み" {
    const io = std.testing.io;

    const child = try withCancel(std.testing.allocator, io, canceled);
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.context().err(io));
}

test "withCancel: signal().waitTimeout は未キャンセルならfalseを返す" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);
    const fired = scope.context().signal().waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
    );

    try std.testing.expect(!fired);
}

test "withCancel: signal().waitTimeout はcancel後にtrueを返す" {
    const io = std.testing.io;

    const scope = try withCancel(std.testing.allocator, io, background);
    defer scope.deinit(std.testing.allocator, io);

    scope.cancel(io);

    const fired = scope.context().signal().waitTimeout(
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

    try std.testing.expect(child2.context().signal().isFired());
}

test "withCancel: 深い線形連鎖でも親cancelが末端まで伝播する（panicしない）" {
    const io = std.testing.io;

    // 線形連鎖は hand-over-hand により常に 1 フレームで処理される。
    // max_context_depth 未満の深い連鎖でも末端まで伝播することを確認する。
    const depth = 256;
    var scopes: [depth]OwnedCancelScope = undefined;

    scopes[0] = try withCancel(std.testing.allocator, io, background);
    var i: usize = 1;
    while (i < depth) : (i += 1) {
        scopes[i] = try withCancel(std.testing.allocator, io, scopes[i - 1].context());
    }
    // 子から順に（親より先に）解放する。
    defer {
        var j: usize = depth;
        while (j > 0) {
            j -= 1;
            scopes[j].deinit(std.testing.allocator, io);
        }
    }

    scopes[0].cancel(io);

    try std.testing.expectEqual(
        @as(?ContextError, error.Canceled),
        scopes[depth - 1].context().err(io),
    );
}

test "withCancel: 分岐ツリー全体にcancelが伝播する" {
    const io = std.testing.io;

    const root = try withCancel(std.testing.allocator, io, background);
    const a = try withCancel(std.testing.allocator, io, root.context());
    const a_child = try withCancel(std.testing.allocator, io, a.context());
    const b = try withCancel(std.testing.allocator, io, root.context());
    // 解放は子→親の順（defer は宣言の逆順に実行される）。
    defer root.deinit(std.testing.allocator, io);
    defer b.deinit(std.testing.allocator, io);
    defer a.deinit(std.testing.allocator, io);
    defer a_child.deinit(std.testing.allocator, io);

    root.cancel(io);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), a.context().err(io));
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), a_child.context().err(io));
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), b.context().err(io));
}

test "withCancel: 深い左偏分岐ツリー全体にcancelが伝播する" {
    const io = std.testing.io;

    // 各 spine[i] が「子 spine[i+1]（分岐）＋末尾 extra[i]」を持つ左偏分岐ツリー。
    // この形状は cancelIterative の明示スタックを深く（分岐ネスト分）消費するため、
    // バッファ境界付近でも全ノードへ伝播することを確認する。
    const depth = 80;
    var spine: [depth]OwnedCancelScope = undefined;
    var extra: [depth]OwnedCancelScope = undefined;

    // 先に spine を全段作る（spine[i+1] が spine[i] の children[0] になる）。
    spine[0] = try withCancel(std.testing.allocator, io, background);
    var i: usize = 1;
    while (i < depth) : (i += 1) {
        spine[i] = try withCancel(std.testing.allocator, io, spine[i - 1].context());
    }
    // 次に extra を作る（spine[i] の children[1] になり、spine の子を非末尾にする）。
    i = 0;
    while (i < depth) : (i += 1) {
        extra[i] = try withCancel(std.testing.allocator, io, spine[i].context());
    }
    // 解放は深い段から（子→親の順）。各段では extra[i] を spine[i] より先に解放する。
    defer {
        var j: usize = depth;
        while (j > 0) {
            j -= 1;
            extra[j].deinit(std.testing.allocator, io);
            spine[j].deinit(std.testing.allocator, io);
        }
    }

    spine[0].cancel(io);

    try std.testing.expectEqual(
        @as(?ContextError, error.Canceled),
        spine[depth - 1].context().err(io),
    );
    try std.testing.expectEqual(
        @as(?ContextError, error.Canceled),
        extra[0].context().err(io),
    );
    try std.testing.expectEqual(
        @as(?ContextError, error.Canceled),
        extra[depth - 1].context().err(io),
    );
}

test "withCancel: 深さが上限に達すると ContextDepthExceeded を返す" {
    const io = std.testing.io;

    var scopes: std.ArrayList(OwnedCancelScope) = .empty;
    defer {
        // 深い方（後に作った方）から解放する。
        var i: usize = scopes.items.len;
        while (i > 0) {
            i -= 1;
            scopes.items[i].deinit(std.testing.allocator, io);
        }
        scopes.deinit(std.testing.allocator);
    }

    // 上限に達するまで派生し続ける。深さ検査は確保前に行われるため、
    // 失敗した呼び出しはリークしない。
    var parent = background;
    while (true) {
        const scope = withCancel(std.testing.allocator, io, parent) catch |e| {
            try std.testing.expectEqual(error.ContextDepthExceeded, e);
            break;
        };
        try scopes.append(std.testing.allocator, scope);
        parent = scope.context();
    }

    try std.testing.expect(scopes.items.len > 0);
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
    try std.testing.expect(scope.context().signal().isFired());
}

test "withDeadline: 未来のdeadlineは初期状態がsignal未発火" {
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

    try std.testing.expect(!scope.context().signal().isFired());
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

test "withDeadline: 未キャンセル親 + 過去deadlineでもdeinitがクラッシュしない" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const parent = try withCancel(std.testing.allocator, io, background);
    defer parent.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const past: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns - 1 },
        .clock = .awake,
    };
    const child = try withDeadline(std.testing.allocator, io, pool, parent.context(), past);
    child.deinit(std.testing.allocator, io);
}

test "withDeadline: 親のdeadlineが早ければdeadline()は親のdeadlineを返す" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const parent_dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 10 * std.time.ns_per_s },
        .clock = .awake,
    };
    const child_dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };

    const parent = try withDeadline(std.testing.allocator, io, pool, background, parent_dl);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withDeadline(std.testing.allocator, io, pool, parent.context(), child_dl);
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(
        @as(?std.Io.Clock.Timestamp, parent_dl),
        child.context().deadline(),
    );
}

test "withDeadline: 指定dlが親のdeadlineより早ければdeadline()は指定dlを返す" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const parent_dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const child_dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 10 * std.time.ns_per_s },
        .clock = .awake,
    };

    const parent = try withDeadline(std.testing.allocator, io, pool, background, parent_dl);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withDeadline(std.testing.allocator, io, pool, parent.context(), child_dl);
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(
        @as(?std.Io.Clock.Timestamp, child_dl),
        child.context().deadline(),
    );
}

test "withDeadline: cancel_ctx親の deadline が早ければ effective_dl は親の deadline になる" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const parent_dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 10 * std.time.ns_per_s },
        .clock = .awake,
    };
    const child_dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };

    const parent = try withDeadline(std.testing.allocator, io, pool, background, parent_dl);
    defer parent.deinit(std.testing.allocator, io);

    const cancel = try withCancel(std.testing.allocator, io, parent.context());
    defer cancel.deinit(std.testing.allocator, io);

    const child = try withDeadline(std.testing.allocator, io, pool, cancel.context(), child_dl);
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(
        @as(?std.Io.Clock.Timestamp, parent_dl),
        child.context().deadline(),
    );
}

test "withDeadline: 親のdeadlineが過去のとき指定値が未来でもfast-pathになる" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const parent_dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns - 1 },
        .clock = .awake,
    };
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };

    const parent = try withDeadline(std.testing.allocator, io, pool, background, parent_dl);
    defer parent.deinit(std.testing.allocator, io);

    const child = try withDeadline(std.testing.allocator, io, pool, parent.context(), future);
    defer child.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(
        @as(?ContextError, error.DeadlineExceeded),
        child.context().err(io),
    );
    try std.testing.expect(child.context().signal().isFired());
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
    try std.testing.expect(scope.context().signal().isFired());
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

test "withTimeout: cancel後にsignal()が発火する" {
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

    try std.testing.expect(!scope.context().signal().isFired());
    scope.cancel(io);
    try std.testing.expect(scope.context().signal().isFired());
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

// --- isValidTypedKey ---

test "isValidTypedKey: TypedKey(T)はバリデーションを通過する" {
    try std.testing.expect(comptime isValidTypedKey(TypedKey(u32)));
}

test "isValidTypedKey: TypedKey以外の型はバリデーション失敗条件を満たす" {
    const Plain = struct {};
    try std.testing.expect(comptime !isValidTypedKey(Plain));
}

test "isValidTypedKey: keyが*anyopaqueでない型はバリデーション失敗条件を満たす" {
    const BadKey = struct {
        pub const Value = u32;
        pub const key: u32 = 0;
    };
    try std.testing.expect(comptime !isValidTypedKey(BadKey));
}

test "isValidTypedKey: ValueがTypeでない型はバリデーション失敗条件を満たす" {
    const BadKey = struct {
        pub const Value: u32 = 0;
        pub const key: u32 = 0;
    };
    try std.testing.expect(comptime !isValidTypedKey(BadKey));
}

// --- resolveParentState ---

test "resolveParentState: background/todo/canceledはnullを返す" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Context,
        expected: ?*CancelState,
    }{
        .{ .name = "background", .input = background, .expected = null },
        .{ .name = "todo", .input = todo, .expected = null },
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

    const result = resolveParentState(.{ .value_ctx = value_ctx }) orelse return error.TestFailed;
    try std.testing.expectEqual(&cancel_ctx.cancel_state, result);
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

// --- cancelIfDeadlineExpired ---

test "cancelIfDeadlineExpired: deadlineが現在時刻以前ならDeadlineExceeded" {
    const io = std.testing.io;

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = now_ns }, .clock = .awake };

    try std.testing.expectEqual(
        @as(?ContextError, error.DeadlineExceeded),
        cancelIfDeadlineExpired(io, background, dl),
    );
}

test "cancelIfDeadlineExpired: 親がキャンセル済みならCanceledを引き継ぐ" {
    const io = std.testing.io;

    const parent = try withCancel(std.testing.allocator, io, background);
    parent.cancel(io);
    defer parent.deinit(std.testing.allocator, io);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = now_ns }, .clock = .awake };

    try std.testing.expectEqual(
        @as(?ContextError, error.Canceled),
        cancelIfDeadlineExpired(io, parent.context(), dl),
    );
}

test "cancelIfDeadlineExpired: deadlineが現在時刻より未来ならnullを返す" {
    const io = std.testing.io;

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };

    try std.testing.expectEqual(
        @as(?ContextError, null),
        cancelIfDeadlineExpired(io, background, dl),
    );
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
