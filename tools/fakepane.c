/* fakepane: hidden Chrome_WidgetWin_1 "Learn View 12" stand-in for
 * validating learnheal's gating.  Logs every WM_WINDOWPOSCHANGED with a
 * timestamp, exits after 35 s.  build: build_learnheal.sh recipe. */
#include <windows.h>

static char buf[512];
static void emit( const char *s ){ DWORD n; WriteFile( GetStdHandle(STD_OUTPUT_HANDLE), s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

static DWORD t0;

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_WINDOWPOSCHANGED)
    {
        RECT r; GetWindowRect( hwnd, &r );
        P( "fakepane: t+%lums size %dx%d\n", GetTickCount() - t0,
           (int)(r.right - r.left), (int)(r.bottom - r.top) );
    }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

int mainCRTStartup(void)
{
    WNDCLASSA wc = {0};
    HWND hwnd;
    MSG msg;
    DWORD start;

    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA( NULL );
    wc.lpszClassName = "Chrome_WidgetWin_1";
    RegisterClassA( &wc );
    t0 = start = GetTickCount();
    hwnd = CreateWindowExA( 0, "Chrome_WidgetWin_1", "Learn View 12", WS_POPUP,
                            100, 100, 400, 400, 0, 0, wc.hInstance, 0 );
    P( "fakepane: created %p (hidden)\n", hwnd );
    while (GetTickCount() - start < 35000)
    {
        while (PeekMessageA( &msg, 0, 0, 0, PM_REMOVE )) DispatchMessageA( &msg );
        Sleep( 50 );
    }
    P( "fakepane: done\n" );
    return 0;
}
