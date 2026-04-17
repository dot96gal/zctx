//! zctx: Zig向けのGoのContext（キャンセル）実装。

/// 一射ブロードキャストシグナル。GoのDone()チャンネルのclose相当。
pub const Signal = @import("signal.zig").Signal;
/// 複数シグナルのいずれかを待つ（Goのselect相当）。
pub const waitAny = @import("signal.zig").waitAny;

/// タグ付き共用体によるコンテキスト型。
pub const Context = @import("context.zig").Context;
/// コンテキストの終了理由を表すエラー集合。
pub const ContextError = @import("context.zig").ContextError;
/// withCancel / withDeadline / withTimeout / withTypedValue の返り値型。
pub const OwnedContext = @import("context.zig").OwnedContext;
/// comptime 型安全キーを生成する関数。
pub const TypedKey = @import("context.zig").TypedKey;

/// ルートコンテキスト。キャンセルされない。
pub const background = @import("context.zig").background;
/// プレースホルダーコンテキスト。background と同じ振る舞い。
pub const todo = @import("context.zig").todo;
/// 最初からキャンセル済みのコンテキスト。
pub const cancelled = @import("context.zig").cancelled;

/// 手動キャンセル可能なコンテキストを作成する。
pub const withCancel = @import("context.zig").withCancel;
/// デッドライン付きコンテキストを作成する。
pub const withDeadline = @import("context.zig").withDeadline;
/// タイムアウト付きコンテキストを作成する。
pub const withTimeout = @import("context.zig").withTimeout;
/// 型安全な値付きコンテキストを作成する。
pub const withTypedValue = @import("context.zig").withTypedValue;
