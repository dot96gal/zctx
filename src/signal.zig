const std = @import("std");

/// 一射ブロードキャストシグナル。GoのDone()チャンネルのclose相当。
/// waiters は侵入的リンクリスト（アロケータ不要）。`var sig = Signal{}` で初期化可能。
pub const Signal = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    fired: std.atomic.Value(bool) = .init(false),
    waiters: ?*WaiterNode = null, // 侵入的リンクリスト。waitAny() 内でスタック確保。

    /// ノンブロッキング確認（ポーリング）
    pub fn isFired(self: *const Signal) bool {
        return self.fired.load(.acquire);
    }

    /// 発火まで ブロック
    pub fn wait(self: *Signal) void {
        if (self.isFired()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.isFired()) self.cond.wait(&self.mutex);
    }

    /// 発火（idempotent）。登録済みの WaiterNode 全ての target.notify() を呼ぶ。
    pub fn fire(self: *Signal) void {
        if (self.fired.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        self.mutex.lock();
        var w = self.waiters;
        while (w) |waiter| : (w = waiter.next) waiter.target.notify(waiter.index);
        self.mutex.unlock();
        self.cond.broadcast();
    }

    /// 発火まで最大 timeoutNs ナノ秒待つ。
    /// 発火した（または既に発火済み）なら true、タイムアウトなら false を返す。
    pub fn waitTimeout(self: *Signal, timeoutNs: u64) bool {
        if (self.isFired()) return true;
        self.mutex.lock();
        defer self.mutex.unlock();
        const start = std.time.Instant.now() catch {
            return self.isFired();
        };
        while (!self.isFired()) {
            const elapsedNs = (std.time.Instant.now() catch return self.isFired()).since(start);
            if (elapsedNs >= timeoutNs) return false;
            const remainingNs = timeoutNs - elapsedNs;
            self.cond.timedWait(&self.mutex, remainingNs) catch return self.isFired();
        }
        return true;
    }
};

/// waitAny() 内でスタック確保される待機ターゲット（1回の waitAny につき1つ）。
const WaitTarget = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    firedIndex: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),

    fn notify(self: *WaitTarget, idx: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.firedIndex.cmpxchgStrong(
            std.math.maxInt(usize),
            idx,
            .acq_rel,
            .acquire,
        );
        self.cond.broadcast();
    }

    fn waitForAny(self: *WaitTarget) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sentinel = std.math.maxInt(usize);
        while (self.firedIndex.load(.acquire) == sentinel) {
            self.cond.wait(&self.mutex);
        }
        return self.firedIndex.load(.acquire);
    }
};

/// waitAny() 内でスタック確保される、Signal の侵入的リンクリストのノード（1シグナルにつき1つ）。
const WaiterNode = struct {
    target: *WaitTarget,
    index: usize,
    next: ?*WaiterNode = null,
};

/// 複数シグナルのいずれかを待つ（Goのselect相当）。
/// signals は *Signal フィールドを持つ struct（anytype）。
/// 戻り値: 発火したフィールド名に対応する FieldEnum 値。exhaustive switch が使える。
pub fn waitAny(signals: anytype) std.meta.FieldEnum(@TypeOf(signals)) {
    const T = @TypeOf(signals);
    const fields = std.meta.fields(T);
    var ptrs: [fields.len]*Signal = undefined;
    inline for (fields, 0..) |f, i| ptrs[i] = @field(signals, f.name);
    const idx = waitAnySlice(&ptrs);
    return @enumFromInt(idx);
}

/// waitAny の内部実装。
fn waitAnySlice(signals: []const *Signal) usize {
    // WaitTarget（1個）と WaiterNode（signals.len 個）をスタック確保
    var target = WaitTarget{};
    // コンパイル時にスライス長が不明なため、最大サイズで配列確保
    // 実際の利用では anytype struct のフィールド数がコンパイル時に決まる
    var nodes_buf: [64]WaiterNode = undefined;
    const nodes = nodes_buf[0..signals.len];
    for (0..signals.len) |i| nodes[i] = .{ .target = &target, .index = i };

    // 各シグナルに mutex 保持下で登録（発火済みなら登録済み分をクリーンアップして返却）
    var registered: usize = 0;
    for (signals, 0..) |sig, i| {
        sig.mutex.lock();
        if (sig.isFired()) {
            sig.mutex.unlock();
            // 登録済みの nodes[0..registered] をリストから除去してから返す
            for (signals[0..registered], 0..) |prev_sig, j| {
                prev_sig.mutex.lock();
                removeNode(prev_sig, &nodes[j]);
                prev_sig.mutex.unlock();
            }
            return i;
        }
        // nodes[i] を sig.waiters の先頭に挿入
        nodes[i].next = sig.waiters;
        sig.waiters = &nodes[i];
        sig.mutex.unlock();
        registered += 1;
    }

    // WaitTarget で最初の通知を待つ
    const firedIdx = target.waitForAny();

    // 全シグナルから WaiterNode を除去（mutex 保護）
    for (signals, 0..) |sig, i| {
        sig.mutex.lock();
        removeNode(sig, &nodes[i]);
        sig.mutex.unlock();
    }
    return firedIdx;
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
    var sig = Signal{};
    sig.fire();
    try std.testing.expect(sig.isFired());
}

test "Signal: fireはidempotent" {
    var sig = Signal{};
    sig.fire();
    sig.fire();
    try std.testing.expect(sig.isFired());
}

test "Signal: 発火済みならwaitは即座に返る" {
    var sig = Signal{};
    sig.fire();
    sig.wait();
}

test "Signal: 別スレッドからのfireでwaitが起きる" {
    var sig = Signal{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Signal) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            s.fire();
        }
    }.run, .{&sig});
    sig.wait();
    thread.join();
    try std.testing.expect(sig.isFired());
}

test "Signal.waitTimeout: タイムアウト前に発火したらtrue" {
    var sig = Signal{};
    sig.fire();
    const fired = sig.waitTimeout(1 * std.time.ns_per_s);
    try std.testing.expect(fired);
}

test "Signal.waitTimeout: タイムアウトしたらfalse" {
    var sig = Signal{};
    const fired = sig.waitTimeout(1); // 1ns → タイムアウト
    try std.testing.expect(!fired);
}

test "Signal.waitTimeout: 別スレッドのfireで早期リターンしtrueを返す" {
    var sig = Signal{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Signal) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            s.fire();
        }
    }.run, .{&sig});
    const fired = sig.waitTimeout(1 * std.time.ns_per_s);
    thread.join();
    try std.testing.expect(fired);
}

test "waitAny: 先に発火したシグナルのフィールド名を返す" {
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig1.fire();
    const result = waitAny(.{ .first = &sig0, .second = &sig1 });
    try std.testing.expectEqual(.second, result);
}

test "waitAny: 戻り後にSignalをfireしても安全（リスナー解除確認・registered=0）" {
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig0.fire();
    _ = waitAny(.{ .first = &sig0, .second = &sig1 });
    sig1.fire();
}

test "waitAny: 早期returnで登録済みWaiterNodeが除去される（use-after-free防止・registered=1）" {
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig1.fire();
    _ = waitAny(.{ .first = &sig0, .second = &sig1 });
    sig0.fire();
}

test "waitAny: 複数発火済みでも必ずいずれか一方を返す（実装詳細・依存禁止）" {
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig0.fire();
    sig1.fire();
    const result = waitAny(.{ .first = &sig0, .second = &sig1 });
    try std.testing.expect(result == .first or result == .second);
}
