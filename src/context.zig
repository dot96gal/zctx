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
            .cancel_ctx => |c| c.cancel_state.source.signal(),
            .deadline_ctx => |d| d.cancel_state.source.signal(),
            .value_ctx => |v| v.parent.done(),
        };
    }

    pub fn err(ctx: Context, io: std.Io) ?ContextError {
        return switch (ctx) {
            .background, .todo => null,
            .canceled => ContextError.Canceled,
            .cancel_ctx => |c| blk: {
                c.cancel_state.mutex.lockUncancelable(io);
                defer c.cancel_state.mutex.unlock(io);
                break :blk c.cancel_state.cancel_err;
            },
            .deadline_ctx => |d| blk: {
                d.cancel_state.mutex.lockUncancelable(io);
                defer d.cancel_state.mutex.unlock(io);
                break :blk d.cancel_state.cancel_err;
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

pub const CancelState = struct {
    pub const CancelChild = union(enum) {
        cancel_ctx: *CancelCtx,
        deadline_ctx: *DeadlineCtx,

        pub fn propagate(child: CancelChild, io: std.Io, reason: ContextError) void {
            switch (child) {
                .cancel_ctx => |c| c.cancel_state.cancel(io, reason),
                .deadline_ctx => |d| d.cancel_state.cancel(io, reason),
            }
        }
    };

    mutex: std.Io.Mutex,
    source: SignalSource,
    cancel_err: ?ContextError,
    children: std.ArrayListUnmanaged(CancelChild),

    pub fn init() CancelState {
        return .{
            .mutex = .init,
            .source = .{},
            .cancel_err = null,
            .children = .empty,
        };
    }

    pub fn deinit(self: *CancelState, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
    }

    // ロック戦略: acquireCancelLock でロック解放後に propagateChildren を呼ぶ。
    // 子の cancel は子自身の mutex を取得するため、親の mutex 保持中に呼ぶとデッドロックになる。
    // registerToState はキャンセル済み時のみロック保持中に propagate を呼ぶ。
    // 子の propagate が取るのは子自身の mutex であり、親の mutex を再取得しないため安全。
    pub fn cancel(self: *CancelState, io: std.Io, reason: ContextError) void {
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

        // cancel_err を設定済みのため children への追記はなく、ロック解放後もスライスは安定する。
        return self.children.items;
    }

    fn propagateChildren(io: std.Io, items: []const CancelChild, reason: ContextError) void {
        for (items) |child| child.propagate(io, reason);
    }

    fn unregister(self: *CancelState, io: std.Io, child: CancelChild) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.cancel_err != null) return;

        for (self.children.items, 0..) |item, i| {
            if (std.meta.eql(item, child)) {
                _ = self.children.swapRemove(i);
                return;
            }
        }

        @panic("unregister: child not found");
    }
};

pub const CancelCtx = struct {
    parent: Context,
    cancel_state: CancelState,
    parent_cancel_state: ?*CancelState,

    pub fn deinit(self: *CancelCtx, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.parent_cancel_state) |ps| ps.unregister(io, .{ .cancel_ctx = self });

        self.cancel_state.cancel(io, error.Canceled);
        self.cancel_state.deinit(allocator);

        allocator.destroy(self);
    }
};

pub const DeadlineCtx = struct {
    parent: Context,
    cancel_state: CancelState,
    parent_cancel_state: ?*CancelState,
    deadline: std.Io.Clock.Timestamp,
    timer_thread: ?std.Thread,

    pub fn deinit(self: *DeadlineCtx, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.parent_cancel_state) |ps| ps.unregister(io, .{ .deadline_ctx = self });

        self.cancel_state.cancel(io, error.Canceled);

        if (self.timer_thread) |t| t.join();
        self.cancel_state.deinit(allocator);

        allocator.destroy(self);
    }
};

