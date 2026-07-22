/* wmresize2.c — Live-accurate mimic for the aware-at-192 regime.
 *
 * Like wmresize.c but models Live's ALF as it behaves WITH the IFEO
 * dpiAwareness=2 mitigation active: process per-monitor aware, layout in
 * the window's DPI, and the empirical "+4 @96" band DPI-SCALED
 * (pad = 4 * dpi / 96).  Run with argument "flat" to use the unscaled
 * +4 instead (the patch-0029 assumption).
 *     wmresize2.exe          -> pad scales with dpi (hypothesis: Live)
 *     wmresize2.exe flat     -> pad fixed at 4     (hypothesis: probe-era)
 * Output wmresize2.txt.  ~20 s run.
 */
#include <windows.h>

static HANDLE g_out;
static char buf[512];
static void emit( const char *s ){ DWORD n; WriteFile( g_out, s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

static int g_reentry;
static int g_flat;

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_WINDOWPOSCHANGED && !g_reentry)
    {
        WINDOWPOS *pos = (WINDOWPOS *)lp;
        RECT cr, wr, adj;
        UINT dpi = GetDpiForWindow( hwnd );
        int pad = g_flat ? 4 : MulDiv( 4, dpi, 96 );
        int want_w, want_h;

        GetClientRect( hwnd, &cr );
        GetWindowRect( hwnd, &wr );
        SetRect( &adj, 0, 0, cr.right, cr.bottom );
        AdjustWindowRectExForDpi( &adj, (DWORD)GetWindowLongPtrW( hwnd, GWL_STYLE ),
                                  GetMenu( hwnd ) != NULL,
                                  (DWORD)GetWindowLongPtrW( hwnd, GWL_EXSTYLE ), dpi );
        want_w = adj.right - adj.left;
        want_h = adj.bottom - adj.top + pad;
        P( "WPC flags %04x pos %dx%d | dpi %u pad %d | window %dx%d client %dx%d | model -> %dx%d (drift %d)\n",
           (UINT)pos->flags, (int)pos->cx, (int)pos->cy, dpi, pad,
           (int)(wr.right - wr.left), (int)(wr.bottom - wr.top),
           (int)cr.right, (int)cr.bottom, want_w, want_h,
           (int)(want_h - (wr.bottom - wr.top)) );

        g_reentry = 1;
        SetWindowPos( hwnd, NULL, 0, 0, want_w, want_h,
                      SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER );
        g_reentry = 0;
    }
    return DefWindowProcW( hwnd, msg, wp, lp );
}

int mainCRTStartup( void )
{
    WNDCLASSW wc = {0};
    HMENU menu;
    HWND hwnd;
    MSG msg;
    DWORD64 t0;
    const WCHAR *cmd = GetCommandLineW();

    g_flat = cmd && (lstrlenW( cmd ) > 0) &&
             (cmd[lstrlenW( cmd ) - 1] == L't');   /* ...flat */

    g_out = CreateFileA( "wmresize2.txt", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );

    SetProcessDpiAwarenessContext( DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 );

    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW( NULL );
    wc.lpszClassName = L"WmResizeProbe2";
    RegisterClassW( &wc );

    menu = CreateMenu();
    AppendMenuW( menu, MF_STRING, 1, L"File" );
    AppendMenuW( menu, MF_STRING, 2, L"Edit" );
    AppendMenuW( menu, MF_STRING, 3, L"Create" );
    AppendMenuW( menu, MF_STRING, 4, L"View" );
    AppendMenuW( menu, MF_STRING, 5, L"Options" );
    AppendMenuW( menu, MF_STRING, 6, L"Help" );

    hwnd = CreateWindowExW( 0x100, wc.lpszClassName, L"wmresize2 probe",
                            0x06cf0000 | WS_VISIBLE, 200, 200, 900, 600,
                            NULL, menu, wc.hInstance, NULL );
    if (!hwnd) { P( "create failed %d\n", (int)GetLastError() ); goto done; }
    P( "created hwnd %p flat=%d\n", hwnd, g_flat );

    t0 = GetTickCount64();
    while (GetTickCount64() - t0 < 20000)
    {
        while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE ))
        {
            TranslateMessage( &msg );
            DispatchMessageW( &msg );
        }
        MsgWaitForMultipleObjects( 0, NULL, FALSE, 200, QS_ALLINPUT );
    }
    DestroyWindow( hwnd );
done:
    CloseHandle( g_out );
    return 0;
}
