const std = @import("std");

const android = @import("android");

const util = @import("util.zig");

pub const panic = android.panic;
pub const log = android.log;

const EGLContext = android.egl.EGLContext;
const JNI = android.JNI;
const c = android.egl.c;

const app_log = std.log.scoped(.app);

comptime {
    _ = android.ANativeActivity_createFunc;
}

/// Entry point for our application.
/// This struct provides the interface to the android support package.
pub const AndroidApp = struct {
    const Self = @This();

    const TouchPoint = struct {
        /// if null, then fade out
        index: ?i32,
        intensity: f32,
        x: f32,
        y: f32,
        age: i64,
    };

    allocator: std.mem.Allocator,
    activity: *android.ANativeActivity,

    thread: ?std.Thread = null,
    audio_thread: ?std.Thread = null,
    running: bool = true,

    egl_lock: std.Thread.Mutex = .{},
    egl: ?EGLContext = null,
    egl_init: bool = true,

    input_lock: std.Thread.Mutex = .{},
    input: ?*android.AInputQueue = null,

    config: ?*android.AConfiguration = null,

    touch_points: [16]?TouchPoint = [1]?TouchPoint{null} ** 16,
    screen_width: f32 = undefined,
    screen_height: f32 = undefined,

    /// This is the entry point which initializes a application
    /// that has stored its previous state.
    /// `stored_state` is that state, the memory is only valid for this function.
    pub fn init(allocator: std.mem.Allocator, activity: *android.ANativeActivity, stored_state: ?[]const u8) !Self {
        _ = stored_state;

        return Self{
            .allocator = allocator,
            .activity = activity,
        };
    }

    /// This function is called when the application is successfully initialized.
    /// It should create a background thread that processes the events and runs until
    /// the application gets destroyed.
    pub fn start(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, mainLoop, .{self});
        self.audio_thread = try std.Thread.spawn(.{}, audioLoop, .{self});
    }

    /// Uninitialize the application.
    /// Don't forget to stop your background thread here!
    pub fn deinit(self: *Self) void {
        @atomicStore(bool, &self.running, false, .SeqCst);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.audio_thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.config) |config| {
            android.AConfiguration_delete(config);
        }
        self.* = undefined;
    }

    pub fn onNativeWindowCreated(self: *Self, window: *android.ANativeWindow) void {
        self.egl_lock.lock();
        defer self.egl_lock.unlock();

        if (self.egl) |*old| {
            old.deinit();
        }

        self.screen_width = @intToFloat(f32, android.ANativeWindow_getWidth(window));
        self.screen_height = @intToFloat(f32, android.ANativeWindow_getHeight(window));

        self.egl = EGLContext.init(window, .gles2) catch |err| blk: {
            app_log.err("Failed to initialize EGL for window: {}\n", .{err});
            break :blk null;
        };
        self.egl_init = true;
    }

    pub fn onNativeWindowDestroyed(self: *Self, window: *android.ANativeWindow) void {
        _ = window;
        self.egl_lock.lock();
        defer self.egl_lock.unlock();

        if (self.egl) |*old| {
            old.deinit();
        }
        self.egl = null;
    }

    pub fn onInputQueueCreated(self: *Self, input: *android.AInputQueue) void {
        self.input_lock.lock();
        defer self.input_lock.unlock();

        self.input = input;
    }

    pub fn onInputQueueDestroyed(self: *Self, input: *android.AInputQueue) void {
        _ = input;

        self.input_lock.lock();
        defer self.input_lock.unlock();

        self.input = null;
    }

    fn printConfig(config: *android.AConfiguration) void {
        var lang: [2]u8 = undefined;
        var country: [2]u8 = undefined;

        android.AConfiguration_getLanguage(config, &lang);
        android.AConfiguration_getCountry(config, &country);

        app_log.debug(
            \\App Configuration:
            \\  MCC:         {}
            \\  MNC:         {}
            \\  Language:    {s}
            \\  Country:     {s}
            \\  Orientation: {}
            \\  Touchscreen: {}
            \\  Density:     {}
            \\  Keyboard:    {}
            \\  Navigation:  {}
            \\  KeysHidden:  {}
            \\  NavHidden:   {}
            \\  SdkVersion:  {}
            \\  ScreenSize:  {}
            \\  ScreenLong:  {}
            \\  UiModeType:  {}
            \\  UiModeNight: {}
            \\
        , .{
            android.AConfiguration_getMcc(config),
            android.AConfiguration_getMnc(config),
            &lang,
            &country,
            android.AConfiguration_getOrientation(config),
            android.AConfiguration_getTouchscreen(config),
            android.AConfiguration_getDensity(config),
            android.AConfiguration_getKeyboard(config),
            android.AConfiguration_getNavigation(config),
            android.AConfiguration_getKeysHidden(config),
            android.AConfiguration_getNavHidden(config),
            android.AConfiguration_getSdkVersion(config),
            android.AConfiguration_getScreenSize(config),
            android.AConfiguration_getScreenLong(config),
            android.AConfiguration_getUiModeType(config),
            android.AConfiguration_getUiModeNight(config),
        });
    }

    fn processKeyEvent(self: *Self, event: *android.AInputEvent) !bool {
        const event_type = @intToEnum(android.AKeyEventActionType, android.AKeyEvent_getAction(event));
        std.log.scoped(.input).debug(
            \\Key Press Event: {}
            \\  Flags:       {}
            \\  KeyCode:     {}
            \\  ScanCode:    {}
            \\  MetaState:   {}
            \\  RepeatCount: {}
            \\  DownTime:    {}
            \\  EventTime:   {}
            \\
        , .{
            event_type,
            android.AKeyEvent_getFlags(event),
            android.AKeyEvent_getKeyCode(event),
            android.AKeyEvent_getScanCode(event),
            android.AKeyEvent_getMetaState(event),
            android.AKeyEvent_getRepeatCount(event),
            android.AKeyEvent_getDownTime(event),
            android.AKeyEvent_getEventTime(event),
        });

        if (event_type == .AKEY_EVENT_ACTION_DOWN) {
            var jni = JNI.init(self.activity);
            defer jni.deinit();

            var codepoint = jni.AndroidGetUnicodeChar(
                android.AKeyEvent_getKeyCode(event),
                android.AKeyEvent_getMetaState(event),
            );
            var buf: [8]u8 = undefined;

            var len = std.unicode.utf8Encode(codepoint, &buf) catch 0;
            var key_text = buf[0..len];

            std.log.scoped(.input).debug("Pressed key: '{s}' U+{X}", .{ key_text, codepoint });
        }

        return false;
    }

    fn insertPoint(self: *Self, point: TouchPoint) void {
        std.debug.assert(point.index != null);
        var oldest: *TouchPoint = undefined;

        for (self.touch_points) |*opt, i| {
            if (opt.*) |*pt| {
                if (pt.index != null and pt.index.? == point.index.?) {
                    pt.* = point;
                    return;
                }

                if (i == 0) {
                    oldest = pt;
                } else {
                    if (pt.age < oldest.age) {
                        oldest = pt;
                    }
                }
            } else {
                opt.* = point;
                return;
            }
        }
        oldest.* = point;
    }

    fn processMotionEvent(self: *Self, event: *android.AInputEvent) !bool {
        const event_type = @intToEnum(android.AMotionEventActionType, android.AMotionEvent_getAction(event));

        {
            var jni = JNI.init(self.activity);
            defer jni.deinit();

            // Show/Hide keyboard
            // _ = jni.AndroidDisplayKeyboard(true);

            // this allows you to send the app in the background
            // const success = jni.AndroidSendToBack(true);
            // _ = success;
            // std.log.scoped(.input).debug("SendToBack() = {}\n", .{success});

            // This is a demo on how to request permissions:
            if (event_type == .AMOTION_EVENT_ACTION_UP) {
                if (!JNI.AndroidHasPermissions(&jni, "android.permission.RECORD_AUDIO")) {
                    JNI.AndroidRequestAppPermissions(&jni, "android.permission.RECORD_AUDIO");
                }
            }
        }

        std.log.scoped(.input).debug(
            \\Motion Event {}
            \\  Flags:        {}
            \\  MetaState:    {}
            \\  ButtonState:  {}
            \\  EdgeFlags:    {}
            \\  DownTime:     {}
            \\  EventTime:    {}
            \\  XOffset:      {}
            \\  YOffset:      {}
            \\  XPrecision:   {}
            \\  YPrecision:   {}
            \\  PointerCount: {}
            \\
        , .{
            event_type,
            android.AMotionEvent_getFlags(event),
            android.AMotionEvent_getMetaState(event),
            android.AMotionEvent_getButtonState(event),
            android.AMotionEvent_getEdgeFlags(event),
            android.AMotionEvent_getDownTime(event),
            android.AMotionEvent_getEventTime(event),
            android.AMotionEvent_getXOffset(event),
            android.AMotionEvent_getYOffset(event),
            android.AMotionEvent_getXPrecision(event),
            android.AMotionEvent_getYPrecision(event),
            android.AMotionEvent_getPointerCount(event),
        });

        var i: usize = 0;
        var cnt = android.AMotionEvent_getPointerCount(event);
        while (i < cnt) : (i += 1) {
            std.log.scoped(.input).debug(
                \\Pointer {}:
                \\  PointerId:   {}
                \\  ToolType:    {}
                \\  RawX:        {d}
                \\  RawY:        {d}
                \\  X:           {d}
                \\  Y:           {d}
                \\  Pressure:    {}
                \\  Size:        {}
                \\  TouchMajor:  {}
                \\  TouchMinor:  {}
                \\  ToolMajor:   {}
                \\  ToolMinor:   {}
                \\  Orientation: {}
                \\
            , .{
                i,
                android.AMotionEvent_getPointerId(event, i),
                android.AMotionEvent_getToolType(event, i),
                android.AMotionEvent_getRawX(event, i),
                android.AMotionEvent_getRawY(event, i),
                android.AMotionEvent_getX(event, i),
                android.AMotionEvent_getY(event, i),
                android.AMotionEvent_getPressure(event, i),
                android.AMotionEvent_getSize(event, i),
                android.AMotionEvent_getTouchMajor(event, i),
                android.AMotionEvent_getTouchMinor(event, i),
                android.AMotionEvent_getToolMajor(event, i),
                android.AMotionEvent_getToolMinor(event, i),
                android.AMotionEvent_getOrientation(event, i),
            });

            self.insertPoint(TouchPoint{
                .x = android.AMotionEvent_getX(event, i),
                .y = android.AMotionEvent_getY(event, i),
                .index = android.AMotionEvent_getPointerId(event, i),
                .age = android.AMotionEvent_getEventTime(event),
                .intensity = 1.0,
            });
        }

        return false;
    }

    fn audioLoop(self: *Self) !void {
        var audio_buffer: []f32 = try self.allocator.alloc(f32, 1024);
        defer self.allocator.free(audio_buffer);
        var audio_data = try AudioData.init(audio_buffer);
        defer audio_data.deinit();

        while (@atomicLoad(bool, &self.running, .SeqCst)) {
            if (audio_data.is_playing and audio_data.is_done_buffer and audio_data.play_start_time.read() > std.time.ns_per_s * 2) {
                _ = audio_data.player.*.*.SetPlayState.?(audio_data.player, c.SL_PLAYSTATE_STOPPED);
                _ = audio_data.player_buf_q.*.*.Clear.?(audio_data.player_buf_q);
                audio_data.is_playing = false;
            }
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn mainLoop(self: *Self) !void {
        // This code somehow crashes yet. Needs more investigations
        var jni = JNI.init(self.activity);
        defer jni.deinit();

        // Must be called from main thread…
        _ = jni.AndroidMakeFullscreen();

        var loop: usize = 0;
        app_log.info("mainLoop() started\n", .{});

        self.config = blk: {
            var cfg = android.AConfiguration_new() orelse return error.OutOfMemory;
            android.AConfiguration_fromAssetManager(cfg, self.activity.assetManager);
            break :blk cfg;
        };

        if (self.config) |cfg| {
            printConfig(cfg);
        }

        var render: Render = undefined;

        while (@atomicLoad(bool, &self.running, .SeqCst)) {

            // Input process
            {
                // we lock the handle of our input so we don't have a race condition
                self.input_lock.lock();
                defer self.input_lock.unlock();
                if (self.input) |input| {
                    var event: ?*android.AInputEvent = undefined;
                    while (android.AInputQueue_getEvent(input, &event) >= 0) {
                        std.debug.assert(event != null);
                        if (android.AInputQueue_preDispatchEvent(input, event) != 0) {
                            continue;
                        }

                        const event_type = @intToEnum(android.AInputEventType, android.AInputEvent_getType(event));
                        const handled = switch (event_type) {
                            .AINPUT_EVENT_TYPE_KEY => try self.processKeyEvent(event.?),
                            .AINPUT_EVENT_TYPE_MOTION => try self.processMotionEvent(event.?),
                            else => blk: {
                                std.log.scoped(.input).info("Unhandled input event type ({})\n", .{event_type});
                                break :blk false;
                            },
                        };

                        // if (app.onInputEvent != NULL)
                        //     handled = app.onInputEvent(app, event);
                        android.AInputQueue_finishEvent(input, event, if (handled) @as(c_int, 1) else @as(c_int, 0));
                    }
                }
            }

            // Render process
            {
                // same for the EGL context
                self.egl_lock.lock();
                defer self.egl_lock.unlock();
                if (self.egl) |egl| {
                    try egl.makeCurrent();

                    if (self.egl_init) {
                        render = Render.init();
                        self.egl_init = false;
                    }
                    render.render(loop);
                    try egl.swapBuffers();
                }
            }
            loop += 1;

            std.time.sleep(10 * std.time.ns_per_ms);
        }
        app_log.info("mainLoop() finished\n", .{});
    }
};

const MeshVertex = extern struct {
    pos: Vector4,
    normal: Vector4,
};

const Vector4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32 = 1.0,

    fn readFromSlice(slice: []const u8) Vector4 {
        return Vector4{
            .x = @bitCast(f32, std.mem.readIntLittle(u32, slice[0..4])),
            .y = @bitCast(f32, std.mem.readIntLittle(u32, slice[4..8])),
            .z = @bitCast(f32, std.mem.readIntLittle(u32, slice[8..12])),
            .w = 1.0,
        };
    }
};

