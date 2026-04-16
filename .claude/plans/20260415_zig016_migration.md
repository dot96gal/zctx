# Zig 0.16.0 移行計画

作成日: 2026-04-15
更新日: 2026-04-16（LSP による API 検証・std.Io.Event 採用・deadlineNs 型決定）

## 調査概要

`mise.toml` の `zig = "0.16.0"` は既に設定済みのため、実際に `zig build test`（キャッシュクリア後）を実行して挙動を確認した。
LSP（zls）と標準ライブラリ実ファイル（`~/.local/share/mise/installs/zig/0.16.0/lib/std/`）で全 API を検証済み。

## macOS SDK 問題の解消確認

**解消済み。** Zig 0.16.0 では `-target aarch64-macos` ワークアラウンドなしで `zig build`・`zig build test` が正常動作することを確認した。

`mise.toml` のすべての `-target aarch64-macos` フラグ、`zig build-lib` / `zig test` への置き換え、TODO コメント、example の symlink 経由ワークアラウンドが対象となる。

## 0.16.0 で発生するコンパイルエラー

`zig test src/context.zig` および `zig test src/signal.zig` で確認済みのエラー:

| エラー箇所 | 旧 API (0.15) | 新 API (0.16) |
|---|---|---|
| `signal.zig:6` | `std.Thread.Mutex` | `std.Io.Mutex` |
| `signal.zig:7` | `std.Thread.Condition` | 削除（`std.Io.Event` で代替） |
| `signal.zig:8` | `std.atomic.Value(bool)` | `std.Io.Event` |
| `signal.zig:40,44` | `std.time.Instant.now()` | `std.Io.Event.waitTimeout` で代替 |
| `context.zig:138` | `std.Thread.Mutex` | `std.Io.Mutex` |
| `context.zig:266,295,318,442,454,492` | `std.time.nanoTimestamp()` | `std.Io.Clock.Timestamp.now(io, .monotonic).raw.nanoseconds` |
| `example/*.zig:main` | `pub fn main() !void` | `pub fn main(io: std.Io, args: []const []const u8) !void` |
| `example/*.zig` | `std.heap.GeneralPurposeAllocator` | `std.heap.DebugAllocator` |
| テスト内 | `std.Thread.sleep(...)` | `std.Io.sleep(io, duration, clock) catch {}` |

## 新 API の主な変更点

### std.Io.Event（Signal.fired の代替）

```zig
// std.Io.Event = enum(u32) { unset, waiting, is_set }
// 一射イベント（1回 set したら reset 不要）

pub fn isSet(event: *const Event) bool { ... }        // ノンブロッキング確認
pub fn waitUncancelable(event: *Event, io: Io) void { ... }  // 発火まで無限待機
pub fn waitTimeout(event: *Event, io: Io, timeout: Timeout) WaitTimeoutError!void { ... }
pub fn set(e: *Event, io: Io) void { ... }            // idempotent、内部で futexWake

// WaitTimeoutError = error{Timeout} || Cancelable = error{Timeout, Canceled}
// waitTimeout のエラー意味（ドキュメントコメント由来）:
//   void           → 発火した（is_set 状態）
//   error.Timeout  → タイムアウト、または spurious wakeup（どちらも発火なし）
//   error.Canceled → キャンセル要求のみ

// 初期化
var event: std.Io.Event = .unset;       // 通常
var event: std.Io.Event = .is_set;      // 発火済み初期化（alwaysFiredSignal 用）
```

### std.Io.Timeout（futexWaitTimeout / waitTimeout に渡す型）

```zig
pub const Timeout = union(enum) {
    none,
    duration: Clock.Duration,   // Clock.Duration = struct { raw: Io.Duration, clock: Clock }
    deadline: Clock.Timestamp,
};

// timeoutNs: u64 から Timeout を構築する方法
const timeout: std.Io.Timeout = .{
    .duration = .{
        .raw = .{ .nanoseconds = @intCast(timeoutNs) },  // Io.Duration.nanoseconds: i96
        .clock = .monotonic,
    },
};
```

### std.Io.Mutex

```zig
pub const Mutex = extern struct {
    pub const init: Mutex = .{ .state = .init(.unlocked) };
    pub fn lock(m: *Mutex, io: Io) Cancelable!void { ... }
    pub fn lockUncancelable(m: *Mutex, io: Io) void { ... }
    pub fn unlock(m: *Mutex, io: Io) void { ... }
};
```

