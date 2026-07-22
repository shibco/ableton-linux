/* dcompspy.c — find every window carrying Wine-dcomp presentation state (PE, CRT-free).
 *
 * The patched dcomp/dxgi leave window properties on the windows they manage:
 *   __wine_dcomp_target / __wine_dcomp_origproc   (dcomp.dll Phase-5 target subclass)
 *   __wine_dcomp_orig_wndproc / __wine_dcomp_comp_dc / __wine_dcomp_comp_size /
 *   __wine_dcomp_swapchain / __wine_dcomp_parent_clip   (dxgi presentation subclass)
 *   __wine_dcomp_active + __wine_dcomp_wnd_* on the desktop window
 * Walking all windows and dumping these tells us which HWNDs are composition
 * targets and which carry a reblit comp buffer — without touching Live.
 *
 * output: dcompspy.txt in cwd.  build: same recipe as hwndspy.exe
 */
#include <windows.h>

static HANDLE g_out;
static char buf[1024];
static void emit( const char *s ){ DWORD n; WriteFile( g_out, s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

static void check( HWND hwnd, int depth )
{
    HANDLE target = GetPropW( hwnd, L"__wine_dcomp_target" );
    HANDLE origproc = GetPropW( hwnd, L"__wine_dcomp_origproc" );
    HANDLE owndproc = GetPropW( hwnd, L"__wine_dcomp_orig_wndproc" );
    HANDLE comp_dc = GetPropW( hwnd, L"__wine_dcomp_comp_dc" );
    HANDLE comp_size = GetPropW( hwnd, L"__wine_dcomp_comp_size" );
    HANDLE swapchain = GetPropW( hwnd, L"__wine_dcomp_swapchain" );
    HWND child;

    if (target || origproc || owndproc || comp_dc || comp_size || swapchain)
    {
        char cls[128] = "", title[128] = "";
        RECT r = {0};
        DWORD pid = 0;
        LONG style, ex;

        GetClassNameA( hwnd, cls, sizeof(cls) );
        GetWindowTextA( hwnd, title, sizeof(title) );
        GetWindowRect( hwnd, &r );
        GetWindowThreadProcessId( hwnd, &pid );
        style = GetWindowLongA( hwnd, GWL_STYLE );
        ex = GetWindowLongA( hwnd, GWL_EXSTYLE );

        P( "%p pid=%u cls=\"%s\" title=\"%s\" rect=(%d,%d)-(%d,%d) style=%08x ex=%08x\r\n",
           hwnd, (unsigned)pid, cls, title,
           (int)r.left, (int)r.top, (int)r.right, (int)r.bottom,
           (unsigned)style, (unsigned)ex );
        P( "    target=%p origproc=%p orig_wndproc=%p comp_dc=%p comp_size=%p (%ux%u) swapchain=%p\r\n",
           target, origproc, owndproc, comp_dc, comp_size,
           comp_size ? (unsigned)LOWORD((LPARAM)comp_size) : 0,
           comp_size ? (unsigned)HIWORD((LPARAM)comp_size) : 0,
           swapchain );
        {
            COLORREF key = 0; BYTE alpha = 0; DWORD lwa = 0;
            if (GetLayeredWindowAttributes( hwnd, &key, &alpha, &lwa ))
                P( "    layered attrs: colorkey=%08x alpha=%u flags=%08x\r\n",
                   (unsigned)key, (unsigned)alpha, (unsigned)lwa );
        }
    }

    for (child = GetWindow( hwnd, GW_CHILD ); child; child = GetWindow( child, GW_HWNDNEXT ))
        check( child, depth + 1 );
}

static BOOL CALLBACK top_cb( HWND hwnd, LPARAM lp )
{
    check( hwnd, 0 );
    return TRUE;
}

static BOOL CALLBACK desk_prop_cb( HWND hwnd, LPWSTR name, HANDLE value, ULONG_PTR lp )
{
    /* Atom-only names come back as integer atoms (< 0x10000) — skip those. */
    if (!((ULONG_PTR)name >> 16)) return TRUE;
    if (name[0] == '_' && name[1] == '_' && name[2] == 'w')
    {
        char narrow[128];
        WideCharToMultiByte( CP_ACP, 0, name, -1, narrow, sizeof(narrow), NULL, NULL );
        P( "desktop prop: %s = %p\r\n", narrow, value );
    }
    return TRUE;
}

int mainCRTStartup( void )
{
    HWND msg_child;

    g_out = CreateFileA( "dcompspy.txt", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                         CREATE_ALWAYS, 0, NULL );

    emit( "=== desktop window props ===\r\n" );
    EnumPropsExW( GetDesktopWindow(), desk_prop_cb, 0 );

    emit( "=== windows with dcomp props ===\r\n" );
    EnumWindows( top_cb, 0 );

    /* message-only windows */
    emit( "=== message-only windows ===\r\n" );
    for (msg_child = FindWindowExW( HWND_MESSAGE, NULL, NULL, NULL ); msg_child;
         msg_child = FindWindowExW( HWND_MESSAGE, msg_child, NULL, NULL ))
        check( msg_child, 0 );

    CloseHandle( g_out );
    return 0;
}
