const std = @import("std");
const signal_mod = @import("signal.zig");
pub const Signal = signal_mod.Signal;

/// コンテキストの終了理由。
pub const ContextError = error{
    Canceled,
    DeadlineExceeded,
};

// モジュールレベル変数。Context.done() が参照する。
// neverFiredSignal は background / todo の done() が返す共有シグナル。
// 外部から fire されることはないため、waitAny() に background.done() / todo.done() を
// 渡した場合、対応する WaiterNode はリークする。これらを waitAny() に渡さないこと。
var neverFiredSignal: Signal = .{};
var alwaysFiredSignal: Signal = .{ .fired = .is_set };

/// タグ付き共用体によるContext。
/// フィールド名とメソッド名の衝突を避けるため、deadline/value の派生コンテキストは
/// deadlineCtx / valueCtx という variant 名を使う。
pub const Context = union(enum) {
    background,
    todo,
    cancelled,
    cancel: *CancelCtx,
    deadlineCtx: *DeadlineCtx,
    valueCtx: *ValueCtx,

    /// キャンセルシグナルを返す。background / todo は永遠に発火しない。
    pub fn done(ctx: Context) *Signal {
        return switch (ctx) {
            .background, .todo => &neverFiredSignal,
            .cancelled => &alwaysFiredSignal,
            .cancel => |c| &c.state.signal,
            .deadlineCtx => |d| &d.state.signal,
            .valueCtx => |v| v.parent.done(),
        };
    }

    /// コンテキストの終了理由を返す。未キャンセルなら null。
    pub fn err(ctx: Context, io: std.Io) ?ContextError {
        return switch (ctx) {
            .background, .todo => null,
            .cancelled => ContextError.Canceled,
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

    /// デッドライン（std.Io.Clock.Timestamp 基準ナノ秒）を返す。なければ null。
    pub fn deadline(ctx: Context) ?i96 {
        return switch (ctx) {
            .background, .todo => null,
            .cancelled => null,
            .cancel => null,
            .deadlineCtx => |d| d.deadlineNs,
            .valueCtx => |v| v.parent.deadline(),
        };
    }

    fn rawValue(ctx: Context, key: *const anyopaque) ?*anyopaque {
        return switch (ctx) {
            .background, .todo => null,
            .cancelled => null,
            // cancel / deadlineCtx は自身に値を持たないが、先祖の valueCtx に委譲する。
            .cancel => |c| c.parent.rawValue(key),
            .deadlineCtx => |d| d.parent.rawValue(key),
            .valueCtx => |v| if (v.key == key) v.val else v.parent.rawValue(key),
        };
    }

    /// 型安全な値の取り出し。
    pub fn typedValue(ctx: Context, comptime Key: type) ?Key.Value {
        const raw = ctx.rawValue(Key.key) orelse return null;
        return @as(*Key.Value, @ptrCast(@alignCast(raw))).*;
    }
};

/// withCancel / withDeadline / withTimeout / withTypedValue の返り値型。
pub const OwnedContext = struct {
    context: Context,

    /// シグナルのみ発火。メモリは解放しない。idempotent。
    pub fn cancel(self: OwnedContext, io: std.Io) void {
        switch (self.context) {
            .background, .todo, .cancelled => {},
            .cancel => |c| c.state.cancelFn(io, error.Canceled),
            .deadlineCtx => |d| d.state.cancelFn(io, error.Canceled),
            .valueCtx => {},
        }
    }

    /// メモリを解放する。未キャンセルなら先にキャンセルしてから解放。defer で必ず呼ぶ。
    pub fn deinit(self: OwnedContext, io: std.Io) void {
        switch (self.context) {
            .background, .todo, .cancelled => {},
            .cancel => |c| c.deinit(io),
            .deadlineCtx => |d| d.deinit(io),
            .valueCtx => |v| v.deinit(),
        }
    }
};

/// ルートコンテキスト（アロケータ不要）。キャンセルされない。
pub const background: Context = .background;

/// プレースホルダー（アロケータ不要）。background と同じ振る舞い。
pub const todo: Context = .todo;

/// 最初からキャンセル済みのコンテキスト（アロケータ不要）。
pub const cancelled: Context = .cancelled;

/// comptime 型安全キー。
/// key は型ごとにユニークなポインタ。
/// u8 の var 変数を使うことでリンカが同一アドレスにマージしないことを保証する。
pub fn TypedKey(comptime T: type) type {
    return struct {
        pub const Value = T;
        // var にすることで各 TypedKey(T) instantiation に固有のアドレスを確保する。
        // u0（zero-size）だとリンカが複数の定数を同一アドレスにマージする可能性がある。
        var _unique: u8 = 0;
        pub const key: *anyopaque = &_unique;
    };
}

// --- CancelState ---

/// CancelCtx / DeadlineCtx 共通の状態とキャンセルロジック。
const CancelState = struct {
    signal: Signal,
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
            .signal = .{},
            .cancelErr = null,
            .mutex = .init,
            .allocator = allocator,
            .children = .empty,
        };
    }

    /// シグナルのみ発火。メモリは解放しない。idempotent。
    fn cancelFn(self: *CancelState, io: std.Io, reason: ContextError) void {
        self.mutex.lockUncancelable(io);
        if (self.cancelErr != null) {
            self.mutex.unlock(io);
            return;
        }
        self.cancelErr = reason;
        // children をスナップショットとして取り出し、ロック解放後に propagate する。
        // ロック保持中に子の cancelFn を呼ぶとロック保持時間が長くなるため。
        var children = self.children;
        self.children = .empty;
        self.mutex.unlock(io);
        for (children.items) |child| child.propagate(io, reason);
        children.deinit(self.allocator);
        self.signal.fire(io);
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
    deadlineNs: i96,
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
        .cancelled => child.propagate(io, error.Canceled),
        .cancel => |p| try registerToState(io, &p.state, child),
        .deadlineCtx => |p| try registerToState(io, &p.state, child),
        .valueCtx => |v| try registerChild(io, v.parent, child),
    };
}