### 時刻取得

**型の注意**: `std.Io.Timestamp.nanoseconds` は `i96`。`deadlineNs` の型を `i128` から `i96` に変更する（後述）。

```zig
// 旧: std.time.nanoTimestamp() → i128
// 新: std.Io.Clock.Timestamp.now(io, .monotonic).raw.nanoseconds → i96
const ns: i96 = std.Io.Clock.Timestamp.now(io, .monotonic).raw.nanoseconds;
```

### std.Io.sleep

```zig
// シグネチャ（Io.zig:2397）
pub fn sleep(io: Io, duration: Duration, clock: Clock) Cancelable!void
// Duration = std.Io.Duration = struct { nanoseconds: i96 }

// 旧: std.Thread.sleep(10 * std.time.ns_per_ms)
// 新: （Cancelable!void なので catch が必要）
std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .monotonic) catch {};
```

### テスト向け io

```zig
// テスト内では std.testing.io を使う
test "..." {
    const io = std.testing.io;
    ...
}
```

### futex API（WaitTarget 用）

```zig
// WaitTarget.firedIndex（std.atomic.Value(u32)）の操作に使用
// T は @sizeOf(T) == @sizeOf(u32) が必須（comptime assert あり）

pub fn futexWaitUncancelable(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T) void
pub fn futexWake(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, max_waiters: u32) void
```

## アーキテクチャへの影響

`std.Io.Mutex.lockUncancelable` を使うためキャンセルエラーは伝播しない。
`std.Io.Event` を使うことで `Signal` 内の futex 呼び出しを直接書かずに済む。

**公開 API の変更が必要な箇所:**

| 現在 | 変更後 |
|---|---|
| `Signal.wait()` | `Signal.wait(io: Io) void` |
| `Signal.waitTimeout(timeoutNs: u64) bool` | `Signal.waitTimeout(io: Io, timeoutNs: u64) bool` |
| `Signal.fire()` | `Signal.fire(io: Io) void` |
| `waitAny(signals)` | `waitAny(io: Io, signals: anytype) FieldEnum` |
| `Context.err()` | `Context.err(io: Io) ?CancelError` |
| `OwnedContext.cancel()` | `OwnedContext.cancel(io: Io) void` |
| `OwnedContext.deinit()` | `OwnedContext.deinit(io: Io) void` |
| `withCancel(alloc, parent)` | `withCancel(io, parent, alloc)` |
| `withDeadline(alloc, parent, deadline)` | `withDeadline(io, parent, deadline, alloc)` |
| `withTimeout(alloc, parent, timeout)` | `withTimeout(io, parent, timeout, alloc)` |

> **引数順の根拠（stdlib の慣例）**:
> - メソッド: `self → io → ペイロード引数 → allocator`
> - 自由関数: `io → ペイロード引数 → allocator`
>
> `allocator` は末尾に置く（例: `std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator)`、`std.Io.Dir.realPathFileAlloc(dir, io, sub_path, allocator)`）。

**戻り型のエラー集合について**: 内部実装で `lockUncancelable` を使えばキャンセルエラーは発生しない。Signal / waitAny / cancel / deinit はすべて `void`（エラーなし）を維持できる。`Context.err()` も `lockUncancelable` を使うため戻り型は `?CancelError` のままを維持できる。

**withCancel も io が必要**: `withCancel` は `registerChild` → `registerToState` を経由して `mutex.lockUncancelable()` を呼ぶため、`io` が必要。

## 実装計画

### Phase 1: mise.toml の整理（macOS SDK ワークアラウンド除去）

- `[tasks.build]`: `zig build-lib src/root.zig -target aarch64-macos -fno-emit-bin` → `zig build --summary all`
- `[tasks.test]`: `zig test src/context.zig -target aarch64-macos` → `zig build test --summary all`
- `[tasks."example:*"]`: `-target aarch64-macos` フラグ除去、将来的に `zig build` 経由に変更
- コメント内の TODO・ワークアラウンド説明を更新

### Phase 2: signal.zig の移行

**Signal の再設計方針（std.Io.Event 採用）:**

`Signal.fired` を `std.Io.Event` に変更する。`Event` は `enum(u32)` であり futex 互換（4バイト）。
`Event` が `wait`/`waitTimeout`/`set` を内包するため、直接の futex 呼び出しが不要になる。
`Signal.cond`（`std.Thread.Condition`）は削除し、`Signal.mutex`（`std.Io.Mutex`）は waiters list 管理のみに使用する。

