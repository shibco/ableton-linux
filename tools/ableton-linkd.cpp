/* ableton-linkd.cpp: native Ableton Link session anchor + probe.
 *
 * A small always-on peer for the Link session on 224.76.78.75:20808. It
 * exists for two reasons the platform cannot provide by itself:
 *
 *  - anchoring: as the longest-lived peer it holds the session tempo and
 *    timeline across Live restarts, and relays Start Stop Sync
 *    (enableStartStopSync) without owning a transport;
 *  - verification: --probe gives an automated, scriptable verdict on
 *    whether other peers (e.g. Live under Wine) can join the session.
 *
 * The daemon is strictly passive per the Ableton Link anti-hijack
 * guidelines: after construction it never calls setTempo, forceBeatAtTime
 * or requestBeatAtTime. The initial tempo only applies when this process
 * founds a new session; joining an existing session adopts its timeline.
 *
 * It deliberately does NOT bridge JACK transport: native Link-enabled
 * Linux apps join the same session over the network directly, and upstream
 * jack_link remains an option for JACK-only apps.
 *
 * Modes:
 *   (no args)     foreground: log on peer/tempo/start-stop changes only
 *   --daemon      fork to background, log to ~/.log/ableton-linkd/ableton-linkd.log
 *   --probe [s]   join, wait up to s seconds (default 10), print
 *                 "peers: N" and "tempo: T.T", exit 0 iff N >= 1
 *   --tempo BPM   initial tempo when founding a session (default 120.0)
 *   --verbose     also log a status line every 10 s (the pre-2026.08 default;
 *                 ABLETON_LINKD_VERBOSE=1 does the same)
 *   --help        usage
 *
 * Logging is event-driven by default. The change callbacks cover peers,
 * tempo and transport, so a quiet session writes nothing. The periodic
 * status line used to be unconditional. Under the systemd unit that was
 * 8640 identical journal lines a day. It read as a stuck process and
 * invited force quits, so it is now opt-in via --verbose.
 *
 * SIGTERM/SIGINT shut down cleanly: Link is disabled (a byebye goes out on
 * the wire) and the process exits 0.
 *
 * build: ./build_ableton-linkd.sh   (extracts ../vendor/link-4.0.tar.zst
 *        and compiles against the vendored Ableton Link SDK, header-only
 *        C++17 + asio; no dependency on a checked-out Link clone)
 * run:   started by the ableton-live launcher or the ableton-linkd.service
 *        user unit; safe to run standalone.
 */
#include <ableton/Link.hpp>

#include <cerrno>
#include <chrono>
#include <cstdarg>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <thread>
#include <unistd.h>

namespace {

/* Valid tempo range, matching the SDK's own clamp (ClientSessionTimelines.hpp). */
constexpr double kMinBpm = 20.0;
constexpr double kMaxBpm = 999.0;

constexpr auto kStatusPeriod = std::chrono::seconds(10);
constexpr int kDefaultProbeSecs = 10;
/* Grace after the first peer appears, so the session tempo has sync'd
 * before --probe reports it. */
constexpr auto kProbeGrace = std::chrono::milliseconds(500);

volatile std::sig_atomic_t g_quit = 0;

void on_signal(int)
{
    g_quit = 1;
}

void install_signal_handlers()
{
    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGINT, &sa, nullptr);
    signal(SIGPIPE, SIG_IGN);
    /* Flush stdout/stderr on exit so the log is complete after kill. */
    std::setvbuf(stdout, nullptr, _IOLBF, 0);
    std::setvbuf(stderr, nullptr, _IOLBF, 0);
}

std::string timestamp()
{
    std::time_t t = std::time(nullptr);
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", std::localtime(&t));
    return buf;
}

/* Log lines go to stderr; in --daemon mode stderr is the log file. */
void log_line(const char* fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    std::fprintf(stderr, "%s ableton-linkd: ", timestamp().c_str());
    std::vfprintf(stderr, fmt, ap);
    std::fputc('\n', stderr);
    va_end(ap);
}

void print_status(ableton::Link& link)
{
    const auto state = link.captureAppSessionState();
    log_line("peers: %zu  tempo: %.1f  playing: %s",
             link.numPeers(), state.tempo(),
             state.isPlaying() ? "yes" : "no");
}

/* mkdir -p ~/.log/ableton-linkd */
bool ensure_log_dir(std::string& dir_out)
{
    const char* home = std::getenv("HOME");
    if (!home || !*home) {
        std::fprintf(stderr, "ableton-linkd: HOME is not set\n");
        return false;
    }
    std::string log_root = std::string(home) + "/.log";
    dir_out = log_root + "/ableton-linkd";
    if (mkdir(log_root.c_str(), 0755) != 0 && errno != EEXIST)
        return false;
    if (mkdir(dir_out.c_str(), 0755) != 0 && errno != EEXIST)
        return false;
    return true;
}

/* fork to background, setsid, redirect stdout+stderr to the log file.
 * Called before the Link instance is constructed: forking after asio has
 * spawned its threads would be unsafe. */
bool daemonize(const std::string& log_dir)
{
    const std::string log_path = log_dir + "/ableton-linkd.log";
    int fd = open(log_path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        std::fprintf(stderr, "ableton-linkd: cannot open %s: %s\n",
                     log_path.c_str(), std::strerror(errno));
        return false;
    }

    const pid_t pid = fork();
    if (pid < 0) {
        std::fprintf(stderr, "ableton-linkd: fork failed: %s\n",
                     std::strerror(errno));
        close(fd);
        return false;
    }
    if (pid > 0)
        _exit(0); /* parent: child takes over */

    setsid();
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    if (fd > STDERR_FILENO)
        close(fd);
    return true;
}