fn registerToState(io: std.Io, state: *CancelState, child: CancelState.CancelChild) !void {
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    if (state.cancelErr != null) {
        child.propagate(io, state.cancelErr.?);
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
    const remaining = ctx.deadlineNs - now;
    if (remaining > 0) {
        const waitNs: u64 = if (remaining > std.math.maxInt(u64))
            std.math.maxInt(u64)
        else
            @intCast(remaining);
        if (ctx.state.signal.waitTimeout(ctx.io, waitNs)) return;
    }
    ctx.state.cancelFn(ctx.io, error.DeadlineExceeded);
}

/// デッドライン付きコンテキストを作成する。deadlineNs は std.Io.Clock.Timestamp 基準（i96）。
pub fn withDeadline(
    io: std.Io,
    parent: Context,
    deadlineNs: i96,
    allocator: std.mem.Allocator,
) (error{OutOfMemory} || std.Thread.SpawnError)!OwnedContext {
    const ctx = try allocator.create(DeadlineCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .parent = parent,
        .state = CancelState.init(allocator),
        .deadlineNs = deadlineNs,
        .io = io,
        .timerThread = null,
    };

    // fast-path: 既に期限切れならスレッド不要
    if (deadlineNs <= std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds) {
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
    const dl = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + @as(i96, timeoutNs);
    return withDeadline(io, parent, dl, allocator);
}

/// 型安全な値付きコンテキストを作成する。
pub fn withTypedValue(
    comptime Key: type,
    allocator: std.mem.Allocator,
    parent: Context,
    val: Key.Value,
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
            fn f(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*Key.Value, @ptrCast(@alignCast(ptr))));
            }
        }.f,
    };
    return .{ .context = .{ .valueCtx = ctx } };
}

// --- テスト ---

test "background: doneにならない" {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(?ContextError, null), background.err(io));
}

test "todo: doneにならない" {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(?ContextError, null), todo.err(io));
}

test "cancelled: 即座にdone" {
    const io = std.testing.io;
    try std.testing.expectEqual(ContextError.Canceled, cancelled.err(io).?);
    try std.testing.expect(cancelled.done().isFired());
}

test "withCancel: 初期状態はdoneでない" {
    const io = std.testing.io;
    const r = try withCancel(io, background, std.testing.allocator);
    defer r.deinit(io);
    try std.testing.expectEqual(@as(?ContextError, null), r.context.err(io));
}

test "withCancel: cancel後はdone" {
    const io = std.testing.io;
    const r = try withCancel(io, background, std.testing.allocator);
    defer r.deinit(io);
    r.cancel(io);
    try std.testing.expectEqual(ContextError.Canceled, r.context.err(io).?);
}

test "withCancel: cancelはidempotent" {
    const io = std.testing.io;
    const r = try withCancel(io, background, std.testing.allocator);
    defer r.deinit(io);
    r.cancel(io);
    r.cancel(io);
}

test "withCancel: cancelなしでdeinitしてもリークなし" {
    const io = std.testing.io;
    const r = try withCancel(io, background, std.testing.allocator);
    r.deinit(io);
}

test "withCancel: 親cancelが子に伝播する" {
    const io = std.testing.io;
    const parent = try withCancel(io, background, std.testing.allocator);
    defer parent.deinit(io);
    const child = try withCancel(io, parent.context, std.testing.allocator);
    defer child.deinit(io);

    parent.cancel(io);
    try std.testing.expectEqual(ContextError.Canceled, child.context.err(io).?);
}