const mesh = blk: {
    const stl_data = @embedFile("logo.stl");

    const count = std.mem.readIntLittle(u32, stl_data[80..][0..4]);

    var slice: []const u8 = stl_data[84..];

    var array: [3 * count]MeshVertex = undefined;
    var index: usize = 0;

    @setEvalBranchQuota(10_000);

    while (index < count) : (index += 1) {
        const normal = Vector4.readFromSlice(slice[0..]);
        const v1 = Vector4.readFromSlice(slice[12..]);
        const v2 = Vector4.readFromSlice(slice[24..]);
        const v3 = Vector4.readFromSlice(slice[36..]);
        const attrib_count = std.mem.readIntLittle(u16, slice[48..50]);

        array[3 * index + 0] = MeshVertex{
            .pos = v1,
            .normal = normal,
        };
        array[3 * index + 1] = MeshVertex{
            .pos = v2,
            .normal = normal,
        };
        array[3 * index + 2] = MeshVertex{
            .pos = v3,
            .normal = normal,
        };

        slice = slice[50 + attrib_count ..];
    }

    break :blk array;
};

const Render = struct {
    touch_program: GLuint,
    vertex_buffer: GLuint,

    const GLuint = c.GLuint;
    const vVertices = [_]c.GLfloat{
        0.0, 0.0,
        1.0, 0.0,
        0.0, 1.0,
    };

    pub fn init() @This() {
        var this: @This() = undefined;

        c.glGenBuffers(1, &this.vertex_buffer);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, this.vertex_buffer);
        c.glBufferData(c.GL_ARRAY_BUFFER, vVertices.len * @sizeOf(c.GLfloat), &vVertices, c.GL_STATIC_DRAW);

        if (c.eglGetProcAddress("DebugMessageCallbackKHR")) |glDebugMessageCallbackKHR| {
            const DEBUGPROC = *const fn (c.GLenum, c.GLenum, c.GLuint, c.GLenum, c.GLsizei, ?[*]const u8, ?*anyopaque) callconv(.C) void;
            const glDebugMessageCallback = @ptrCast(*const fn (DEBUGPROC, ?*anyopaque) void, glDebugMessageCallbackKHR);
            glDebugMessageCallback(util.debugMessageCallback, null);
        } else {
            app_log.info("No debug callback", .{});
        }

        this.touch_program = c.glCreateProgram();
        {
            var ps = c.glCreateShader(c.GL_VERTEX_SHADER);
            var fs = c.glCreateShader(c.GL_FRAGMENT_SHADER);

            var ps_code =
                \\#version 100
                \\attribute vec2 vPosition;
                \\void main() {
                \\  gl_Position = vec4(vPosition, 0.0, 1.0);
                \\}
                \\
            ;
            var fs_code =
                \\#version 100
                \\precision mediump float;
                \\
                \\void main() {
                \\  gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
                \\}
                \\
            ;

            c.glShaderSource(ps, 1, @ptrCast([*c]const [*c]const u8, &ps_code), null);
            c.glShaderSource(fs, 1, @ptrCast([*c]const [*c]const u8, &fs_code), null);

            c.glCompileShader(ps);
            c.glCompileShader(fs);

            var buf: [1024]u8 = undefined;

            var is_compiled: c.GLint = c.GL_FALSE;
            c.glGetShaderiv(ps, c.GL_COMPILE_STATUS, &is_compiled);
            if (is_compiled == c.GL_FALSE) {
                var max_length: c.GLint = 0;
                c.glGetShaderiv(ps, c.GL_INFO_LOG_LENGTH, &max_length);
                max_length = @max(max_length, @intCast(c_int, buf.len));
                c.glGetShaderInfoLog(ps, max_length, &max_length, &buf);
                const str = buf[0..@intCast(usize, max_length)];
                app_log.err("\n\n\tVertex Shader - is_compiled={}\n\t{s}\n", .{ is_compiled, str });
            }
            is_compiled = c.GL_FALSE;
            c.glGetShaderiv(fs, c.GL_COMPILE_STATUS, &is_compiled);
            if (is_compiled == c.GL_FALSE) {
                var max_length: c.GLint = 0;
                c.glGetShaderiv(fs, c.GL_INFO_LOG_LENGTH, &max_length);
                max_length = @max(max_length, @intCast(c_int, buf.len));
                c.glGetShaderInfoLog(fs, max_length, &max_length, &buf);
                const str = buf[0..@intCast(usize, max_length)];
                app_log.err("\n\n\tFragment Shader - is_compiled={}\n\t{s}\n", .{ is_compiled, str });
            }

            c.glAttachShader(this.touch_program, ps);
            c.glAttachShader(this.touch_program, fs);

            c.glLinkProgram(this.touch_program);

            c.glDetachShader(this.touch_program, ps);
            c.glDetachShader(this.touch_program, fs);
        }

        return this;
    }

    pub fn render(self: *@This(), loop: usize) void {
        const t = @intToFloat(f32, loop) / 100.0;

        c.glClearColor(
            0.5 + 0.5 * @sin(t + 0.0),
            0.5 + 0.5 * @sin(t + 1.0),
            0.5 + 0.5 * @sin(t + 2.0),
            1.0,
        );
        c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);

        c.glUseProgram(self.touch_program);

        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vertex_buffer);

        const vPosition = c.glGetAttribLocation(self.touch_program, "vPosition");
        if (vPosition < 0) {
            app_log.err("vPosition is negative!!! {}", .{vPosition});
        }

        c.glEnableVertexAttribArray(@intCast(c.GLuint, vPosition));
        c.glVertexAttribPointer(@intCast(c.GLuint, vPosition), 2, c.GL_FLOAT, c.GL_FALSE, 0, null);

        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);

        c.glDisableVertexAttribArray(0);
    }
};