**Signal の新しい構造:**

```zig
pub const Signal = struct {
    mutex: std.Io.Mutex = .init,        // waiters リスト保護のみ
    fired: std.Io.Event = .unset,       // 発火状態（atomic enum(u32)）
    waiters: ?*WaiterNode = null,
};
```

**Signal メソッドの新実装:**

```zig
pub fn isFired(self: *const Signal) bool {
    return self.fired.isSet();
}

pub fn wait(self: *Signal, io: std.Io) void {
    self.fired.waitUncancelable(io);
}

pub fn fire(self: *Signal, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (self.fired.isSet()) return;  // idempotent
    var w = self.waiters;
    while (w) |waiter| : (w = waiter.next) waiter.target.notify(io, waiter.index);
    self.fired.set(io);  // wait()/waitTimeout() 待機スレッドを起こす（最後に呼ぶ）
}

pub fn waitTimeout(self: *Signal, io: std.Io, timeoutNs: u64) bool {
    if (self.fired.isSet()) return true;
    // duration ではなく deadline で構築することでループ時にタイマーがリセットされない
    const deadline_ts = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .{ .nanoseconds = @intCast(timeoutNs) },
        .clock = .monotonic,
    });
    const timeout: std.Io.Timeout = .{ .deadline = deadline_ts };
    // error.Timeout（タイムアウトまたは spurious wakeup）でもループして isSet() を再確認する
    while (!self.fired.isSet()) {
        const now_ns = std.Io.Clock.Timestamp.now(io, .monotonic).raw.nanoseconds;
        if (now_ns >= deadline_ts.raw.nanoseconds) return false;
        self.fired.waitTimeout(io, timeout) catch {};
    }
    return true;
}
```

**WaitTarget の再設計（futex を直接使用）:**

`Condition.timedWait` 相当がないため、`WaitTarget` は `std.Io.Mutex` / `std.Io.Condition` を使わず futex で直接実装する。
`firedIndex` を `std.atomic.Value(u32)` にすることで futex 互換（`@sizeOf(u32) == 4` の assert を満たす）。

```zig
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
```

**WaiterNode の変更:**

```zig
const WaiterNode = struct {
    target: *WaitTarget,
    index: u32,          // usize → u32（WaitTarget.firedIndex の型に合わせる）
    next: ?*WaiterNode = null,
};
```

**実装手順:**

1. `Signal.fired` を `std.Io.Event = .unset` に変更
2. `Signal.cond` フィールドを削除（`std.Thread.Condition` → 不要）
3. `Signal.mutex` を `std.Io.Mutex = .init` に変更
4. 各メソッドを再実装（上記コード参照）:
   - `isFired()`: `self.fired.isSet()`
   - `wait(io)`: `self.fired.waitUncancelable(io)`
   - `fire(io)`: mutex 保持下で `isSet()` 確認 → waiters 通知 → `fired.set(io)`
   - `waitTimeout(io, timeoutNs)`: `fromNow` で deadline 構築 → deadline ループ（`!isSet()` の間、時刻チェック → `waitTimeout catch {}`） → `isSet()` 返却
5. `WaitTarget.mutex` / `WaitTarget.cond` フィールドを削除
6. `WaitTarget.firedIndex` を `std.atomic.Value(u32)` に変更（sentinel: `maxInt(u32)`）
7. `WaitTarget.notify(io, idx)` に `io: std.Io` を追加し futex 版に再実装
8. `WaitTarget.waitForAny(io)` に `io: std.Io` を追加し futex ループ版に再実装
9. `WaiterNode.index` を `usize` → `u32` に変更
10. `waitAny` のシグネチャに `io: std.Io` を追加
    - `nodes[i] = .{ .target = &target, .index = i }` → `index: @intCast(i)` に変更
    - `target.waitForAny()` → `target.waitForAny(io)` に変更
    - `sig.mutex.lock()` → `sig.mutex.lockUncancelable(io)` に変更
    - `sig.mutex.unlock()` → `sig.mutex.unlock(io)` に変更
11. テスト内の `std.Thread.sleep` → `std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .monotonic) catch {}`
    - スレッド関数のシグネチャに `io: std.Io` を追加し `std.Thread.spawn` の引数にも `io` を渡す（2箇所:「別スレッドからのfireでwaitが起きる」テストと「別スレッドのfireで早期リターンしtrueを返す」テスト）
