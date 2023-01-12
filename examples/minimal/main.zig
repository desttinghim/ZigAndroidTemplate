const std = @import("std");
const android = @import("android");

pub const panic = android.panic;

const app_log = std.log.scoped(.app);

comptime {
    _ = android.ANativeActivity_createFunc;
}

pub const AndroidApp = struct {
    allocator: std.mem.Allocator,
    activity: *android.ANativeActivity,

    thread: ?std.Thread = null,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, activity: *android.ANativeActivity, stored_state: ?[]const u8) !AndroidApp {
        _ = stored_state;

        return AndroidApp{
            .allocator = allocator,
            .activity = activity,
        };
    }

    pub fn start(self: *AndroidApp) !void {
        self.thread = try std.Thread.spawn(.{}, mainLoop, .{self});
    }

    pub fn deinit(self: *AndroidApp) void {
        @atomicStore(bool, &self.running, false, .SeqCst);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn mainLoop(self: *AndroidApp) !void {
        while (self.running) {
            std.time.sleep(1 * std.time.ns_per_s);
        }
    }
};
