const std = @import("std");

/// 一射ブロードキャストシグナル。GoのDone()チャンネルのclose相当。
/// waiters は侵入的リンクリスト（アロケータ不要）。`var sig = Signal{}` で初期化可能。
pub const Signal = struct {
    mutex: std.Io.Mutex = .init, // waiters リスト保護のみ
    fired: std.Io.Event = .unset, // 発火状態（atomic enum(u32)）
    waiters: ?*WaiterNode = null, // 侵入的リンクリスト。waitAny() 内でスタック確保。

    /// ノンブロッキング確認（ポーリング）
    pub fn isFired(self: *const Signal) bool {
        return self.fired.isSet();
    }

    /// 発火まで ブロック
    pub fn wait(self: *Signal, io: std.Io) void {
        self.fired.waitUncancelable(io);
    }

    /// 発火（idempotent）。登録済みの WaiterNode 全ての target.notify() を呼ぶ。
    pub fn fire(self: *Signal, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.fired.isSet()) return;
        var w = self.waiters;
        while (w) |waiter| : (w = waiter.next) waiter.target.notify(io, waiter.index);
        self.fired.set(io);
    }

    /// 発火まで最大 timeoutNs ナノ秒待つ。
    /// 発火した（または既に発火済み）なら true、タイムアウトなら false を返す。
    pub fn waitTimeout(self: *Signal, io: std.Io, timeoutNs: u64) bool {
        if (self.fired.isSet()) return true;
        const deadline_ts = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .{ .nanoseconds = @intCast(timeoutNs) },
            .clock = .awake,
        });
        const timeout: std.Io.Timeout = .{ .deadline = deadline_ts };
        while (!self.fired.isSet()) {
            const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
            if (now_ns >= deadline_ts.raw.nanoseconds) return false;
            self.fired.waitTimeout(io, timeout) catch {};
        }
        return true;
    }
};

/// waitAny() 内でスタック確保される待機ターゲット（1回の waitAny につき1つ）。
const WaitTarget = struct {
    firedIndex: std.atomic.Value(u32) = .init(std.math.maxInt(u32)),

    fn notify(self: *WaitTarget, io: std.Io, idx: u32) void {
        _ = self.firedIndex.cmpxchgStrong(
            std.math.maxInt(u32),
            idx,
            .acq_rel,
            .acquire,
        );
        io.futexWake(u32, &self.firedIndex.raw, std.math.maxInt(u32));
    }

    fn waitForAny(self: *WaitTarget, io: std.Io) u32 {
        const sentinel: u32 = std.math.maxInt(u32);
        while (self.firedIndex.load(.acquire) == sentinel) {
            io.futexWaitUncancelable(u32, &self.firedIndex.raw, sentinel);
        }
        return self.firedIndex.load(.acquire);
    }
};

/// waitAny() 内でスタック確保される、Signal の侵入的リンクリストのノード（1シグナルにつき1つ）。
const WaiterNode = struct {
    target: *WaitTarget,
    index: u32,
    next: ?*WaiterNode = null,
};

/// 複数シグナルのいずれかを待つ（Goのselect相当）。
/// signals は *Signal フィールドを持つ struct（anytype）。
/// 戻り値: 発火したフィールド名に対応する FieldEnum 値。exhaustive switch が使える。
pub fn waitAny(io: std.Io, signals: anytype) std.meta.FieldEnum(@TypeOf(signals)) {
    const T = @TypeOf(signals);
    const fields = std.meta.fields(T);

    var ptrs: [fields.len]*Signal = undefined;
    inline for (fields, 0..) |f, i| ptrs[i] = @field(signals, f.name);

    // WaitTarget（1個）と WaiterNode（fields.len 個）をスタック確保。
    // fields.len はコンパイル時確定なので固定長配列で安全に確保できる。
    var target = WaitTarget{};
    var nodes: [fields.len]WaiterNode = undefined;
    for (0..fields.len) |i| nodes[i] = .{ .target = &target, .index = @intCast(i) };

    // 各シグナルに mutex 保持下で登録（発火済みなら登録済み分をクリーンアップして返却）
    var registered: usize = 0;
    for (ptrs, 0..) |sig, i| {
        sig.mutex.lockUncancelable(io);
        if (sig.isFired()) {
            sig.mutex.unlock(io);
            // 登録済みの nodes[0..registered] をリストから除去してから返す
            for (ptrs[0..registered], 0..) |prev_sig, j| {
                prev_sig.mutex.lockUncancelable(io);
                removeNode(prev_sig, &nodes[j]);
                prev_sig.mutex.unlock(io);
            }
            return @enumFromInt(i);
        }
        // nodes[i] を sig.waiters の先頭に挿入
        nodes[i].next = sig.waiters;
        sig.waiters = &nodes[i];
        sig.mutex.unlock(io);
        registered += 1;
    }

    // WaitTarget で最初の通知を待つ
    const firedIdx = target.waitForAny(io);

    // 全シグナルから WaiterNode を除去（mutex 保護）
    for (ptrs, 0..) |sig, i| {
        sig.mutex.lockUncancelable(io);
        removeNode(sig, &nodes[i]);
        sig.mutex.unlock(io);
    }
    return @enumFromInt(firedIdx);
}

