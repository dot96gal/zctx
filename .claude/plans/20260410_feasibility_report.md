# GoのContext（キャンセル）をZigで実装する実現性レポート

作成日: 2026-04-10  
対象Zigバージョン: 0.15.2

---

## 1. GoのContext概要

Goの`context`パッケージは以下の機能を提供する。

### インターフェース

```go
type Context interface {
    Done() <-chan struct{}       // キャンセルされたら閉じられるチャンネル
    Err() error                  // キャンセル理由（nil / Canceled / DeadlineExceeded）
    Deadline() (time.Time, bool) // デッドライン
    Value(key any) any           // キーバリューストア
}
```

### コンストラクタ

| 関数 | 説明 |
|------|------|
| `context.Background()` | ルートコンテキスト（キャンセルなし） |
| `context.TODO()` | プレースホルダー |
| `context.WithCancel(parent)` | 手動キャンセル可能なコンテキスト |
| `context.WithTimeout(parent, d)` | タイムアウト付きコンテキスト |
| `context.WithDeadline(parent, t)` | デッドライン付きコンテキスト |
| `context.WithValue(parent, k, v)` | キーバリュー付きコンテキスト |

### 主要な振る舞い

- **親→子の伝播**: 親がキャンセルされると、全ての子も自動でキャンセルされる
- **スレッドセーフ**: 複数のゴルーチンから安全に使える
- **`Done()`チャンネル**: `select`文でキャンセルを待機できる

---

## 2. ZigとGoの機能差異

### 2.1 インターフェース

| Go | Zig |
|----|-----|
| `interface` | ネイティブのインターフェースなし |
| ダックタイピング | vtable（関数ポインタ struct）またはタグ付き共用体 |

**Zigでの対応方針**:  
- **タグ付き共用体アプローチ**: `const Context = union(enum) { background, cancel: *CancelCtx, ... }` — パターンマッチングが明確。網羅性がコンパイル時に検証される。`anyopaque`キャストが不要でZigらしい。
- **vtableアプローチ**: `const Context = struct { ptr: *anyopaque, vtable: *const VTable }` — ユーザーによる拡張が可能。`std.mem.Allocator`と同様のパターン。

→ **推奨: タグ付き共用体アプローチ**。コンテキストの種類（background/todo/cancelled/cancel/deadline/value）は閉じた集合であり、Zigらしい網羅性チェックが活きる。`anyopaque`キャストも不要。`std.json.Value`・`std.builtin.Type`と同様の設計。

### 2.2 チャンネル（Done()）

| Go | Zig |
|----|-----|
| `chan struct{}`（ブロッキング待機可能） | 標準ライブラリにチャンネルなし |

**分析**:  
GoのDone()チャンネルが提供する機能は3つ。

1. **ポーリング** — `select { case <-ctx.Done(): ... default: ... }`
2. **ブロッキング待機** — `<-ctx.Done()`
3. **複数シグナルの同時待機** — `select { case <-ctx.Done(): ... case v := <-workCh: ... }` ← 最重要

なお、Done()チャンネルは値を送受信しない（`close(ch)`でブロードキャストするだけ）。フルチャンネルは過剰で、**`Signal`型（一射ブロードキャスト信号）**が適切な抽象。

**Zigでの対応方針**:  
`Signal`型を独立したプリミティブとして実装し、`ctx.done()` が `*Signal` を返すAPIにする。`waitAny()`で複数シグナルの同時待機も実現する。

```zig
/// 一射ブロードキャストシグナル。GoのDone()チャンネルのclose相当。
/// waiters は侵入的リンクリスト（アロケータ不要）。`var sig = Signal{}` で初期化可能。
pub const Signal = struct {
    mutex:   std.Thread.Mutex = .{},
    cond:    std.Thread.Condition = .{},
    fired:   std.atomic.Value(bool) = .init(false),
    waiters: ?*WaiterNode = null,  // 侵入的リンクリスト。waitAny() 内でスタック確保。

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
    /// `timerWorker` が手動キャンセルを受け取って早期終了するために使う。
    pub fn waitTimeout(self: *Signal, timeoutNs: u64) bool {
        if (self.isFired()) return true;
        self.mutex.lock();
        defer self.mutex.unlock();
        // start は monotonic clock で残り時間を追跡するために使う。
        // nanoTimestamp() (CLOCK_REALTIME) ではなく Instant (CLOCK_MONOTONIC) を使うことで
        // NTP による時刻逆行に依存しない。
        const start = std.time.Instant.now() catch {
            // now() が失敗するプラットフォームは事実上ない。失敗時は wait せず戻る。
            return self.isFired();
        };
        while (!self.isFired()) {
            const elapsedNs = (std.time.Instant.now() catch return self.isFired()).since(start);
            if (elapsedNs >= timeoutNs) return false;
            const remainingNs = timeoutNs - elapsedNs;
            // timedWait が error.Timeout を返すのと fire() が fired=true をセットするのが
            // 競合した場合に false negative が起きないよう、タイムアウト時も isFired() を再確認する。
            self.cond.timedWait(&self.mutex, remainingNs) catch return self.isFired();
        }
        return true;
    }
};

/// 複数シグナルのいずれかを待つ（Goのselect相当）。
/// signals は *Signal フィールドを持つ struct（anytype）。
/// 戻り値: 発火したフィールド名に対応する FieldEnum 値。exhaustive switch が使える。
pub fn waitAny(signals: anytype) std.meta.FieldEnum(@TypeOf(signals)) {
    const T = @TypeOf(signals);
    const fields = std.meta.fields(T);
    // struct フィールドを *Signal スライスに変換（comptime）
    var ptrs: [fields.len]*Signal = undefined;
    inline for (fields, 0..) |f, i| ptrs[i] = @field(signals, f.name);
    // 内部スライス実装に委譲してインデックスを得る
    const idx = waitAnySlice(&ptrs);
    return @enumFromInt(idx);
}

/// waitAny の内部実装。公開しない。
fn waitAnySlice(signals: []const *Signal) usize { ... }
```

**`waitAny`の実装方針**:  
`WaitTarget`（1つ）と `WaiterNode`（シグナル数分）を `waitAny()` 内でスタック確保し、各 Signal の侵入的リンクリストに `WaiterNode` を繋ぐ。Signal.fire() 時に各 `WaiterNode` の `target.notify()` を呼ぶことで `WaitTarget` へ通知を転送する。Signal はアロケータを持たず、`Signal{}` での初期化やモジュールレベル静的変数として定義できる。  
公開 API の `waitAny` は `anytype` を受け取り `std.meta.FieldEnum` を返すことで、呼び出し側が名前付き case で exhaustive switch を書ける。内部では `waitAnySlice`（スライス + インデックス）を呼ぶ。

```zig
/// waitAny() 内でスタック確保される待機ターゲット（1回の waitAny につき1つ）。
/// 複数の Signal のうち最初に fire() されたインデックスを記録し、waitForAny() を起こす。
/// WaiterNode（N個）とペアで使う。WaiterNode が Signal のリストに登録され、
/// fire 時に target.notify() を呼ぶことでここへ通知が集まる。
const WaitTarget = struct {
    mutex:      std.Thread.Mutex = .{},
    cond:       std.Thread.Condition = .{},
    firedIndex: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),

    fn notify(self: *WaitTarget, idx: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.firedIndex.cmpxchgStrong(
            std.math.maxInt(usize), idx, .acq_rel, .acquire);
        self.cond.broadcast(); // mutex 保持下で broadcast（Signal.fire() は mutex 外で broadcast するが、
                               // どちらも firedIndex / fired がアトミック変数なので missed wakeup は起きない。
                               // ここは mutex 内ブロードキャストとしているが、実装上どちらでも正しい）
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
/// Signal.fire() 時に target.notify() を呼び出すことで WaitTarget へ通知を転送する。
/// 1つの WaiterNode は1つの Signal のリストにのみ属する（next は1本）。
/// N シグナルに対して N ノード + 1 WaitTarget が必要な理由：
///   1本の next ポインタでは複数のリストに同時登録できないため、
///   ノードとターゲットを分離してスタック確保する。
const WaiterNode = struct {
    target: *WaitTarget,         // 通知先（waitAny 呼び出しごとに共有・1つのみ）
    index:  usize,               // この WaiterNode が監視する signals のインデックス
    next:   ?*WaiterNode = null, // 侵入的リンクリストの次ノード
};
```

`waitAny()` / `waitAnySlice()` の実装では、**`signal.mutex` 保持下で `isFired()` を確認してから `WaiterNode` を追加する**必要がある。この "check-then-add" をアトミックに行わないと、`ALWAYS_FIRED_SIGNAL`（`cancelledContext.done()` の戻り値）や手動 `fire()` 済みシグナルを渡した場合にデッドロックになる。

**理由**: `fire()` は `cmpxchgStrong(false, true, ...)` が成功した 1 回だけ `waiters` を走査する。もし `fire()` の走査が終わった後で `WaiterNode` を追加しても `target.notify()` は呼ばれず、`waitForAny()` が永久にブロックする。

**必須手順** (`waitAnySlice` 内):
1. 全シグナルをループし、各シグナルの `mutex` をロック
2. `isFired()` が true なら、登録済みの `WaiterNode`（インデックス 0〜i-1 分）をリストから除去してから当該インデックスを返す（use-after-free 防止）
3. false なら `WaiterNode` をリストに追加してアンロック
4. `target.waitForAny()` で待機
5. 戻る前に全シグナルの `mutex` をロックして `WaiterNode` を除去し、アンロック

```zig
// waitAnySlice の実装イメージ（擬似コード）
fn waitAnySlice(signals: []const *Signal) usize {
    // ① WaitTarget（1個）と WaiterNode（signals.len 個）をスタック確保
    // WaitTarget: 全シグナルの通知先。waitForAny() はここで待つ。
    // WaiterNode: 各シグナルのリストに登録するノード。1ノード1リスト（next は1本）。
    var target = WaitTarget{};
    var nodes: [/*signals.len*/]WaiterNode = undefined;
    for (0..signals.len) |i| nodes[i] = .{ .target = &target, .index = i };

    // ② 各シグナルに mutex 保持下で登録（発火済みなら登録済み分をクリーンアップして返却）
    var registered: usize = 0;
    for (signals, 0..) |sig, i| {
        sig.mutex.lock();
        if (sig.isFired()) {
            sig.mutex.unlock();
            // 登録済みの nodes[0..registered] をリストから除去してから返す。
            // 除去せずに return するとスタックフレーム解放後も
            // ポインタが残り use-after-free になる。
            for (signals[0..registered]) |prev_sig| {
                prev_sig.mutex.lock();
                // リストから &nodes[j] を除去（省略）
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

    // ③ WaitTarget で最初の通知を待つ
    // Signal[i].fire() → nodes[i].target.notify(i) → target.firedIndex = i → target.cond.broadcast()
    const firedIdx = target.waitForAny();

    // ④ 全シグナルから WaiterNode を除去（mutex 保護）
    for (signals) |sig| {
        sig.mutex.lock();
        // リストから &nodes[i] を除去（省略）
        sig.mutex.unlock();
    }
    return firedIdx;
}
```

