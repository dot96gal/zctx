const std = @import("std");
const signalMod = @import("signal.zig");
pub const Signal = signalMod.Signal;
const SignalSource = signalMod.SignalSource;

/// コンテキストの終了理由。
pub const ContextError = error{
    Canceled,
    DeadlineExceeded,
};

// モジュールレベル変数。Context.done() が参照する。
// neverFiredSignal は BACKGROUND / TODO の done() が返す共有シグナル。
// Signal ラッパー経由では fire() を呼べない（型で保証）。
var neverFiredSignal: SignalSource = .{};
var alwaysFiredSignal: SignalSource = .{ .fired = .is_set };

/// コンテキスト型。
pub const Context = union(enum) {
    background,
    todo,
    canceled,
    cancel: *CancelCtx,
    deadlineCtx: *DeadlineCtx,
    valueCtx: *ValueCtx,

    /// 待機専用シグナルを返す（`fire()` 不可）。BACKGROUND / TODO は永遠に発火しない。
    pub fn done(ctx: Context) Signal {
        return switch (ctx) {
            .background, .todo => neverFiredSignal.signal(),
            .canceled => alwaysFiredSignal.signal(),
            .cancel => |c| c.state.source.signal(),
            .deadlineCtx => |d| d.state.source.signal(),
            .valueCtx => |v| v.parent.done(),
        };
    }

    /// コンテキストの終了理由を返す。未キャンセルなら null を返す。
    pub fn err(ctx: Context, io: std.Io) ?ContextError {
        return switch (ctx) {
            .background, .todo => null,
            .canceled => ContextError.Canceled,
            .cancel => |c| blk: {
                c.state.mutex.lockUncancelable(io);
                defer c.state.mutex.unlock(io);
                break :blk c.state.cancelErr;
            },
            .deadlineCtx => |d| blk: {
                d.state.mutex.lockUncancelable(io);
                defer d.state.mutex.unlock(io);
                break :blk d.state.cancelErr;
            },
            .valueCtx => |v| v.parent.err(io),
        };
    }

    /// デッドラインを返す。設定されていなければ null を返す。
    pub fn deadline(ctx: Context) ?std.Io.Clock.Timestamp {
        return switch (ctx) {
            .background, .todo => null,
            .canceled => null,
            .cancel => null,
            .deadlineCtx => |d| d.deadline,
            .valueCtx => |v| v.parent.deadline(),
        };
    }

    fn rawValue(ctx: Context, key: *const anyopaque) ?*anyopaque {
        return switch (ctx) {
            .background, .todo => null,
            .canceled => null,
            // cancel / deadlineCtx は自身に値を持たないが、先祖の valueCtx に委譲する。
            .cancel => |c| c.parent.rawValue(key),
            .deadlineCtx => |d| d.parent.rawValue(key),
            .valueCtx => |v| if (v.key == key) v.val else v.parent.rawValue(key),
        };
    }

    /// キーに対応する値を型安全に返す。値が存在しなければ null を返す。
    pub fn typedValue(ctx: Context, comptime Key: type) ?Key.Value {
        const raw = ctx.rawValue(Key.key) orelse return null;
        return @as(*Key.Value, @ptrCast(@alignCast(raw))).*;
    }
};

/// withCancel / withDeadline / withTimeout / withTypedValue の返り値型。
pub const OwnedContext = struct {
    context: Context,

    /// シグナルのみを発火する。メモリは解放しない。複数回呼んでも安全に動作する（冪等）。
    /// `.valueCtx` の場合はキャンセル機構を持たないため何もしない。
    pub fn cancel(self: OwnedContext, io: std.Io) void {
        switch (self.context) {
            .background, .todo, .canceled => {},
            .cancel => |c| c.state.cancelFn(io, error.Canceled),
            .deadlineCtx => |d| d.state.cancelFn(io, error.Canceled),
            .valueCtx => {},
        }
    }

    /// メモリを解放する。未キャンセルなら先にキャンセルしてから解放する。defer で必ず呼ぶ。
    pub fn deinit(self: OwnedContext, io: std.Io) void {
        switch (self.context) {
            .background, .todo, .canceled => {},
            .cancel => |c| c.deinit(io),
            .deadlineCtx => |d| d.deinit(io),
            .valueCtx => |v| v.deinit(),
        }
    }
};