pub const ValueCtx = struct {
    parent: Context,
    key: *const anyopaque,
    val: *anyopaque,
    val_deinit: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,

    pub fn deinit(self: *ValueCtx, allocator: std.mem.Allocator) void {
        self.val_deinit(allocator, self.val);
        allocator.destroy(self);
    }
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

test "Context.done: cancel_ctx はキャンセル後に発火する" {
    const io = std.testing.io;

    var ctx = CancelCtx{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer ctx.cancel_state.deinit(std.testing.allocator);

    const c: Context = .{ .cancel_ctx = &ctx };
    try std.testing.expect(!c.done().isFired());
    ctx.cancel_state.cancel(io, error.Canceled);
    try std.testing.expect(c.done().isFired());
}

test "Context.done: deadline_ctx はキャンセル後に発火する" {
    const io = std.testing.io;

    var ctx: DeadlineCtx = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer ctx.cancel_state.deinit(std.testing.allocator);

    const c: Context = .{ .deadline_ctx = &ctx };
    try std.testing.expect(!c.done().isFired());
    ctx.cancel_state.cancel(io, error.DeadlineExceeded);
    try std.testing.expect(c.done().isFired());
}

test "Context.done: value_ctx は親の done() を委譲する" {
    const Key = TypedKey(u32);

    const test_cases = [_]struct {
        name: []const u8,
        input: Context,
        expected: bool,
    }{
        .{ .name = "background", .input = background, .expected = false },
        .{ .name = "canceled", .input = canceled, .expected = true },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const val_ptr = try std.testing.allocator.create(u32);
        val_ptr.* = 0;
        const ctx = try std.testing.allocator.create(ValueCtx);
        ctx.* = .{
            .parent = tc.input,
            .key = Key.key,
            .val = val_ptr,
            .val_deinit = struct {
                fn impl(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                    alloc.destroy(@as(*u32, @ptrCast(@alignCast(ptr))));
                }
            }.impl,
        };
        defer ctx.deinit(std.testing.allocator);

        const c: Context = .{ .value_ctx = ctx };
        try std.testing.expectEqual(tc.expected, c.done().isFired());
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

test "Context.err: cancel_ctx はキャンセル後に Canceled を返す" {
    const io = std.testing.io;

    var ctx = CancelCtx{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer ctx.cancel_state.deinit(std.testing.allocator);

    const c: Context = .{ .cancel_ctx = &ctx };
    try std.testing.expectEqual(@as(?ContextError, null), c.err(io));
    ctx.cancel_state.cancel(io, error.Canceled);
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), c.err(io));
}

test "Context.err: deadline_ctx はキャンセル後に DeadlineExceeded を返す" {
    const io = std.testing.io;

    var ctx: DeadlineCtx = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer ctx.cancel_state.deinit(std.testing.allocator);

    const c: Context = .{ .deadline_ctx = &ctx };
    try std.testing.expectEqual(@as(?ContextError, null), c.err(io));
    ctx.cancel_state.cancel(io, error.DeadlineExceeded);
    try std.testing.expectEqual(@as(?ContextError, error.DeadlineExceeded), c.err(io));
}

test "Context.err: value_ctx は親に委譲する" {
    const io = std.testing.io;

    const Key = TypedKey(u32);

    const val_ptr = try std.testing.allocator.create(u32);
    val_ptr.* = 42;
    const ctx = try std.testing.allocator.create(ValueCtx);
    ctx.* = .{
        .parent = canceled,
        .key = Key.key,
        .val = val_ptr,
        .val_deinit = struct {
            fn impl(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*u32, @ptrCast(@alignCast(ptr))));
            }
        }.impl,
    };
    defer ctx.deinit(std.testing.allocator);

    const c: Context = .{ .value_ctx = ctx };
    try std.testing.expectEqual(@as(?ContextError, error.Canceled), c.err(io));
}

// --- Context.deadline ---

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

test "Context.deadline: cancel_ctx は null を返す" {
    var ctx = CancelCtx{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer ctx.cancel_state.deinit(std.testing.allocator);

    const c: Context = .{ .cancel_ctx = &ctx };
    try std.testing.expectEqual(@as(?std.Io.Clock.Timestamp, null), c.deadline());
}

test "Context.deadline: deadline_ctx は設定値を返す" {
    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = 1_000_000_000 },
        .clock = .awake,
    };
    var ctx: DeadlineCtx = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .deadline = dl,
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer ctx.cancel_state.deinit(std.testing.allocator);

    const c: Context = .{ .deadline_ctx = &ctx };
    try std.testing.expectEqual(@as(?std.Io.Clock.Timestamp, dl), c.deadline());
}

test "Context.deadline: value_ctx は親の deadline を委譲する" {
    const Key = TypedKey(u32);

    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = 1_000_000_000 },
        .clock = .awake,
    };
    var parent_ctx: DeadlineCtx = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .deadline = dl,
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer parent_ctx.cancel_state.deinit(std.testing.allocator);

    const val_ptr = try std.testing.allocator.create(u32);
    val_ptr.* = 0;
    const ctx = try std.testing.allocator.create(ValueCtx);
    ctx.* = .{
        .parent = .{ .deadline_ctx = &parent_ctx },
        .key = Key.key,
        .val = val_ptr,
        .val_deinit = struct {
            fn impl(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*u32, @ptrCast(@alignCast(ptr))));
            }
        }.impl,
    };
    defer ctx.deinit(std.testing.allocator);

    const c: Context = .{ .value_ctx = ctx };
    try std.testing.expectEqual(@as(?std.Io.Clock.Timestamp, dl), c.deadline());
}

