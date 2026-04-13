const std = @import("std");
const signal_mod = @import("signal.zig");
pub const Signal = signal_mod.Signal;

/// キャンセル理由。
pub const CancelError = error{
    Canceled,
    DeadlineExceeded,
};

// モジュールレベル変数。Context.done() が参照する。
var neverFiredSignal: Signal = .{};
var alwaysFiredSignal: Signal = .{ .fired = .init(true) };

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

    pub fn done(ctx: Context) *Signal {
        return switch (ctx) {
            .background, .todo => &neverFiredSignal,
            .cancelled => &alwaysFiredSignal,
            .cancel => |c| &c.state.signal,
            .deadlineCtx => |d| &d.state.signal,
            .valueCtx => |v| v.parent.done(),
        };
    }

    pub fn err(ctx: Context) ?CancelError {
        return switch (ctx) {
            .background, .todo => null,
            .cancelled => CancelError.Canceled,
            .cancel => |c| blk: {
                c.state.mutex.lock();
                defer c.state.mutex.unlock();
                break :blk c.state.cancelErr;
            },
            .deadlineCtx => |d| blk: {
                d.state.mutex.lock();
                defer d.state.mutex.unlock();
                break :blk d.state.cancelErr;
            },
            .valueCtx => |v| v.parent.err(),
        };
    }

    pub fn deadline(ctx: Context) ?i128 {
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
    pub fn cancel(self: OwnedContext) void {
        switch (self.context) {
            .background, .todo, .cancelled => {},
            .cancel => |c| c.state.cancelFn(error.Canceled),
            .deadlineCtx => |d| d.state.cancelFn(error.Canceled),
            .valueCtx => {},
        }
    }

    /// メモリを解放する。未キャンセルなら先にキャンセルしてから解放。defer で必ず呼ぶ。
    pub fn deinit(self: OwnedContext) void {
        switch (self.context) {
            .background, .todo, .cancelled => {},
            .cancel => |c| c.deinit(),
            .deadlineCtx => |d| d.deinit(),
            .valueCtx => |v| v.deinit(),
        }
    }
};

/// ルートコンテキスト（アロケータ不要）。キャンセルされない。
pub const background: Context = .background;

/// プレースホルダー（アロケータ不要）。background と同じ振る舞い。
pub const todo: Context = .todo;

/// 最初からキャンセル済みのコンテキスト（アロケータ不要）。
pub const cancelledContext: Context = .cancelled;

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
    cancelErr: ?CancelError,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    children: std.ArrayListUnmanaged(CancelChild),

    const CancelChild = union(enum) {
        cancel: *CancelCtx,
        deadlineCtx: *DeadlineCtx,

        fn propagate(child: CancelChild, reason: CancelError) void {
            switch (child) {
                .cancel => |c| c.state.cancelFn(reason),
                .deadlineCtx => |d| d.state.cancelFn(reason),
            }
        }
    };

    fn init(allocator: std.mem.Allocator) CancelState {
        return .{
            .signal = .{},
            .cancelErr = null,
            .mutex = .{},
            .allocator = allocator,
            .children = .{},
        };
    }

    /// シグナルのみ発火。メモリは解放しない。idempotent。
    fn cancelFn(self: *CancelState, reason: CancelError) void {
        self.mutex.lock();
        if (self.cancelErr != null) {
            self.mutex.unlock();
            return;
        }
        self.cancelErr = reason;
        for (self.children.items) |child| child.propagate(reason);
        self.children.deinit(self.allocator);
        self.mutex.unlock();
        self.signal.fire();
    }
};

// --- CancelCtx ---

const CancelCtx = struct {
    allocator: std.mem.Allocator,
    parent: Context,
    state: CancelState,

    fn deinit(self: *CancelCtx) void {
        self.state.cancelFn(error.Canceled);
        self.allocator.destroy(self);
    }
};

// --- DeadlineCtx ---