/// ルートコンテキスト（アロケータ不要）。キャンセルされない。
pub const BACKGROUND: Context = .background;

/// プレースホルダー（アロケータ不要）。BACKGROUND と同じように振る舞う。
pub const TODO: Context = .todo;

/// 最初からキャンセル済みのコンテキスト（アロケータ不要）。
pub const CANCELED: Context = .canceled;

/// comptime 型安全キーを生成する。`withTypedValue` / `typedValue` で使用する。
pub fn TypedKey(comptime T: type) type {
    return struct {
        pub const Value = T;
        // var にすることで各 TypedKey(T) instantiation に固有のアドレスを確保する。
        // u0（zero-size）だとリンカが複数の定数を同一アドレスにマージする可能性がある。
        var marker: u8 = 0;
        pub const key: *anyopaque = &marker;
    };
}

// --- CancelState ---

/// CancelCtx / DeadlineCtx 共通の状態とキャンセルロジック。
const CancelState = struct {
    source: SignalSource,
    cancelErr: ?ContextError,
    mutex: std.Io.Mutex,
    allocator: std.mem.Allocator,
    children: std.ArrayListUnmanaged(CancelChild),

    const CancelChild = union(enum) {
        cancel: *CancelCtx,
        deadlineCtx: *DeadlineCtx,

        fn propagate(child: CancelChild, io: std.Io, reason: ContextError) void {
            switch (child) {
                .cancel => |c| c.state.cancelFn(io, reason),
                .deadlineCtx => |d| d.state.cancelFn(io, reason),
            }
        }
    };

    fn init(allocator: std.mem.Allocator) CancelState {
        return .{
            .source = .{},
            .cancelErr = null,
            .mutex = .init,
            .allocator = allocator,
            .children = .empty,
        };
    }

    /// シグナルのみを発火する。メモリは解放しない。複数回呼んでも安全に動作する（冪等）。
    fn cancelFn(self: *CancelState, io: std.Io, reason: ContextError) void {
        self.mutex.lockUncancelable(io);
        if (self.cancelErr != null) {
            self.mutex.unlock(io);
            return;
        }
        self.cancelErr = reason;
        // children をスナップショットとして取り出し、ロック解放後に propagate する。
        // propagate はロック外で行う必要があるため defer ではなく手動アンロックを使用する。
        // ロック保持中に子の cancelFn を呼ぶとロック保持時間が長くなるため。
        var children = self.children;
        self.children = .empty;
        self.mutex.unlock(io);
        for (children.items) |child| child.propagate(io, reason);
        children.deinit(self.allocator);
        self.source.fire(io);
    }
};

// --- CancelCtx ---

const CancelCtx = struct {
    allocator: std.mem.Allocator,
    parent: Context,
    state: CancelState,

    fn deinit(self: *CancelCtx, io: std.Io) void {
        self.state.cancelFn(io, error.Canceled);
        self.allocator.destroy(self);
    }
};

// --- DeadlineCtx ---

const DeadlineCtx = struct {
    allocator: std.mem.Allocator,
    parent: Context,
    state: CancelState,
    deadline: std.Io.Clock.Timestamp,
    io: std.Io,
    timerThread: ?std.Thread,

    fn deinit(self: *DeadlineCtx, io: std.Io) void {
        self.state.cancelFn(io, error.Canceled);
        if (self.timerThread) |t| t.join();
        self.allocator.destroy(self);
    }
};

// --- ValueCtx ---

const ValueCtx = struct {
    allocator: std.mem.Allocator,
    parent: Context,
    key: *const anyopaque,
    val: *anyopaque,
    valDeinit: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,

    fn deinit(self: *ValueCtx) void {
        self.valDeinit(self.allocator, self.val);
        self.allocator.destroy(self);
    }
};

// --- 親子登録 ---

