/* swamprobe.c — non-disruptive window-tree + DPI + hit-test probe (PE, CRT-free).
 *
 * Built as a real PE with clang -target x86_64-windows against Wine's own
 * headers + import libs (the patched Wine is new-WoW64/PE-only and cannot run
 * winelib .exe.so modules — that is why a winelib build exits 46 with no output).
 * No msvcrt: output via wsprintfA + WriteFile to swamprobe.txt in the cwd.
 *
 * MUST run in the SAME prefix/wineserver as the running Ableton Live
 * (WINEPREFIX=~/works/plugs/studio + the patched wine binary), otherwise it sees a
 * fresh empty desktop and the dump is empty. Use run_probe.sh.
 *
 * The probe sets itself per-monitor-v2 so ALL coordinates it reports are
 * physical (192-dpi X-screen) space, comparable across windows regardless of
 * each window's own awareness.
 *
 * usage:
 *   swamprobe                 dump all top-level windows + children
 *   swamprobe hit <x> <y>     WindowFromPoint + NCHITTEST at physical coords
 *   swamprobe watch <secs>    poll cursor pos/buttons/focus; log transitions
 *                             (verifies whether injected input reaches Wine)
 *
 * build: see build_swamprobe.sh (this dir).
 */
#include <windows.h>

typedef DPI_AWARENESS_CONTEXT (WINAPI *pCtx)(HWND);
typedef DPI_AWARENESS         (WINAPI *pAw)(DPI_AWARENESS_CONTEXT);
typedef UINT                  (WINAPI *pDpi)(HWND);
typedef BOOL                  (WINAPI *pSetPCtx)(DPI_AWARENESS_CONTEXT);
static pCtx p_ctx; static pAw p_aw; static pDpi p_dpi;

static HANDLE g_out;
static char   buf[2048];
static int    g_count;