const AudioData = struct {
    time: f32 = 0,
    sample_rate: f32 = 44100,
    buffer: []f32,

    engine_obj: c.SLObjectItf = null,
    engine: c.SLEngineItf = null,
    output_mix_obj: c.SLObjectItf = null,
    output_mix_vol: c.SLVolumeItf = null,
    clip_samples: ?*anyopaque = null,
    clip_num_samples: c_uint = 0,
    clip_samples_per_sec: c_uint = 0,
    format: c.SLDataFormat_PCM = undefined,
    src: c.SLDataSource = undefined,
    dst: c.SLDataSink = undefined,
    in_loc: c.SLDataLocator_AndroidSimpleBufferQueue = undefined,
    out_loc: c.SLDataLocator_OutputMix = undefined,
    player_obj: c.SLObjectItf = null,
    player: c.SLPlayItf = null,
    player_vol: c.SLVolumeItf = null,
    player_buf_q: c.SLAndroidSimpleBufferQueueItf = null,
    is_playing: bool = false,
    is_done_buffer: bool = false,
    play_start_time: std.time.Timer = undefined,
    pub fn init(buffer: []f32) !@This() {
        var self = @This(){ .buffer = buffer };
        // Create engine
        var res: c.SLresult = c.slCreateEngine(&self.engine_obj, 0, null, 0, null, null);
        log_opensles_result(res, "Create engine");

        res = self.engine_obj.*.*.Realize.?(self.engine_obj, c.SL_BOOLEAN_FALSE);
        log_opensles_result(res, "Realize engine");

        res = self.engine_obj.*.*.GetInterface.?(self.engine_obj, c.SL_IID_ENGINE, @ptrCast(*anyopaque, &self.engine));
        log_opensles_result(res, "Get engine interface");

        // Create main OutputMix, try to get volume interface
        var ids = [_]c.SLInterfaceID{c.SL_IID_VOLUME};
        var req = [_]c.SLboolean{c.SL_BOOLEAN_FALSE};

        res = self.engine.*.*.CreateOutputMix.?(self.engine, &self.output_mix_obj, ids.len, &ids, @ptrCast(*const c_uint, &req));
        log_opensles_result(res, "Create output mix");

        res = self.output_mix_obj.*.*.Realize.?(self.output_mix_obj, c.SL_BOOLEAN_FALSE);
        log_opensles_result(res, "Realize output mix");

        res = self.output_mix_obj.*.*.GetInterface.?(self.output_mix_obj, c.SL_IID_VOLUME, @ptrCast(*anyopaque, &self.output_mix_vol));
        log_opensles_result(res, "Get volume interface");
        if (res != c.SL_RESULT_SUCCESS) self.output_mix_vol = null;

        self.format = .{
            .formatType = c.SL_DATAFORMAT_PCM,
            .numChannels = 1,
            .samplesPerSec = 44100 * 1000, // mHz
            .bitsPerSample = c.SL_PCMSAMPLEFORMAT_FIXED_16,
            .containerSize = 16,
            .channelMask = c.SL_SPEAKER_FRONT_CENTER,
            .endianness = c.SL_BYTEORDER_LITTLEENDIAN,
        };

        self.src = .{
            .pLocator = &self.in_loc,
            .pFormat = &self.format,
        };

        self.out_loc.locatorType = c.SL_DATALOCATOR_OUTPUTMIX;
        self.out_loc.outputMix = self.output_mix_obj;

        self.dst = .{
            .pLocator = &self.out_loc,
            .pFormat = null,
        };

        const ids2 = [_]c.SLInterfaceID{ c.SL_IID_VOLUME, c.SL_IID_ANDROIDSIMPLEBUFFERQUEUE };
        const req2 = [_]c.SLboolean{ c.SL_BOOLEAN_FALSE, c.SL_BOOLEAN_FALSE };

        log_opensles_result(self.engine.*.*.CreateAudioPlayer.?(self.engine, &self.player_obj, &self.src, &self.dst, ids2.len, &ids2, &req2), "Create audio player");
        log_opensles_result(self.player_obj.*.*.Realize.?(self.player_obj, c.SL_BOOLEAN_FALSE), "Realize player");
        log_opensles_result(self.player_obj.*.*.GetInterface.?(self.player_obj, c.SL_IID_PLAY, @ptrCast(*anyopaque, &self.player)), "Get player interface");
        log_opensles_result(self.player_obj.*.*.GetInterface.?(self.player_obj, c.SL_IID_VOLUME, @ptrCast(*anyopaque, &self.player_vol)), "Get volume interface");
        log_opensles_result(self.player_obj.*.*.GetInterface.?(self.player_obj, c.SL_IID_ANDROIDSIMPLEBUFFERQUEUE, @ptrCast(*anyopaque, &self.player_buf_q)), "Get buf q interface");

        log_opensles_result(self.player.*.*.RegisterCallback.?(self.player, play_callback, &self), "Register callback");
        log_opensles_result(self.player.*.*.SetCallbackEventsMask.?(self.player, c.SL_PLAYEVENT_HEADATEND), "Set events mask");

        if (self.player_buf_q.*.*.RegisterCallback) |RegisterCallback| {
            res = RegisterCallback(self.player_buf_q, AudioData.callback, &self);
            log_opensles_result(res, "Register callback");
        }

        self.play_start_time = try std.time.Timer.start();

        return self;
    }

    fn deinit(self: *@This()) void {
        app_log.info("destroy engine", .{});
        self.engine_obj.*.*.Destroy.?(self.engine_obj);
        self.engine_obj = null;
        self.engine = null;
    }

    fn play_callback(player: c.SLPlayItf, context: ?*anyopaque, event: c.SLuint32) callconv(.C) void {
        _ = player;
        const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), context));
        if (event & c.SL_PLAYEVENT_HEADATEND > 0) self.is_done_buffer = true;
    }

    fn callback(bq: c.SLAndroidSimpleBufferQueueItf, context: ?*anyopaque) callconv(.C) void {
        app_log.info("callback start", .{});
        const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), context));
        app_log.info("ptr cast", .{});
        // for (self.buffer) |*sample, i| {
        //     const time = @sin(@intToFloat(f32, i) + self.time);
        //     sample.* = std.math.sin(440 * 2.0 * std.math.pi * time / self.sample_rate) * 0.1;
        // }
        _ = bq.*.*.Enqueue.?(bq, self.buffer.ptr, @intCast(c_uint, self.buffer.len * @sizeOf(f32)));
        // self.time += @intToFloat(f32, self.buffer.len);
        app_log.info("enqueue", .{});
    }
};

