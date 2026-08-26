// abl-bench-osc.js — bench harness bridge, runs inside the abl-bench-osc
// Max for Live device. Build recipe and OSC protocol: bench/m4l/README.md.
//
// Patcher wiring:
//   [live.thisdevice] -> inlet     (init bang once the Live API is ready)
//   [udpreceive 19001] -> inlet    (commands from the harness)
//   outlet -> [udpsend 127.0.0.1 19002]   (telemetry to the harness)
//
// Written for the classic [js] object: ES5 only, no modern syntax.

autowatch = 1;
inlets = 1;
outlets = 1;

var song = null;
var app = null;
var playObs = null;
var cpuTask = null;
var cpuPeriod = 500;   // ms between /abl/bench/cpu reports; 0 = off
var cpuOk = false;

// live.thisdevice bangs when the device may use the Live API. A plain
// loadbang fires too early inside Live; do not add one.
function bang() { init(); }

function init() {
    song = new LiveAPI("live_set");
    app = new LiveAPI("live_app");

    playObs = new LiveAPI(onPlaying, "live_set");
    playObs.property = "is_playing";

    // The CPU meter reached the Live Object Model in Live 11
    // (Application.average_process_usage / peak_process_usage). Probe once;
    // when absent, /abl/bench/cpu reports -1 -1 and the harness falls back
    // to the manual DSP entry.
    var probe = app.get("average_process_usage");
    cpuOk = (probe != null && probe.length > 0 && probe[0] !== "");
    if (!cpuOk)
        post("abl-bench-osc: no average_process_usage on this Live build\n");

    applyCpuPeriod();
    out("/abl/bench/ready", [cpuOk ? 1 : 0]);
}

function onPlaying(args) {
    if (args && args[0] === "is_playing")
        out("/abl/bench/playing", [args[1] ? 1 : 0]);
}

function sendCpu() {
    var avg = -1, peak = -1, v;
    if (app && !cpuOk) {
        // Self-heal: an init that raced the Live API leaves the probe dead;
        // retry with a fresh handle until the meter reads.
        app = new LiveAPI("live_app");
        v = app.get("average_process_usage");
        cpuOk = (v != null && v.length > 0 && v[0] !== "");
    }
    if (app && cpuOk) {
        v = app.get("average_process_usage");
        if (v != null && v.length > 0) avg = v[0];
        v = app.get("peak_process_usage");
        if (v != null && v.length > 0) peak = v[0];
    }
    // Values are forwarded exactly as the Live API reports them; the harness
    // owns any scaling.
    out("/abl/bench/cpu", [avg, peak]);
}

function applyCpuPeriod() {
    if (cpuTask) { cpuTask.cancel(); cpuTask = null; }
    if (cpuPeriod > 0) {
        cpuTask = new Task(sendCpu);
        cpuTask.interval = cpuPeriod;
        cpuTask.repeat();
    }
}

// Incoming OSC. The device wires [udpreceive] straight into this object,
// so the OSC address arrives as the Max message selector and lands in
// anything(). osc() is an alternate entry for a [prepend osc] wiring:
// there the message arrives as "osc <address> <args...>".
function anything() {
    dispatch(messagename, arrayfromargs(arguments));
}

function osc() {
    var a = arrayfromargs(arguments);
    if (!a.length) return;
    dispatch(String(a[0]), a.slice(1));
}

function dispatch(addr, a) {
    switch (addr) {
    case "/abl/bench/ping":
        out("/abl/bench/pong", a);
        break;
    case "/abl/bench/play":
        if (song) song.call("start_playing");
        break;
    case "/abl/bench/stop":
        if (song) song.call("stop_playing");
        break;
    case "/abl/bench/rewind":
        if (song) song.set("current_song_time", 0);
        break;
    case "/abl/bench/poll":
        sendCpu();
        break;
    case "/abl/bench/cpu-period":
        cpuPeriod = a.length ? Math.max(0, a[0] | 0) : 500;
        applyCpuPeriod();
        break;
    default:
        post("abl-bench-osc: unknown message " + addr + "\n");
    }
}

function out(addr, args) {
    outlet.apply(this, [0, addr].concat(args));
}
