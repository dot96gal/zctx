const std = @import("std");

pub const Signal = struct {
    inner: SignalInner,

    pub fn isFired(self: Signal) bool {
        return switch (self.inner) {
            .never_fires => false,
            .already_fired => true,
            .source => |s| s.isFired(),
        };
    }

    pub fn wait(self: Signal, io: std.Io) void {
        switch (self.inner) {
            .never_fires => @panic("Signal.wait: cannot wait on done() of background/todo context"),
            .already_fired => {},
            .source => |s| s.waitUncancelable(io),
        }
    }

    pub fn waitTimeout(self: Signal, io: std.Io, timeout: std.Io.Clock.Duration) bool {
        return switch (self.inner) {
            .never_fires => false,
            .already_fired => true,
            .source => |s| s.waitTimeout(io, timeout),
        };
    }
};

pub const SignalSource = struct {
    const WaitResult = enum { deadline_exceeded, within_deadline };

    fired: std.Io.Event = .unset,

    pub fn fire(self: *SignalSource, io: std.Io) void {
        if (self.fired.isSet()) return;
        self.fired.set(io);
    }

    // 発火するまでポーリング待機する。タイムアウト前に発火すれば true、超過なら false を返す。
    pub fn waitTimeout(self: *SignalSource, io: std.Io, timeout: std.Io.Clock.Duration) bool {
        if (timeout.raw.nanoseconds <= 0) return false;
        if (self.fired.isSet()) return true;

        const deadline_ts = std.Io.Clock.Timestamp.fromNow(io, timeout);
        while (!self.fired.isSet()) {
            // Canceled はシステムレベルの割り込み通知。isFired() を再確認してループを続ける。
            const result = self.waitOnce(io, deadline_ts) catch .within_deadline;
            if (result == .deadline_exceeded) return false;
        }

        return true;
    }

    pub fn signal(self: *SignalSource) Signal {
        return .{ .inner = .{ .source = self } };
    }

    fn isFired(self: *const SignalSource) bool {
        return self.fired.isSet();
    }

    fn waitOnce(
        self: *SignalSource,
        io: std.Io,
        deadline_ts: std.Io.Clock.Timestamp,
    ) error{ Timeout, Canceled }!WaitResult {
        const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (now_ns >= deadline_ts.raw.nanoseconds) return .deadline_exceeded;

        try self.fired.waitTimeout(io, .{ .deadline = deadline_ts });
        return .within_deadline;
    }

    fn waitUncancelable(self: *SignalSource, io: std.Io) void {
        self.fired.waitUncancelable(io);
    }
};

const SignalInner = union(enum) {
    never_fires,
    already_fired,
    source: *SignalSource,
};

// --- Signal.isFired ---

test "Signal.isFired: 初期状態はfalse" {
    var source = SignalSource{};

    try std.testing.expect(!source.signal().isFired());
}

test "Signal.isFired: fire後はtrue" {
    const io = std.testing.io;

    var source = SignalSource{};
    source.fire(io);

    try std.testing.expect(source.signal().isFired());
}

test "Signal.isFired: never_fires/already_firedは固定状態を返す" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Signal,
        expected: bool,
    }{
        .{ .name = "never_fires", .input = .{ .inner = .never_fires }, .expected = false },
        .{ .name = "already_fired", .input = .{ .inner = .already_fired }, .expected = true },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, tc.input.isFired());
    }
}

// --- Signal.wait ---

test "Signal.wait: 発火済みなら即座に返る" {
    const io = std.testing.io;

    var source = SignalSource{};
    source.fire(io);

    source.signal().wait(io);
}

test "Signal.wait: 別スレッドからのfireでwaitが起きる" {
    const io = std.testing.io;

    var source = SignalSource{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *SignalSource, tio: std.Io) void {
            std.Io.sleep(tio, .{ .nanoseconds = 1 * std.time.ns_per_ms }, .awake) catch
                @panic("sleep failed");
            s.fire(tio);
        }
    }.run, .{ &source, io });
    source.signal().wait(io);
    thread.join();

    try std.testing.expect(source.isFired());
}

test "Signal.wait: already_firedは即座に返る" {
    const io = std.testing.io;

    const sig = Signal{ .inner = .already_fired };
    sig.wait(io);
}

// --- Signal.waitTimeout ---

test "Signal.waitTimeout: 発火済みならtrueを返す" {
    const io = std.testing.io;

    var source = SignalSource{};
    source.fire(io);

    try std.testing.expect(source.signal().waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 1 * std.time.ns_per_s }, .clock = .awake },
    ));
}