12. テスト内で `const io = std.testing.io;` を使用

### Phase 3: context.zig の移行

1. `CancelState.mutex` を `std.Io.Mutex` に変更（初期値 `= .init`）
   - `CancelState.init` 関数内の `.mutex = .{}` も `.mutex = .init` に変更
2. `cancelFn(self: *CancelState, io: Io, reason: CancelError)` に `io` 引数を追加
   - 内部の `mutex.lock()` → `lockUncancelable(io)`、`mutex.unlock()` → `unlock(io)` に変更
   - `children.deinit` 後の `signal.fire(io)` も変更（Phase 2 完了後）
3. `CancelChild.propagate(child, io, reason)` に `io` 引数を追加
   - `cancelFn` が `io` を受け取るため、呼び出し元の `propagate` も同様に変更
4. `registerChild(io, parent, child)` に `io` を先頭に追加
   - `registerToState` と `propagate` が `io` を要求するため、再帰呼び出しを含む全呼び出し箇所も `io` を渡すよう変更
5. `registerToState(io, state, child)` に `io` を先頭に追加
   - `mutex.lock()` → `lockUncancelable(io)`、`mutex.unlock()` → `unlock(io)`
   - 内部の `child.propagate(state.cancelErr.?)` → `child.propagate(io, state.cancelErr.?)` に変更
6. `Context.err(io: Io)` に `io` 引数を追加
   - `.cancel` variant: `c.state.mutex.lock()` → `lockUncancelable(io)`、`mutex.unlock()` → `unlock(io)`
   - `.deadlineCtx` variant: `d.state.mutex.lock()` → `lockUncancelable(io)`、`mutex.unlock()` → `unlock(io)`
   - `.valueCtx` variant: `v.parent.err()` → `v.parent.err(io)` に変更
   - `context.zig` の `alwaysFiredSignal` 初期値を `.{ .fired = .init(true) }` → `.{ .fired = .is_set }` に変更（`fired` が `std.Io.Event` になるため）
7. `withCancel` / `withDeadline` / `withTimeout` のシグネチャ更新:
   - `io: Io` を**先頭（第1引数）**に、`allocator` を**末尾**に移動する（自由関数の stdlib 慣例: `io → ペイロード → allocator`）
   - `withCancel(io, parent, alloc)` / `withDeadline(io, parent, deadlineNs, alloc)` / `withTimeout(io, parent, timeoutNs, alloc)` の形にする
   - `withDeadline` / `withTimeout` は `DeadlineCtx` の `io` フィールドへの保存にも使う
   - `withDeadline` 内の `std.time.nanoTimestamp()` 置き換え（line 295）:
     - fast-path: `if (deadlineNs <= std.time.nanoTimestamp())` → `if (deadlineNs <= std.Io.Clock.Timestamp.now(io, .monotonic).raw.nanoseconds)`
   - `withDeadline` 内の `cancelFn` 呼び出し2箇所に `io` を追加:
     - fast-path: `ctx.state.cancelFn(error.DeadlineExceeded)` → `ctx.state.cancelFn(io, error.DeadlineExceeded)`
     - errdefer: `ctx.state.cancelFn(error.Canceled)` → `ctx.state.cancelFn(io, error.Canceled)`
   - `withTimeout` 内の `std.time.nanoTimestamp()` 置き換え（line 318）:
     - `const dl = std.time.nanoTimestamp() + @as(i128, timeoutNs)` → `const dl = std.Io.Clock.Timestamp.now(io, .monotonic).raw.nanoseconds + @as(i96, timeoutNs)`
8. `DeadlineCtx` に `io: std.Io` フィールドを追加し、`timerWorker` に `io` を渡す
   - `timerWorker` 内の `std.time.nanoTimestamp()` → `std.Io.Clock.Timestamp.now(ctx.io, .monotonic).raw.nanoseconds`
   - `timerWorker` 内の `ctx.state.signal.waitTimeout(waitNs)` → `ctx.state.signal.waitTimeout(ctx.io, waitNs)`
   - `timerWorker` 内の `ctx.state.cancelFn(error.DeadlineExceeded)` → `ctx.state.cancelFn(ctx.io, error.DeadlineExceeded)`
   - `deadlineNs` の型を `i128` → **`i96`** に変更（`std.Io.Timestamp.nanoseconds` の型に統一）
   - 公開関数 `withDeadline` の引数 `deadlineNs: i128` も **`i96`** に変更
   - `Context.deadline()` の戻り型 `?i128` も **`?i96`** に変更
   - `deadline()` の戻り型変更に伴い、テスト内の型アノテーションも更新（line 496, 502）:
     - `try std.testing.expectEqual(@as(?i128, dl), r.context.deadline())` → `@as(?i96, dl)`
     - `try std.testing.expectEqual(@as(?i128, null), r.context.deadline())` → `@as(?i96, null)`