fn registerChild(io: std.Io, parent: Context, child: CancelState.CancelChild) !void {
    return switch (parent) {
        .background, .todo => {},
        .canceled => child.propagate(io, error.Canceled),
        .cancel => |p| try registerToState(io, &p.state, child),
        .deadlineCtx => |p| try registerToState(io, &p.state, child),
        .valueCtx => |v| try registerChild(io, v.parent, child),
    };
}

fn registerToState(io: std.Io, state: *CancelState, child: CancelState.CancelChild) !void {
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    if (state.cancelErr) |cerr| {
        // 子の追加とキャンセル判断をアトミックに保つためロック保持中に呼ぶ。
        // 子は別の CancelState のロックを取るためデッドロックは生じない。
        child.propagate(io, cerr);
    } else {
        try state.children.append(state.allocator, child);
    }
}

// --- コンストラクタ ---

/// 手動キャンセル可能なコンテキストを作成する。
pub fn withCancel(io: std.Io, parent: Context, allocator: std.mem.Allocator) error{OutOfMemory}!OwnedContext {
    const ctx = try allocator.create(CancelCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .parent = parent,
        .state = CancelState.init(allocator),
    };
    try registerChild(io, parent, .{ .cancel = ctx });
    return .{ .context = .{ .cancel = ctx } };
}

/// タイマースレッドのワーカー。
fn timerWorker(ctx: *DeadlineCtx) void {
    const now = std.Io.Clock.Timestamp.now(ctx.io, .awake).raw.nanoseconds;
    const remaining = ctx.deadline.raw.nanoseconds - now;
    // remaining が負またはゼロの場合（時計の後退・スレッド起動の遅延による race）も期限切れとして扱う。
    if (remaining > 0) {
        const waitNs: u64 = if (remaining > std.math.maxInt(u64))
            std.math.maxInt(u64)
        else
            @intCast(remaining);
        if (ctx.state.source.waitTimeout(ctx.io, waitNs)) return;
    }
    ctx.state.cancelFn(ctx.io, error.DeadlineExceeded);
}

/// デッドライン付きコンテキストを作成する。
pub fn withDeadline(
    io: std.Io,
    parent: Context,
    dl: std.Io.Clock.Timestamp,
    allocator: std.mem.Allocator,
) (error{OutOfMemory} || std.Thread.SpawnError)!OwnedContext {
    const ctx = try allocator.create(DeadlineCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .parent = parent,
        .state = CancelState.init(allocator),
        .deadline = dl,
        .io = io,
        .timerThread = null,
    };

    // fast-path: 既に期限切れならスレッド不要
    if (dl.raw.nanoseconds <= std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds) {
        try registerChild(io, parent, .{ .deadlineCtx = ctx });
        ctx.state.cancelFn(io, error.DeadlineExceeded);
        return .{ .context = .{ .deadlineCtx = ctx } };
    }

    ctx.timerThread = try std.Thread.spawn(.{}, timerWorker, .{ctx});

    errdefer {
        ctx.state.cancelFn(io, error.Canceled);
        ctx.timerThread.?.join();
    }

    try registerChild(io, parent, .{ .deadlineCtx = ctx });
    return .{ .context = .{ .deadlineCtx = ctx } };
}

/// タイムアウト付きコンテキストを作成する。timeoutNs はナノ秒。
pub fn withTimeout(
    io: std.Io,
    parent: Context,
    timeoutNs: u64,
    allocator: std.mem.Allocator,
) (error{OutOfMemory} || std.Thread.SpawnError)!OwnedContext {
    const nowNs = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = nowNs + @as(i96, timeoutNs) }, .clock = .awake };
    return withDeadline(io, parent, dl, allocator);
}

/// 型安全な値付きコンテキストを作成する。
pub fn withTypedValue(
    parent: Context,
    comptime Key: type,
    val: Key.Value,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!OwnedContext {
    const valPtr = try allocator.create(Key.Value);
    errdefer allocator.destroy(valPtr);
    valPtr.* = val;

    const ctx = try allocator.create(ValueCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .parent = parent,
        .key = Key.key,
        .val = @ptrCast(valPtr),
        .valDeinit = struct {
            fn deinitValue(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*Key.Value, @ptrCast(@alignCast(ptr))));
            }
        }.deinitValue,
    };
    return .{ .context = .{ .valueCtx = ctx } };
}

