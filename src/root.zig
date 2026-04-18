//! zctx: Go の context パッケージを Zig に移植したキャンセル伝播ライブラリ。

pub const Signal = @import("signal.zig").Signal;

pub const Context = @import("context.zig").Context;
pub const ContextError = @import("context.zig").ContextError;
pub const OwnedContext = @import("context.zig").OwnedContext;
pub const TypedKey = @import("context.zig").TypedKey;

pub const background = @import("context.zig").background;
pub const todo = @import("context.zig").todo;
pub const canceled = @import("context.zig").canceled;

pub const withCancel = @import("context.zig").withCancel;
pub const withDeadline = @import("context.zig").withDeadline;
pub const withTimeout = @import("context.zig").withTimeout;
pub const withTypedValue = @import("context.zig").withTypedValue;

test {
    _ = @import("signal.zig");
    _ = @import("context.zig");
}