`waitAny()` は各 Signal のリストに `WaiterNode` を追加し、戻る前に除去する（mutex 保護）。早期 return 時（登録ループ中に発火済みシグナルを発見した場合）も、登録済みの `WaiterNode` を全て除去してから返す。

### 2.3 ゴルーチン / 非同期

| Go | Zig |
|----|-----|
| ゴルーチン（軽量スレッド） | `std.Thread`（OSスレッド）|
| `time.AfterFunc` | `std.Thread.spawn` でタイマースレッド |

- Zigの`async/await`は0.12で削除済み。スレッドを使う必要がある。
- `WithTimeout` / `WithDeadline` はバックグラウンドスレッドでタイマーを管理する実装が必要。

### 2.4 ガベージコレクション / メモリ管理

| Go | Zig |
|----|-----|
| GC（自動解放） | 手動管理（`defer result.deinit()`） |

**Zigでの対応方針**:
- コンテキストはヒープ確保（アロケータを引数で受け取る）
- **キャンセルと解放を分離する**: `cancel()` はシグナルのみ、`deinit()` がメモリ解放
  - これにより「キャンセル後の状態を検査する」テストが書ける（後述セクション7参照）
- ライフタイムはGoより明示的になるが、Zigの哲学と一致する

```zig
// 利用例
const result = try withCancel(allocator, parent);
defer result.deinit(); // 常にメモリ解放（cancelの有無に関わらず）

result.cancel(); // シグナルのみ。メモリは触らない。idempotent。

// 別スレッドでの利用（Canceled / DeadlineExceeded を正確に返す）
if (result.context.err()) |e| return e;
```

### 2.5 型安全なValue

| Go | Zig |
|----|-----|
| `any`（interface{}）| `anyopaque`ポインタ + 型情報が必要 |

**Zigでの対応方針**:
- 内部実装: キーを`usize`、値を`*anyopaque`で扱う（`ctx.value(key)` は `typedValue` の実装基盤として使う）
- 公開API: `comptime`型付きキーと `withTypedValue` / `typedValue` メソッドのみ公開。`@ptrCast`を利用側に露出しない。
  - テストコードの煩雑さを解消し、型の取り違えをコンパイル時に検出できる
  - 低レベル `withValue` は公開しない（`withTypedValue` で全ユースケースをカバー）

```zig
// TypedKey: 型ごとにユニークなキーを生成
pub fn TypedKey(comptime T: type) type {
    return struct {
        pub const Value = T;
        pub const key: usize = @intFromPtr(&struct { var x: u8 = 0; }.x);
    };
}

// withTypedValue: 値をヒープにコピーして保持。ValueCtx.deinit() で解放。
// 呼び出し側は value のライフタイムを気にしなくてよい。
pub fn withTypedValue(
    comptime Key: type,
    allocator: std.mem.Allocator,
    parent: Context,
    value: Key.Value,
) !OwnedContext { ... }

// typedValue: Context のメソッドとして定義（他のメソッドと統一）
// 型安全な取り出し（@ptrCast 不要）
pub fn typedValue(ctx: Context, comptime Key: type) ?Key.Value { ... }
// → ctx.typedValue(Key) として呼び出す（セクション3.1のContextメソッド定義に含める）

// 利用例
const UserKey = zctx.TypedKey(User);
const result = try zctx.withTypedValue(UserKey, allocator, parent, user);
defer result.deinit();

const u: ?User = result.context.typedValue(UserKey); // @ptrCast 不要
```

---

## 3. 実装設計案

### 3.1 型定義

```zig
/// キャンセル理由。error set として定義することで、呼び出し側が `return e` や
/// `try ctx.check()` で Zig の通常のエラー伝播に組み込める。
/// `expectEqual(CancelError.Canceled, ...)` のようなアクセスも変わらない。
pub const CancelError = error{
    Canceled,
    DeadlineExceeded,
};

/// タグ付き共用体によるContext。
/// 種類は閉じた集合（background/todo/cancelled/cancel/deadline/value）。
/// switchによる網羅性チェックがコンパイル時に働く。
pub const Context = union(enum) {
    background,
    todo,             // プレースホルダー。background と同じ振る舞い。静的解析ツール向けの意味付け。
    cancelled,        // 常にdone=true、err=Canceled。静的。アロケータ不要。
    cancel:   *CancelCtx,
    deadline: *DeadlineCtx,
    value:    *ValueCtx,

    pub fn done(ctx: Context) *Signal {
        return switch (ctx) {
            .background, .todo => &NEVER_FIRED_SIGNAL,
            .cancelled         => &ALWAYS_FIRED_SIGNAL,
            .cancel            => |c| &c.state.signal,
            .deadline          => |d| &d.state.signal,
            .value             => |v| v.parent.done(),
        };
    }

    pub fn err(ctx: Context) ?CancelError {
        return switch (ctx) {
            .background, .todo => null,
            .cancelled         => .Canceled,
            .cancel => |c| blk: {
                c.state.mutex.lock();
                defer c.state.mutex.unlock();
                break :blk c.state.cancelErr;
            },
            .deadline => |d| blk: {
                d.state.mutex.lock();
                defer d.state.mutex.unlock();
                break :blk d.state.cancelErr;
            },
            .value => |v| v.parent.err(),
        };
    }
    // 注: cancelErr は mutex 保護下で書き込まれるため、読み取りも mutex を取得する。
    // mutex なしの読み取りはデータレースになる（.cancel / .deadline ケース）。

    pub fn deadline(ctx: Context) ?i128 {
        return switch (ctx) {
            .background, .todo => null,
            .cancelled         => null,
            .cancel            => null,
            .deadline          => |d| d.deadlineNs,
            .value             => |v| v.parent.deadline(),
        };
    }

    fn value(ctx: Context, key: usize) ?*anyopaque {
        return switch (ctx) {
            .background, .todo => null,
            .cancelled         => null,
            .cancel            => null,
            .deadline          => null,
            .value             => |v| if (v.key == key) v.val else v.parent.value(key),
        };
    }

    /// 型安全な値の取り出し（@ptrCast 不要）。
    pub fn typedValue(ctx: Context, comptime Key: type) ?Key.Value {
        const raw = ctx.value(Key.key) orelse return null;
        return @as(*Key.Value, @ptrCast(@alignCast(raw))).*;
    }
};

/// withCancel / withDeadline / withTimeout / withTypedValue の返り値型。
/// "Owned" はこの値がコンテキストのオーナーであることを示す（deinit() でメモリを解放する責任）。
/// cancel() と deinit() を分離し、キャンセル後も context の読み取りを安全にする。
/// anyopaque を使わず Context のタグで dispatch する。
pub const OwnedContext = struct {
    context: Context,

    /// シグナルのみ発火。メモリは解放しない。idempotent。
    /// .value は独立したキャンセル不可。withCancel でラップした親の cancel() を呼ぶこと。
    pub fn cancel(self: OwnedContext) void {
        switch (self.context) {
            .background, .todo, .cancelled => {},
            .cancel   => |c| c.state.cancel(.Canceled),
            .deadline => |d| d.state.cancel(.Canceled),
            .value    => {}, // ValueCtx はキャンセル所有者ではない。no-op。
            // 注: .value で cancel() を呼んでも何も起きない。
            // 親コンテキストをキャンセルしたい場合は親の OwnedContext.cancel() を直接呼ぶ。
        }
    }

    /// メモリを解放する。未キャンセルなら先にキャンセルしてから解放。
    /// defer で必ず呼ぶ。
    pub fn deinit(self: OwnedContext) void {
        switch (self.context) {
            .background, .todo, .cancelled => {},
            .cancel   => |c| c.deinit(),
            .deadline => |d| d.deinit(),
            .value    => |v| v.deinit(),
        }
    }
};

/// ルートコンテキスト（アロケータ不要）。キャンセルされない。
pub const background: Context = .background;

/// プレースホルダー（アロケータ不要）。background と同じ振る舞い。
/// 「後で適切なコンテキストに置き換えること」を意図して使う。
pub const todo: Context = .todo;

/// 最初からキャンセル済みのコンテキスト（アロケータ不要）。
/// .cancelled variant の値。*CancelCtx のヒープ確保が不要。
/// done() は module-level の ALWAYS_FIRED_SIGNAL を返す。
pub const cancelledContext: Context = .cancelled;

/// context.zig 内部のモジュールレベル変数。Context.done() が参照する。
/// Signal は Mutex を含むため const にできず var で定義する。
/// ALWAYS_FIRED_SIGNAL は fired フィールドを直接 true に設定して初期化する
/// （起動時に fire() を呼ぶことが comptime では不可能なため）。
var NEVER_FIRED_SIGNAL: Signal = .{};
var ALWAYS_FIRED_SIGNAL: Signal = .{ .fired = .init(true) };
```

**利用例（Signalベース）:**

```zig
// キャンセル確認（err() イディオム）
if (ctx.err()) |e| return e;

// ブロッキング待機（Signal API を直接使う）
ctx.done().wait();

// 複数シグナルの同時待機（Goのselect相当）
const sig = waitAny(.{
    .cancel  = ctx.done(),
    .work    = work_signal,
    .timeout = timeout_signal,
});
switch (sig) {
    .cancel  => return error.Canceled,
    .work    => process(work_result),
    .timeout => return error.Timeout,
    // else unreachable 不要。コンパイラが網羅性を保証。
}
```

### 3.2 CancelContextの実装

CancelCtx と DeadlineCtx の共通フィールド・ロジックを `CancelState` に切り出す。  
伝播ロジックは1箇所だけ定義され、両者が委譲する。