9. `CancelCtx.deinit(self, io)` / `DeadlineCtx.deinit(self, io)` に `io` を追加
   - 内部の `self.state.cancelFn(error.Canceled)` → `self.state.cancelFn(io, error.Canceled)` に変更
10. `OwnedContext.cancel(io)` / `OwnedContext.deinit(io)` に `io` を追加
    - `cancel` 内: `c.state.cancelFn(error.Canceled)` → `c.state.cancelFn(io, error.Canceled)`、`d.state.cancelFn(error.Canceled)` → `d.state.cancelFn(io, error.Canceled)` に変更
    - `deinit` 内: `c.deinit()` / `d.deinit()` → `c.deinit(io)` / `d.deinit(io)` に変更
11. テスト内で `const io = std.testing.io;` を使用、各呼び出しに `io` を渡す
    - `std.time.nanoTimestamp()` → `std.Io.Clock.Timestamp.now(io, .monotonic).raw.nanoseconds` に置き換え（`withDeadline` / `withTimeout` テスト内の3箇所: line 442, 454, 492）
    - `withTimeout` テスト内の `dl` の型も `i96` に変わる（`now` が `i96` になるため自動的に変わる、型アノテーションを追加している場合は `i96` に合わせること）
    - `withCancel` / `withDeadline` / `withTimeout` のテスト内の全呼び出し箇所も引数順を変更する（シグネチャ変更に伴う）:
      - `withDeadline(std.testing.allocator, background, past)` → `withDeadline(io, background, past, std.testing.allocator)`（line 443, 455）
      - `withDeadline(std.testing.allocator, background, dl)` → `withDeadline(io, background, dl, std.testing.allocator)`（line 494）
      - `withTimeout(std.testing.allocator, background, ...)` → `withTimeout(io, background, ..., std.testing.allocator)`（line 426, 433, 461）
      - `withCancel(std.testing.allocator, ...)` → `withCancel(io, ..., std.testing.allocator)`（全テスト内の呼び出し箇所）

### Phase 4: example ファイルの移行

各 example（`basic.zig`, `timeout.zig`, `propagation.zig`, `value.zig`, `wait_any.zig`）:

1. `pub fn main() !void` → `pub fn main(io: std.Io, args: []const []const u8) !void`
2. `std.heap.GeneralPurposeAllocator(.{}){}` → `std.heap.DebugAllocator(.{}){}` と `.deinit()` の戻り値変更対応
3. すべての Signal / Context 操作に `io` を渡す
   - `wait_any.zig` の匿名スレッド関数も変更が必要:
     - `fn run(owned: zctx.OwnedContext) void` → `fn run(args: struct { owned: zctx.OwnedContext, io: std.Io }) void` のように `io` を受け渡す
     - `std.Thread.sleep(50 * std.time.ns_per_ms)` → `std.Io.sleep(args.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .monotonic) catch {}`
     - `owned.cancel()` → `args.owned.cancel(args.io)`
     - `std.Thread.spawn` の引数タプルにも `io` を追加する
4. `@import("src/root.zig")` → `@import("zctx")` への変更は **Phase 5 完了後**に行う（build.zig への依存があるため Phase 4 ではまだ手をつけない）

### Phase 5: build.zig の更新（example の正式統合）

- `example/src` シンボリックリンクを削除
- `build.zig` に example の実行ステップを追加（`b.addExecutable` + `root_module` で `zctx` モジュール参照）
- 各 example の `@import("src/root.zig")` → `@import("zctx")` に変更（Phase 4 から持ち越し）
- `mise.toml` の `example:*` タスクを `zig build run-example-basic` などの形式に変更

### Phase 6: README.md の更新

全フェーズ完了後に README.md を最新の API に合わせて更新する。

**利用者向けセクション**

API 一覧（`### API 一覧`）の全シグネチャを更新:

```zig
// 変更前
zctx.withCancel(alloc, parent)
zctx.withTimeout(alloc, parent, timeoutNs)
zctx.withDeadline(alloc, parent, deadlineNs)
result.cancel()
result.deinit()
ctx.err()
signal.wait()
signal.waitTimeout(timeoutNs)
zctx.waitAny(.{ ... })

// 変更後
zctx.withCancel(io, parent, alloc)
zctx.withTimeout(io, parent, timeoutNs, alloc)
zctx.withDeadline(io, parent, deadlineNs, alloc)   // deadlineNs: i96
result.cancel(io)
result.deinit(io)
ctx.err(io)
signal.wait(io)
signal.waitTimeout(io, timeoutNs)
zctx.waitAny(io, .{ ... })
```

コードサンプルを 0.16.0 対応に更新（全サンプル共通）:
- `main` シグネチャ: `pub fn main() !void` → `pub fn main(io: std.Io, args: []const []const u8) !void`
- `std.heap.GeneralPurposeAllocator(.{}){}` → `std.heap.DebugAllocator(.{}){}`
- `std.Thread.sleep(...)` → `std.Io.sleep(io, .{ .nanoseconds = ... }, .monotonic) catch {}`
- 各 API 呼び出しに `io` 引数を追加

**開発者向けセクション**

- `### 必要なツール`: `Zig 0.15.2` → `Zig 0.16.0`
- `### タスク`:
  - `mise run build` の説明: `zig build-lib` → `zig build --summary all`
  - `mise run test` のテスト件数をビルド結果に合わせて更新
  - `mise run example:*` の形式を Phase 5 後の新コマンド（`zig build run-example-*`）に更新
- `### ファイル構成`:
  - `example/src@` シンボリックリンクの行を削除（Phase 5 で除去済み）

## 実装時の注意事項

- `std.Io.Mutex.lockUncancelable` を優先使用してエラー伝播を最小化し、公開 API の戻り型を `void` に保つ
- `Signal.fire(io)` の実装: mutex 保持下で `fired.isSet()` を確認（idempotent 保証）→ waiters 通知 → `fired.set(io)` の順にすること
- `Signal.wait(io)` は `fired.waitUncancelable(io)` を直接呼ぶだけでよい（`Event` 内部で `is_set` なら即返りする）
- `Signal.waitTimeout(io, ns)` は `Clock.Timestamp.fromNow` で deadline を算出し、`while (!isSet())` ループ内で時刻チェック → `fired.waitTimeout(io, deadline_timeout) catch {}` の形で実装する。`error.Timeout`（タイムアウト or spurious）と `error.Canceled`（キャンセル）の両方を無視し、ループ先頭で `isSet()` と `now >= deadline` を再確認する
- `std.Io.Timeout` の deadline 構築: `std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .{ .nanoseconds = @intCast(timeoutNs) }, .clock = .monotonic })` で `Clock.Timestamp` を得て `.{ .deadline = deadline_ts }` に包む
- `WaitTarget.firedIndex` は `std.atomic.Value(u32)`（futex は `@sizeOf(T) == 4` の comptime assert あり）
- `timerWorker` に `io` を渡す方法: `DeadlineCtx` に `io: std.Io` フィールドを追加し、`withDeadline` から受け取った `io` を保存して `std.Thread.spawn` 時に渡す
- `deadlineNs` の型: **`i96`** に統一する（`std.Io.Timestamp.nanoseconds` の型と一致させる）
- `std.Io.Mutex` の初期化: `pub const init` があるため `= .init` で初期化可能
- `std.Io.Event` の初期化: `= .unset`（通常）、`= .is_set`（alwaysFiredSignal 用）
- Phase の順序依存: Phase 2（signal.zig）→ Phase 3（context.zig）の順を守ること（context.zig は Signal.fire(io) を呼ぶため）
- **引数順の原則**: メソッドは `self → io → ペイロード引数 → allocator`、自由関数は `io → ペイロード引数 → allocator`。`allocator` は末尾（`std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator)` 等に倣う）

## 未解決事項

- [x] `deadlineNs` の型変更方針: **`i96` に変更する**（`std.Io.Timestamp.nanoseconds` に統一）
- [x] Phase 5（build.zig での example 統合）は Phase 4 完了後に改めて検討 → 完了

## 実装振り返り：計画と実際の差異

実装時に判明した、計画ドキュメントの記述と実際の Zig 0.16.0 API の差異を記録する。