/// Signal の waiters リストから指定ノードを除去する（mutex 保持下で呼ぶこと）。
fn removeNode(sig: *Signal, node: *WaiterNode) void {
    if (sig.waiters == null) return;
    if (sig.waiters == node) {
        sig.waiters = node.next;
        return;
    }
    var cur = sig.waiters;
    while (cur) |c| {
        if (c.next == node) {
            c.next = node.next;
            return;
        }
        cur = c.next;
    }
}

// --- テスト ---

test "Signal: 初期状態はfiredでない" {
    var sig = Signal{};
    try std.testing.expect(!sig.isFired());
}

test "Signal: fire後はisFiredがtrue" {
    const io = std.testing.io;
    var sig = Signal{};
    sig.fire(io);
    try std.testing.expect(sig.isFired());
}

test "Signal: fireはidempotent" {
    const io = std.testing.io;
    var sig = Signal{};
    sig.fire(io);
    sig.fire(io);
    try std.testing.expect(sig.isFired());
}

test "Signal: 発火済みならwaitは即座に返る" {
    const io = std.testing.io;
    var sig = Signal{};
    sig.fire(io);
    sig.wait(io);
}

test "Signal: 別スレッドからのfireでwaitが起きる" {
    const io = std.testing.io;
    var sig = Signal{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(args: struct { s: *Signal, io: std.Io }) void {
            std.Io.sleep(args.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            args.s.fire(args.io);
        }
    }.run, .{.{ .s = &sig, .io = io }});
    sig.wait(io);
    thread.join();
    try std.testing.expect(sig.isFired());
}

test "Signal.waitTimeout: タイムアウト前に発火したらtrue" {
    const io = std.testing.io;
    var sig = Signal{};
    sig.fire(io);
    const fired = sig.waitTimeout(io, 1 * std.time.ns_per_s);
    try std.testing.expect(fired);
}

test "Signal.waitTimeout: タイムアウトしたらfalse" {
    const io = std.testing.io;
    var sig = Signal{};
    const fired = sig.waitTimeout(io, 1); // 1ns → タイムアウト
    try std.testing.expect(!fired);
}

test "Signal.waitTimeout: 別スレッドのfireで早期リターンしtrueを返す" {
    const io = std.testing.io;
    var sig = Signal{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(args: struct { s: *Signal, io: std.Io }) void {
            std.Io.sleep(args.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            args.s.fire(args.io);
        }
    }.run, .{.{ .s = &sig, .io = io }});
    const fired = sig.waitTimeout(io, 1 * std.time.ns_per_s);
    thread.join();
    try std.testing.expect(fired);
}

test "waitAny: 先に発火したシグナルのフィールド名を返す" {
    const io = std.testing.io;
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig1.fire(io);
    const result = waitAny(io, .{ .first = &sig0, .second = &sig1 });
    try std.testing.expectEqual(.second, result);
}

test "waitAny: 戻り後にSignalをfireしても安全（リスナー解除確認・registered=0）" {
    const io = std.testing.io;
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig0.fire(io);
    _ = waitAny(io, .{ .first = &sig0, .second = &sig1 });
    sig1.fire(io);
}

test "waitAny: 早期returnで登録済みWaiterNodeが除去される（use-after-free防止・registered=1）" {
    const io = std.testing.io;
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig1.fire(io);
    _ = waitAny(io, .{ .first = &sig0, .second = &sig1 });
    sig0.fire(io);
}

test "waitAny: 複数発火済みでも必ずいずれか一方を返す（実装詳細・依存禁止）" {
    const io = std.testing.io;
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig0.fire(io);
    sig1.fire(io);
    const result = waitAny(io, .{ .first = &sig0, .second = &sig1 });
    try std.testing.expect(result == .first or result == .second);
}
