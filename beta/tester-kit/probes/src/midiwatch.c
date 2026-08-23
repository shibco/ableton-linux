/* midiwatch.c — WinMM MIDI topology watcher and hotplug assertion probe.
 *
 * With no arguments, this polls the current input/output lists and logs
 * WM_DEVICECHANGE without opening a MIDI handle. Assertion modes take their
 * baseline first, then require a matching device to appear and open it only
 * after publication. Cycle mode keeps those handles open while the device is
 * removed and recreated.
 *
 *   midiwatch.exe --assert-add MATCH INPUTS OUTPUTS TIMEOUT_MS
 *   midiwatch.exe --assert-cycle MATCH INPUTS OUTPUTS TIMEOUT_MS [CYCLES]
 *
 * build: see build_midiwatch.sh
 */
#include <windows.h>
#include <mmsystem.h>
#include <dbt.h>

#define MAXDEV 128
#define ARG_SIZE 128

static HANDLE g_out;
static char print_buffer[2048];
static char in_names[MAXDEV][MAXPNAMELEN];
static char out_names[MAXDEV][MAXPNAMELEN];
static UINT in_count = ~0u, out_count = ~0u;
static HMIDIIN input_handle;
static HMIDIOUT output_handle;
static volatile LONG input_events;
static volatile LONG device_changes;

static void emit(const char *text)
{
    DWORD written;
    WriteFile(g_out, text, lstrlenA(text), &written, NULL);
}

#define P(...) do { wsprintfA(print_buffer, __VA_ARGS__); emit(print_buffer); } while (0)

static int contains(const char *text, const char *part)
{
    int text_len = lstrlenA(text), part_len = lstrlenA(part), i, j;

    for (i = 0; i + part_len <= text_len; i++)
    {
        for (j = 0; j < part_len && text[i + j] == part[j]; j++);
        if (j == part_len) return 1;
    }
    return 0;
}

static int next_arg(const char **cursor, char *value, UINT size)
{
    const char *text = *cursor;
    char quote = 0;
    UINT used = 0;

    while (*text == ' ' || *text == '\t') text++;
    if (!*text) return 0;
    if (*text == '"') quote = *text++;
    while (*text && ((quote && *text != quote) || (!quote && *text != ' ' && *text != '\t')))
    {
        if (used + 1 < size) value[used++] = *text;
        text++;
    }
    if (quote && *text == quote) text++;
    value[used] = 0;
    *cursor = text;
    return 1;
}

static int parse_uint(const char *text, UINT min, UINT max, UINT *value)
{
    UINT result = 0;

    if (!*text) return 0;
    while (*text)
    {
        UINT digit;
        if (*text < '0' || *text > '9') return 0;
        digit = *text++ - '0';
        if (result > (max - digit) / 10) return 0;
        result = result * 10 + digit;
    }
    if (result < min || result > max) return 0;
    *value = result;
    return 1;
}

/* Returns nonzero if a count or visible name changed. */
static int snapshot(int input)
{
    UINT count = input ? midiInGetNumDevs() : midiOutGetNumDevs();
    UINT *old_count = input ? &in_count : &out_count;
    char (*names)[MAXPNAMELEN] = input ? in_names : out_names;
    int changed = count != *old_count;
    UINT i;

    for (i = 0; i < count && i < MAXDEV; i++)
    {
        char current[MAXPNAMELEN];
        MMRESULT result;

        current[0] = 0;
        if (input)
        {
            MIDIINCAPSA caps;
            caps.szPname[0] = 0;
            result = midiInGetDevCapsA(i, &caps, sizeof(caps));
            if (result == MMSYSERR_NOERROR)
                lstrcpynA(current, caps.szPname, MAXPNAMELEN);
        }
        else
        {
            MIDIOUTCAPSA caps;
            caps.szPname[0] = 0;
            result = midiOutGetDevCapsA(i, &caps, sizeof(caps));
            if (result == MMSYSERR_NOERROR)
                lstrcpynA(current, caps.szPname, MAXPNAMELEN);
        }
        if (lstrcmpA(current, names[i]))
        {
            changed = 1;
            lstrcpynA(names[i], current, MAXPNAMELEN);
        }
    }
    *old_count = count;
    return changed;
}

static void dump(int input)
{
    UINT count = input ? in_count : out_count;
    char (*names)[MAXPNAMELEN] = input ? in_names : out_names;
    UINT i;

    P("  midi-%s: %u device(s)\r\n", input ? "in " : "out", count);
    for (i = 0; i < count && i < MAXDEV; i++)
        P("    %u: '%s'\r\n", i, names[i]);
}

