/* updateprobe.c: pin GetUpdateRect's empty-rectangle behavior (PE, CRT-free).
 *
 * Regression probe for the known-clean GetUpdateRect fast path
 * (patches/performance/0005, WINE_MSG_FASTPATH). With no update region the
 * call returns FALSE and EMPTIES the caller's rectangle: the server path
 * zeroes it (NtGdiGetRgnBox writes the empty extents before returning
 * NULLREGION for the empty region), and Windows documents the same for
 * GetUpdateRect. A poisoned RECT must therefore come back {0,0,0,0}.
 *
 * This probe MUST PASS on the unpatched build, and on the patched build
 * with the fast path on and off.
 *
 * output: updateprobe.txt in cwd (also mirrored to stdout), "PASS"/"FAIL"
 * lines + SUMMARY. exit code: number of failed assertions (0 = pass).
 *
 * build: build_updateprobe.sh (this dir), then run inside the Ableton prefix:
 *   tools/run_in_prefix.sh updateprobe.exe
 */
#include <windows.h>

static HANDLE g_out, g_con;
static char   buf[512];
static int    g_pass, g_fail;

static void emit( const char *s )
{
    DWORD n;
    if (g_out) WriteFile( g_out, s, lstrlenA(s), &n, NULL );
    if (g_con) WriteFile( g_con, s, lstrlenA(s), &n, NULL );
}
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)
#define CHECK(cond, name) do { if (cond) { g_pass++; P( "PASS %s\n", name ); } \
                               else { g_fail++; P( "FAIL %s (line %d, lasterr %u)\n", name, __LINE__, (UINT)GetLastError() ); } } while (0)

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_PAINT)
    {
        PAINTSTRUCT ps;
        BeginPaint( hwnd, &ps );
        EndPaint( hwnd, &ps );
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

void mainCRTStartup( void )
{
    WNDCLASSA wc;
    HWND hwnd;
    RECT r;
    MSG msg;
    BOOL ret;

    g_out = CreateFileA( "updateprobe.txt", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    if (g_out == INVALID_HANDLE_VALUE) g_out = NULL;
    g_con = GetStdHandle( STD_OUTPUT_HANDLE );
    if (g_con == INVALID_HANDLE_VALUE) g_con = NULL;

    P( "updateprobe: GetUpdateRect empties the rectangle when nothing needs painting\n" );

    ZeroMemory( &wc, sizeof wc );
    wc.lpfnWndProc   = wndproc;
    wc.hInstance     = GetModuleHandleA( NULL );
    wc.lpszClassName = "updateprobe";
    if (!RegisterClassA( &wc ) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    {
        g_fail++;
        P( "FAIL setup: RegisterClassA failed (lasterr %u)\n", (UINT)GetLastError() );
        goto done;
    }
    hwnd = CreateWindowExA( 0, "updateprobe", "updateprobe", WS_OVERLAPPEDWINDOW,
                            0, 0, 200, 200, NULL, NULL, wc.hInstance, NULL );
    if (!hwnd)
    {
        g_fail++;
        P( "FAIL setup: CreateWindowExA failed (lasterr %u)\n", (UINT)GetLastError() );
        goto done;
    }
    ShowWindow( hwnd, SW_SHOW );
    UpdateWindow( hwnd );  /* paints once; leaves no update region behind */
    while (PeekMessageA( &msg, hwnd, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );

    r.left = 5; r.top = 6; r.right = 7; r.bottom = 8;  /* poison */
    ret = GetUpdateRect( hwnd, &r, FALSE );
    P( "info clean-window ret=%d rect=%ld,%ld,%ld,%ld\n",
       ret, r.left, r.top, r.right, r.bottom );
    CHECK( ret == FALSE, "clean-window-returns-false" );
    CHECK( r.left == 0 && r.top == 0 && r.right == 0 && r.bottom == 0,
           "clean-window-empties-rect" );

    ret = GetUpdateRect( hwnd, NULL, FALSE );
    CHECK( ret == FALSE, "clean-window-null-rect-returns-false" );

    DestroyWindow( hwnd );
done:
    P( "SUMMARY pass=%d fail=%d\n", g_pass, g_fail );
    if (g_out) CloseHandle( g_out );
    ExitProcess( g_fail );
}
