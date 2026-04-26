const std = @import("std");

/// 一度だけ発火する待機専用のシグナル。`fire()` は呼べない。Go の `Done()` チャンネルを閉じる操作に相当する。
/// `Context.done()` が返す型。
pub const Signal = struct {
    source: *SignalSource,

    /// 発火状態をノンブロッキングで確認する。
    pub fn isFired(self: Signal) bool {
        return self.source.isFired();
    }

    /// 発火するまでブロックする。
    pub fn wait(self: Signal, io: std.Io) void {
        self.source.wait(io);
    }

    /// 発火まで最大 timeoutNs ナノ秒待つ。
    /// 発火した（または既に発火済み）なら true、タイムアウトなら false を返す。
    pub fn waitTimeout(self: Signal, io: std.Io, timeoutNs: u64) bool {
        return self.source.waitTimeout(io, timeoutNs);
    }
};

/// 一度だけ発火するブロードキャストシグナルのソース。`var src = SignalSource{}` で初期化可能。
/// 内部型。`Context.done()` は `Signal`（待機専用ラッパー）を返す。
pub const SignalSource = struct {
    fired: std.Io.Event = .unset,

    fn isFired(self: *const SignalSource) bool {
        return self.fired.isSet();
    }

    fn wait(self: *SignalSource, io: std.Io) void {
        self.fired.waitUncancelable(io);
    }

    /// 発火する。複数回呼んでも安全に動作する（冪等）。
    pub fn fire(self: *SignalSource, io: std.Io) void {
        if (self.fired.isSet()) return;
        self.fired.set(io);
    }

    /// 発火まで最大 timeoutNs ナノ秒待つ。
    /// 発火した（または既に発火済み）なら true、タイムアウトなら false を返す。
    pub fn waitTimeout(self: *SignalSource, io: std.Io, timeoutNs: u64) bool {
        if (self.fired.isSet()) return true;
        const deadlineTs = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .{ .nanoseconds = @intCast(timeoutNs) },
            .clock = .awake,
        });
        const timeout: std.Io.Timeout = .{ .deadline = deadlineTs };
        while (!self.fired.isSet()) {
            const nowNs = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
            if (nowNs >= deadlineTs.raw.nanoseconds) return false;
            // Canceled はシステムレベルの割り込み通知。isFired() を再確認してループを続ける。
            self.fired.waitTimeout(io, timeout) catch |err| switch (err) {
                error.Timeout, error.Canceled => {},
            };
        }
        return true;
    }

    /// 待機専用の Signal ラッパーを返す。
    pub fn signal(self: *SignalSource) Signal {
        return .{ .source = self };
    }
};

// --- テスト ---

test "SignalSource: 初期状態はfiredでない" {
    var src = SignalSource{};
    try std.testing.expect(!src.isFired());
}

test "SignalSource: fire後はisFiredがtrue" {
    const io = std.testing.io;
    var src = SignalSource{};
    src.fire(io);
    try std.testing.expect(src.isFired());
}

test "SignalSource: fireはidempotent" {
    const io = std.testing.io;
    var src = SignalSource{};
    src.fire(io);
    src.fire(io);
    try std.testing.expect(src.isFired());
}

test "SignalSource: 発火済みならwaitは即座に返る" {
    const io = std.testing.io;
    var src = SignalSource{};
    src.fire(io);
    src.wait(io);
}

test "SignalSource: 別スレッドからのfireでwaitが起きる" {
    const io = std.testing.io;
    var src = SignalSource{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *SignalSource, tio: std.Io) void {
            std.Io.sleep(tio, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch |err| std.debug.panic("sleep failed: {}", .{err});
            s.fire(tio);
        }
    }.run, .{ &src, io });
    src.wait(io);
    thread.join();
    try std.testing.expect(src.isFired());
}

test "SignalSource.waitTimeout: タイムアウト前に発火したらtrue" {
    const io = std.testing.io;
    var src = SignalSource{};
    src.fire(io);
    const fired = src.waitTimeout(io, 1 * std.time.ns_per_s);
    try std.testing.expect(fired);
}

test "SignalSource.waitTimeout: タイムアウトしたらfalse" {
    const io = std.testing.io;
    var src = SignalSource{};
    const fired = src.waitTimeout(io, 1); // 1ns → タイムアウト
    try std.testing.expect(!fired);
}

test "SignalSource.waitTimeout: 別スレッドのfireで早期リターンしtrueを返す" {
    const io = std.testing.io;
    var src = SignalSource{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *SignalSource, tio: std.Io) void {
            std.Io.sleep(tio, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch |err| std.debug.panic("sleep failed: {}", .{err});
            s.fire(tio);
        }
    }.run, .{ &src, io });
    const fired = src.waitTimeout(io, 1 * std.time.ns_per_s);
    thread.join();
    try std.testing.expect(fired);
}