static UINT matching_count(int input, const char *match)
{
    UINT count = input ? in_count : out_count;
    char (*names)[MAXPNAMELEN] = input ? in_names : out_names;
    UINT i, matches = 0;

    for (i = 0; i < count && i < MAXDEV; i++)
        if (contains(names[i], match)) matches++;
    return matches;
}

static UINT first_match(int input, const char *match)
{
    UINT count = input ? in_count : out_count;
    char (*names)[MAXPNAMELEN] = input ? in_names : out_names;
    UINT i;

    for (i = 0; i < count && i < MAXDEV; i++)
        if (contains(names[i], match)) return i;
    return ~0u;
}

static void poll_lists(void)
{
    int inputs_changed = snapshot(1), outputs_changed = snapshot(0);

    if (inputs_changed || outputs_changed)
    {
        P("[t=%u] device list changed\r\n", (UINT)GetTickCount());
        if (inputs_changed) dump(1);
        if (outputs_changed) dump(0);
    }
}

static void pump_messages(void)
{
    MSG message;

    while (PeekMessageA(&message, NULL, 0, 0, PM_REMOVE))
    {
        TranslateMessage(&message);
        DispatchMessageA(&message);
    }
}

static int deadline_expired(DWORD deadline)
{
    return (int)(GetTickCount() - deadline) >= 0;
}

static int topology_matches(UINT added_inputs, UINT added_outputs,
                            const char *match, int present)
{
    if (present)
        return matching_count(1, match) == added_inputs &&
               matching_count(0, match) == added_outputs;
    return !matching_count(1, match) && !matching_count(0, match);
}

static int wait_for_topology(UINT added_inputs, UINT added_outputs,
                             const char *match, int present, UINT timeout)
{
    DWORD deadline = GetTickCount() + timeout;

    while (!deadline_expired(deadline))
    {
        pump_messages();
        poll_lists();
        if (topology_matches(added_inputs, added_outputs, match, present)) return 1;
        Sleep(20);
    }
    P("ASSERT FAIL phase=%s in=%u out=%u match_in=%u match_out=%u\r\n",
      present ? "publication" : "removal", in_count, out_count,
      matching_count(1, match), matching_count(0, match));
    return 0;
}

static void CALLBACK midi_callback(HMIDIIN handle, UINT message, DWORD_PTR instance,
                                   DWORD_PTR param1, DWORD_PTR param2)
{
    (void)handle;
    (void)instance;
    (void)param1;
    (void)param2;
    if (message == MIM_DATA || message == MIM_LONGDATA)
        InterlockedIncrement(&input_events);
}

static int open_matching_handles(const char *match, UINT want_input, UINT want_output)
{
    if (want_input && !input_handle)
    {
        UINT id = first_match(1, match);
        MMRESULT result;

        if (id == ~0u) return 0;
        result = midiInOpen(&input_handle, id, (DWORD_PTR)midi_callback, 0,
                            CALLBACK_FUNCTION);
        if (result != MMSYSERR_NOERROR)
        {
            input_handle = NULL;
            return 0;
        }
        result = midiInStart(input_handle);
        if (result != MMSYSERR_NOERROR)
        {
            midiInClose(input_handle);
            input_handle = NULL;
            return 0;
        }
        P("ASSERT OPEN_INPUT id=%u\r\n", id);
    }

    if (want_output && !output_handle)
    {
        UINT id = first_match(0, match);
        MMRESULT result;

        if (id == ~0u) return 0;
        result = midiOutOpen(&output_handle, id, 0, 0, CALLBACK_NULL);
        if (result != MMSYSERR_NOERROR)
        {
            output_handle = NULL;
            return 0;
        }
        P("ASSERT OPEN_OUTPUT id=%u\r\n", id);
    }
    return (!want_input || input_handle) && (!want_output || output_handle);
}

static int send_output_pair(void)
{
    if (!output_handle) return 1;
    return midiOutShortMsg(output_handle, 0x00643c90) == MMSYSERR_NOERROR &&
           midiOutShortMsg(output_handle, 0x00003c80) == MMSYSERR_NOERROR;
}

static LONG read_input_events(void)
{
    return InterlockedCompareExchange(&input_events, 0, 0);
}

static LONG read_device_changes(void)
{
    return InterlockedCompareExchange(&device_changes, 0, 0);
}

static int wait_for_notification(LONG notification_floor, UINT timeout)
{
    DWORD deadline = GetTickCount() + timeout;

    while (!deadline_expired(deadline))
    {
        pump_messages();
        if (read_device_changes() > notification_floor)
        {
            P("ASSERT NOTIFIED device_changes=%u\r\n", (UINT)read_device_changes());
            return 1;
        }
        Sleep(20);
    }
    P("ASSERT FAIL phase=notification device_changes=%u\r\n",
      (UINT)read_device_changes());
    return 0;
}

