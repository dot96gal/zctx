const std = @import("std");
const context_mod = @import("context.zig");
const signal_mod = @import("signal.zig");

const CancelState = context_mod.CancelState;
const ContextError = context_mod.ContextError;
const SignalSource = signal_mod.SignalSource;

pub const TimerPool = struct {
    const Entry = struct {
        deadline: std.Io.Clock.Timestamp,
        cancel_state: *CancelState,

        fn lessThan(a: Entry, b: Entry) bool {
            return a.deadline.raw.nanoseconds < b.deadline.raw.nanoseconds;
        }
    };

    thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),
    mutex: std.Io.Mutex,
    heap: std.ArrayList(Entry),
    wakeup_ptr: ?*SignalSource,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
    ) (error{OutOfMemory} || std.Thread.SpawnError)!*TimerPool {
        const self = try allocator.create(TimerPool);
        errdefer allocator.destroy(self);

        self.* = .{
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .mutex = .init,
            .heap = .empty,
            .wakeup_ptr = null,
        };

        self.thread = try std.Thread.spawn(.{}, run, .{ self, io });

        return self;
    }

    pub fn deinit(self: *TimerPool, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.heap.items.len > 0)
            @panic("TimerPool.deinit: all scopes must be deinit'd before pool");

        self.shutdown.store(true, .release);

        self.mutex.lockUncancelable(io);
        if (self.wakeup_ptr) |w| w.fire(io);
        self.mutex.unlock(io);

        if (self.thread) |t| t.join();

        self.heap.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn register(
        self: *TimerPool,
        allocator: std.mem.Allocator,
        io: std.Io,
        state: *CancelState,
        dl: std.Io.Clock.Timestamp,
    ) error{OutOfMemory}!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        try self.heap.append(allocator, .{ .deadline = dl, .cancel_state = state });
        siftUp(self.heap.items, self.heap.items.len - 1);
        if (self.wakeup_ptr) |w| w.fire(io);
    }

    pub fn unregister(self: *TimerPool, io: std.Io, state: *CancelState) void {
        // ベンチマークの比較結果から線形探索 O(n) を設計として採用する。
        // （インデックスマップ O(log n) による最適化の効果は少なかった）
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (self.heap.items, 0..) |entry, i| {
            if (entry.cancel_state == state) {
                _ = self.heap.swapRemove(i);
                if (i < self.heap.items.len) {
                    siftDown(self.heap.items, i);
                    siftUp(self.heap.items, i);
                }
                return;
            }
        }
    }

    fn run(self: *TimerPool, io: std.Io) void {
        var wakeup: SignalSource = .{};
        const forever: std.Io.Clock.Duration = .{
            .raw = .{ .nanoseconds = std.math.maxInt(i64) },
            .clock = .awake,
        };

        while (true) {
            // フェーズ1: 期限切れエントリを処理し次 deadline を読む（ロック保持）
            self.mutex.lockUncancelable(io);
            wakeup = .{};
            self.wakeup_ptr = &wakeup;

            // mutex 解放後に OwnedDeadlineScope.deinit が cancel_state を解放しうる（UAF 防止）。
            // デッドロックは生じない：CancelState.mutex → TimerPool.mutex のパスは存在しない。
            self.processExpired(io);

            const next_deadline: ?std.Io.Clock.Timestamp = if (self.heap.items.len > 0)
                self.heap.items[0].deadline
            else
                null;
            self.mutex.unlock(io);

            if (self.shutdown.load(.acquire)) break;

            // フェーズ2: 次 deadline またはウェイクアップシグナルを待機する
            const remaining: std.Io.Clock.Duration = if (next_deadline) |dl|
                dl.durationFromNow(io)
            else
                forever;

            _ = wakeup.waitTimeout(io, remaining);

            // フェーズ3: wakeup_ptr をクリアする（ロック保持）
            self.mutex.lockUncancelable(io);
            self.wakeup_ptr = null;
            self.mutex.unlock(io);

            if (self.shutdown.load(.acquire)) break;
        }
    }

    // 呼び出し元は self.mutex を保持していること
    fn processExpired(self: *TimerPool, io: std.Io) void {
        while (self.heap.items.len > 0) {
            const top = self.heap.items[0];
            if (top.deadline.durationFromNow(io).raw.nanoseconds > 0) break;

            const entry = popMin(&self.heap);
            entry.cancel_state.cancel(io, error.DeadlineExceeded);
        }
    }
};

fn popMin(heap: *std.ArrayList(TimerPool.Entry)) TimerPool.Entry {
    if (heap.items.len == 0) @panic("popMin called on empty heap");

    const min = heap.items[0];
    const last = heap.items[heap.items.len - 1];
    heap.shrinkRetainingCapacity(heap.items.len - 1);
    if (heap.items.len > 0) {
        heap.items[0] = last;
        siftDown(heap.items, 0);
    }

    return min;
}

