/// zctx: Zig向けのGoのContext（キャンセル）実装。
pub const Signal = @import("signal.zig").Signal;
pub const waitAny = @import("signal.zig").waitAny;

pub const Context = @import("context.zig").Context;
pub const CancelError = @import("context.zig").CancelError;
pub const OwnedContext = @import("context.zig").OwnedContext;
pub const TypedKey = @import("context.zig").TypedKey;

pub const background = @import("context.zig").background;
pub const todo = @import("context.zig").todo;
pub const cancelledContext = @import("context.zig").cancelledContext;

pub const withCancel = @import("context.zig").withCancel;
pub const withDeadline = @import("context.zig").withDeadline;
pub const withTimeout = @import("context.zig").withTimeout;
pub const withTypedValue = @import("context.zig").withTypedValue;