```zig
/// CancelCtx / DeadlineCtx 共通の状態とキャンセルロジック。
const CancelState = struct {
    signal:     Signal,
    cancelErr: ?CancelError,
    mutex:      std.Thread.Mutex,
    children:   std.ArrayList(CancelChild),

    const CancelChild = union(enum) {
        cancel:   *CancelCtx,
        deadline: *DeadlineCtx,

        fn propagate(child: CancelChild, reason: CancelError) void {
            switch (child) {
                .cancel   => |c| c.state.cancel(reason),
                .deadline => |d| d.state.cancel(reason),
            }
        }
    };

    /// シグナルのみ発火。メモリは解放しない。idempotent。
    /// CancelCtx / DeadlineCtx 両方が委譲する。
    fn cancel(self: *CancelState, reason: CancelError) void {
        self.mutex.lock();
        // isFired() ではなく cancelErr != null で判定する。
        // isFired() は mutex.unlock() 後の signal.fire() 呼び出しより前は false のままであり、
        // その窓で別スレッドが cancel() に入ると children.deinit() が二重呼び出しになる（double-free）。
        // cancelErr は mutex 保持下でのみセットされるため、この確認は安全。
        if (self.cancelErr != null) { self.mutex.unlock(); return; }
        self.cancelErr = reason;
        for (self.children.items) |child| child.propagate(reason);
        self.children.deinit();
        self.mutex.unlock();
        self.signal.fire();
    }
};

const CancelCtx = struct {
    allocator: std.mem.Allocator,
    parent:    Context,
    state:     CancelState,   // 共通ロジックを委譲

    fn deinit(self: *CancelCtx) void {
        self.state.cancel(.Canceled); // 冪等
        self.allocator.destroy(self);
    }
};
```

### 3.3 親子連携

タグ付き共用体により、switchで親の種類に応じた登録先を明示的に決定できる。

**TOCTOU 問題への対処**: 「親の children に append する」操作と「親が既にキャンセル済みか確認する」操作を、親の mutex を保持したまま原子的に行う必要がある。これを怠ると、append 直後に別スレッドが親の cancel() を呼んで children を走査・deinit した場合、子が伝播を受け取れない missed-wakeup が発生する。

```zig
pub fn withCancel(allocator: std.mem.Allocator, parent: Context) !OwnedContext {
    const ctx = try allocator.create(CancelCtx);
    errdefer allocator.destroy(ctx); // 以降のエラーで自動解放（リーク防止）
    ctx.* = .{
        .allocator = allocator,
        .parent    = parent,
        .state     = .{
            .signal     = .{},
            .cancelErr = null,
            .mutex      = .{},
            .children   = .init(allocator),
        },
    };
    // TOCTOU 防止: registerChild が親 mutex 保持下で「登録 or 即 fire」を原子的に行う
    try registerChild(parent, .{ .cancel = ctx });
    return .{ .context = .{ .cancel = ctx } };
}

// withDeadline の実装は §3.4 参照（スレッド生成を registerChild より先に行う2段 errdefer 構成）。

/// value コンテキスト越しに先祖を辿り、最初の cancel/deadline に子を登録する。
/// background / todo に到達した場合は登録不要（キャンセルされない）。
/// child は CancelChild（.cancel または .deadline）で、withCancel / withDeadline 両方に対応する。
fn registerChild(parent: Context, child: CancelState.CancelChild) !void {
    return switch (parent) {
        .background, .todo => {},                        // キャンセルされない。登録不要。
        .cancelled         => child.propagate(.Canceled), // 常にキャンセル済み → cancelErr も含め即伝播
        .cancel   => |p| registerToState(&p.state, child),
        .deadline => |p| registerToState(&p.state, child),
        .value    => |v| registerChild(v.parent, child),  // 先祖を再帰的に辿る
    };
}

/// CancelState に子を登録する（mutex 保護）。
/// 既キャンセルなら append せず propagate する（TOCTOU 防止の核心）。
/// CancelState.cancel() は mutex 保持中に cancelErr をセットし children.deinit() するため、
/// cancelErr != null を mutex 保持下で確認することで安全な排他が成立する。
/// fireChild（signal.fire() のみ）ではなく propagate（state.cancel() 経由）を使うことで、
/// 新規子の cancelErr も確実にセットされる。
fn registerToState(state: *CancelState, child: CancelState.CancelChild) !void {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.cancelErr != null) {
        child.propagate(state.cancelErr.?); // 既キャンセル済み → cancelErr も含め即伝播
    } else {
        try state.children.append(child);
    }
}
```

### 3.4 Deadlineの実装

`WithTimeout` / `WithDeadline` はバックグラウンドスレッドでタイマーを管理する。タイマースレッドは手動キャンセルで中断可能にする（詳細は後述）。

**`deinit()` 内でのスレッド `join()` は実装上の必須要件。**  
これを省くとテスト終了後もタイマースレッドが生存し、`testing.allocator` のリーク検出が誤作動したり後続テストに干渉する。

**タイマースレッドの動作方針（中断可能・ポーリング不要）:**  
タイマースレッドは `std.time.sleep()` ではなく `Signal.waitTimeout()` でデッドラインまで待機する。手動 `cancel()` が呼ばれると `CancelState.signal` が発火し、`waitTimeout()` が早期リターンするためスレッドがすぐ終了する。これにより `deinit()` 内の `timerThread.join()` がブロックしない。

```zig
// タイマースレッドの実装イメージ
fn timerWorker(ctx: *DeadlineCtx) void {
    // CLOCK_REALTIME で残り時間を計算。
    // ただし待機自体は Signal.waitTimeout() が CLOCK_MONOTONIC（std.time.Instant）で
    // 残り時間を追跡するため、NTP による時刻逆行の影響を受けない。
    const now = std.time.nanoTimestamp();
    const remaining = ctx.deadlineNs - now;
    if (remaining > 0) {
        // remaining は i128。Signal.waitTimeout は u64 を受け取る。
        // remaining > maxInt(u64)（約292年後）の場合は上限をクランプする。
        const waitNs: u64 = if (remaining > std.math.maxInt(u64))
            std.math.maxInt(u64)
        else
            @intCast(remaining);
        // 発火済み（手動 cancel 済み）なら即リターン。ブロッキングを防ぐ核心。
        if (ctx.state.signal.waitTimeout(waitNs)) return;
    }
    ctx.state.cancel(.DeadlineExceeded); // idempotent。手動 cancel 済みでも安全。
    // スレッド終了
}
```

**過去のデッドラインへの対応（fast-path）:**  
`deadlineNs <= std.time.nanoTimestamp()` の場合はタイマースレッドを起動せず、`withDeadline` 内で即 `registerChild` → 即 `cancel(.DeadlineExceeded)` を呼ぶ。スレッド起動コストを省き、`timerThread` フィールドを `?std.Thread` にすることで実現する。

```zig
pub fn withDeadline(
    allocator:  std.mem.Allocator,
    parent:     Context,
    deadlineNs: i128,
) !OwnedContext {
    const ctx = try allocator.create(DeadlineCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator   = allocator,
        .parent      = parent,
        .state       = .{ .signal = .{}, .cancelErr = null, .mutex = .{}, .children = .init(allocator) },
        .deadlineNs  = deadlineNs,
        .timerThread = null, // fast-path では null のまま
    };

    // fast-path: 既に期限切れならスレッド不要
    if (deadlineNs <= std.time.nanoTimestamp()) {
        try registerChild(parent, .{ .deadline = ctx });
        ctx.state.cancel(.DeadlineExceeded);
        return .{ .context = .{ .deadline = ctx } };
    }

    // ① registerChild より先にスレッドを起動する。
    ctx.timerThread = try std.Thread.spawn(.{}, timerWorker, .{ctx});

    errdefer {
        ctx.state.cancel(.Canceled);
        ctx.timerThread.?.join();
    }

    try registerChild(parent, .{ .deadline = ctx });
    return .{ .context = .{ .deadline = ctx } };
}

pub fn withTimeout(
    allocator:  std.mem.Allocator,
    parent:     Context,
    timeoutNs:  u64,
) !OwnedContext {
    // CLOCK_REALTIME を使う。timerWorker 内の待機は CLOCK_MONOTONIC で追跡するため
    // NTP 影響はスレッド起動時の remaining 計算のみに限定される。
    const dl = std.time.nanoTimestamp() + @as(i128, timeoutNs);
    return withDeadline(allocator, parent, dl);
}

const DeadlineCtx = struct {
    allocator:    std.mem.Allocator,
    parent:       Context,
    state:        CancelState,
    deadlineNs:  i128,
    timerThread: ?std.Thread,  // fast-path（過去デッドライン）では null

    fn deinit(self: *DeadlineCtx) void {
        self.state.cancel(.Canceled); // idempotent。未キャンセルなら先にキャンセル（タイマースレッドも終了へ）
        if (self.timerThread) |t| t.join(); // null（fast-path）なら join 不要
        self.allocator.destroy(self);
    }
};
```

**クロック選択の注記:**  
`deadlineNs` パラメータは `std.time.nanoTimestamp()` と同じ基準（POSIX CLOCK_REALTIME）。この値は NTP による時刻の跳び戻りで変動する可能性がある。ただし `timerWorker` 内の待機は `Signal.waitTimeout()` が `std.time.Instant`（CLOCK_MONOTONIC）で残り時間を追跡するため、NTP の影響はスレッド起動時の `remaining` 計算のみに限定される。完全にモノトニックな API を提供したい場合は将来の拡張として `withDeadlineMono(alloc, parent, std.time.Instant)` を検討する。

### 3.5 ValueCtx の実装

`withTypedValue` は `value` を値渡しで受け取るため、`ValueCtx` がヒープにコピーして保持する。コピーの解放は `deinit()` が担う。  
スカラ型・構造体型の場合は value のライフタイムを気にしなくてよい。  
ただし、**スライス・ポインタ型の場合は値表現（ptr/len）のみコピーされる**。指す先のデータはコピーされないため、そのライフタイムは呼び出し側が保証する必要がある（例: `TypedKey([]const u8)` でリクエストスコープ全体で有効な文字列を渡す）。

