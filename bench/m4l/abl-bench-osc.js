// Connects the benchmark suite to the abl-bench-osc Max for Live device.
// The build steps and message list are in bench/m4l/README.md.
//
// Patcher connections:
//   [live.thisdevice] -> inlet     (starts after the Live API becomes ready)
//   [udpreceive 19001] -> inlet    (receives suite commands)
//   outlet -> [udpsend 127.0.0.1 19002]   (sends reports to the suite)
//
// The classic [js] object uses ES5 syntax.

autowatch = 1;
inlets = 1;
outlets = 1;

var song = null;
var app = null;
var playObs = null;
var cpuTask = null;
var cpuPeriod = 500;   // ms between /abl/bench/cpu reports; 0 stops reports
var cpuOk = false;

// live.thisdevice sends a bang when the Live API becomes ready. A loadbang can
// run earlier, so use the current bang.
function bang() { init(); }

function init() {
    song = new LiveAPI("live_set");
    app = new LiveAPI("live_app");

    playObs = new LiveAPI(onPlaying, "live_set");
    playObs.property = "is_playing";

    // Live 11 added average and peak CPU values to the Live Object Model.
    // Read the average value at start. An empty value produces -1 -1 in the
    // report, and the suite then uses the listener's DSP entry.
    var probe = app.get("average_process_usage");
    cpuOk = (probe != null && probe.length > 0 && probe[0] !== "");
    if (!cpuOk)
        post("abl-bench-osc: CPU value pending for the current Live build\n");

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
        // Start-up can occur before the CPU value becomes ready. Request a new
        // Live handle until the meter supplies a value.
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
    // Send the values in Live's original units. The suite applies any scale.
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

// [udpreceive] sends the OSC address to anything() as a Max message selector.
// osc() accepts the alternate [prepend osc] form: "osc <address> <args...>".
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
        post("abl-bench-osc: supported commands are in bench/m4l/README.md; received " + addr + "\n");
    }
}

function out(addr, args) {
    outlet.apply(this, [0, addr].concat(args));
}
