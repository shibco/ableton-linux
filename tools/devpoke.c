/* devpoke.c — broadcast WM_DEVICECHANGE/DBT_DEVNODES_CHANGED (PE, CRT-free).
 *
 * Asks every top-level window in the session to re-enumerate its devices,
 * the way Windows' PnP manager does when the device tree changes. This is
 * the cheap half of H3 in ABLETON-WINE-DEVICE-HOTPLUG.md: DBT_DEVNODES_CHANGED
 * needs no RegisterDeviceNotification and carries lparam 0, so unlike a
 * device-interface arrival it can be broadcast across processes without
 * marshalling a struct into the receiver.
 *
 * Used to answer: does Live re-enumerate MIDI when it is told to? Run Live
 * under WINEDEBUG=+winmm, fire this, and look for MMDRV_GetNum /
 * midiInGetDevCaps traces that follow it.
 *
 * usage: run_in_prefix.sh devpoke.exe [count] [gap_ms]
 * build: see build_devpoke.sh
 */
#include <windows.h>
#include <dbt.h>

static HANDLE g_out;
static char buf[512];

static void emit( const char *s ){ DWORD n; WriteFile( g_out, s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

static UINT parse_uint( const char **p, UINT fallback )
{
    UINT v = 0;
    int any = 0;

    while (**p == ' ') (*p)++;
    while (**p >= '0' && **p <= '9') { v = v * 10 + (UINT)(**p - '0'); (*p)++; any = 1; }
    return any ? v : fallback;
}

void mainCRTStartup( void )
{
    const char *cmd = GetCommandLineA();
    UINT count, gap, i;

    g_out = GetStdHandle( STD_OUTPUT_HANDLE );

    /* skip past the exe name, quoted or not */
    if (*cmd == '"') { cmd++; while (*cmd && *cmd != '"') cmd++; if (*cmd) cmd++; }
    else while (*cmd && *cmd != ' ') cmd++;

    count = parse_uint( &cmd, 1 );
    gap   = parse_uint( &cmd, 1000 );

    for (i = 0; i < count; i++)
    {
        DWORD recipients = BSM_APPLICATIONS;
        LONG  ret;

        SetLastError( 0 );
        ret = BroadcastSystemMessageW( BSF_POSTMESSAGE | BSF_IGNORECURRENTTASK,
                                       &recipients, WM_DEVICECHANGE,
                                       DBT_DEVNODES_CHANGED, 0 );
        P( "[t=%u] broadcast %u/%u DBT_DEVNODES_CHANGED -> %d (err %u)\r\n",
           (UINT)GetTickCount(), i + 1, count, (int)ret, (UINT)GetLastError() );

        if (i + 1 < count) Sleep( gap );
    }

    ExitProcess( 0 );
}