```zig
const ValueCtx = struct {
    allocator:  std.mem.Allocator,
    parent:     Context,
    key:        usize,
    val:        *anyopaque,
    /// 型情報を持つ解放関数。deinit() 時に val が指すヒープ領域を解放する。
    valDeinit: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,

    fn deinit(self: *ValueCtx) void {
        self.valDeinit(self.allocator, self.val); // 値のコピーを解放
        self.allocator.destroy(self);
    }
};

// withTypedValue の実装イメージ
pub fn withTypedValue(
    comptime Key: type,
    allocator: std.mem.Allocator,
    parent:    Context,
    value:     Key.Value,
) !OwnedContext {
    // 値をヒープにコピー
    const valPtr = try allocator.create(Key.Value);
    errdefer allocator.destroy(valPtr);
    valPtr.* = value;

    const ctx = try allocator.create(ValueCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator  = allocator,
        .parent     = parent,
        .key        = Key.key,
        .val        = valPtr,
        .valDeinit = struct {
            fn f(alloc: std.mem.Allocator, ptr: *anyopaque) void {
                alloc.destroy(@as(*Key.Value, @ptrCast(@alignCast(ptr))));
            }
        }.f,
    };
    return .{ .context = .{ .value = ctx } };
}
```

---

## 4. 実現性評価

### 4.1 実現可能な機能

| 機能 | 実現性 | 備考 |
|------|--------|------|
| `Background()` / `TODO()` | ✅ 容易 | 静的なシングルトン |
| `WithCancel()` | ✅ 可能 | Signal + Mutex |
| `WithTimeout()` / `WithDeadline()` | ✅ 可能 | タイマースレッド + `Signal.waitTimeout()` で中断可能。過去デッドラインは fast-path（スレッド不要）で即キャンセル |
| `withTypedValue()` | ✅ 可能 | タグ付き共用体、型安全はcomptime |
| 親→子キャンセル伝播 | ✅ 可能 | Mutex保護されたArrayList |
| `Done()` チャンネル相当 | ✅ 可能 | Signal型（一射ブロードキャスト） |
| 複数シグナルの同時待機 | ✅ 可能 | `waitAny(signals)` で実現。`anytype` + `FieldEnum` で exhaustive switch |
| スレッドセーフ | ✅ 可能 | std.Thread.Mutex |

### 4.2 Goとの差異・制約

1. **明示的なメモリ管理**: `deinit()`の呼び出し忘れはメモリリーク。`defer result.deinit()`を推奨。
2. **スレッドコスト**: タイムアウト機能はOSスレッドを使用。Goのゴルーチンより重い。
3. **Value型安全性**: 低レベルAPIは`@ptrCast`が必要。高レベル（TypedKey）APIで解消。
4. **`waitAny`のリスナー管理**: `WaitTarget`（1つ）と `WaiterNode`（シグナル数分）は `waitAny()` 内でスタック確保（侵入的リンクリスト）。ヒープ確保は発生しない。ただし `waitAny()` 呼び出し中はシグナルのライフタイムを呼び出し側が保証する必要がある。

### 4.3 リスク・課題

| 課題 | 深刻度 | 対策 |
|------|--------|------|
| `deinit()`忘れによるメモリリーク | 中 | `defer result.deinit()` を規約化 |
| スレッド共有時の `deinit` 順序 | 中 | `defer result.deinit()` を `defer t.join()` より先に宣言する規約（セクション10.1） |
| 親子登録時のレースコンディション | 中 | `registerToState()` が親 mutex 保持下で `cancelErr` 確認と `children.append()` を原子的に実行（§3.3 参照） |
| `waitAny`中にSignalが解放される | 中 | `waitAny`の呼び出し側がシグナルのライフタイムを保証する規約 |
| タイマースレッドのリーク | 中 | `deinit()`内で必ず `timerThread.join()`（`?std.Thread` の場合は null チェックあり）。省くとテスト干渉・リーク誤検出が発生 |
| ~~タイマースレッドの中断不可（deinit ブロッキング）~~ | ~~高~~ | **解決済み**: `timerWorker` が `Signal.waitTimeout()` で待機するため、手動 `cancel()` で即終了。`deinit()` はブロックしない（§3.4 参照） |
| `deadlineNs` が CLOCK_REALTIME 基準 | 低 | 待機は `Signal.waitTimeout()` 内で `std.time.Instant`（CLOCK_MONOTONIC）を使うため NTP 逆行の影響はスレッド起動時の残り時間計算のみ。将来 `withDeadlineMono` で完全対応 |
| `TypedKey(T)` の衝突（同じ型→同じキー） | 中 | 同一型を複数の用途に使うと実行時に値が衝突する。コンパイル時検出不可。ドキュメントで規約化し、将来は第2引数で識別子を強制（§5 タスク7 参照） |
| `TypedKey` のキー値（`@intFromPtr`）の将来的な安定性 | 低 | Zig の comptime memoization により現バージョンでは同型引数→同アドレスが保証されるが、将来の言語変更で変わりうる。影響範囲は `typedValue()` の値の取り出しのみ。タスク7（第2引数で識別子を強制）で解消できる |
| ~~`CancelError` が `enum` で `return e` 不可~~ | ~~高~~ | **解決済み**: `error{Canceled, DeadlineExceeded}` に変更。`return e` や `try ctx.check()` で Zig のエラー伝播に組み込める（§3.1 参照） |
| ~~`Signal.waitTimeout()` false negative~~ | ~~中~~ | **解決済み**: `catch return self.isFired()` に変更。タイムアウトと fire() の競合時も正しく `true` を返す（§2.2 参照） |
| ~~`waitAnySlice` の事前 `isFired()` チェック未定義~~ | ~~中~~ | **解決済み**: `signal.mutex` 保持下で check-then-add をアトミックに行う実装要件を `waitAny` 実装方針に明記（§2.2 参照）。`ALWAYS_FIRED_SIGNAL` を渡してもデッドロックしない |
| ~~`waitAnySlice` の `SharedWaiter` 設計（役割混在によるデッドロック + 早期 return 時の use-after-free）~~ | ~~高~~ | **解決済み**: `SharedWaiter` を `WaitTarget`（通知先・1つ）と `WaiterNode`（リストノード・N個）に分離。Signal.fire() は `waiter.target.notify(waiter.index)` で転送。早期 return 前に登録済み `WaiterNode` を全除去（§2.2 参照） |
| Zig 0.15.2のAPI変更 | 低 | 開発版のため標準ライブラリAPIが変わる可能性 |

---

## 5. 結論

**実現性: 高い。**

GoのContext（キャンセル）の主要機能はZig 0.15.2で実装可能。GoのゴルーチンやGCがない分、APIはやや異なるが、`std.Thread.Mutex`・`std.Thread.Condition`・`std.atomic.Value`を組み合わせることで同等の機能を提供できる。

`Done()`チャンネル相当は`Signal`型（一射ブロードキャストシグナル）として実装し、`waitAny()`を用意することでGoの`select`文相当の複数シグナル同時待機も実現できる。

### ファイル構成

Signalは別ライブラリには切り出さない。プロジェクトのルール（外部ライブラリ禁止）に抵触するため。  
同一リポジトリ内でファイルを分け、`root.zig`から`pub`で再エクスポートする。

```
src/
  root.zig      ← Signal・waitAny・Context等を pub で再エクスポート
  signal.zig    ← Signal, waitAny の実装
  context.zig   ← Context, withCancel, withDeadline, withTypedValue... の実装
```

```zig
// root.zig
pub const Signal       = @import("signal.zig").Signal;
pub const waitAny      = @import("signal.zig").waitAny;
pub const Context      = @import("context.zig").Context;
pub const CancelError  = @import("context.zig").CancelError;
pub const OwnedContext = @import("context.zig").OwnedContext;
pub const TypedKey     = @import("context.zig").TypedKey;
pub const background        = @import("context.zig").background;
pub const todo              = @import("context.zig").todo;
pub const cancelledContext  = @import("context.zig").cancelledContext;
pub const withCancel        = @import("context.zig").withCancel;
pub const withDeadline      = @import("context.zig").withDeadline;
pub const withTimeout       = @import("context.zig").withTimeout;
pub const withTypedValue    = @import("context.zig").withTypedValue;
// withValue（低レベル）は公開しない。withTypedValue で全ユースケースをカバーできる。
```

### タスクリスト

| # | タスク | ファイル | 状態 |
|---|--------|---------|------|
| 1 | `Signal` / `waitAny(anytype)` / `waitAnySlice` / `Signal.waitTimeout()` を実装する | `src/signal.zig` | pending |
| 2 | ルートコンテキストを実装する（`Context` タグ付き共用体・`cancelled` variant・`OwnedContext`・`CancelState`・`TypedKey`・`background` / `todo` / `cancelledContext`） | `src/context.zig` | pending |
| 3 | `withCancel()` と親→子キャンセル伝播を実装する（`errdefer` によるリーク防止含む） | `src/context.zig` | pending |
| 4 | `withDeadline()` / `withTimeout()` を実装する（`timerThread: ?std.Thread`・fast-path・`Signal.waitTimeout()` による中断可能スレッド・`timerThread.join()` 必須） | `src/context.zig` | pending |
| 5 | `withTypedValue()` を実装する（低レベル `withValue` は非公開） | `src/context.zig` | pending |
| 6 | `root.zig` を整備して公開APIをエクスポートする | `src/root.zig` | pending |
| 7 | （将来）`TypedKey` の衝突防止：第2引数に一意な識別子（`comptime []const u8`）を要求する API の検討 | `src/context.zig` | future |
| 8 | （将来）`withDeadlineMono(alloc, parent, std.time.Instant)` を追加し、完全にモノトニックなデッドライン API を提供する | `src/context.zig` | future |
| 9 | （将来）`FakeClock` を実装し、タイムアウト系テストを実時間に依存させない時刻注入インターフェースを提供する（§7.4 参照） | `src/context.zig` | future |
| 10 | （将来）キャンセルコールバック `withCancelFunc` を追加する（`CancelState` に `onCancel` フィールドを追加）（§10.3 参照） | `src/context.zig` | future |

タスク1〜6は前のタスクに依存する（順番に実施する）。タスク7〜10は基本機能完成後の将来対応。

### 参考: Zigにしかない強み

- **コンパイル時型チェック**: `comptime`を使ったValue APIで型安全性を強化できる
- **ゼロコスト抽象**: タグ付き共用体のswitchはコンパイラが最適化しやすい
- **明示的ライフタイム**: メモリ管理が明確で、リークを`defer`で防げる
- **`Signal`の公開**: ファイル分離により`signal.zig`単体でテスト・利用でき、zctxユーザーも`Signal`・`waitAny`を直接使える

---

## 6. 利用者向けサンプルコード