fn siftUp(items: []TimerPool.Entry, i: usize) void {
    var idx = i;
    while (idx > 0) {
        const parent = (idx - 1) / 2;
        if (!TimerPool.Entry.lessThan(items[idx], items[parent])) break;
        std.mem.swap(TimerPool.Entry, &items[parent], &items[idx]);
        idx = parent;
    }
}

fn siftDown(items: []TimerPool.Entry, i: usize) void {
    var idx = i;
    while (true) {
        var smallest = idx;
        const left = 2 * idx + 1;
        const right = 2 * idx + 2;

        if (left < items.len and TimerPool.Entry.lessThan(items[left], items[smallest])) {
            smallest = left;
        }

        if (right < items.len and TimerPool.Entry.lessThan(items[right], items[smallest])) {
            smallest = right;
        }

        if (smallest == idx) break;

        std.mem.swap(TimerPool.Entry, &items[smallest], &items[idx]);
        idx = smallest;
    }
}

// --- Entry.lessThan ---

test "Entry.lessThan: 比較結果" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { a_ns: i64, b_ns: i64 },
        expected: bool,
    }{
        .{
            .name = "a < b のとき true",
            .input = .{ .a_ns = 100, .b_ns = 200 },
            .expected = true,
        },
        .{
            .name = "a == b のとき false",
            .input = .{ .a_ns = 100, .b_ns = 100 },
            .expected = false,
        },
        .{
            .name = "a > b のとき false",
            .input = .{ .a_ns = 200, .b_ns = 100 },
            .expected = false,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var dummy = CancelState.init();
        defer dummy.deinit(std.testing.allocator);

        const a: TimerPool.Entry = .{
            .deadline = .{ .raw = .{ .nanoseconds = tc.input.a_ns }, .clock = .awake },
            .cancel_state = &dummy,
        };
        const b: TimerPool.Entry = .{
            .deadline = .{ .raw = .{ .nanoseconds = tc.input.b_ns }, .clock = .awake },
            .cancel_state = &dummy,
        };

        try std.testing.expectEqual(tc.expected, TimerPool.Entry.lessThan(a, b));
    }
}

// --- TimerPool.init ---

test "TimerPool.init: 正常に生成・破棄できる" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    pool.deinit(std.testing.allocator, io);
}

// --- TimerPool.deinit ---

test "TimerPool.deinit: エントリをすべて削除してから破棄できる" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);

    var state = CancelState.init();
    defer state.deinit(std.testing.allocator);

    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = std.math.maxInt(i64) },
        .clock = .awake,
    };
    try pool.register(std.testing.allocator, io, &state, future);
    pool.unregister(io, &state);

    pool.deinit(std.testing.allocator, io);
}

// --- TimerPool.register ---

test "TimerPool.register: エントリを追加できる" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    var state = CancelState.init();
    defer state.deinit(std.testing.allocator);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };

    try pool.register(std.testing.allocator, io, &state, dl);
    pool.unregister(io, &state);
}

test "TimerPool.register: OOMでエラーを返す" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    var state = CancelState.init();
    defer state.deinit(std.testing.allocator);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        pool.register(failing.allocator(), io, &state, dl),
    );
}

// --- TimerPool.unregister ---

test "TimerPool.unregister: 存在しないエントリは何もしない" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    var state = CancelState.init();
    defer state.deinit(std.testing.allocator);

    pool.unregister(io, &state);
}

test "TimerPool.unregister: 複数エントリがある状態で先頭要素を削除できる" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    var state1 = CancelState.init();
    defer state1.deinit(std.testing.allocator);
    var state2 = CancelState.init();
    defer state2.deinit(std.testing.allocator);

    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl1: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 60 * std.time.ns_per_s },
        .clock = .awake,
    };
    const dl2: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = now_ns + 120 * std.time.ns_per_s },
        .clock = .awake,
    };

    try pool.register(std.testing.allocator, io, &state1, dl1);
    try pool.register(std.testing.allocator, io, &state2, dl2);

    pool.unregister(io, &state1);
    pool.unregister(io, &state2);

    try std.testing.expectEqual(@as(?ContextError, null), state1.cancel_err);
    try std.testing.expectEqual(@as(?ContextError, null), state2.cancel_err);
}

// --- TimerPool.run ---