test "Signal.waitTimeout: タイムアウトしたらfalse" {
    const io = std.testing.io;

    var source = SignalSource{};
    try std.testing.expect(!source.signal().waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
    ));
}

test "Signal.waitTimeout: never_fires/already_firedは固定状態を返す" {
    const io = std.testing.io;

    const test_cases = [_]struct {
        name: []const u8,
        input: Signal,
        expected: bool,
    }{
        .{ .name = "never_fires", .input = .{ .inner = .never_fires }, .expected = false },
        .{ .name = "already_fired", .input = .{ .inner = .already_fired }, .expected = true },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, tc.input.waitTimeout(
            io,
            .{ .raw = .{ .nanoseconds = 1 * std.time.ns_per_s }, .clock = .awake },
        ));
    }
}

// --- SignalSource.fire ---

test "SignalSource.fire: 発火後はisFiredがtrue" {
    const io = std.testing.io;

    var source = SignalSource{};
    source.fire(io);

    try std.testing.expect(source.isFired());
}

test "SignalSource.fire: 冪等" {
    const io = std.testing.io;

    var source = SignalSource{};
    source.fire(io);
    source.fire(io);

    try std.testing.expect(source.isFired());
}

// --- SignalSource.waitTimeout ---

test "SignalSource.waitTimeout: タイムアウト前に発火したらtrue" {
    const io = std.testing.io;

    var source = SignalSource{};
    source.fire(io);
    const fired = source.waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 1 * std.time.ns_per_s }, .clock = .awake },
    );

    try std.testing.expect(fired);
}

test "SignalSource.waitTimeout: タイムアウトしたらfalse" {
    const io = std.testing.io;

    var source = SignalSource{};
    const fired = source.waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 1 }, .clock = .awake },
    );

    try std.testing.expect(!fired);
}

test "SignalSource.waitTimeout: 別スレッドのfireで早期リターンしtrueを返す" {
    const io = std.testing.io;

    var source = SignalSource{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *SignalSource, tio: std.Io) void {
            std.Io.sleep(tio, .{ .nanoseconds = 1 * std.time.ns_per_ms }, .awake) catch
                @panic("sleep failed");
            s.fire(tio);
        }
    }.run, .{ &source, io });
    const fired = source.waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 1 * std.time.ns_per_s }, .clock = .awake },
    );
    thread.join();

    try std.testing.expect(fired);
}

test "SignalSource.waitTimeout: 非正のDurationは即座にfalse" {
    const io = std.testing.io;

    var source = SignalSource{};
    try std.testing.expect(!source.waitTimeout(
        io,
        .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake },
    ));
}

// --- SignalSource.signal ---

test "SignalSource.signal: Signalを返す" {
    var source = SignalSource{};
    const sig = source.signal();

    try std.testing.expect(!sig.isFired());
}

// --- SignalSource.isFired ---

test "SignalSource.isFired: 初期状態はfalse" {
    var source = SignalSource{};

    try std.testing.expect(!source.isFired());
}

test "SignalSource.isFired: fire後はtrue" {
    const io = std.testing.io;

    var source = SignalSource{};
    source.fire(io);

    try std.testing.expect(source.isFired());
}

// --- SignalSource.waitOnce ---

test "SignalSource.waitOnce: deadlineを過ぎたらdeadline_exceededを返す" {
    const io = std.testing.io;

    var source = SignalSource{};
    const deadline_ts: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake };

    try std.testing.expectEqual(.deadline_exceeded, try source.waitOnce(io, deadline_ts));
}

test "SignalSource.waitOnce: deadline前はwithin_deadlineを返す" {
    const io = std.testing.io;

    var source = SignalSource{};
    source.fire(io);
    const deadline_ts = std.Io.Clock.Timestamp.fromNow(
        io,
        .{ .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms }, .clock = .awake },
    );

    try std.testing.expectEqual(.within_deadline, try source.waitOnce(io, deadline_ts));
}

// --- SignalSource.waitUncancelable ---

test "SignalSource.waitUncancelable: 発火済みなら即座に返る" {
    const io = std.testing.io;

    var source = SignalSource{};
    source.fire(io);
    source.waitUncancelable(io);
}

test "SignalSource.waitUncancelable: 別スレッドからのfireでwaitが起きる" {
    const io = std.testing.io;

    var source = SignalSource{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *SignalSource, tio: std.Io) void {
            std.Io.sleep(tio, .{ .nanoseconds = 1 * std.time.ns_per_ms }, .awake) catch
                @panic("sleep failed");
            s.fire(tio);
        }
    }.run, .{ &source, io });
    source.waitUncancelable(io);
    thread.join();

    try std.testing.expect(source.isFired());
}