### 6.1 APIサマリー

```zig
// ルートコンテキスト（アロケータ不要）。関数ではなく定数。
zctx.background         // キャンセルされないルート
zctx.todo               // 未実装のプレースホルダー
zctx.cancelledContext   // 最初からキャンセル済み（テスト用途にも便利）

// 派生コンテキスト（返り値は OwnedContext 型）
zctx.withCancel(alloc, parent)
zctx.withTimeout(alloc, parent, timeoutNs)
zctx.withDeadline(alloc, parent, deadlineNs)
zctx.withTypedValue(Key, alloc, parent, value)      // 型安全。低レベル withValue は非公開。

// OwnedContext のメソッド（anyopaque なし。Context タグで dispatch）
result.context   // Context 値
result.cancel()  // シグナルのみ発火。idempotent。メモリは解放しない。
result.deinit()  // メモリ解放（未キャンセルなら先にキャンセル）。defer で呼ぶ。

// Context のメソッド
ctx.done()                    // *Signal  ← isFired() / wait() が使える
ctx.err()                     // ?CancelError（= ?error{Canceled,DeadlineExceeded}）
ctx.deadline()                // ?i128
ctx.typedValue(Key)           // ?Key.Value（型安全、@ptrCast 不要）
// ※ ctx.value(key: usize) は内部実装用の低レベルAPIのため公開しない。typedValue を使うこと。

// Signal のユーティリティ
// signals は *Signal フィールドを持つ struct。戻り値は FieldEnum（exhaustive switch 可）。
zctx.waitAny(.{ .name = signal_ptr, ... })  // std.meta.FieldEnum(@TypeOf(signals))
signal.waitTimeout(timeoutNs)              // bool: 発火=true、タイムアウト=false
```

### 6.2 基本的なキャンセル

```zig
const zctx = @import("zctx");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const result = try zctx.withCancel(allocator, zctx.background);
    defer result.deinit(); // 宣言順: 1番目 → 実行順: 2番目（後）。join より後に解放される。

    const thread = try std.Thread.spawn(.{}, doWork, .{result.context});
    defer thread.join();   // 宣言順: 2番目 → 実行順: 1番目（先）。deinit より前に join される。

    std.time.sleep(100 * std.time.ns_per_ms);
    result.cancel(); // 作業を中断させる（シグナルのみ）
    // defer の LIFO 順: thread.join() → result.deinit() の順で実行される
}

fn doWork(ctx: zctx.Context) void {
    while (ctx.err() == null) {
        // 作業...
        std.time.sleep(10 * std.time.ns_per_ms);
    }
    std.debug.print("cancelled: {?}\n", .{ctx.err()});
}
```

### 6.3 タイムアウト

```zig
fn fetchData(allocator: std.mem.Allocator) ![]u8 {
    const result = try zctx.withTimeout(allocator, zctx.background, 5 * std.time.ns_per_s);
    defer result.deinit();

    return httpGet(result.context, "https://example.com/data");
}

fn httpGet(ctx: zctx.Context, url: []const u8) ![]u8 {
    _ = url;
    while (true) {
        if (ctx.err()) |e| return e; // Canceled / DeadlineExceeded を正確に返す
        // ...受信処理...
    }
}
```

### 6.4 関数をまたいで伝播（典型的なサーバー処理）

```zig
// ハンドラがctxを受け取り、下位関数へ渡す
fn handleRequest(ctx: zctx.Context, req: Request) !Response {
    const user = try authenticate(ctx, req.token);
    const data = try queryDB(ctx, user.id);
    return buildResponse(data);
}

fn authenticate(ctx: zctx.Context, token: []const u8) !User {
    if (ctx.err()) |e| return e;
    // ...認証処理...
}

fn queryDB(ctx: zctx.Context, userId: u64) ![]Row {
    if (ctx.err()) |e| return e;
    // ...DB処理...
}
```

### 6.5 複数シグナルの同時待機（Goのselect相当）

`Signal` は**一射（one-shot）**であり、発火後にリセットできない。`waitAny` は発火済みの Signal があれば即座に返るため、繰り返しループで同じ `*Signal` を使い続けると発火後に無限ループになる。

- **1回限りの通知**（キャンセル待機など）に `Signal` は適している
- **繰り返し通知**が必要な場合は、呼び出し側が毎回新しい `Signal` に差し替えるか、`std.Thread.Mutex` + `std.Thread.Condition` を直接使う

**複数シグナルが同時に発火済みの場合の動作:**  
`waitAny` 呼び出し時点で複数の Signal がすでに発火済みの場合、現在の実装（登録ループを先頭から走査）では走査順の先頭インデックスが返る。ただし、この動作は実装の詳細であり依存してはならない。Go の `select` と同様に「複数発火済みの場合にどれが返るかは未規定」として扱うこと。

```zig
// Signal は一射のため、このパターンは1回限りの通知向け。
// cancel シグナルと1回の work 通知のどちらかを待つ例。
fn worker(ctx: zctx.Context, workSignal: *zctx.Signal) !void {
    // キャンセルか作業依頼か、先に来たほうを処理
    const sig = zctx.waitAny(.{
        .cancel = ctx.done(),
        .work   = workSignal,
    });
    switch (sig) {
        .cancel => {
            std.debug.print("cancelled\n", .{});
        },
        .work => {
            try processWork();
            // work_signal は発火済み。繰り返し待機するには新しい Signal が必要。
        },
        // else unreachable 不要。コンパイラが網羅性を保証。
    }
}
```

### 6.6 WithTypedValue（リクエストスコープの値）

```zig
const RequestIdKey = zctx.TypedKey([]const u8);

fn handleRequest(allocator: std.mem.Allocator, req_id: []const u8) !void {
    const base = try zctx.withCancel(allocator, zctx.background);
    defer base.deinit();

    const result = try zctx.withTypedValue(RequestIdKey, allocator, base.context, req_id);
    defer result.deinit();

    try processRequest(result.context);
}

fn processRequest(ctx: zctx.Context) !void {
    // @ptrCast 不要
    if (ctx.typedValue(RequestIdKey)) |req_id| {
        std.debug.print("req_id: {s}\n", .{req_id});
    }
    // ...処理...
}
```

### 6.7 親→子キャンセル伝播（deinit分離によりcancel後の状態検査が安全）

```zig
pub fn main() !void {
    const parent = try zctx.withCancel(allocator, zctx.background);
    defer parent.deinit();

    const child1 = try zctx.withCancel(allocator, parent.context);
    defer child1.deinit();

    const child2 = try zctx.withTimeout(allocator, parent.context, 10 * std.time.ns_per_s);
    defer child2.deinit();

    parent.cancel(); // child1・child2も同時にキャンセルされる

    std.debug.print("child1: {?}\n", .{child1.context.err()}); // Canceled
    std.debug.print("child2: {?}\n", .{child2.context.err()}); // Canceled
}
```

---

## 7. テスタビリティ

### 7.1 テストしやすい点

| テスト内容 | 方法 |
|-----------|------|
| 正常系 | `zctx.background` をそのまま渡す（アロケータ不要） |
| キャンセル済みパス | `zctx.cancelledContext` を渡す（アロケータ不要） |
| キャンセル後の状態検査 | `result.cancel()` 後も `result.context.err()` が有効（`deinit`分離の恩恵） |
| 親→子伝播の検証 | `parent.cancel()` 後に `child.context.err()` を確認 |
| Value の伝播 | `TypedKey` + `typedValue()` で `@ptrCast` なしに検証 |
| Signal 単体 | `Signal` が公開型のためそのままテスト可能 |

### 7.2 テスト例

```zig
const testing = std.testing;

// 正常系: background を渡す
test "authenticate succeeds" {
    const user = try authenticate(zctx.background, "valid-token");
    try testing.expectEqualStrings("alice", user.name);
}

// キャンセル済みパス: cancelledContext を使う（アロケータ不要）
test "authenticate returns Canceled when context is done" {
    try testing.expectError(error.Canceled, authenticate(zctx.cancelledContext, "token"));
}

// cancel後の状態検査: deinit分離により result.context が有効
test "withCancel fires signal on cancel" {
    const result = try zctx.withCancel(testing.allocator, zctx.background);
    defer result.deinit(); // cancel後も安全に呼べる

    try testing.expectEqual(null, result.context.err());
    result.cancel();
    try testing.expectEqual(zctx.CancelError.Canceled, result.context.err().?);
}

// 親→子伝播
test "parent cancel propagates to children" {
    const parent = try zctx.withCancel(testing.allocator, zctx.background);
    defer parent.deinit();
    const child = try zctx.withCancel(testing.allocator, parent.context);
    defer child.deinit();

    parent.cancel();
    try testing.expectEqual(zctx.CancelError.Canceled, child.context.err().?);
}

// TypedKey による型安全なValue検証
test "typedValue is propagated" {
    const TraceKey = zctx.TypedKey(u64);
    const result = try zctx.withTypedValue(TraceKey, testing.allocator, zctx.background, 12345);
    defer result.deinit();

    const v = result.context.typedValue(TraceKey);
    try testing.expectEqual(@as(?u64, 12345), v);
}

// Signal 単体テスト
test "Signal fires and wakes waiters" {
    var sig = zctx.Signal{};
    try testing.expect(!sig.isFired());
    sig.fire();
    try testing.expect(sig.isFired());
    sig.wait(); // 発火済みなので即座に返る
}
```

### 7.3 テストが困難な点と対策

| 課題 | 深刻度 | 対策 |
|------|--------|------|
| タイムアウトが実時間依存 | 中 | 極小タイムアウト（1ns）+ `sleep`で回避。根本解決は FakeClock（将来対応） |
| タイマースレッドの完了タイミング | 低 | `result.context.done().wait()` でブロックして確認 |

### 7.4 FakeClock（将来対応）

タイムアウト系のテストを実時間に依存させないための時刻注入インターフェース。優先度は低く、基本機能の実装後に検討する。

```zig
// 将来の設計イメージ
pub const Clock = struct {
    ptr:   *anyopaque,
    nowFn: *const fn (*anyopaque) i128,
    pub fn now(self: Clock) i128 { return self.nowFn(self.ptr); }
};

pub const FakeClock = struct {
    timeNs: std.atomic.Value(i128) = .init(0),
    pub fn advance(self: *FakeClock, ns: i128) void { _ = self.timeNs.fetchAdd(ns, .acq_rel); }
    pub fn clock(self: *FakeClock) Clock { ... }
};

// テスト
var fake = zctx.FakeClock{};
const result = try zctx.withTimeoutClock(allocator, parent, 5 * std.time.ns_per_s, fake.clock());
defer result.deinit();
fake.advance(10 * std.time.ns_per_s);
result.context.done().wait();
try testing.expectEqual(zctx.CancelError.DeadlineExceeded, result.context.err().?);
```