test "withCancel: 子cancelは親に影響しない" {
    const io = std.testing.io;
    const parent = try withCancel(io, background, std.testing.allocator);
    defer parent.deinit(io);
    const child = try withCancel(io, parent.context, std.testing.allocator);
    defer child.deinit(io);

    child.cancel(io);
    try std.testing.expectEqual(@as(?ContextError, null), parent.context.err(io));
}

test "withCancel: キャンセル済み親から作った子は即座にdone" {
    const io = std.testing.io;
    const parent = try withCancel(io, background, std.testing.allocator);
    parent.cancel(io);
    defer parent.deinit(io);

    const child = try withCancel(io, parent.context, std.testing.allocator);
    defer child.deinit(io);
    try std.testing.expectEqual(ContextError.Canceled, child.context.err(io).?);
}

test "withCancel: cancelledを親にすると即座にdone" {
    const io = std.testing.io;
    const child = try withCancel(io, cancelled, std.testing.allocator);
    defer child.deinit(io);
    try std.testing.expectEqual(ContextError.Canceled, child.context.err(io).?);
}

test "withTimeout: 期限到達でDeadlineExceeded" {
    const io = std.testing.io;
    const r = try withTimeout(io, background, 1, std.testing.allocator); // 1ns
    defer r.deinit(io);

    r.context.done().wait(io);
    try std.testing.expectEqual(ContextError.DeadlineExceeded, r.context.err(io).?);
}

test "withTimeout: 期限前にcancel → Canceled" {
    const io = std.testing.io;
    const r = try withTimeout(io, background, 60 * std.time.ns_per_s, std.testing.allocator);
    defer r.deinit(io);

    r.cancel(io);
    try std.testing.expectEqual(ContextError.Canceled, r.context.err(io).?);
}

test "withDeadline: 過去のdeadlineは即座にDeadlineExceeded（fast-path）" {
    const io = std.testing.io;
    const past = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - 1;
    const r = try withDeadline(io, background, past, std.testing.allocator);
    defer r.deinit(io);
    try std.testing.expectEqual(ContextError.DeadlineExceeded, r.context.err(io).?);
    try std.testing.expect(r.context.done().isFired());
}

test "withDeadline: 親がキャンセル済みのfast-pathはCanceled" {
    const io = std.testing.io;
    const parent = try withCancel(io, background, std.testing.allocator);
    parent.cancel(io);
    defer parent.deinit(io);

    const past = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - 1;
    const child = try withDeadline(io, parent.context, past, std.testing.allocator);
    defer child.deinit(io);
    try std.testing.expectEqual(ContextError.Canceled, child.context.err(io).?);
}

test "withTimeout: cancel後にdeinitしてもブロックしない" {
    const io = std.testing.io;
    const r = try withTimeout(io, background, 60 * std.time.ns_per_s, std.testing.allocator);
    r.cancel(io);
    r.deinit(io);
}

test "withTypedValue: 対応するキーの値を返す" {
    const Key = TypedKey(u32);
    const r = try withTypedValue(Key, std.testing.allocator, background, 42);
    defer r.deinit(std.testing.io);
    try std.testing.expectEqual(@as(?u32, 42), r.context.typedValue(Key));
}

test "withTypedValue: 親チェーンを辿って値を返す" {
    const io = std.testing.io;
    const Key = TypedKey(u32);
    const base = try withTypedValue(Key, std.testing.allocator, background, 42);
    defer base.deinit(io);
    const child = try withCancel(io, base.context, std.testing.allocator);
    defer child.deinit(io);

    try std.testing.expectEqual(@as(?u32, 42), child.context.typedValue(Key));
}

test "withTypedValue: キーが違えばnullを返す" {
    const Key1 = TypedKey(u32);
    const Key2 = TypedKey(u64);
    const r = try withTypedValue(Key1, std.testing.allocator, background, 42);
    defer r.deinit(std.testing.io);
    try std.testing.expectEqual(@as(?u64, null), r.context.typedValue(Key2));
}

test "Context.deadline: withDeadlineで設定した値を返す" {
    const io = std.testing.io;
    const now = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl = now + 10 * std.time.ns_per_s;
    const r = try withDeadline(io, background, dl, std.testing.allocator);
    defer r.deinit(io);
    try std.testing.expectEqual(@as(?i96, dl), r.context.deadline());
}

test "Context.deadline: withCancelはnullを返す" {
    const io = std.testing.io;
    const r = try withCancel(io, background, std.testing.allocator);
    defer r.deinit(io);
    try std.testing.expectEqual(@as(?i96, null), r.context.deadline());
}