test "TimerPool.run: deadline到達でDeadlineExceededになる" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    var state = CancelState.init();
    defer state.deinit(std.testing.allocator);

    const past: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };
    try pool.register(std.testing.allocator, io, &state, past);

    // pool がこのエントリの deadline 処理を完了するまで待つ。
    // この wait がなければ state.deinit が pool の処理と競合する可能性がある。
    const fired = state.source.signal().waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 5 * std.time.ns_per_s }, .clock = .awake },
    );
    try std.testing.expect(fired);

    try std.testing.expectEqual(@as(?ContextError, error.DeadlineExceeded), state.cancel_err);
}

test "TimerPool.run: deadline前にcancelしてもDeadlineExceededで上書きされない" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    var state = CancelState.init();
    defer state.deinit(std.testing.allocator);

    state.cancel(io, error.Canceled);

    const past: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };
    try pool.register(std.testing.allocator, io, &state, past);
    pool.unregister(io, &state);

    try std.testing.expectEqual(@as(?ContextError, error.Canceled), state.cancel_err);
}

test "TimerPool.run: 複数のdeadlineを1スレッドで処理できる" {
    const io = std.testing.io;

    const pool = try TimerPool.init(std.testing.allocator, io);
    defer pool.deinit(std.testing.allocator, io);

    const n = 5;
    var states = [_]CancelState{CancelState.init()} ** n;
    defer for (&states) |*s| s.deinit(std.testing.allocator);

    const past: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };
    for (&states) |*s| {
        try pool.register(std.testing.allocator, io, s, past);
    }

    for (&states) |*s| {
        // pool がこのエントリの deadline 処理を完了するまで待つ。
        // この wait がなければ states の deinit が pool の処理と競合する可能性がある。
        const fired = s.source.signal().waitTimeout(
            io,
            .{ .raw = .{ .nanoseconds = 5 * std.time.ns_per_s }, .clock = .awake },
        );
        try std.testing.expect(fired);
        try std.testing.expectEqual(@as(?ContextError, error.DeadlineExceeded), s.cancel_err);
    }
}

// --- TimerPool.processExpired ---

test "TimerPool.processExpired: 期限切れ判定" {
    const test_cases = [_]struct {
        name: []const u8,
        input: i64,
        expected: ?ContextError,
    }{
        .{
            .name = "期限切れエントリをキャンセルする",
            .input = 0,
            .expected = error.DeadlineExceeded,
        },
        .{
            .name = "期限切れでないエントリは処理しない",
            .input = std.math.maxInt(i64),
            .expected = null,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const io = std.testing.io;

        var state = CancelState.init();
        defer state.deinit(std.testing.allocator);

        // init はスレッドを spawn するため、直接初期化して決定的な単体テスト環境を作る。
        var pool: TimerPool = .{
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .mutex = .init,
            .heap = .empty,
            .wakeup_ptr = null,
        };
        defer pool.heap.deinit(std.testing.allocator);

        const dl: std.Io.Clock.Timestamp = .{
            .raw = .{ .nanoseconds = tc.input },
            .clock = .awake,
        };
        try pool.heap.append(std.testing.allocator, .{ .deadline = dl, .cancel_state = &state });
        siftUp(pool.heap.items, 0);

        pool.mutex.lockUncancelable(io);
        pool.processExpired(io);
        pool.mutex.unlock(io);

        try std.testing.expectEqual(tc.expected, state.cancel_err);
    }
}

test "TimerPool.processExpired: 空のヒープは何もしない" {
    const io = std.testing.io;

    // init はスレッドを spawn するため、直接初期化して決定的な単体テスト環境を作る。
    var pool: TimerPool = .{
        .thread = null,
        .shutdown = std.atomic.Value(bool).init(false),
        .mutex = .init,
        .heap = .empty,
        .wakeup_ptr = null,
    };

    pool.mutex.lockUncancelable(io);
    pool.processExpired(io);
    pool.mutex.unlock(io);

    try std.testing.expectEqual(@as(usize, 0), pool.heap.items.len);
}

test "TimerPool.processExpired: 期限切れと期限未到達が混在する場合、期限切れのみ処理する" {
    const io = std.testing.io;

    var expired_state = CancelState.init();
    defer expired_state.deinit(std.testing.allocator);
    var future_state = CancelState.init();
    defer future_state.deinit(std.testing.allocator);

    // init はスレッドを spawn するため、直接初期化して決定的な単体テスト環境を作る。
    var pool: TimerPool = .{
        .thread = null,
        .shutdown = std.atomic.Value(bool).init(false),
        .mutex = .init,
        .heap = .empty,
        .wakeup_ptr = null,
    };
    defer pool.heap.deinit(std.testing.allocator);

    const past: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };
    const future: std.Io.Clock.Timestamp = .{
        .raw = .{ .nanoseconds = std.math.maxInt(i64) },
        .clock = .awake,
    };

    try pool.heap.append(std.testing.allocator, .{
        .deadline = past,
        .cancel_state = &expired_state,
    });
    siftUp(pool.heap.items, 0);
    try pool.heap.append(std.testing.allocator, .{
        .deadline = future,
        .cancel_state = &future_state,
    });
    siftUp(pool.heap.items, pool.heap.items.len - 1);

    pool.mutex.lockUncancelable(io);
    pool.processExpired(io);
    pool.mutex.unlock(io);

    try std.testing.expectEqual(
        @as(?ContextError, error.DeadlineExceeded),
        expired_state.cancel_err,
    );
    try std.testing.expectEqual(@as(?ContextError, null), future_state.cancel_err);
}