### 1. `std.Io.Clock` の enum メンバー名

| 計画の記述 | 実際の API |
|---|---|
| `.monotonic` | 存在しない |
| （記載なし） | `.awake`（モノトニッククロック、サスペンド時間を除外） |
| （記載なし） | `.boot`（モノトニッククロック、サスペンド時間を含む） |
| （記載なし） | `.real`（壁掛け時計） |

**影響箇所**: `signal.zig` の `waitTimeout` / テスト内 `sleep`、`context.zig` の `timerWorker` / `withDeadline` / `withTimeout` / 各テスト。
**対処**: すべて `.monotonic` → `.awake` に変更した。

### 2. `main` 関数のシグネチャ

| 計画の記述 | 実際の API |
|---|---|
| `pub fn main(io: std.Io, args: []const []const u8) !void` | `pub fn main(env: std.process.Init) !void` |

`std.process.Init` は以下のフィールドを持つ:

```zig
pub const Init = struct {
    minimal: Minimal,   // args / environ
    arena: *std.heap.ArenaAllocator,
    gpa: Allocator,     // デフォルト汎用アロケータ
    io: Io,             // Io インスタンス
    environ_map: *Environ.Map,
    preopens: Preopens,

    pub const Minimal = struct {
        environ: Environ,
        args: Args,
    };
};
```

`start.zig` は `root.main(.{ .io = ..., .gpa = ..., ... })` の形で呼ぶため、シングル struct 引数のシグネチャが必須。

**影響箇所**: 全 example ファイルの `main`。
**対処**: `pub fn main(env: std.process.Init) !void` に変更し、`env.io` / `env.gpa` から `io` とアロケータを取得。`DebugAllocator` の手動作成は不要になった。

### 3. `std.heap.DebugAllocator` の手動作成

| 計画の記述 | 実際の対処 |
|---|---|
| `var da = std.heap.DebugAllocator(.{}).init` で作成 | `env.gpa` を使用（`std.process.Init` が提供） |

`std.process.Init.gpa` が Debug ビルドでリークチェック付きアロケータを提供するため、`DebugAllocator` を自前で作成する必要がなかった。

### 4. `std.ArrayListUnmanaged` の初期化

| 計画の記述 | 実際の API |
|---|---|
| `.{}` で初期化可能（0.15 以前の挙動） | `.empty` が必要（`items` / `capacity` フィールドが必須） |

Zig 0.16 では `std.ArrayListUnmanaged` の `items` と `capacity` フィールドが必須となったため、`.{}` によるゼロ初期化はコンパイルエラーになる。

```zig
// NG
.children = .{},
// OK
.children = .empty,
```

**影響箇所**: `context.zig` の `CancelState.init`（`.children = .{}`）と `cancelFn`（`self.children = .{}`）の 2 箇所。

### 5. example の `@import` パス（Phase 5）

| 計画の記述 | 実際の対処 |
|---|---|
| Phase 4 では `@import("src/root.zig")` を維持、Phase 5 で `@import("zctx")` に変更 | Phase 4 と Phase 5 を同時に実施 |

`build.zig` に `b.createModule` + `exe_mod.addImport("zctx", mod)` でモジュールを設定し、example は全て `@import("zctx")` を使う形で実装した。`example/src` シンボリックリンクは削除済み。

### 6. `wait_any.zig` のスレッド引数の型一致問題

匿名 struct をスレッド関数の引数型として使う場合、関数パラメータの型宣言と `std.Thread.spawn` 呼び出し側の struct リテラルが **別の匿名 struct 型**として扱われ、型ミスマッチが発生した。

**対処**: ファイルスコープで名前付き struct（`ThreadArgs`）を定義し、両側で同一型を参照するようにした。

```zig
// NG（2つの匿名 struct は別型）
fn run(args: struct { owned: OwnedContext, io: std.Io }) void { ... }
std.Thread.spawn(.{}, run, .{.{ .owned = ctx_b, .io = io }})

// OK（名前付き型で統一）
const ThreadArgs = struct { owned: OwnedContext, io: std.Io };
fn run(args: ThreadArgs) void { ... }
std.Thread.spawn(.{}, run, .{ThreadArgs{ .owned = ctx_b, .io = io }})
```

なお、同じパターンが `signal.zig` のテスト（インライン匿名 struct）では問題なく動作した。`test` ブロック内の匿名 struct とは異なり、`main` 関数内では別スコープと見なされる可能性がある。
