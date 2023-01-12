//! This struct is defined by android
const jui = @import("jui");
const android = @import("android-bind.zig");

pub const ANativeActivityCallbacks = extern struct {
    onStart: ?*const fn (*ANativeActivity) callconv(.C) void,
    onResume: ?*const fn (*ANativeActivity) callconv(.C) void,
    onSaveInstanceState: ?*const fn (*ANativeActivity, *usize) callconv(.C) ?[*]u8,
    onPause: ?*const fn (*ANativeActivity) callconv(.C) void,
    onStop: ?*const fn (*ANativeActivity) callconv(.C) void,
    onDestroy: ?*const fn (*ANativeActivity) callconv(.C) void,
    onWindowFocusChanged: ?*const fn (*ANativeActivity, c_int) callconv(.C) void,
    onNativeWindowCreated: ?*const fn (*ANativeActivity, *android.ANativeWindow) callconv(.C) void,
    onNativeWindowResized: ?*const fn (*ANativeActivity, *android.ANativeWindow) callconv(.C) void,
    onNativeWindowRedrawNeeded: ?*const fn (*ANativeActivity, *android.ANativeWindow) callconv(.C) void,
    onNativeWindowDestroyed: ?*const fn (*ANativeActivity, *android.ANativeWindow) callconv(.C) void,
    onInputQueueCreated: ?*const fn (*ANativeActivity, *android.AInputQueue) callconv(.C) void,
    onInputQueueDestroyed: ?*const fn (*ANativeActivity, *android.AInputQueue) callconv(.C) void,
    onContentRectChanged: ?*const fn (*ANativeActivity, *const android.ARect) callconv(.C) void,
    onConfigurationChanged: ?*const fn (*ANativeActivity) callconv(.C) void,
    onLowMemory: ?*const fn (*ANativeActivity) callconv(.C) void,
};

pub const ANativeActivity = extern struct {
    callbacks: *ANativeActivityCallbacks,
    vm: *jui.JavaVM,
    env: *jui.JNIEnv,
    /// The NativeActiviy object handle.
    ///
    /// IMPORTANT NOTE: This member is mis-named. It should really be named `activity` instead of `clazz`,
    /// since it's a reference to the NativeActivity instance created by the system.
    clazz: jui.jobject,
    internalDataPath: [*:0]const u8,
    externalDataPath: [*:0]const u8,
    sdkVersion: i32,
    instance: ?*anyopaque,
    assetManager: ?*android.AAssetManager,
    obbPath: [*:0]const u8,
};
pub const ANativeActivity_createFunc = *const fn ([*c]ANativeActivity, ?*anyopaque, usize) callconv(.C) void;

pub extern fn ANativeActivity_finish(activity: [*c]ANativeActivity) void;
pub extern fn ANativeActivity_setWindowFormat(activity: [*c]ANativeActivity, format: i32) void;
pub extern fn ANativeActivity_setWindowFlags(activity: [*c]ANativeActivity, addFlags: u32, removeFlags: u32) void;
pub const ANATIVEACTIVITY_SHOW_SOFT_INPUT_IMPLICIT = @enumToInt(enum_unnamed_33.ANATIVEACTIVITY_SHOW_SOFT_INPUT_IMPLICIT);
pub const ANATIVEACTIVITY_SHOW_SOFT_INPUT_FORCED = @enumToInt(enum_unnamed_33.ANATIVEACTIVITY_SHOW_SOFT_INPUT_FORCED);
const enum_unnamed_33 = enum(c_int) {
    ANATIVEACTIVITY_SHOW_SOFT_INPUT_IMPLICIT = 1,
    ANATIVEACTIVITY_SHOW_SOFT_INPUT_FORCED = 2,
    _,
};
pub extern fn ANativeActivity_showSoftInput(activity: [*c]ANativeActivity, flags: u32) void;
pub const ANATIVEACTIVITY_HIDE_SOFT_INPUT_IMPLICIT_ONLY = @enumToInt(enum_unnamed_34.ANATIVEACTIVITY_HIDE_SOFT_INPUT_IMPLICIT_ONLY);
pub const ANATIVEACTIVITY_HIDE_SOFT_INPUT_NOT_ALWAYS = @enumToInt(enum_unnamed_34.ANATIVEACTIVITY_HIDE_SOFT_INPUT_NOT_ALWAYS);
const enum_unnamed_34 = enum(c_int) {
    ANATIVEACTIVITY_HIDE_SOFT_INPUT_IMPLICIT_ONLY = 1,
    ANATIVEACTIVITY_HIDE_SOFT_INPUT_NOT_ALWAYS = 2,
    _,
};
pub extern fn ANativeActivity_hideSoftInput(activity: [*c]ANativeActivity, flags: u32) void;