// --- popMin ---

test "popMin: 最小値を取り出せる" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const i64,
        expected: i64,
    }{
        .{
            .name = "1要素",
            .input = &[_]i64{100},
            .expected = 100,
        },
        .{
            .name = "複数要素",
            .input = &[_]i64{ 300, 100, 200 },
            .expected = 100,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var dummy = CancelState.init();
        defer dummy.deinit(std.testing.allocator);

        var heap: std.ArrayList(TimerPool.Entry) = .empty;
        defer heap.deinit(std.testing.allocator);

        for (tc.input) |ns| {
            try heap.append(std.testing.allocator, .{
                .deadline = .{ .raw = .{ .nanoseconds = ns }, .clock = .awake },
                .cancel_state = &dummy,
            });
            siftUp(heap.items, heap.items.len - 1);
        }

        const min = popMin(&heap);
        try std.testing.expectEqual(tc.expected, min.deadline.raw.nanoseconds);
    }
}

test "popMin: 連続popで昇順に取り出せる" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const i64,
        expected: []const i64,
    }{
        .{
            .name = "3要素を昇順に取り出せる",
            .input = &[_]i64{ 300, 100, 200 },
            .expected = &[_]i64{ 100, 200, 300 },
        },
        .{
            .name = "1要素を連続popできる",
            .input = &[_]i64{42},
            .expected = &[_]i64{42},
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var dummy = CancelState.init();
        defer dummy.deinit(std.testing.allocator);

        var heap: std.ArrayList(TimerPool.Entry) = .empty;
        defer heap.deinit(std.testing.allocator);

        for (tc.input) |ns| {
            try heap.append(std.testing.allocator, .{
                .deadline = .{ .raw = .{ .nanoseconds = ns }, .clock = .awake },
                .cancel_state = &dummy,
            });
            siftUp(heap.items, heap.items.len - 1);
        }

        for (tc.expected) |expected_ns| {
            const min = popMin(&heap);
            try std.testing.expectEqual(expected_ns, min.deadline.raw.nanoseconds);
        }
    }
}

// --- siftUp ---

test "siftUp: 末尾の要素を適切な位置に移動する" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const i64,
        expected: i64,
    }{
        .{
            .name = "末尾が最小値",
            .input = &[_]i64{ 200, 100 },
            .expected = 100,
        },
        .{
            .name = "末尾が最小値でない",
            .input = &[_]i64{ 100, 200 },
            .expected = 100,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var dummy = CancelState.init();
        defer dummy.deinit(std.testing.allocator);

        var heap: std.ArrayList(TimerPool.Entry) = .empty;
        defer heap.deinit(std.testing.allocator);

        for (tc.input) |ns| {
            try heap.append(std.testing.allocator, .{
                .deadline = .{ .raw = .{ .nanoseconds = ns }, .clock = .awake },
                .cancel_state = &dummy,
            });
            siftUp(heap.items, heap.items.len - 1);
        }

        try std.testing.expectEqual(tc.expected, heap.items[0].deadline.raw.nanoseconds);
    }
}

// --- siftDown ---

test "siftDown: rootの要素を適切な位置に移動する" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const i64,
        expected: i64,
    }{
        .{
            .name = "rootが最大値",
            .input = &[_]i64{ 300, 100, 200 },
            .expected = 100,
        },
        .{
            .name = "rootがすでに最小値（変化なし）",
            .input = &[_]i64{ 100, 200, 300 },
            .expected = 100,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var dummy = CancelState.init();
        defer dummy.deinit(std.testing.allocator);

        var heap: std.ArrayList(TimerPool.Entry) = .empty;
        defer heap.deinit(std.testing.allocator);

        for (tc.input) |ns| {
            try heap.append(std.testing.allocator, .{
                .deadline = .{ .raw = .{ .nanoseconds = ns }, .clock = .awake },
                .cancel_state = &dummy,
            });
        }

        siftDown(heap.items, 0);
        try std.testing.expectEqual(tc.expected, heap.items[0].deadline.raw.nanoseconds);
    }
}