/* Register the change callbacks required by the daemon spec. They fire on
 * Link's own thread; logging only, no session-state mutation. */
void register_callbacks(ableton::Link& link)
{
    link.setNumPeersCallback([](std::size_t peers) {
        log_line("peer count changed: %zu", peers);
    });
    link.setTempoCallback([](double tempo) {
        log_line("tempo changed: %.1f", tempo);
    });
    link.setStartStopCallback([](bool playing) {
        log_line("start stop sync: %s", playing ? "playing" : "stopped");
    });
}

/* --probe: join, wait for peers, print a scriptable verdict. */
int run_probe(double tempo, int secs)
{
    install_signal_handlers();

    ableton::Link link(tempo);
    link.enableStartStopSync(true);
    link.enable(true);

    const auto deadline = std::chrono::steady_clock::now()
                          + std::chrono::seconds(secs);
    while (std::chrono::steady_clock::now() < deadline) {
        if (link.numPeers() >= 1) {
            std::this_thread::sleep_for(kProbeGrace);
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (g_quit)
            break;
    }

    const auto state = link.captureAppSessionState();
    const std::size_t peers = link.numPeers();
    std::printf("peers: %zu\n", peers);
    std::printf("tempo: %.1f\n", state.tempo());

    link.enable(false);
    return peers >= 1 ? 0 : 1;
}

/* Foreground and --daemon: anchor the session until signalled. */
int run_anchor(double tempo, bool as_daemon, bool verbose)
{
    if (as_daemon) {
        std::string log_dir;
        if (!ensure_log_dir(log_dir) || !daemonize(log_dir))
            return 1;
    }

    install_signal_handlers();

    ableton::Link link(tempo);
    link.enableStartStopSync(true);
    register_callbacks(link);
    link.enable(true);
    log_line("Ableton Link enabled (initial tempo %.1f, start stop sync on)",
             tempo);
    print_status(link);

    auto last_status = std::chrono::steady_clock::now();
    while (!g_quit) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        const auto now = std::chrono::steady_clock::now();
        if (verbose && now - last_status >= kStatusPeriod) {
            print_status(link);
            last_status = now;
        }
    }

    link.enable(false);
    log_line("Ableton Link disabled, exiting");
    return 0;
}

void print_usage(const char* argv0)
{
    std::printf(
        "ableton-linkd: native Ableton Link session anchor and probe\n"
        "\n"
        "usage: %s [--tempo BPM] [--verbose] [--daemon | --probe [secs] | --help]\n"
        "\n"
        "  (no options)   run in the foreground; log to stderr on peer, tempo and\n"
        "                 start-stop changes\n"
        "  --daemon       fork to the background, log to\n"
        "                 ~/.log/ableton-linkd/ableton-linkd.log\n"
        "  --probe [s]    join, wait up to s seconds (default %d), print \"peers: N\"\n"
        "                 and \"tempo: T.T\"; exit 0 iff at least one peer was seen\n"
        "  --tempo BPM    initial tempo when founding a session (default 120.0,\n"
        "                 valid range %.0f-%.0f)\n"
        "  --verbose      also log a status line every 10 s\n"
        "                 (ABLETON_LINKD_VERBOSE=1 does the same)\n"
        "  --help         this text\n"
        "\n"
        "Strictly passive: after construction it never changes the session tempo\n"
        "or timeline (Ableton Link anti-hijack guidelines). SIGTERM/SIGINT shut\n"
        "down cleanly (Link disabled, exit 0).\n",
        argv0, kDefaultProbeSecs, kMinBpm, kMaxBpm);
}

bool parse_double(const char* s, double lo, double hi, double& out)
{
    char* end = nullptr;
    errno = 0;
    const double v = std::strtod(s, &end);
    if (errno != 0 || end == s || *end != '\0' || v < lo || v > hi)
        return false;
    out = v;
    return true;
}

} // namespace

int main(int argc, char** argv)
{
    double tempo = 120.0;
    bool as_daemon = false;
    bool probe = false;
    int probe_secs = kDefaultProbeSecs;
    const char* verbose_env = std::getenv("ABLETON_LINKD_VERBOSE");
    bool verbose = verbose_env && *verbose_env && std::strcmp(verbose_env, "0") != 0;

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            print_usage(argv[0]);
            return 0;
        } else if (arg == "--daemon") {
            as_daemon = true;
        } else if (arg == "--verbose") {
            verbose = true;
        } else if (arg == "--probe") {
            probe = true;
            /* optional value: --probe 15 */
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                double secs;
                if (!parse_double(argv[i + 1], 1.0, 3600.0, secs)) {
                    std::fprintf(stderr, "ableton-linkd: bad --probe value '%s'\n",
                                 argv[i + 1]);
                    return 2;
                }
                probe_secs = static_cast<int>(secs);
                ++i;
            }
        } else if (arg == "--tempo") {
            if (i + 1 >= argc
                || !parse_double(argv[i + 1], kMinBpm, kMaxBpm, tempo)) {
                std::fprintf(stderr,
                             "ableton-linkd: --tempo needs a BPM value in %.0f-%.0f\n",
                             kMinBpm, kMaxBpm);
                return 2;
            }
            ++i;
        } else {
            std::fprintf(stderr, "ableton-linkd: unknown option '%s' (try --help)\n",
                         arg.c_str());
            return 2;
        }
    }

    if (as_daemon && probe) {
        std::fprintf(stderr, "ableton-linkd: --daemon and --probe are mutually exclusive\n");
        return 2;
    }

    return probe ? run_probe(tempo, probe_secs)
                 : run_anchor(tempo, as_daemon, verbose);
}