static void emit( const char *s ){ DWORD n; WriteFile( g_out, s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

static const char *awstr( HWND h )
{
    if (!p_ctx || !p_aw) return "?";
    switch (p_aw( p_ctx( h ) )) {
        case DPI_AWARENESS_UNAWARE:           return "UNAWARE";
        case DPI_AWARENESS_SYSTEM_AWARE:      return "SYSTEM";
        case DPI_AWARENESS_PER_MONITOR_AWARE: return "PERMON";
        default:                              return "invalid";
    }
}

static void describe( HWND h, int depth )
{
    char cls[128]; char title[160];
    cls[0] = 0; title[0] = 0;
    GetClassNameA( h, cls, sizeof cls );
    GetWindowTextA( h, title, sizeof title );

    LONG style = GetWindowLongW( h, GWL_STYLE );
    LONG ex    = GetWindowLongW( h, GWL_EXSTYLE );
    RECT wr, cr; wr.left=wr.top=wr.right=wr.bottom=0; cr=wr;
    GetWindowRect( h, &wr );
    GetClientRect( h, &cr );
    DWORD pid = 0; DWORD tid = GetWindowThreadProcessId( h, &pid );
    UINT dpi = p_dpi ? p_dpi( h ) : 0;

    BYTE alpha = 0; COLORREF ck = 0; DWORD lflags = 0;
    BOOL layered = (ex & WS_EX_LAYERED) &&
                   GetLayeredWindowAttributes( h, &ck, &alpha, &lflags );

    POINT c; c.x = (wr.left + wr.right) / 2; c.y = (wr.top + wr.bottom) / 2;
    HWND hit = WindowFromPoint( c );
    DWORD_PTR nc = 0;
    SendMessageTimeoutW( h, WM_NCHITTEST, 0, MAKELPARAM(c.x, c.y),
                         SMTO_ABORTIFHUNG, 200, &nc );

    /* wsprintfA does NOT support %.*s (star precision) — emit indent separately */
    const char *pad = (depth >= 2) ? "    " : (depth == 1) ? "  " : "";
    emit( pad );
    P( "hwnd=%p pid=%lu tid=%lu vis=%d cls='%s' '%s'\n",
       h, pid, tid, IsWindowVisible(h), cls, title );
    emit( pad );
    P( "    style=%08lx ex=%08lx%s%s%s%s%s dpi=%u aware=%s\n",
       style, ex,
       (ex & WS_EX_TOOLWINDOW)  ? " TOOL"        : "",
       (ex & WS_EX_LAYERED)     ? " LAYERED"     : "",
       (ex & WS_EX_TRANSPARENT) ? " TRANSPARENT" : "",
       (ex & WS_EX_NOACTIVATE)  ? " NOACTIVATE"  : "",
       (style & WS_DISABLED)    ? " DISABLED"    : "",
       dpi, awstr( h ) );
    emit( pad );
    P( "    winrect=(%ld,%ld)-(%ld,%ld) %ldx%ld client=%ldx%ld\n",
       wr.left, wr.top, wr.right, wr.bottom,
       wr.right - wr.left, wr.bottom - wr.top, cr.right, cr.bottom );
    if (layered)
    {
        emit( pad );
        P( "    LAYERED alpha=%u colorkey=%06lx flags=%lx\n",
           alpha, (unsigned long)ck, lflags );
    }
    if (cls[0]=='J' && cls[1]=='U' && cls[2]=='C' && cls[3]=='E')
    {
        ULONG_PTR ud = (ULONG_PTR)GetWindowLongPtrW( h, GWLP_USERDATA );
        ULONG_PTR x8 = (ULONG_PTR)GetWindowLongPtrW( h, 8 );
        ULONG_PTR x0 = (ULONG_PTR)GetWindowLongPtrW( h, 0 );
        int cbextra = (int)GetClassLongPtrW( h, GCL_CBWNDEXTRA );
        ULONG_PTR wp = (ULONG_PTR)GetWindowLongPtrW( h, GWLP_WNDPROC );
        ULONG_PTR cp = (ULONG_PTR)GetClassLongPtrW( h, GCLP_WNDPROC );
        emit( pad );
        P( "    JUCE: USERDATA=%08x%08x extra8=%08x%08x extra0=%08x%08x cbWndExtra=%d\n",
           (UINT)(ud >> 32), (UINT)ud, (UINT)(x8 >> 32), (UINT)x8,
           (UINT)(x0 >> 32), (UINT)x0, cbextra );
        emit( pad );
        P( "    JUCE: wndproc=%08x%08x classproc=%08x%08x%s\n",
           (UINT)(wp >> 32), (UINT)wp, (UINT)(cp >> 32), (UINT)cp,
           (wp != cp) ? "  *** SUBCLASSED ***" : "" );
    }
    if (GetWindowRgn( h, NULL ) != ERROR)
    {
        emit( pad );
        P( "    HAS WINDOW REGION\n" );
    }
    emit( pad );
    P( "    center=(%ld,%ld) -> WindowFromPoint=%p (%s) NCHITTEST=%ld\n",
       c.x, c.y, hit,
       (hit == h) ? "SELF" :
       (hit && IsChild( h, hit )) ? "own-child" : "*** OTHER ***",
       (long)nc );
}

static BOOL CALLBACK child_cb( HWND h, LPARAM lp ){ describe( h, 2 ); return TRUE; }

static BOOL CALLBACK top_cb( HWND h, LPARAM lp )
{
    g_count++;
    describe( h, 0 );
    EnumChildWindows( h, child_cb, 0 );
    emit( "\n" );
    return TRUE;
}

static const WCHAR focus_time_propW[] =
    {'_','_','w','i','n','e','_','x','1','1','_','f','o','c','u','s','_','t','i','m','e',0};
static const WCHAR whole_window_propW[] =
    {'_','_','w','i','n','e','_','x','1','1','_','w','h','o','l','e','_','w','i','n','d','o','w',0};

static void dump_gui_state( void )
{
    GUITHREADINFO gi;
    HWND fg = GetForegroundWindow();
    HWND desk = GetDesktopWindow();
    HWND live = FindWindowW( L"Ableton Live Window Class", NULL );
    P( "fg=%p active=%p capture=%p cursorwin=", fg, GetActiveWindow(), GetCapture() );
    { POINT pt; GetCursorPos( &pt ); P( "%p pos=(%ld,%ld)", WindowFromPoint( pt ), pt.x, pt.y ); }
    emit( "\n" );
    gi.cbSize = sizeof(gi);
    if (fg && GetGUIThreadInfo( GetWindowThreadProcessId( fg, NULL ), &gi ))
        P( "fg-thread: active=%p focus=%p capture=%p caret=%p flags=%lx\n",
           gi.hwndActive, gi.hwndFocus, gi.hwndCapture, gi.hwndCaret, gi.flags );
    P( "desktop=%p focus_time=%lu\n", desk,
       (unsigned long)(UINT_PTR)GetPropW( desk, focus_time_propW ) );
    if (fg && fg != desk)
        P( "fg-win focus_time=%lu xwin=%lx\n",
           (unsigned long)(UINT_PTR)GetPropW( fg, focus_time_propW ),
           (unsigned long)(UINT_PTR)GetPropW( fg, whole_window_propW ) );
    if (live)
        P( "live=%p focus_time=%lu xwin=%lx vis=%d\n", live,
           (unsigned long)(UINT_PTR)GetPropW( live, focus_time_propW ),
           (unsigned long)(UINT_PTR)GetPropW( live, whole_window_propW ),
           IsWindowVisible( live ) );
}

/* crude ascii->int */
static int my_atoi( const char *s )
{
    int v = 0, neg = 0;
    while (*s == ' ') s++;
    if (*s == '-') { neg = 1; s++; }
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return neg ? -v : v;
}

void mainCRTStartup( void )
{
    const char *cmd = GetCommandLineA();
    char a1[64] = {0}, a2[64] = {0}, a3[64] = {0};
    HMODULE u = GetModuleHandleA( "user32.dll" );
    pSetPCtx p_setctx;

    p_ctx = (pCtx) GetProcAddress( u, "GetWindowDpiAwarenessContext" );
    p_aw  = (pAw)  GetProcAddress( u, "GetAwarenessFromDpiAwarenessContext" );
    p_dpi = (pDpi) GetProcAddress( u, "GetDpiForWindow" );
    p_setctx = (pSetPCtx) GetProcAddress( u, "SetProcessDpiAwarenessContext" );
    if (p_setctx) p_setctx( DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 );

    /* parse up to 3 args after the exe name (no quote handling needed) */
    {
        const char *s = cmd;
        char *dst[3] = { a1, a2, a3 };
        int i = 0, j;
        if (*s == '"') { s++; while (*s && *s != '"') s++; if (*s) s++; }
        else while (*s && *s != ' ') s++;
        for (i = 0; i < 3; i++) {
            while (*s == ' ') s++;
            if (!*s) break;
            j = 0;
            while (*s && *s != ' ' && j < 63) dst[i][j++] = *s++;
            dst[i][j] = 0;
        }
    }

    g_out = CreateFileA( "swamprobe.txt", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    if (g_out == INVALID_HANDLE_VALUE) g_out = GetStdHandle( STD_OUTPUT_HANDLE );

    if (!lstrcmpA( a1, "hit" ))
    {
        POINT pt; HWND hit;
        pt.x = my_atoi( a2 ); pt.y = my_atoi( a3 );
        hit = WindowFromPoint( pt );
        P( "args a1='%s' a2='%s' a3='%s'\n", a1, a2, a3 );
        P( "=== hit (%d,%d) -> %p ===\n", (int)pt.x, (int)pt.y, hit );
        if (hit) {
            DWORD_PTR nc = 0;
            describe( hit, 0 );
            SendMessageTimeoutW( hit, WM_NCHITTEST, 0, MAKELPARAM(pt.x, pt.y),
                                 SMTO_ABORTIFHUNG, 200, &nc );
            P( "NCHITTEST at point = %ld\n", (long)nc );
            /* walk up the parent chain */
            { HWND w = hit; while ((w = GetAncestor( w, GA_PARENT )) != NULL && w != GetDesktopWindow()) describe( w, 1 ); }
        }
        dump_gui_state();
    }
    else if (!lstrcmpA( a1, "watch" ))
    {
        int secs = my_atoi( a2 ); if (secs <= 0 || secs > 120) secs = 10;
        int i, n = secs * 20;
        POINT last = { -99999, -99999 };
        SHORT lastbtn = 0;
        HWND lastfg = (HWND)(ULONG_PTR)-1;
        P( "=== watch %d s (20 Hz): cursor / VK_LBUTTON / foreground transitions ===\n", secs );
        for (i = 0; i < n; i++)
        {
            POINT pt; SHORT btn; HWND fg;
            GetCursorPos( &pt );
            btn = GetAsyncKeyState( VK_LBUTTON );
            fg = GetForegroundWindow();
            if (pt.x != last.x || pt.y != last.y || (btn & 0x8000) != (lastbtn & 0x8000) || fg != lastfg)
            {
                char cls[64] = ""; HWND under = WindowFromPoint( pt );
                GetClassNameA( under, cls, sizeof cls );
                P( "t=%dms pos=(%ld,%ld) LBTN=%d fg=%p under=%p '%s'\n",
                   i * 50, pt.x, pt.y, (btn & 0x8000) ? 1 : 0, fg, under, cls );
                last = pt; lastbtn = btn; lastfg = fg;
            }
            Sleep( 50 );
        }
        dump_gui_state();
    }
    else
    {
        P( "=== swamprobe dump ===\n" );
        dump_gui_state();
        emit( "=== top-level windows (+ children) ===\n\n" );
        EnumWindows( top_cb, 0 );
        P( "=== %d top-level windows ===\n", g_count );
    }

    if (g_out != GetStdHandle( STD_OUTPUT_HANDLE )) CloseHandle( g_out );
    ExitProcess( 0 );
}
