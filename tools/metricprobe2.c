/* metricprobe2.c — pin the exact term where WM_NCCALCSIZE vertical insets
 * differ from AdjustWindowRectExForDpi(bMenu) + muldiv(4,dpi,96) for Live's
 * main-window style 0x16cf0000 / ex 0x100 with a menu bar.
 *
 * Dumps, per dpi 96/144/192:
 *   - GetSystemMetricsForDpi metrics, SPI_GETNONCLIENTMETRICS(ForDpi) values
 *   - real HFONT text metrics of the caption/menu fonts at that dpi
 *   - AdjustWindowRectExForDpi v/h extras (menu 0 and 1)
 *   - the adjust term sum recomputed by hand from the NCM values
 * and, for a real created window (runs at the prefix system dpi):
 *   - WM_NCCALCSIZE insets, real menu-bar height, window/client rects
 *   - the verdict: NCCALCSIZE_v vs adjust_v(sysdpi) + muldiv(4,sysdpi,96)
 *
 * Run once per prefix LogPixels (96/144/192). Output: metricprobe2.txt in cwd.
 * build: build_metricprobe2.sh
 */
#include <windows.h>

static HANDLE g_out;
static char buf[1024];
static void emit( const char *s ){ DWORD n; WriteFile( g_out, s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    return DefWindowProcW( hwnd, msg, wp, lp );
}

static int muldiv96( int v, UINT dpi ) { return MulDiv( v, dpi, 96 ); }

static void dump_metrics_for_dpi( UINT dpi )
{
    NONCLIENTMETRICSW ncm;
    HDC hdc;
    HFONT hfont, old;
    TEXTMETRICW tm;
    RECT r;
    int adjust, v0, v1, h_extra;

    P( "\n==== dpi %u ====\n", dpi );

    P( "GetSystemMetricsForDpi: CYBORDER %d CYEDGE %d CXSIZEFRAME %d CYSIZEFRAME %d CYCAPTION %d CYMENU %d CYMENUSIZE %d CXPADDEDBORDER %d\n",
       GetSystemMetricsForDpi( SM_CYBORDER, dpi ), GetSystemMetricsForDpi( SM_CYEDGE, dpi ),
       GetSystemMetricsForDpi( SM_CXSIZEFRAME, dpi ), GetSystemMetricsForDpi( SM_CYSIZEFRAME, dpi ),
       GetSystemMetricsForDpi( SM_CYCAPTION, dpi ), GetSystemMetricsForDpi( SM_CYMENU, dpi ),
       GetSystemMetricsForDpi( SM_CYMENUSIZE, dpi ), GetSystemMetricsForDpi( SM_CXPADDEDBORDER, dpi ) );

    ncm.cbSize = sizeof(ncm);
    SystemParametersInfoForDpi( SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0, dpi );
    P( "NCM ForDpi: iBorderWidth %d iPaddedBorderWidth %d iCaptionHeight %d iSmCaptionHeight %d iMenuHeight %d\n",
       (int)ncm.iBorderWidth, (int)ncm.iPaddedBorderWidth, (int)ncm.iCaptionHeight,
       (int)ncm.iSmCaptionHeight, (int)ncm.iMenuHeight );
    P( "NCM fonts: lfCaptionFont '%S' lfHeight %d  lfMenuFont '%S' lfHeight %d\n",
       ncm.lfCaptionFont.lfFaceName, (int)ncm.lfCaptionFont.lfHeight,
       ncm.lfMenuFont.lfFaceName, (int)ncm.lfMenuFont.lfHeight );

    hdc = CreateCompatibleDC( NULL );
    hfont = CreateFontIndirectW( &ncm.lfCaptionFont );
    old = SelectObject( hdc, hfont );
    GetTextMetricsW( hdc, &tm );
    P( "caption HFONT: tmHeight %d tmExternalLeading %d tmInternalLeading %d\n",
       (int)tm.tmHeight, (int)tm.tmExternalLeading, (int)tm.tmInternalLeading );
    SelectObject( hdc, old ); DeleteObject( hfont );
    hfont = CreateFontIndirectW( &ncm.lfMenuFont );
    old = SelectObject( hdc, hfont );
    GetTextMetricsW( hdc, &tm );
    P( "menu    HFONT: tmHeight %d tmExternalLeading %d tmInternalLeading %d\n",
       (int)tm.tmHeight, (int)tm.tmExternalLeading, (int)tm.tmInternalLeading );
    {
        RECT trc = {0,0,0,0};
        int th = DrawTextW( hdc, L"File", -1, &trc, DT_SINGLELINE | DT_CALCRECT );
        P( "menu text 'File' DrawText height %d (floor would be CYMENU %d + muldiv(4) %d - 1 = %d)\n",
           th, GetSystemMetricsForDpi( SM_CYMENU, dpi ), muldiv96( 4, dpi ),
           GetSystemMetricsForDpi( SM_CYMENU, dpi ) + muldiv96( 4, dpi ) - 1 );
    }
    SelectObject( hdc, old ); DeleteObject( hfont );
    DeleteDC( hdc );

    /* adjust_window_rect term recomputation (defwnd.c:254):
       adjust = 2 (thickframe outer) + iBorderWidth + iPaddedBorderWidth + 1 (border) */
    adjust = 3 + ncm.iBorderWidth + ncm.iPaddedBorderWidth;
    P( "hand terms: adjust(h) %d  caption %d  menu %d  -> adjust_v(menu=0) %d  adjust_v(menu=1) %d  model(+muldiv4) %d\n",
       adjust, (int)ncm.iCaptionHeight + 1, (int)ncm.iMenuHeight + 1,
       2 * adjust + (int)ncm.iCaptionHeight + 1,
       2 * adjust + (int)ncm.iCaptionHeight + 1 + (int)ncm.iMenuHeight + 1,
       2 * adjust + (int)ncm.iCaptionHeight + 1 + (int)ncm.iMenuHeight + 1 + muldiv96( 4, dpi ) );

    SetRect( &r, 0, 0, 1000, 500 );
    AdjustWindowRectExForDpi( &r, 0x16cf0000, FALSE, 0x100, dpi );
    v0 = r.bottom - r.top - 500; h_extra = r.right - r.left - 1000;
    SetRect( &r, 0, 0, 1000, 500 );
    AdjustWindowRectExForDpi( &r, 0x16cf0000, TRUE, 0x100, dpi );
    v1 = r.bottom - r.top - 500;
    P( "AdjustWindowRectExForDpi: menu=0 v %d h %d ; menu=1 v %d h %d ; menu=1 + muldiv(4,dpi,96) = %d\n",
       v0, h_extra, v1, r.right - r.left - 1000, v1 + muldiv96( 4, dpi ) );
}

int mainCRTStartup( void )
{
    static const DWORD style = 0x06cf0000;   /* live's 0x16cf0000 minus WS_VISIBLE */
    static const DWORD ex_style = 0x100;     /* WS_EX_WINDOWEDGE */
    WNDCLASSW wc = {0};
    HMENU menu;
    HWND hwnd;
    RECT r, wr, cr;
    MENUBARINFO mbi;
    UINT sysdpi, windpi;
    int nc_v, nc_h, adjust_v1;

    g_out = CreateFileA( "metricprobe2.txt", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );

    SetProcessDpiAwarenessContext( DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 );

    sysdpi = GetDpiForSystem();
    P( "system dpi %d  thread ctx %p\n", sysdpi, GetThreadDpiAwarenessContext() );
    P( "plain GetSystemMetrics: CYBORDER %d CYEDGE %d CYSIZEFRAME %d CYCAPTION %d CYMENU %d CXPADDEDBORDER %d\n",
       GetSystemMetrics( SM_CYBORDER ), GetSystemMetrics( SM_CYEDGE ),
       GetSystemMetrics( SM_CYSIZEFRAME ), GetSystemMetrics( SM_CYCAPTION ),
       GetSystemMetrics( SM_CYMENU ), GetSystemMetrics( SM_CXPADDEDBORDER ) );

    dump_metrics_for_dpi( 96 );
    dump_metrics_for_dpi( 144 );
    dump_metrics_for_dpi( 192 );

    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW( NULL );
    wc.lpszClassName = L"MetricProbe2Class";
    RegisterClassW( &wc );

    menu = CreateMenu();
    AppendMenuW( menu, MF_STRING, 1, L"File" );
    AppendMenuW( menu, MF_STRING, 2, L"Edit" );
    AppendMenuW( menu, MF_STRING, 3, L"Create" );
    AppendMenuW( menu, MF_STRING, 4, L"View" );
    AppendMenuW( menu, MF_STRING, 5, L"Options" );
    AppendMenuW( menu, MF_STRING, 6, L"Help" );

    hwnd = CreateWindowExW( ex_style, wc.lpszClassName, L"metricprobe2",
                            style, 100, 100, 1000, 500, NULL, menu,
                            wc.hInstance, NULL );
    if (!hwnd) { P( "CreateWindowExW failed %d\n", (int)GetLastError() ); goto done; }

    windpi = GetDpiForWindow( hwnd );
    GetWindowRect( hwnd, &wr );
    GetClientRect( hwnd, &cr );
    nc_v = (wr.bottom - wr.top) - cr.bottom;
    nc_h = (wr.right - wr.left) - cr.right;

    P( "\n==== real window at window dpi %u (system %u) ====\n", windpi, sysdpi );
    P( "outer %dx%d client %dx%d -> NC v %d h %d\n",
       (int)(wr.right - wr.left), (int)(wr.bottom - wr.top),
       (int)cr.right, (int)cr.bottom, nc_v, nc_h );

    r = wr;  /* WM_NCCALCSIZE wparam=FALSE: in window rect (screen), out client rect */
    SendMessageW( hwnd, WM_NCCALCSIZE, FALSE, (LPARAM)&r );
    P( "WM_NCCALCSIZE insets: left %d top %d right %d bottom %d -> NC v %d h %d\n",
       (int)(r.left - wr.left), (int)(r.top - wr.top),
       (int)(wr.right - r.right), (int)(wr.bottom - r.bottom),
       (int)((wr.bottom - wr.top) - (r.bottom - r.top)),
       (int)((wr.right - wr.left) - (r.right - r.left)) );

    mbi.cbSize = sizeof(mbi);
    if (GetMenuBarInfo( hwnd, OBJID_MENU, 0, &mbi ))
        P( "menu bar rect height %d (top %d bottom %d)\n",
           (int)(mbi.rcBar.bottom - mbi.rcBar.top), (int)mbi.rcBar.top, (int)mbi.rcBar.bottom );

    SetRect( &r, 0, 0, 1000, 500 );
    AdjustWindowRectExForDpi( &r, 0x16cf0000, TRUE, 0x100, windpi );
    adjust_v1 = r.bottom - r.top - 500;
    P( "VERDICT @%u: NCCALCSIZE_v %d  adjust_v(menu=1) %d  adjust+muldiv(4) %d  delta %d  (band implied %d vs CYMENU+muldiv %d)\n",
       windpi, nc_v, adjust_v1, adjust_v1 + muldiv96( 4, windpi ),
       nc_v - ( adjust_v1 + muldiv96( 4, windpi ) ),
       nc_v - ( adjust_v1 - GetSystemMetricsForDpi( SM_CYMENU, windpi ) ),
       GetSystemMetricsForDpi( SM_CYMENU, windpi ) + muldiv96( 4, windpi ) );

    /* round trip: client + adjust + muldiv vs actual outer, what Live's handler does */
    SetRect( &r, 0, 0, cr.right, cr.bottom );
    AdjustWindowRectExForDpi( &r, 0x16cf0000, TRUE, 0x100, windpi );
    P( "round trip: client+adjust = %dx%d, +muldiv4 vertical = %d (actual outer %dx%d, drift %+d)\n",
       (int)(r.right - r.left), (int)(r.bottom - r.top),
       (int)(r.bottom - r.top) + muldiv96( 4, windpi ),
       (int)(wr.right - wr.left), (int)(wr.bottom - wr.top),
       (int)((r.bottom - r.top) + muldiv96( 4, windpi ) - (wr.bottom - wr.top)) );

    DestroyWindow( hwnd );
done:
    CloseHandle( g_out );
    return 0;
}