---

## 8. ライブラリ自体のテスタビリティ

ライブラリ実装者がライブラリの各モジュールをテストする際の観点。テストは各ソースファイル内に `test "..." { ... }` として記述する（コーディング規約に従う）。

### 8.1 Signal のテスト（src/signal.zig）

同期的なテストは書きやすい。ブロッキング動作はスレッドが必要だが、構造は単純。

```zig
test "Signal: 初期状態はfiredでない" {
    var sig = Signal{};
    try testing.expect(!sig.isFired());
}

test "Signal: fire後はisFiredがtrue" {
    var sig = Signal{};
    sig.fire();
    try testing.expect(sig.isFired());
}

test "Signal: fireはidempotent" {
    var sig = Signal{};
    sig.fire();
    sig.fire();
    try testing.expect(sig.isFired());
}

test "Signal: 発火済みならwaitは即座に返る" {
    var sig = Signal{};
    sig.fire();
    sig.wait(); // ブロックしないはず
}

test "Signal: 別スレッドからのfireでwaitが起きる" {
    var sig = Signal{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Signal) void {
            std.time.sleep(10 * std.time.ns_per_ms);
            s.fire();
        }
    }.run, .{&sig});
    sig.wait();
    thread.join();
    try testing.expect(sig.isFired());
}

test "waitAny: 先に発火したシグナルのフィールド名を返す" {
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig1.fire(); // sig1 を先に発火
    const result = waitAny(.{ .first = &sig0, .second = &sig1 });
    try testing.expectEqual(.second, result);
}

test "waitAny: 戻り後にSignalをfireしても安全（リスナー解除確認・registered=0）" {
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig0.fire(); // 最初のシグナル(i=0)が発火済み → registered=0 のまま early return
    _ = waitAny(.{ .first = &sig0, .second = &sig1 });
    sig1.fire(); // リスナー解除後にfireしてもuse-after-freeが起きないはず
}

test "waitAny: 早期returnで登録済みWaiterNodeが除去される（use-after-free防止・registered=1）" {
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig1.fire(); // 2番目のシグナル(i=1)が発火済み → sig0 に nodes[0] を登録後に early return
    // waitAnySlice は sig0 に nodes[0] を登録してから sig1 が発火済みと判定し early return。
    // 早期 return 前に signals[0..1] のクリーンアップ（nodes[0] を sig0 のリストから除去）が
    // 行われなければ、スタック解放後のポインタが sig0.waiters に残留し use-after-free になる。
    _ = waitAny(.{ .first = &sig0, .second = &sig1 });
    // ここでスタックフレーム（nodes）は解放済み。
    // sig0.fire() が sig0.waiters を走査したとき、除去済みなら安全。
    sig0.fire();
}

test "waitAny: 複数発火済みでも必ずいずれか一方を返す（実装詳細・依存禁止）" {
    var sig0 = Signal{};
    var sig1 = Signal{};
    sig0.fire();
    sig1.fire(); // 両方発火済み
    // 実装上は走査順の先頭（.first）が返るが、この動作は実装の詳細。
    // 依存してはならないため、有効な FieldEnum 値が返りクラッシュしないことのみを確認する。
    const result = waitAny(.{ .first = &sig0, .second = &sig1 });
    try testing.expect(result == .first or result == .second);
}

test "Signal.waitTimeout: タイムアウト前に発火したらtrue" {
    var sig = Signal{};
    sig.fire();
    const fired = sig.waitTimeout(1 * std.time.ns_per_s); // 1秒待つが即返るはず
    try testing.expect(fired);
}

test "Signal.waitTimeout: タイムアウトしたらfalse" {
    var sig = Signal{};
    const fired = sig.waitTimeout(1); // 1ns → タイムアウト
    try testing.expect(!fired);
}

test "Signal.waitTimeout: 別スレッドのfireで早期リターンしtrueを返す" {
    var sig = Signal{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Signal) void {
            std.time.sleep(10 * std.time.ns_per_ms);
            s.fire();
        }
    }.run, .{&sig});
    // 1秒のタイムアウトだが、10ms 後に fire されるので true で返るはず
    const fired = sig.waitTimeout(1 * std.time.ns_per_s);
    thread.join();
    try testing.expect(fired);
}
```

### 8.2 Context のテスト（src/context.zig）

`testing.allocator`（LeakCheckingAllocator）を使うことで、`defer result.deinit()` パターンと組み合わせてメモリリークを自動検出できる。

```zig
// ルートコンテキスト
test "background: doneにならない" {
    try testing.expectEqual(@as(?CancelError, null), background.err());
}

test "cancelledContext: 即座にdone" {
    try testing.expectEqual(CancelError.Canceled, cancelledContext.err().?);
}

// withCancel 基本動作
test "withCancel: 初期状態はdoneでない" {
    const r = try withCancel(testing.allocator, background);
    defer r.deinit();
    try testing.expectEqual(@as(?CancelError, null), r.context.err());
}

test "withCancel: cancel後はdone" {
    const r = try withCancel(testing.allocator, background);
    defer r.deinit();
    r.cancel();
    try testing.expectEqual(CancelError.Canceled, r.context.err().?);
}

test "withCancel: cancelはidempotent" {
    const r = try withCancel(testing.allocator, background);
    defer r.deinit();
    r.cancel();
    r.cancel(); // 2回目も安全
}

test "withCancel: cancelなしでdeinitしてもリークなし" {
    const r = try withCancel(testing.allocator, background);
    r.deinit(); // testing.allocatorがリークを検出
}

// 親→子キャンセル伝播
test "withCancel: 親cancelが子に伝播する" {
    const parent = try withCancel(testing.allocator, background);
    defer parent.deinit();
    const child = try withCancel(testing.allocator, parent.context);
    defer child.deinit();

    parent.cancel();
    try testing.expectEqual(CancelError.Canceled, child.context.err().?);
}

test "withCancel: 子cancelは親に影響しない" {
    const parent = try withCancel(testing.allocator, background);
    defer parent.deinit();
    const child = try withCancel(testing.allocator, parent.context);
    defer child.deinit();

    child.cancel();
    try testing.expectEqual(@as(?CancelError, null), parent.context.err());
}

test "withCancel: キャンセル済み親から作った子は即座にdone" {
    const parent = try withCancel(testing.allocator, background);
    parent.cancel();
    defer parent.deinit();

    const child = try withCancel(testing.allocator, parent.context);
    defer child.deinit();
    try testing.expectEqual(CancelError.Canceled, child.context.err().?);
}

// withDeadline / withTimeout
test "withTimeout: 期限到達でDeadlineExceeded" {
    const r = try withTimeout(testing.allocator, background, 1); // 1ns
    defer r.deinit(); // deinit内でtimerThread.join()するため安全

    r.context.done().wait(); // タイマーが発火するまでブロック
    try testing.expectEqual(CancelError.DeadlineExceeded, r.context.err().?);
}

test "withTimeout: 期限前にcancel → Canceled（DeadlineExceededではない）" {
    const r = try withTimeout(testing.allocator, background, 60 * std.time.ns_per_s);
    defer r.deinit();

    r.cancel();
    try testing.expectEqual(CancelError.Canceled, r.context.err().?);
}

test "withDeadline: 過去のdeadlineは即座にDeadlineExceeded（fast-path・スレッドなし）" {
    // std.time.nanoTimestamp() - 1 は確実に過去
    const past = std.time.nanoTimestamp() - 1;
    const r = try withDeadline(testing.allocator, background, past);
    defer r.deinit(); // timerThread は null（fast-path）なので join しない
    // done().wait() 不要。即座に done になっているはず。
    try testing.expectEqual(CancelError.DeadlineExceeded, r.context.err().?);
    try testing.expect(r.context.done().isFired());
}

test "withDeadline: 親がキャンセル済みのfast-pathはCanceled（DeadlineExceededではない）" {
    // registerChild で親の .Canceled が先にセットされる → fast-path の .DeadlineExceeded は no-op になる。
    // Go の Context と同様に「親キャンセルが優先」であることを確認する。
    const parent = try withCancel(testing.allocator, background);
    parent.cancel();
    defer parent.deinit();

    const past = std.time.nanoTimestamp() - 1;
    const child = try withDeadline(testing.allocator, parent.context, past);
    defer child.deinit();
    try testing.expectEqual(CancelError.Canceled, child.context.err().?);
}

test "withTimeout: cancel後にdeinitしてもブロックしない（中断可能スレッド確認）" {
    // 60秒のタイムアウトでスレッドを起動し、即 cancel → deinit がブロックしないことを確認
    const r = try withTimeout(testing.allocator, background, 60 * std.time.ns_per_s);
    r.cancel();
    r.deinit(); // Signal.waitTimeout() により timerWorker が即終了 → join がブロックしない
}

// withTypedValue
test "withTypedValue: 対応するキーの値を返す" {
    const Key = TypedKey(u32);
    const r = try withTypedValue(Key, testing.allocator, background, 42);
    defer r.deinit();
    try testing.expectEqual(@as(?u32, 42), r.context.typedValue(Key));
}

test "withTypedValue: 親チェーンを辿って値を返す" {
    const Key = TypedKey(u32);
    const base = try withTypedValue(Key, testing.allocator, background, 42);
    defer base.deinit();
    const child = try withCancel(testing.allocator, base.context);
    defer child.deinit();

    try testing.expectEqual(@as(?u32, 42), child.context.typedValue(Key));
}

// 【設計上の注意】TypedKey(T) は comptime memoization により、
// 同じ型引数で2回呼ぶと同一の型・同一のキー値になる。
// 「別キー」を表現するには型引数の型自体を変える必要がある。
//
//   const Key1 = TypedKey(struct { const _tag = 1; }); // 別の匿名型
//   const Key2 = TypedKey(struct { const _tag = 2; }); // 別の匿名型
//
// Goの context.WithValue も同様に「型が同じ値は同じキー」という仕様。
// Zigではユーザーが一意な sentinel 型を定義してキーにする規約とする。

test "withTypedValue: 存在しないキーはnullを返す" {
    const Key1 = TypedKey(u32);
    const Key2 = TypedKey(u64); // u32 と u64 は異なる型 → 異なるキー値（異なるアドレス）
    const r = try withTypedValue(Key1, testing.allocator, background, @as(u32, 42));
    defer r.deinit();
    try testing.expectEqual(@as(?u64, null), r.context.typedValue(Key2));
}

// .cancelled variant の直接テスト
test "cancelledContext: deadline()はnullを返す" {
    try testing.expectEqual(@as(?i128, null), cancelledContext.deadline());
}

test "cancelledContext: value()はnullを返す" {
    const Key = TypedKey(u32);
    try testing.expectEqual(@as(?u32, null), cancelledContext.typedValue(Key));
}

test "cancelledContext: cancelledを親にした子は即座にdone" {
    const child = try withCancel(testing.allocator, cancelledContext);
    defer child.deinit();
    try testing.expectEqual(CancelError.Canceled, child.context.err().?);
}

// CancelState 単体テスト（内部型だが src/context.zig 内の test ブロックで直接テスト可）
test "CancelState: cancelはidempotent" {
    // init() は存在しない。struct リテラルで初期化する。
    // cancel() 内で children.deinit() が呼ばれるため、defer による別途 deinit は不要（double-free になる）。
    var state: CancelState = .{
        .signal    = .{},
        .cancelErr = null,
        .mutex     = .{},
        .children  = .init(testing.allocator),
    };

    state.cancel(.Canceled);
    state.cancel(.Canceled); // 2回目も安全、シグナルは1回しか発火しない
    try testing.expect(state.signal.isFired());
    try testing.expectEqual(CancelError.Canceled, state.cancelErr.?);
    // children は最初の cancel() 内で deinit 済み。testing.allocator はリーク検出しない。
}
```