fn log_opensles_result(res: c.SLresult, name: []const u8) void {
    const str = switch (res) {
        c.SL_RESULT_SUCCESS => "SLES Success",
        c.SL_RESULT_PRECONDITIONS_VIOLATED => "SLES PRECONDITIONS_VIOLATED",
        c.SL_RESULT_PARAMETER_INVALID => "SLES PARAMETER_INVALID",
        c.SL_RESULT_MEMORY_FAILURE => "SLES MEMORY_FAILURE",
        c.SL_RESULT_RESOURCE_ERROR => "SLES RESOURCE_ERROR",
        c.SL_RESULT_RESOURCE_LOST => "SLES RESOURCE_LOST",
        c.SL_RESULT_IO_ERROR => "SLES IO_ERROR",
        c.SL_RESULT_BUFFER_INSUFFICIENT => "SLES BUFFER_INSUFFICIENT",
        c.SL_RESULT_CONTENT_CORRUPTED => "SLES CONTENT_CORRUPTED",
        c.SL_RESULT_CONTENT_UNSUPPORTED => "SLES CONTENT_UNSUPPORTED",
        c.SL_RESULT_CONTENT_NOT_FOUND => "SLES CONTENT_NOT_FOUND",
        c.SL_RESULT_PERMISSION_DENIED => "SLES PERMISSION_DENIED",
        c.SL_RESULT_FEATURE_UNSUPPORTED => "SLES FEATURE_UNSUPPORTED",
        c.SL_RESULT_INTERNAL_ERROR => "SLES INTERNAL_ERROR",
        c.SL_RESULT_UNKNOWN_ERROR => "SLES UNKNOWN_ERROR",
        c.SL_RESULT_OPERATION_ABORTED => "SLES OPERATION_ABORTED",
        c.SL_RESULT_CONTROL_LOST => "SLES CONTROL_LOST",
        // c.SL_RESULT_READONLY => "SLES READONLY",
        // c.SL_RESULT_ENGINEOPTION_UNSUPPORTED => "SLES ENGINEOPTION_UNSUPPORTED",
        // c.SL_RESULT_SOURCE_SINK_INCOMPATIBLE => "SLES SOURCE_SINK_INCOMPATIBLE",
        else => "SLES Unmatched",
    };
    app_log.info("{s} - Result: {s}", .{ name, str });
}
