//! zctx: Go の context パッケージを Zig に移植したキャンセル伝播ライブラリ。

pub const background = @import("context.zig").background;
pub const todo = @import("context.zig").todo;
pub const canceled = @import("context.zig").canceled;

pub const Signal = @import("signal.zig").Signal;
pub const Context = @import("context.zig").Context;
pub const ContextError = @import("context.zig").ContextError;
pub const TypedKey = @import("context.zig").TypedKey;
pub const ScopeError = @import("scope.zig").ScopeError;
pub const OwnedCancelScope = @import("scope.zig").OwnedCancelScope;
pub const OwnedDeadlineScope = @import("scope.zig").OwnedDeadlineScope;
pub const OwnedValueScope = @import("scope.zig").OwnedValueScope;
pub const TimerPool = @import("timer_pool.zig").TimerPool;

pub const withCancel = @import("scope.zig").withCancel;
pub const withTimeout = @import("scope.zig").withTimeout;
pub const withDeadline = @import("scope.zig").withDeadline;
pub const withTypedValue = @import("scope.zig").withTypedValue;

test {
    _ = @import("signal.zig");
    _ = @import("context.zig");
    _ = @import("scope.zig");
    _ = @import("timer_pool.zig");
}