### 8.3 テスタビリティのまとめ

| テスト対象 | テスタビリティ | 備考 |
|-----------|--------------|------|
| Signal 単体（同期） | 良好 | アロケータ不要、シンプル |
| Signal wait（非同期） | 良好 | スレッド必要だが構造は単純 |
| Signal.waitTimeout | 良好 | タイムアウト: 1ns で決定的。早期リターン: 別スレッドで fire |
| waitAny | 良好 | 発火済みシグナルで決定的にテスト可能。複数発火時は走査順先頭が返る（実装の詳細）。依存禁止のためクラッシュしないことで確認 |
| withCancel 基本動作 | 良好 | `testing.allocator` でリーク自動検出 |
| 親→子キャンセル伝播 | 良好 | 同期的に結果を確認可能 |
| withTimeout（タイマー） | 良好 | `deinit()`内の `thread.join()` があれば安全 |
| withTimeout 中断可能性 | 良好 | 60秒タイムアウトを即 cancel → deinit がブロックしないことを確認 |
| withDeadline（fast-path） | 良好 | 過去デッドラインでスレッドなしの即キャンセルを決定的に確認 |
| withDeadline fast-path（親キャンセル済み） | 良好 | `Canceled` が `DeadlineExceeded` より優先されることを確認 |
| `.cancelled` variant | 良好 | ヒープ確保なし、deadline/value/子伝播を直接テスト可能 |
| CancelState 単体 | 良好 | `cancel()` idempotent を内部 test ブロックで直接検証 |
| レースコンディション | 困難 | 結果（即座にdone）で代替検証 |
| waitAny リスナー解除 | 間接的 | 解除後の `fire()` でクラッシュしないことを確認 |

---

## 9. 保守性

### 9.1 設計上の保守性ポイント

| # | 観点 | 対応方針 |
|---|------|---------|
| 1 | CancelCtx / DeadlineCtx の重複 | `CancelState` に共通ロジックを集約。両者は委譲するだけ |
| 2 | `OwnedContext` 内に type-erased ptr を持ちたい誘惑 | `Context` タグで dispatch。`anyopaque` を排除 |
| 3 | `children.append()` 失敗時リーク | `errdefer allocator.destroy(ctx)` で後始末 |
| 4 | `cancelledContext` の Signal 寿命 | `.cancelled` variant を Context に追加。静的シグナル不要 |
| 5 | TypedKey の規約未強制 | ドキュメントコメントで明示（将来: 第2引数で識別子を要求） |

### 9.2 新しい Context variant を追加する場合のチェックリスト

タグ付き共用体を採用しているため、新 variant 追加時はコンパイラが以下の switch を網羅エラーで教えてくれる。

**【コンパイラが自動検出する箇所（Context switch）】**

- `Context.done()`
- `Context.err()`
- `Context.deadline()`
- `Context.value()`  ← `typedValue()` はここに委譲するため、`value()` の更新のみで足りる
- `OwnedContext.cancel()`
- `OwnedContext.deinit()`
- `registerChild()` 内の parent switch

`Context.typedValue()` は独自の switch を持たず `ctx.value()` に委譲するため、上記リストには含めない（`value()` を更新すれば自動で対応できる）。

**【手動対応が必要な箇所（CancelChild switch）】**

新 variant が**キャンセル可能**（`CancelState` を持つ）場合に限り、`CancelChild` enum への追加も手動で行う必要がある。その後は `CancelChild.propagate()` 内の child switch の更新漏れをコンパイラが検出する。

- `CancelChild` enum に新しい arm を追加する（手動）
- `CancelChild.propagate()` 内の child switch（コンパイラが検出）

現在 `CancelChild` は `cancel` / `deadline` の2種のみ。`ValueCtx` は意図的に除外されており、キャンセル所有者でないため伝播の対象外。新しい非キャンセル variant（ValueCtx 相当）を追加する場合は `CancelChild` の変更は不要。

### 9.3 CancelState の責務境界

`CancelState.cancel()` はシグナル発火と子への伝播のみ担う。メモリ解放は各 Ctx の `deinit()` の責務。この分離により、`CancelState` 単体でロジックをテストできる。

---

## 10. 拡張性

### 10.1 複数スレッドへのコンテキスト共有（重要な制約）

Context を複数スレッドに渡す場合、**オーナーが `deinit()` を呼ぶ前に全スレッドが `result.context` の読み取りを終えていなければならない**。Go は GC が参照を管理するため問題にならないが、Zig では caller がライフタイムを保証する責任を持つ。

`deinit()` 後に `result.context` を読むと use-after-free になる。

**安全なパターン（`defer` の LIFO 順を活用）:**

```zig
const result = try withCancel(allocator, background);
defer result.deinit();                    // 宣言順: 1番目 → 実行順: 2番目（後）

const t = try std.Thread.spawn(.{}, worker, .{result.context});
defer t.join();                           // 宣言順: 2番目 → 実行順: 1番目（先）

// defer の LIFO 順: t.join() が先に実行 → result.deinit() が後に実行
// ※ 宣言順と実行順が逆なので注意。deinit を先に、join を後に宣言すること。
```

**危険なパターン:**

```zig
defer t.join();          // 宣言順: 1番目 → 実行順: 2番目（後）
defer result.deinit();   // 宣言順: 2番目 → 実行順: 1番目（先）← スレッドがまだ動いているかもしれない
```

**規約**: `defer result.deinit()` は必ず `defer t.join()` より**先に**宣言する。

### 10.2 Context の閉鎖性（意図した制約）

タグ付き共用体のため利用者がカスタム Context を作れない。ほとんどの用途は `withTypedValue` で対応できる。

```zig
// 認証情報をコンテキストに載せる → withTypedValue で十分
const AuthKey = TypedKey(AuthInfo);
const result = try withTypedValue(AuthKey, alloc, parent, auth);
```

「キャンセル時に追加ロジックを実行したい」用途はキャンセルコールバック（後述）で対応する。

### 10.3 キャンセルコールバック（将来の拡張ポイント）

現設計にはキャンセル時のフック機能がない。コネクションのクローズ・リソース解放などに使われる。`CancelState` に `onCancel` フィールドを追加するだけで実装可能な構造になっている。

```zig
// 将来の設計イメージ
pub fn withCancelFunc(
    allocator: std.mem.Allocator,
    parent:    Context,
    func:      *const fn () void,
) !OwnedContext {
    // CancelState.cancel() 内で func を呼び出す
}
```

### 10.4 `waitAny` は Signal 限定（対応可能）

外部イベント（OS シグナル、ファイルディスクリプタなど）を直接 `waitAny` に渡せない。ただし `Signal` が公開型なので、外部イベントを `Signal.fire()` でラップすれば対応できる。

```zig
var osSig = Signal{};
// OS シグナルハンドラから osSig.fire() を呼ぶ
const sig = waitAny(.{ .cancel = ctx.done(), .os = &osSig });
switch (sig) {
    .cancel => return error.Canceled,
    .os     => handleOsSignal(),
}
```

### 10.5 まとめ

| # | 観点 | 重要度 | 対応方針 |
|---|------|--------|---------|
| 1 | 複数スレッドへの共有（`deinit` 順序） | **高** | 規約としてドキュメント化。`defer` の LIFO 順に注意 |
| 2 | Context の閉鎖性 | 低 | 許容。`withTypedValue` で代替できる旨をドキュメント化 |
| 3 | キャンセルコールバック | 低 | 将来の拡張ポイント。`CancelState` に追加するだけ |
| 4 | `waitAny` は Signal 限定 | 低 | `Signal.fire()` でラップすれば対応可 |

---

## 11. Zigらしさ（設計判断まとめ）

Go の Context を Zig に移植する際に、言語哲学の違いから意識的に下した設計判断。

| # | 判断 | Go との違い | Zigらしい理由 |
|---|------|------------|-------------|
| 1 | `Context` を vtable ではなくタグ付き共用体にする | Go は interface | 種類が閉じた集合。switch 網羅性をコンパイラが検証。`anyopaque` キャスト不要 |
| 2 | `Signal` のリスナーを侵入的リンクリスト（スタック確保）にする | Go は channel | `Signal{}` で初期化可能。アロケータ不要。静的シグナルも定義できる |
| 3 | `background` / `todo` / `cancelledContext` を定数にする | Go は関数呼び出し | 引数なし・副作用なし → 定数が自然。`std.heap.page_allocator` と同様のパターン |
| 4 | `todo` を独立した variant にする | Go は Background と同じ型 | タグ付き共用体で `.background` と `.todo` を区別できる。静的解析なしでも意図が伝わる |
| 5 | `OwnedContext` と命名する（Go の `CancelFunc` に相当） | Go は `(Context, CancelFunc)` の組 | "Owned" = このスコープがコンテキストのオーナー（`deinit()` の責任がある）を明示 |
| 6 | `waitAny` を `anytype` + `FieldEnum` にする | Go は `select` 文（言語機能） | `anytype` + comptime reflection は Zig 標準パターン。exhaustive switch がライブラリ利用者側で使える |
| 7 | フィールド名を camelCase にする | Go は camelCase/PascalCase | Zig 公式スタイルガイドに準拠 |

