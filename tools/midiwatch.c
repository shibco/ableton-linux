/* midiwatch.c — winmm MIDI device-list watcher (PE, CRT-free).
 *
 * Polls midiInGetNumDevs()/midiOutGetNumDevs() twice a second without opening
 * a MIDI endpoint, and prints the full device list whenever the count or any
 * name changes. Also creates a hidden top-level window and logs every
 * WM_DEVICECHANGE it receives, both
 * the unfiltered DBT_DEVNODES_CHANGED broadcast and anything delivered
 * through RegisterDeviceNotificationW with DEVICE_NOTIFY_ALL_INTERFACE_CLASSES
 * — the same registration Live makes.
 *
 * Used to separate the three layers that can hold a hotplugged MIDI device
 * out of Live: the winealsa device table, winmm's cached device count, and
 * the absence of any device-change notification.
 *
 * build: see build_midiwatch.sh; run: run_in_prefix.sh midiwatch.exe
 */
#include <windows.h>
#include <mmsystem.h>
#include <dbt.h>

static HANDLE g_out;
static char buf[2048];

static void emit( const char *s ){ DWORD n; WriteFile( g_out, s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

#define MAXDEV 64
static char in_names[MAXDEV][MAXPNAMELEN];
static char out_names[MAXDEV][MAXPNAMELEN];
static UINT in_count = ~0u, out_count = ~0u;

/* Returns 1 if the list changed since the last call. */
static int snapshot( int is_in )
{
    UINT n = is_in ? midiInGetNumDevs() : midiOutGetNumDevs();
    UINT *last = is_in ? &in_count : &out_count;
    char (*names)[MAXPNAMELEN] = is_in ? in_names : out_names;
    int changed = (n != *last);
    UINT i;

    for (i = 0; i < n && i < MAXDEV; i++) {
        char cur[MAXPNAMELEN];
        cur[0] = 0;
        if (is_in) {
            MIDIINCAPSA c; c.szPname[0] = 0;
            midiInGetDevCapsA( i, &c, sizeof(c) );
            lstrcpynA( cur, c.szPname, MAXPNAMELEN );
        } else {
            MIDIOUTCAPSA c; c.szPname[0] = 0;
            midiOutGetDevCapsA( i, &c, sizeof(c) );
            lstrcpynA( cur, c.szPname, MAXPNAMELEN );
        }
        if (lstrcmpA( cur, names[i] )) { changed = 1; lstrcpynA( names[i], cur, MAXPNAMELEN ); }
    }
    *last = n;
    return changed;
}

static void dump( int is_in )
{
    UINT n = is_in ? in_count : out_count;
    char (*names)[MAXPNAMELEN] = is_in ? in_names : out_names;
    UINT i;

    P( "  midi-%s: %u device(s)\r\n", is_in ? "in " : "out", n );
    for (i = 0; i < n && i < MAXDEV; i++)
        P( "    %u: '%s'\r\n", i, names[i] );
}

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_DEVICECHANGE) {
        const char *what = "other";
        switch (wp) {
            case DBT_DEVNODES_CHANGED:   what = "DBT_DEVNODES_CHANGED"; break;
            case DBT_DEVICEARRIVAL:      what = "DBT_DEVICEARRIVAL"; break;
            case DBT_DEVICEREMOVECOMPLETE: what = "DBT_DEVICEREMOVECOMPLETE"; break;
        }
        P( "[t=%u] WM_DEVICECHANGE wparam=%08x (%s)\r\n",
           (UINT)GetTickCount(), (UINT)wp, what );
        if (lp) {
            DEV_BROADCAST_HDR *h = (DEV_BROADCAST_HDR *)lp;
            P( "         devicetype=%u\r\n", (UINT)h->dbch_devicetype );
        }
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

void mainCRTStartup( void )
{
    WNDCLASSA wc;
    HWND hwnd;
    DEV_BROADCAST_DEVICEINTERFACE_A filter;
    HDEVNOTIFY notify;
    MSG m;
    DWORD next_poll;

    g_out = GetStdHandle( STD_OUTPUT_HANDLE );

    /* A real top-level window: DBT_DEVNODES_CHANGED goes to every top-level
     * window with no registration at all, so this alone catches the cheapest
     * possible trigger. */
    wc.style = 0;
    wc.lpfnWndProc = wndproc;
    wc.cbClsExtra = wc.cbWndExtra = 0;
    wc.hInstance = GetModuleHandleA( NULL );
    wc.hIcon = NULL;
    wc.hCursor = NULL;
    wc.hbrBackground = NULL;
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "midiwatch";
    RegisterClassA( &wc );
    hwnd = CreateWindowExA( 0, "midiwatch", "midiwatch", WS_OVERLAPPEDWINDOW,
                            0, 0, 100, 100, NULL, NULL, wc.hInstance, NULL );
    if (!hwnd) { P( "CreateWindow failed %u\r\n", (UINT)GetLastError() ); ExitProcess( 1 ); }
    P( "watcher hwnd %p\r\n", hwnd );

    /* Same registration Live makes (it imports RegisterDeviceNotificationW). */
    filter.dbcc_size = sizeof(filter);
    filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
    filter.dbcc_reserved = 0;
    filter.dbcc_name[0] = 0;
    notify = RegisterDeviceNotificationA( hwnd, &filter,
                                          DEVICE_NOTIFY_WINDOW_HANDLE |
                                          DEVICE_NOTIFY_ALL_INTERFACE_CLASSES );
    P( "RegisterDeviceNotification -> %p (err %u)\r\n", notify, (UINT)GetLastError() );

    snapshot( 1 ); snapshot( 0 );
    P( "[t=%u] initial\r\n", (UINT)GetTickCount() );
    dump( 1 ); dump( 0 );

    /* Deliberately hold no MIDI handle. A dedicated topology monitor must
     * discover the first device and work in output-only sessions. */
    P( "watching without open MIDI handles; plug/unplug now, kill me to stop\r\n" );

    next_poll = GetTickCount() + 500;
    for (;;) {
        while (PeekMessageA( &m, NULL, 0, 0, PM_REMOVE )) {
            TranslateMessage( &m );
            DispatchMessageA( &m );
        }
        if ((int)(GetTickCount() - next_poll) >= 0) {
            int a = snapshot( 1 ), b = snapshot( 0 );
            if (a || b) {
                P( "[t=%u] device list changed\r\n", (UINT)GetTickCount() );
                if (a) dump( 1 );
                if (b) dump( 0 );
            }
            next_poll = GetTickCount() + 500;
        }
        Sleep( 20 );
    }
}