const DeadlineCtx = struct {
    allocator: std.mem.Allocator,
    parent: Context,
    state: CancelState,
    deadlineNs: i128,
    timerThread: ?std.Thread,

    fn deinit(self: *DeadlineCtx) void {
        self.state.cancelFn(error.Canceled);
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

fn registerChild(parent: Context, child: CancelState.CancelChild) !void {
    return switch (parent) {
        .background, .todo => {},
        .cancelled => child.propagate(error.Canceled),
        .cancel => |p| try registerToState(&p.state, child),
        .deadlineCtx => |p| try registerToState(&p.state, child),
        .valueCtx => |v| try registerChild(v.parent, child),
    };
}

fn registerToState(state: *CancelState, child: CancelState.CancelChild) !void {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.cancelErr != null) {
        child.propagate(state.cancelErr.?);
    } else {
        try state.children.append(state.allocator, child);
    }
}

// --- コンストラクタ ---

/// 手動キャンセル可能なコンテキストを作成する。
pub fn withCancel(allocator: std.mem.Allocator, parent: Context) !OwnedContext {
    const ctx = try allocator.create(CancelCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .parent = parent,
        .state = CancelState.init(allocator),
    };
    try registerChild(parent, .{ .cancel = ctx });
    return .{ .context = .{ .cancel = ctx } };
}

/// タイマースレッドのワーカー。
fn timerWorker(ctx: *DeadlineCtx) void {
    const now = std.time.nanoTimestamp();
    const remaining = ctx.deadlineNs - now;
    if (remaining > 0) {
        const waitNs: u64 = if (remaining > std.math.maxInt(u64))
            std.math.maxInt(u64)
        else
            @intCast(remaining);
        if (ctx.state.signal.waitTimeout(waitNs)) return;
    }
    ctx.state.cancelFn(error.DeadlineExceeded);
}

/// デッドライン付きコンテキストを作成する。deadlineNs は std.time.nanoTimestamp() 基準。
pub fn withDeadline(
    allocator: std.mem.Allocator,
    parent: Context,
    deadlineNs: i128,
) !OwnedContext {
    const ctx = try allocator.create(DeadlineCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .parent = parent,
        .state = CancelState.init(allocator),
        .deadlineNs = deadlineNs,
        .timerThread = null,
    };

    // fast-path: 既に期限切れならスレッド不要
    if (deadlineNs <= std.time.nanoTimestamp()) {
        try registerChild(parent, .{ .deadlineCtx = ctx });
        ctx.state.cancelFn(error.DeadlineExceeded);
        return .{ .context = .{ .deadlineCtx = ctx } };
    }

    ctx.timerThread = try std.Thread.spawn(.{}, timerWorker, .{ctx});

    errdefer {
        ctx.state.cancelFn(error.Canceled);
        ctx.timerThread.?.join();
    }

    try registerChild(parent, .{ .deadlineCtx = ctx });
    return .{ .context = .{ .deadlineCtx = ctx } };
}

/// タイムアウト付きコンテキストを作成する。timeoutNs はナノ秒。
pub fn withTimeout(
    allocator: std.mem.Allocator,
    parent: Context,
    timeoutNs: u64,
) !OwnedContext {
    const dl = std.time.nanoTimestamp() + @as(i128, timeoutNs);
    return withDeadline(allocator, parent, dl);
}

/// 型安全な値付きコンテキストを作成する。
pub fn withTypedValue(
    comptime Key: type,
    allocator: std.mem.Allocator,
    parent: Context,
    val: Key.Value,
) !OwnedContext {
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
    try std.testing.expectEqual(@as(?CancelError, null), background.err());
}

test "todo: doneにならない" {
    try std.testing.expectEqual(@as(?CancelError, null), todo.err());
}

test "cancelledContext: 即座にdone" {
    try std.testing.expectEqual(CancelError.Canceled, cancelledContext.err().?);
    try std.testing.expect(cancelledContext.done().isFired());
}

test "withCancel: 初期状態はdoneでない" {
    const r = try withCancel(std.testing.allocator, background);
    defer r.deinit();
    try std.testing.expectEqual(@as(?CancelError, null), r.context.err());
}

test "withCancel: cancel後はdone" {
    const r = try withCancel(std.testing.allocator, background);
    defer r.deinit();
    r.cancel();
    try std.testing.expectEqual(CancelError.Canceled, r.context.err().?);
}

test "withCancel: cancelはidempotent" {
    const r = try withCancel(std.testing.allocator, background);
    defer r.deinit();
    r.cancel();
    r.cancel();
}

test "withCancel: cancelなしでdeinitしてもリークなし" {
    const r = try withCancel(std.testing.allocator, background);
    r.deinit();
}

test "withCancel: 親cancelが子に伝播する" {
    const parent = try withCancel(std.testing.allocator, background);
    defer parent.deinit();
    const child = try withCancel(std.testing.allocator, parent.context);
    defer child.deinit();

    parent.cancel();
    try std.testing.expectEqual(CancelError.Canceled, child.context.err().?);
}

test "withCancel: 子cancelは親に影響しない" {
    const parent = try withCancel(std.testing.allocator, background);
    defer parent.deinit();
    const child = try withCancel(std.testing.allocator, parent.context);
    defer child.deinit();

    child.cancel();
    try std.testing.expectEqual(@as(?CancelError, null), parent.context.err());
}

test "withCancel: キャンセル済み親から作った子は即座にdone" {
    const parent = try withCancel(std.testing.allocator, background);
    parent.cancel();
    defer parent.deinit();

    const child = try withCancel(std.testing.allocator, parent.context);
    defer child.deinit();
    try std.testing.expectEqual(CancelError.Canceled, child.context.err().?);
}

test "withCancel: cancelledContextを親にすると即座にdone" {
    const child = try withCancel(std.testing.allocator, cancelledContext);
    defer child.deinit();
    try std.testing.expectEqual(CancelError.Canceled, child.context.err().?);
}

test "withTimeout: 期限到達でDeadlineExceeded" {
    const r = try withTimeout(std.testing.allocator, background, 1); // 1ns
    defer r.deinit();

    r.context.done().wait();
    try std.testing.expectEqual(CancelError.DeadlineExceeded, r.context.err().?);
}

test "withTimeout: 期限前にcancel → Canceled" {
    const r = try withTimeout(std.testing.allocator, background, 60 * std.time.ns_per_s);
    defer r.deinit();

    r.cancel();
    try std.testing.expectEqual(CancelError.Canceled, r.context.err().?);
}

test "withDeadline: 過去のdeadlineは即座にDeadlineExceeded（fast-path）" {
    const past = std.time.nanoTimestamp() - 1;
    const r = try withDeadline(std.testing.allocator, background, past);
    defer r.deinit();
    try std.testing.expectEqual(CancelError.DeadlineExceeded, r.context.err().?);
    try std.testing.expect(r.context.done().isFired());
}

test "withDeadline: 親がキャンセル済みのfast-pathはCanceled" {
    const parent = try withCancel(std.testing.allocator, background);
    parent.cancel();
    defer parent.deinit();

    const past = std.time.nanoTimestamp() - 1;
    const child = try withDeadline(std.testing.allocator, parent.context, past);
    defer child.deinit();
    try std.testing.expectEqual(CancelError.Canceled, child.context.err().?);
}

test "withTimeout: cancel後にdeinitしてもブロックしない" {
    const r = try withTimeout(std.testing.allocator, background, 60 * std.time.ns_per_s);
    r.cancel();
    r.deinit();
}

test "withTypedValue: 対応するキーの値を返す" {
    const Key = TypedKey(u32);
    const r = try withTypedValue(Key, std.testing.allocator, background, 42);
    defer r.deinit();
    try std.testing.expectEqual(@as(?u32, 42), r.context.typedValue(Key));
}

test "withTypedValue: 親チェーンを辿って値を返す" {
    const Key = TypedKey(u32);
    const base = try withTypedValue(Key, std.testing.allocator, background, 42);
    defer base.deinit();
    const child = try withCancel(std.testing.allocator, base.context);
    defer child.deinit();

    try std.testing.expectEqual(@as(?u32, 42), child.context.typedValue(Key));
}

test "withTypedValue: キーが違えばnullを返す" {
    const Key1 = TypedKey(u32);
    const Key2 = TypedKey(u64);
    const r = try withTypedValue(Key1, std.testing.allocator, background, 42);
    defer r.deinit();
    try std.testing.expectEqual(@as(?u64, null), r.context.typedValue(Key2));
}

test "Context.deadline: withDeadlineで設定した値を返す" {
    const now = std.time.nanoTimestamp();
    const dl = now + 10 * std.time.ns_per_s;
    const r = try withDeadline(std.testing.allocator, background, dl);
    defer r.deinit();
    try std.testing.expectEqual(@as(?i128, dl), r.context.deadline());
}

test "Context.deadline: withCancelはnullを返す" {
    const r = try withCancel(std.testing.allocator, background);
    defer r.deinit();
    try std.testing.expectEqual(@as(?i128, null), r.context.deadline());
}