// --- Context.typedValue ---

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

test "Context.typedValue: value_ctx でキーが一致すれば値を返す" {
    const Key = TypedKey(u32);

    const val_ptr = try std.testing.allocator.create(u32);
    val_ptr.* = 42;
    const ctx = try std.testing.allocator.create(ValueCtx);
    ctx.* = .{
        .parent = background,
        .key = Key.key,
        .val = val_ptr,
        .val_deinit = struct {
            fn impl(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*u32, @ptrCast(@alignCast(ptr))));
            }
        }.impl,
    };
    defer ctx.deinit(std.testing.allocator);

    const c: Context = .{ .value_ctx = ctx };
    try std.testing.expectEqual(@as(?u32, 42), c.typedValue(Key));
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

test "Context.rawValue: value_ctx でキーが一致すれば値を返す" {
    const Key = TypedKey(u32);

    const val_ptr = try std.testing.allocator.create(u32);
    val_ptr.* = 42;
    const ctx = try std.testing.allocator.create(ValueCtx);
    ctx.* = .{
        .parent = background,
        .key = Key.key,
        .val = val_ptr,
        .val_deinit = struct {
            fn impl(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*u32, @ptrCast(@alignCast(ptr))));
            }
        }.impl,
    };
    defer ctx.deinit(std.testing.allocator);

    const c: Context = .{ .value_ctx = ctx };
    try std.testing.expect(c.rawValue(Key.key) != null);
}

test "Context.rawValue: cancel_ctx は親に委譲する" {
    const Key = TypedKey(u32);

    const val_ptr = try std.testing.allocator.create(u32);
    val_ptr.* = 42;
    const value_ctx = try std.testing.allocator.create(ValueCtx);
    value_ctx.* = .{
        .parent = background,
        .key = Key.key,
        .val = val_ptr,
        .val_deinit = struct {
            fn impl(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*u32, @ptrCast(@alignCast(ptr))));
            }
        }.impl,
    };
    defer value_ctx.deinit(std.testing.allocator);

    var cancel_ctx = CancelCtx{
        .parent = .{ .value_ctx = value_ctx },
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer cancel_ctx.cancel_state.deinit(std.testing.allocator);

    const c: Context = .{ .cancel_ctx = &cancel_ctx };
    try std.testing.expect(c.rawValue(Key.key) != null);
}

test "Context.rawValue: deadline_ctx は親に委譲する" {
    const Key = TypedKey(u32);

    const val_ptr = try std.testing.allocator.create(u32);
    val_ptr.* = 42;
    const value_ctx = try std.testing.allocator.create(ValueCtx);
    value_ctx.* = .{
        .parent = background,
        .key = Key.key,
        .val = val_ptr,
        .val_deinit = struct {
            fn impl(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*u32, @ptrCast(@alignCast(ptr))));
            }
        }.impl,
    };
    defer value_ctx.deinit(std.testing.allocator);

    var deadline_ctx: DeadlineCtx = .{
        .parent = .{ .value_ctx = value_ctx },
        .cancel_state = CancelState.init(),
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer deadline_ctx.cancel_state.deinit(std.testing.allocator);

    const c: Context = .{ .deadline_ctx = &deadline_ctx };
    try std.testing.expect(c.rawValue(Key.key) != null);
}

// --- CancelState.CancelChild.propagate ---