static int wait_for_io(const char *match, UINT want_input, UINT want_output,
                       LONG input_floor, UINT timeout)
{
    DWORD deadline = GetTickCount() + timeout;
    int output_ready = !want_output;

    while (!deadline_expired(deadline))
    {
        pump_messages();
        if (!open_matching_handles(match, want_input, want_output))
        {
            Sleep(20);
            continue;
        }
        if (want_output && send_output_pair()) output_ready = 1;
        if ((!want_input || read_input_events() > input_floor) && output_ready)
            return 1;
        Sleep(20);
    }
    P("ASSERT FAIL phase=io input_events=%u output_ready=%u\r\n",
      (UINT)read_input_events(), output_ready);
    return 0;
}

static void close_handles(void)
{
    if (input_handle)
    {
        midiInStop(input_handle);
        midiInReset(input_handle);
        midiInClose(input_handle);
        input_handle = NULL;
    }
    if (output_handle)
    {
        midiOutReset(output_handle);
        midiOutClose(output_handle);
        output_handle = NULL;
    }
}

static int run_assertion(const char *mode, const char *match,
                         UINT added_inputs, UINT added_outputs,
                         UINT timeout, UINT cycles)
{
    UINT base_inputs = in_count, base_outputs = out_count, cycle;
    LONG input_floor, notification_floor = read_device_changes();

    P("ASSERT BASELINE in=%u out=%u match_in=%u match_out=%u\r\n",
      base_inputs, base_outputs, matching_count(1, match), matching_count(0, match));
    if (matching_count(1, match) || matching_count(0, match))
    {
        P("ASSERT FAIL phase=baseline reason=matching-device-already-present\r\n");
        return 4;
    }

    if (!wait_for_topology(added_inputs, added_outputs, match, 1, timeout)) return 4;
    P("ASSERT ADDED in=%u out=%u\r\n", in_count, out_count);
    input_floor = read_input_events();
    if (!wait_for_io(match, added_inputs != 0, added_outputs != 0,
                     input_floor, timeout))
    {
        close_handles();
        return 4;
    }
    if (!wait_for_notification(notification_floor, timeout))
    {
        close_handles();
        return 4;
    }

    if (!lstrcmpA(mode, "add"))
    {
        P("ASSERT PASS mode=add input_events=%u device_changes=%u\r\n",
          (UINT)read_input_events(), (UINT)device_changes);
        close_handles();
        return 0;
    }

    for (cycle = 1; cycle <= cycles; cycle++)
    {
        notification_floor = read_device_changes();
        P("ASSERT READY_FOR_REMOVE cycle=%u\r\n", cycle);
        if (!wait_for_topology(added_inputs, added_outputs, match, 0, timeout))
        {
            close_handles();
            return 4;
        }
        if (!wait_for_notification(notification_floor, timeout))
        {
            close_handles();
            return 4;
        }
        P("ASSERT REMOVED cycle=%u\r\n", cycle);
        notification_floor = read_device_changes();
        P("ASSERT READY_FOR_READD cycle=%u\r\n", cycle);
        if (!wait_for_topology(added_inputs, added_outputs, match, 1, timeout))
        {
            close_handles();
            return 4;
        }
        input_floor = read_input_events();
        if (!wait_for_io(match, added_inputs != 0, added_outputs != 0,
                         input_floor, timeout))
        {
            close_handles();
            return 4;
        }
        if (!wait_for_notification(notification_floor, timeout))
        {
            close_handles();
            return 4;
        }
        P("ASSERT CYCLE_PASS cycle=%u input_events=%u\r\n",
          cycle, (UINT)read_input_events());
    }

    P("ASSERT PASS mode=cycle cycles=%u input_events=%u device_changes=%u\r\n",
      cycles, (UINT)read_input_events(), (UINT)device_changes);
    close_handles();
    return 0;
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_DEVICECHANGE)
    {
        const char *kind = "other";

        InterlockedIncrement(&device_changes);
        if (wparam == DBT_DEVNODES_CHANGED) kind = "DBT_DEVNODES_CHANGED";
        else if (wparam == DBT_DEVICEARRIVAL) kind = "DBT_DEVICEARRIVAL";
        else if (wparam == DBT_DEVICEREMOVECOMPLETE) kind = "DBT_DEVICEREMOVECOMPLETE";
        P("[t=%u] WM_DEVICECHANGE wparam=%08x (%s)\r\n",
          (UINT)GetTickCount(), (UINT)wparam, kind);
        if (lparam)
        {
            DEV_BROADCAST_HDR *header = (DEV_BROADCAST_HDR *)lparam;
            P("         devicetype=%u\r\n", (UINT)header->dbch_devicetype);
        }
    }
    return DefWindowProcA(window, message, wparam, lparam);
}