---

## 12. 実装振り返り（計画からの乖離）

実装日: 2026-04-12  
対象Zigバージョン: 0.15.2 / macOS SDK: 26.4

### 12.1 Zig 0.15.2 API 変更への対応

計画策定時点と実際の Zig 0.15.2 API の差異により、以下の修正が必要だった。

#### `std.time.sleep` の削除

| 計画 | 実装 |
|------|------|
| `std.time.sleep(ns)` | `std.Thread.sleep(ns)` |

`std.time.sleep` は Zig 0.15.x で削除され、`std.Thread.sleep` に移動した。タイマースレッドのテストコードで使用していたため変更。

#### `std.ArrayList` の API 変更

| 計画 | 実装 |
|------|------|
| `children: std.ArrayList(T)` にアロケータを格納 | `CancelState` にアロケータを追加し、アンマネージドな `std.ArrayList(T)` を使用 |
| `.children = .init(allocator)` | `.children = .{}` |
| `children.append(item)` | `children.append(allocator, item)` |
| `children.deinit()` | `children.deinit(allocator)` |

Zig 0.15.2 では `std.ArrayList(T)` が `array_list.Aligned(T, null)` に統一され、アロケータを内部に保持しないアンマネージド型になった（旧 `ArrayListUnmanaged` 相当）。`CancelState` にアロケータフィールドを追加することで対応した。

### 12.2 設計上の問題と修正

#### union フィールド名とメソッド名の衝突

| 計画 | 実装 |
|------|------|
| `.deadline: *DeadlineCtx`、`pub fn deadline(ctx: Context) ?i128` | `.deadlineCtx: *DeadlineCtx`（variant 名を変更） |
| `.value: *ValueCtx`、`fn value(ctx: Context, key: usize) ?*anyopaque` | `.valueCtx: *ValueCtx`（variant 名を変更）、`fn rawValue(...)` |

Zig では union(enum) のフィールド名とメソッド名が同一名前空間に属するため、重複が許されない。計画では `.deadline` variant と `deadline()` メソッドが共存する設計になっていたが、これはコンパイルエラーになる。

**解決方法**: variant 名を `deadlineCtx` / `valueCtx` に変更。公開メソッド名（`deadline()` / `typedValue()`）はそのまま維持。ライブラリ利用者が直接 variant にマッチすることは想定しないため、variant 名の変更は公開 API への影響が限定的。

#### `TypedKey` のキー生成方式

| 計画 | 実装 |
|------|------|
| `const _sentinel: u0 = 0; pub const key: usize = @intFromPtr(&_sentinel);` | `var _unique: u8 = 0; pub const key: *anyopaque = &_unique;` |

計画の方式には2つの問題があった。

1. **`@intFromPtr` がコンパイル時評価不可**: Zig 0.15.2 ではコンテナレベルの定数に対してランタイム値（ポインタアドレス）を `@intFromPtr` で `usize` に変換することが禁止されている（"initializer of container-level variable must be comptime-known" エラー）。
2. **`u0` のゼロサイズ問題**: `u0` はサイズ 0 の型であり、リンカが同一アドレスに複数の `u0 = 0` 定数をマージする可能性がある。実際に `TypedKey(u32)` と `TypedKey(u64)` が同一キー値を返すバグとして顕在化した（"expected null, found 42" テスト失敗）。

**解決方法**: キー型を `usize` から `*anyopaque` に変更し、`var _unique: u8 = 0` の変数アドレスをキーとして使う。`var` かつ `u8`（1バイト）にすることでリンカによるアドレスマージを防ぐ。`ValueCtx.key` も `*anyopaque` に変更し、比較はポインタ比較で行う。

#### `Context.value()` の親委譲漏れ

| 計画 | 実装 |
|------|------|
| `.cancel => null`、`.deadline => null` | `.cancel => |c| c.parent.rawValue(key)`、`.deadlineCtx => |d| d.parent.rawValue(key)` |

計画のセクション 3.1 の `value()` 実装では `.cancel => null`、`.deadline => null` となっていたが、セクション 8.2 のテスト「withTypedValue: 親チェーンを辿って値を返す」では `withCancel` でラップした上位の `withTypedValue` から値を取り出せることを期待している。これは矛盾しており、実装上は親への委譲が必要だった。

**解決方法**: `rawValue` の `.cancel` / `.deadlineCtx` ケースで親コンテキストに委譲するよう修正（Go の `context.Value()` の動作と整合）。

#### `CancelState.cancel()` のメソッド名変更

| 計画 | 実装 |
|------|------|
| `fn cancel(self: *CancelState, reason: CancelError)` | `fn cancelFn(self: *CancelState, reason: CancelError)` |

`CancelState.CancelChild` の variant 名が `.cancel: *CancelCtx` であるため、同じ `CancelState` スコープ内に `fn cancel(...)` というメソッドを定義すると名前が衝突する。

**解決方法**: メソッド名を `cancelFn` に改名。ライブラリの公開 API には影響なし（`OwnedContext.cancel()` から内部呼び出しされるのみ）。

#### `CancelChild` の variant 名変更

| 計画 | 実装 |
|------|------|
| `deadline: *DeadlineCtx` | `deadlineCtx: *DeadlineCtx` |

`Context` の `.deadline` → `.deadlineCtx` 変更と同様の理由で `CancelChild` の `.deadline` variant も `.deadlineCtx` に変更した。`CancelChild.propagate()` 内の switch もあわせて更新済み。

### 12.3 ビルドシステムの問題

#### `zig build` が macOS SDK 26.4 でリンク失敗

Zig 0.15.2 の `zig build` コマンドが macOS SDK 26.4 環境で `build_zcu.o` のリンクに失敗する。

```
error: undefined symbol: __availability_version_check
    note: referenced by libcompiler_rt.a:___isPlatformVersionAtLeast
error: undefined symbol: _abort
    note: referenced by build_zcu.o:_posix.abort
（他 POSIX シンボル多数）
```

**根本原因**: Zig 側の問題であり、macOS SDK（Xcode）の更新では解決しない。

`__availability_version_check` 自体は Apple の `libSystem.B.dylib` に存在する。問題は **Zig 0.15.2 に同梱されている lld（LLVM リンカ）が macOS 26.x（Darwin 25.x）SDK のパスに未対応**なことにある。

| コマンド | 使うリンカ | 結果 |
|---------|-----------|------|
| `zig build` | Zig 同梱の lld | ❌ SDK 26.x 未対応 |
| `zig build-lib / zig test / zig build-exe` + `-target aarch64-macos` | Apple の `ld`（clang 経由） | ✅ 正常リンク |

`-target aarch64-macos` を明示すると Zig が Apple のシステムリンカチェーンを使うため、macOS 26 SDK を正しく解決できる。

また、`zig build-exe -M` フラグによるモジュール依存指定は `-target aarch64-macos` を付けても lld を使うため、同じリンカエラーが発生する。`-M` フラグ有無に関わらず、`zig build-exe <file>` の positional 引数形式でのみ Apple ld が使われることを確認した（`example/` のサンプルコードで実証）。

**回避策（現在の状態）**:
- `mise.toml` の `test` タスク: `zig build test --summary all` → `zig test src/context.zig -target aarch64-macos`
- `mise.toml` の `build` タスク: `zig build --summary all` → `zig build-lib src/root.zig -target aarch64-macos -fno-emit-bin`（コンパイルチェックのみ。`src/main.zig` 削除後の現状）
- `example/` のコンパイル: `-M` フラグ不使用。`example/src → src/` のシンボリックリンクで `@import("src/root.zig")` を解決（§12.4 参照）

**解決条件**: Zig が macOS 26.x SDK のパス解決に対応したバージョン（nightly で確認済みだが他の API 破壊的変更を伴うため移行は保留）がリリースされれば、`zig build` に戻せる。解決後の移行手順は §12.4 参照。

### 12.4 `example/` ディレクトリの追加

計画外の追加として、`example/` ディレクトリにサンプルコードを5ファイル作成した。

| ファイル | 内容 |
|---|---|
| `example/basic.zig` | `withCancel` の基本的な使い方 |
| `example/timeout.zig` | `withTimeout` によるタイムアウト |
| `example/propagation.zig` | 親キャンセルが子に伝播する様子 |
| `example/value.zig` | `TypedKey` による型安全な値の受け渡し |
| `example/wait_any.zig` | `waitAny` による複数シグナルの同時待機 |

#### インポート方式のワークアラウンド

`-M` フラグが lld を使うため（§12.3）、`example/` から `src/` のライブラリを参照する手段として `example/src → src/` のシンボリックリンクを作成した。

```
example/
  src@      ← ../src へのシンボリックリンク
  basic.zig ← @import("src/root.zig") で参照
  ...
```

各 `example/*.zig` の冒頭に以下の TODO コメントを残している:

```zig
// 現在は example/src → src/ のシンボリックリンク経由でライブラリを参照している。
// TODO: Zig が macOS 26.x SDK + -M フラグに対応した際は、以下のように変更する:
//   1. example/src シンボリックリンクを削除する
//   2. @import("src/root.zig") → @import("zctx") に変更する
//   3. mise.toml のコンパイルコマンドで -Mzctx=src/root.zig を指定する
//      または build.zig にモジュール登録（b.addModule("zctx", ...)）を使うこと。
```

#### `src/main.zig` の削除

`example/basic.zig` が `withCancel` のデモを担うため、`src/main.zig` は不要と判断し削除した。`build.zig` から実行ファイル関連のステップ（`exe`・`run_step`・`exe_tests`）も除去し、ライブラリモジュール定義とテストのみ残した。

#### `mise run example:*` タスク

`mise.toml` に以下のタスクを追加した（`zig build-exe <file> -target aarch64-macos` 形式）:

```
mise run example:basic
mise run example:timeout
mise run example:propagation
mise run example:value
mise run example:wait_any
```