// --- テスト ---

test "background: doneにならない" {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(?ContextError, null), BACKGROUND.err(io));
}

test "todo: doneにならない" {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(?ContextError, null), TODO.err(io));
}

test "canceled: 即座にdone" {
    const io = std.testing.io;
    try std.testing.expectEqual(ContextError.Canceled, CANCELED.err(io).?);
    try std.testing.expect(CANCELED.done().isFired());
}

test "withCancel: 初期状態はdoneでない" {
    const io = std.testing.io;
    const r = try withCancel(io, BACKGROUND, std.testing.allocator);
    defer r.deinit(io);
    try std.testing.expectEqual(@as(?ContextError, null), r.context.err(io));
}

test "withCancel: cancel後はdone" {
    const io = std.testing.io;
    const r = try withCancel(io, BACKGROUND, std.testing.allocator);
    defer r.deinit(io);
    r.cancel(io);
    try std.testing.expectEqual(ContextError.Canceled, r.context.err(io).?);
}

test "withCancel: cancelはidempotent" {
    const io = std.testing.io;
    const r = try withCancel(io, BACKGROUND, std.testing.allocator);
    defer r.deinit(io);
    r.cancel(io);
    r.cancel(io);
}

test "withCancel: cancelなしでdeinitしてもリークなし" {
    const io = std.testing.io;
    const r = try withCancel(io, BACKGROUND, std.testing.allocator);
    r.deinit(io);
}

test "withCancel: 親cancelが子に伝播する" {
    const io = std.testing.io;
    const parent = try withCancel(io, BACKGROUND, std.testing.allocator);
    defer parent.deinit(io);
    const child = try withCancel(io, parent.context, std.testing.allocator);
    defer child.deinit(io);

    parent.cancel(io);
    try std.testing.expectEqual(ContextError.Canceled, child.context.err(io).?);
}

test "withCancel: 子cancelは親に影響しない" {
    const io = std.testing.io;
    const parent = try withCancel(io, BACKGROUND, std.testing.allocator);
    defer parent.deinit(io);
    const child = try withCancel(io, parent.context, std.testing.allocator);
    defer child.deinit(io);

    child.cancel(io);
    try std.testing.expectEqual(@as(?ContextError, null), parent.context.err(io));
}

test "withCancel: キャンセル済み親から作った子は即座にdone" {
    const io = std.testing.io;
    const parent = try withCancel(io, BACKGROUND, std.testing.allocator);
    parent.cancel(io);
    defer parent.deinit(io);

    const child = try withCancel(io, parent.context, std.testing.allocator);
    defer child.deinit(io);
    try std.testing.expectEqual(ContextError.Canceled, child.context.err(io).?);
}

test "withCancel: canceledを親にすると即座にdone" {
    const io = std.testing.io;
    const child = try withCancel(io, CANCELED, std.testing.allocator);
    defer child.deinit(io);
    try std.testing.expectEqual(ContextError.Canceled, child.context.err(io).?);
}

test "withTimeout: 期限到達でDeadlineExceeded" {
    const io = std.testing.io;
    const r = try withTimeout(io, BACKGROUND, 1, std.testing.allocator); // 1ns
    defer r.deinit(io);

    r.context.done().wait(io);
    try std.testing.expectEqual(ContextError.DeadlineExceeded, r.context.err(io).?);
}

test "withTimeout: 期限前にcancel → Canceled" {
    const io = std.testing.io;
    const r = try withTimeout(io, BACKGROUND, 60 * std.time.ns_per_s, std.testing.allocator);
    defer r.deinit(io);

    r.cancel(io);
    try std.testing.expectEqual(ContextError.Canceled, r.context.err(io).?);
}

