const std = @import("std");
const app_log = std.log.scoped(.app);

const android = @import("android");

const c = android.egl.c;

pub fn debugMessageCallback(
    source: c.GLenum,
    logtype: c.GLenum,
    id: c.GLuint,
    severity: c.GLenum,
    length: c.GLsizei,
    message_c: ?[*]const c.GLchar,
    user_param: ?*const anyopaque,
) callconv(.C) void {
    _ = user_param;
    const message = message: {
        if (message_c) |message_ptr| {
            break :message if (length > 0) message_ptr[0..@intCast(usize, length)] else "";
        } else {
            break :message "";
        }
    };
    switch (severity) {
        c.GL_DEBUG_SEVERITY_HIGH => app_log.err("source = {}, type = {}, id = {}, severity = {}, message = {s}", .{ source, logtype, id, severity, message }),
        c.GL_DEBUG_SEVERITY_MEDIUM => app_log.warn("source = {}, type = {}, id = {}, severity = {}, message = {s}", .{ source, logtype, id, severity, message }),
        else => app_log.info("source = {}, type = {}, id = {}, severity = {}, message = {s}", .{ source, logtype, id, severity, message }),
    }
}
