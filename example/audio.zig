const std = @import("std");

const android = @import("android");

const JNI = android.JNI;
const c = android.egl.c;

const app_log = std.log.scoped(.app);

const Oscillator = struct {
    isWaveOn: bool,
    phase: f64 = 0.0,
    phaseIncrement: f64 = 0,
    const amplitude = 0.3;
    const frequency = 440;
    fn setWaveOn(self: *@This(), isWaveOn: bool) void {
        @atomicStore(bool, *self.isWaveOn, isWaveOn, .SeqCst);
    }
    fn setSampleRate(self: *@This(), sample_rate: i32) void {
        self.phaseIncrement = std.math.tau / @intToFloat(f64, sample_rate);
    }
    fn render(self: *@This(), audio_data: []f32) void {
        if (!@atomicLoad(bool, &self.isWaveOn, .SeqCst)) self.phase = 0;

        for (audio_data) |*frame| {
            if (!@atomicLoad(bool, &self.isWaveOn, .SeqCst)) {
                frame.* = @floatCast(f32, std.math.sin(self.phase) * amplitude);
                self.phase += self.phaseIncrement;
                if (self.phase > std.math.tau) self.phase -= std.math.tau;
            } else {
                frame.* = 0;
            }
        }
    }
};

pub const AudioEngine = struct {
    oscillator: Oscillator = undefined,
    stream: ?*c.AAudioStream = null,

    const buffer_size_in_bursts = 2;

    fn dataCallback(
        stream: ?*c.AAudioStream,
        user_data: ?*anyopaque,
        audio_data: ?*anyopaque,
        num_frames: i32,
    ) callconv(.C) c.aaudio_data_callback_result_t {
        _ = stream;
        const oscillator = @ptrCast(*Oscillator, @alignCast(@alignOf(Oscillator), user_data.?));
        const audio_slice = @ptrCast([*]f32, @alignCast(@alignOf(f32), audio_data.?))[0..@intCast(usize, num_frames)];
        oscillator.render(audio_slice);
        return c.AAUDIO_CALLBACK_RESULT_CONTINUE;
    }

    fn errorCallback(
        stream: ?*c.AAudioStream,
        user_data: ?*anyopaque,
        err: c.aaudio_result_t,
    ) callconv(.C) void {
        _ = stream;
        if (err == c.AAUDIO_ERROR_DISCONNECTED) {
            const self = @ptrCast(*AudioEngine, @alignCast(@alignOf(AudioEngine), user_data.?));
            _ = std.Thread.spawn(.{}, restart, .{self}) catch {
                app_log.err("Couldn't spawn thread", .{});
            };
        }
    }

    pub fn start(self: *@This()) bool {
        var stream_builder: ?*c.AAudioStreamBuilder = null;
        _ = c.AAudio_createStreamBuilder(&stream_builder);
        defer _ = c.AAudioStreamBuilder_delete(stream_builder);

        c.AAudioStreamBuilder_setFormat(stream_builder, c.AAUDIO_FORMAT_PCM_FLOAT);
        c.AAudioStreamBuilder_setChannelCount(stream_builder, 1);
        c.AAudioStreamBuilder_setPerformanceMode(stream_builder, c.AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
        c.AAudioStreamBuilder_setDataCallback(stream_builder, dataCallback, &self.oscillator);
        c.AAudioStreamBuilder_setErrorCallback(stream_builder, errorCallback, self);

        {
            const result = c.AAudioStreamBuilder_openStream(stream_builder, &self.stream);
            if (result != c.AAUDIO_OK) {
                app_log.err("Error opening stream {s}", .{c.AAudio_convertResultToText(result)});
                return false;
            }
        }

        const sample_rate = c.AAudioStream_getSampleRate(self.stream);
        self.oscillator.setSampleRate(sample_rate);

        _ = c.AAudioStream_setBufferSizeInFrames(self.stream, c.AAudioStream_getFramesPerBurst(self.stream) * buffer_size_in_bursts);

        {
            const result = c.AAudioStream_requestStart(self.stream);
            if (result != c.AAUDIO_OK) {
                app_log.err("Error starting stream {s}", .{c.AAudio_convertResultToText(result)});
                return false;
            }
        }

        return true;
    }

    var restartingLock = std.Thread.Mutex{};
    pub fn restart(self: *@This()) void {
        if (restartingLock.tryLock()) {
            self.stop();
            _ = self.start();
            restartingLock.unlock();
        }
    }

    pub fn stop(self: *@This()) void {
        if (self.stream) |stream| {
            _ = c.AAudioStream_requestStop(stream);
            _ = c.AAudioStream_close(stream);
        }
    }

    pub fn setToneOn(self: *@This(), isToneOn: bool) void {
        self.oscillator.setWaveOn(isToneOn);
    }
};