test "CancelState.CancelChild.propagate: cancel_ctxブランチに伝播する" {
    const io = std.testing.io;

    var child_ctx = CancelCtx{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer child_ctx.cancel_state.deinit(std.testing.allocator);

    const child: CancelState.CancelChild = .{ .cancel_ctx = &child_ctx };
    child.propagate(io, error.Canceled);

    try std.testing.expectEqual(
        @as(?ContextError, error.Canceled),
        child_ctx.cancel_state.cancel_err,
    );
}

test "CancelState.CancelChild.propagate: deadline_ctxブランチに伝播する" {
    const io = std.testing.io;

    var child_ctx: DeadlineCtx = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer child_ctx.cancel_state.deinit(std.testing.allocator);

    const child: CancelState.CancelChild = .{ .deadline_ctx = &child_ctx };
    child.propagate(io, error.Canceled);

    try std.testing.expectEqual(
        @as(?ContextError, error.Canceled),
        child_ctx.cancel_state.cancel_err,
    );
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

    var child_ctx = CancelCtx{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer child_ctx.cancel_state.deinit(std.testing.allocator);

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
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer child.deinit(std.testing.allocator, io);

    {
        var parent_state = CancelState.init();
        defer parent_state.deinit(std.testing.allocator);

        try parent_state.children.append(std.testing.allocator, .{ .cancel_ctx = child });
        parent_state.cancel(io, error.Canceled);

        try std.testing.expectEqual(
            @as(?ContextError, error.Canceled),
            child.cancel_state.cancel_err,
        );
    }
}

test "CancelState.cancel: deadline_ctx子コンテキストに伝播する" {
    const io = std.testing.io;

    const child = try std.testing.allocator.create(DeadlineCtx);
    child.* = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer child.deinit(std.testing.allocator, io);

    {
        var parent_state = CancelState.init();
        defer parent_state.deinit(std.testing.allocator);

        try parent_state.children.append(std.testing.allocator, .{ .deadline_ctx = child });
        parent_state.cancel(io, error.Canceled);

        try std.testing.expectEqual(
            @as(?ContextError, error.Canceled),
            child.cancel_state.cancel_err,
        );
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
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
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
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    defer child.deinit(std.testing.allocator, io);

    const items = [_]CancelState.CancelChild{.{ .cancel_ctx = child }};
    CancelState.propagateChildren(io, &items, error.Canceled);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.cancel_state.cancel_err);
}

test "CancelState.propagateChildren: deadline_ctx子コンテキストに伝播する" {
    const io = std.testing.io;

    const child = try std.testing.allocator.create(DeadlineCtx);
    child.* = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
        .parent_cancel_state = null,
    };
    defer child.deinit(std.testing.allocator, io);

    const items = [_]CancelState.CancelChild{.{ .deadline_ctx = child }};
    CancelState.propagateChildren(io, &items, error.Canceled);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), child.cancel_state.cancel_err);
}

// --- CancelState.unregister ---

test "CancelState.unregister: 未キャンセル状態で子を削除する" {
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

    try parent_state.children.append(std.testing.allocator, .{ .cancel_ctx = child });
    try std.testing.expectEqual(@as(usize, 1), parent_state.children.items.len);

    parent_state.unregister(io, .{ .cancel_ctx = child });
    try std.testing.expectEqual(@as(usize, 0), parent_state.children.items.len);
}

test "CancelState.unregister: キャンセル済み状態では何もしない" {
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

    try parent_state.children.append(std.testing.allocator, .{ .cancel_ctx = child });
    parent_state.cancel(io, error.Canceled);

    parent_state.unregister(io, .{ .cancel_ctx = child });
}

// --- CancelCtx.deinit ---

test "CancelCtx.deinit: メモリを解放する" {
    const io = std.testing.io;

    const ctx = try std.testing.allocator.create(CancelCtx);
    ctx.* = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
    };
    ctx.deinit(std.testing.allocator, io);
}

// --- DeadlineCtx.deinit ---

test "DeadlineCtx.deinit: timer_threadがnullのときメモリを解放する" {
    const io = std.testing.io;

    const ctx = try std.testing.allocator.create(DeadlineCtx);
    ctx.* = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
    };
    ctx.deinit(std.testing.allocator, io);
}

test "DeadlineCtx.deinit: timer_threadをjoinしてメモリを解放する" {
    const io = std.testing.io;

    const ctx = try std.testing.allocator.create(DeadlineCtx);
    ctx.* = .{
        .parent = background,
        .cancel_state = CancelState.init(),
        .parent_cancel_state = null,
        .deadline = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
        .timer_thread = null,
    };
    errdefer ctx.deinit(std.testing.allocator, io);

    ctx.timer_thread = try std.Thread.spawn(.{}, struct {
        fn run(source: *SignalSource, tio: std.Io) void {
            _ = source.waitTimeout(tio, .{
                .raw = .{ .nanoseconds = 60 * std.time.ns_per_s },
                .clock = .awake,
            });
        }
    }.run, .{ &ctx.cancel_state.source, io });

    ctx.deinit(std.testing.allocator, io);
}

// --- ValueCtx.deinit ---

test "ValueCtx.deinit: 値とコンテキストのメモリを解放する" {
    const val_ptr = try std.testing.allocator.create(u32);
    errdefer std.testing.allocator.destroy(val_ptr);
    val_ptr.* = 42;

    const ctx = try std.testing.allocator.create(ValueCtx);
    ctx.* = .{
        .parent = background,
        .key = TypedKey(u32).key,
        .val = val_ptr,
        .val_deinit = struct {
            fn impl(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*u32, @ptrCast(@alignCast(ptr))));
            }
        }.impl,
    };
    ctx.deinit(std.testing.allocator);
}

// --- TypedKey ---

test "TypedKey: 型ごとに固有のキーを返す" {
    const K1 = TypedKey(u32);
    const K2 = TypedKey(u64);

    try std.testing.expect(K1.key != K2.key);
}