static void usage(void)
{
    emit("usage:\r\n"
         "  midiwatch.exe\r\n"
         "  midiwatch.exe --assert-add MATCH INPUTS OUTPUTS TIMEOUT_MS\r\n"
         "  midiwatch.exe --assert-cycle MATCH INPUTS OUTPUTS TIMEOUT_MS [CYCLES]\r\n");
}

void mainCRTStartup(void)
{
    const char *command = GetCommandLineA();
    char executable[ARG_SIZE], option[ARG_SIZE], match[ARG_SIZE];
    char input_arg[ARG_SIZE], output_arg[ARG_SIZE], timeout_arg[ARG_SIZE];
    char cycles_arg[ARG_SIZE];
    const char *mode = "watch";
    UINT added_inputs = 0, added_outputs = 0, timeout = 0, cycles = 1;
    WNDCLASSA window_class;
    DEV_BROADCAST_DEVICEINTERFACE_A filter;
    HDEVNOTIFY notification;
    HWND window;
    DWORD next_poll;

    g_out = GetStdHandle(STD_OUTPUT_HANDLE);
    next_arg(&command, executable, sizeof(executable));
    if (next_arg(&command, option, sizeof(option)))
    {
        if (!lstrcmpA(option, "--help") || !lstrcmpA(option, "-h"))
        {
            usage();
            ExitProcess(0);
        }
        if (!lstrcmpA(option, "--assert-add")) mode = "add";
        else if (!lstrcmpA(option, "--assert-cycle")) mode = "cycle";
        else
        {
            usage();
            ExitProcess(2);
        }
        if (!next_arg(&command, match, sizeof(match)) ||
            !next_arg(&command, input_arg, sizeof(input_arg)) ||
            !next_arg(&command, output_arg, sizeof(output_arg)) ||
            !next_arg(&command, timeout_arg, sizeof(timeout_arg)) ||
            !parse_uint(input_arg, 0, MAXDEV, &added_inputs) ||
            !parse_uint(output_arg, 0, MAXDEV, &added_outputs) ||
            !parse_uint(timeout_arg, 100, 600000, &timeout) ||
            (!added_inputs && !added_outputs))
        {
            usage();
            ExitProcess(2);
        }
        if (next_arg(&command, cycles_arg, sizeof(cycles_arg)))
        {
            if (lstrcmpA(mode, "cycle") || !parse_uint(cycles_arg, 1, 100, &cycles) ||
                next_arg(&command, option, sizeof(option)))
            {
                usage();
                ExitProcess(2);
            }
        }
    }

    window_class.style = 0;
    window_class.lpfnWndProc = window_proc;
    window_class.cbClsExtra = window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandleA(NULL);
    window_class.hIcon = NULL;
    window_class.hCursor = NULL;
    window_class.hbrBackground = NULL;
    window_class.lpszMenuName = NULL;
    window_class.lpszClassName = "midiwatch";
    RegisterClassA(&window_class);
    window = CreateWindowExA(0, "midiwatch", "midiwatch", WS_OVERLAPPEDWINDOW,
                             0, 0, 100, 100, NULL, NULL,
                             window_class.hInstance, NULL);
    if (!window)
    {
        P("CreateWindow failed %u\r\n", (UINT)GetLastError());
        ExitProcess(1);
    }

    filter.dbcc_size = sizeof(filter);
    filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
    filter.dbcc_reserved = 0;
    filter.dbcc_name[0] = 0;
    notification = RegisterDeviceNotificationA(window, &filter,
            DEVICE_NOTIFY_WINDOW_HANDLE | DEVICE_NOTIFY_ALL_INTERFACE_CLASSES);
    P("watcher hwnd %p notification=%p\r\n", window, notification);

    snapshot(1);
    snapshot(0);
    P("[t=%u] initial\r\n", (UINT)GetTickCount());
    dump(1);
    dump(0);

    if (lstrcmpA(mode, "watch"))
        ExitProcess(run_assertion(mode, match, added_inputs, added_outputs,
                                  timeout, cycles));

    P("watching without open MIDI handles; plug/unplug now, kill me to stop\r\n");
    next_poll = GetTickCount() + 500;
    for (;;)
    {
        pump_messages();
        if ((int)(GetTickCount() - next_poll) >= 0)
        {
            poll_lists();
            next_poll = GetTickCount() + 500;
        }
        Sleep(20);
    }
}
