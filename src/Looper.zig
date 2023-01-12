//! Convenience wrapper for ALooper.
//!
//! ALooper is the state tracking an event loop for a thread. Loopers do not define event structures or other such things;
//! rather, they are a lower-level facility to attach one or more discrete objects listening for an event. An "event" here is simply
//! data available on a file descriptor: each attached object has an associated file descriptor, and waiting for "events" means
//! (internally) polling on all of these file descriptors until one or more of them have data available.
//!
//! A thread can only have one ALooper associated with it.
const std = @import("std");
const android = @import("android-bind.zig");

const Looper = @This();

// This is needed because to run a callback on the UI thread Looper you must
// react to a fd change, so we use a pipe to force it
pipe: [2]std.os.fd_t = undefined,
// This is used with futexes so that runOnUiThread waits until the callback is completed
// before returning.
condition: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(0),
looper: *android.ALooper = undefined,
id: std.Thread.Id = undefined,

pub fn init() !Looper {
    var looper = Looper{
        .looper = android.ALooper_forThread() orelse return error.NoLooperForThread,
        .id = std.Thread.getCurrentId(),
        .pipe = try std.os.pipe(),
    };
    android.ALooper_acquire(looper.looper);
    return looper;
}

/// Run the given function on the Looper thread.
/// Necessary for manipulating the view hierarchy on Android.
/// Note: this function is not thread-safe, but could be made so simply using a mutex
pub fn runOnLooperThreadAwait(self: *Looper, comptime func: anytype, args: anytype) !void {
    if (std.Thread.getCurrentId() == self.id) {
        // awaitCall has been run from the
        @call(.auto, func, args);
        return;
    }

    const Args = @TypeOf(args);
    const allocator = self.allocator;

    const Data = struct { args: Args, self: *Looper };

    const data_ptr = try allocator.create(Data);
    data_ptr.* = .{ .args = args, .self = self };
    errdefer allocator.destroy(data_ptr);

    const Instance = struct {
        fn callback(_: c_int, _: c_int, data: ?*anyopaque) callconv(.C) c_int {
            const data_struct = @ptrCast(*Data, @alignCast(@alignOf(Data), data.?));
            const self_ptr = data_struct.self;
            defer self_ptr.allocator.destroy(data_struct);

            @call(.auto, func, data_struct.args);
            std.Thread.Futex.wake(&self_ptr.condition, 1);
            return 0;
        }
    };

    const result = android.ALooper_addFd(
        self.looper,
        self.pipe[0],
        0,
        android.ALOOPER_EVENT_INPUT,
        Instance.callback,
        data_ptr,
    );
    std.debug.assert(try std.os.write(self.pipe[1], "hello") == 5);
    if (result == -1) {
        return error.LooperError;
    }

    std.Thread.Futex.wait(&self.condition, 0);
}