test "withDeadline: 過去のdeadlineは即座にDeadlineExceeded（fast-path）" {
    const io = std.testing.io;
    const past = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - 1 }, .clock = .awake };
    const r = try withDeadline(io, BACKGROUND, past, std.testing.allocator);
    defer r.deinit(io);
    try std.testing.expectEqual(ContextError.DeadlineExceeded, r.context.err(io).?);
    try std.testing.expect(r.context.done().isFired());
}

test "withDeadline: 親がキャンセル済みのfast-pathはCanceled" {
    const io = std.testing.io;
    const parent = try withCancel(io, BACKGROUND, std.testing.allocator);
    parent.cancel(io);
    defer parent.deinit(io);

    const past = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - 1 }, .clock = .awake };
    const child = try withDeadline(io, parent.context, past, std.testing.allocator);
    defer child.deinit(io);
    try std.testing.expectEqual(ContextError.Canceled, child.context.err(io).?);
}

test "withTimeout: cancel後にdeinitしてもブロックしない" {
    const io = std.testing.io;
    const r = try withTimeout(io, BACKGROUND, 60 * std.time.ns_per_s, std.testing.allocator);
    r.cancel(io);
    r.deinit(io);
}

test "withTypedValue: 対応するキーの値を返す" {
    const Key = TypedKey(u32);
    const r = try withTypedValue(BACKGROUND, Key, 42, std.testing.allocator);
    defer r.deinit(std.testing.io);
    try std.testing.expectEqual(@as(?u32, 42), r.context.typedValue(Key));
}

test "withTypedValue: 親チェーンを辿って値を返す" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const base = try withTypedValue(BACKGROUND, Key, 42, std.testing.allocator);
    defer base.deinit(io);
    const child = try withCancel(io, base.context, std.testing.allocator);
    defer child.deinit(io);

    try std.testing.expectEqual(@as(?u32, 42), child.context.typedValue(Key));
}

test "withTypedValue: キーが違えばnullを返す" {
    const Key1 = TypedKey(u32);
    const Key2 = TypedKey(u64);
    const r = try withTypedValue(BACKGROUND, Key1, 42, std.testing.allocator);
    defer r.deinit(std.testing.io);
    try std.testing.expectEqual(@as(?u64, null), r.context.typedValue(Key2));
}

test "withTypedValue: cancelは何もしない（valueCtxはキャンセル機構を持たない）" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const r = try withTypedValue(BACKGROUND, Key, 42, std.testing.allocator);
    defer r.deinit(io);
    r.cancel(io);
    try std.testing.expect(!r.context.done().isFired());
    try std.testing.expectEqual(@as(?u32, 42), r.context.typedValue(Key));
}

test "Context.deadline: withDeadlineで設定した値を返す" {
    const io = std.testing.io;
    const nowNs = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = nowNs + 10 * std.time.ns_per_s }, .clock = .awake };
    const r = try withDeadline(io, BACKGROUND, dl, std.testing.allocator);
    defer r.deinit(io);
    try std.testing.expectEqual(@as(?std.Io.Clock.Timestamp, dl), r.context.deadline());
}

test "Context.deadline: withCancelはnullを返す" {
    const io = std.testing.io;
    const r = try withCancel(io, BACKGROUND, std.testing.allocator);
    defer r.deinit(io);
    try std.testing.expectEqual(@as(?std.Io.Clock.Timestamp, null), r.context.deadline());
}

test "withCancel: done().waitTimeout は未キャンセルならfalseを返す" {
    const io = std.testing.io;
    const r = try withCancel(io, BACKGROUND, std.testing.allocator);
    defer r.deinit(io);
    const fired = r.context.done().waitTimeout(io, 1); // 1ns → タイムアウト
    try std.testing.expect(!fired);
}

test "withCancel: done().waitTimeout はcancel後にtrueを返す" {
    const io = std.testing.io;
    const r = try withCancel(io, BACKGROUND, std.testing.allocator);
    defer r.deinit(io);
    r.cancel(io);
    const fired = r.context.done().waitTimeout(io, 1 * std.time.ns_per_s);
    try std.testing.expect(fired);
}
