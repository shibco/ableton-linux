/* learnheal: resident auto-heal for the Learn View stale first layout
 * (notes/ABLETON-WINE-LEARNVIEW-FLICKER.md).  Chromium lays the pane out
 * once at a transient creation size and does not re-render until the
 * widget is resized; a 1px resize and back of the Chrome_WidgetWin_1
 * widget (posteresize.c) forces the re-layout.  Nudging at bind time
 * leaves Chromium unable to handle later resizes, so a pane must hold a
 * stable rect across scans first and is nudged once; a material size
 * change re-arms one nudge.  Exits after Live has been gone for 60 s.
 * build: tools/build_learnheal.sh; install: ~/.local/share/ableton-wine/ */
#include <windows.h>

#define MAX_TRACK 32

struct entry
{
    HWND hwnd;
    RECT rect;
    int stable;   /* consecutive scans with an unchanged rect */
    int poked;
};

static struct entry tracked[MAX_TRACK];
static int live_seen;      /* a window titled like Live exists this scan */
static int live_gone_scans;

static char buf[512];
static void emit( const char *s ){ DWORD n; WriteFile( GetStdHandle(STD_OUTPUT_HANDLE), s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

/* no CRT under -nostdlib */
static const char *find_sub( const char *s, const char *sub )
{
    int i, j;
    for (i = 0; s[i]; i++)
    {
        for (j = 0; sub[j] && s[i + j] == sub[j]; j++) ;
        if (!sub[j]) return s + i;
    }
    return 0;
}

static void poke( HWND hwnd )
{
    RECT r; GetWindowRect( hwnd, &r );
    int w = r.right - r.left, h = r.bottom - r.top;
    P( "learnheal: poking %p %dx%d\n", hwnd, w, h );
    SetWindowPos( hwnd, 0, 0, 0, w + 1, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE );
    Sleep( 600 );
    SetWindowPos( hwnd, 0, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE );
}

static struct entry *track( HWND hwnd )
{
    int i, free_slot = -1;
    for (i = 0; i < MAX_TRACK; i++)
    {
        if (tracked[i].hwnd == hwnd) return &tracked[i];
        if (!tracked[i].hwnd && free_slot < 0) free_slot = i;
    }
    if (free_slot < 0) return NULL;
    tracked[free_slot].hwnd = hwnd;
    SetRectEmpty( &tracked[free_slot].rect );
    tracked[free_slot].stable = 0;
    tracked[free_slot].poked = 0;
    return &tracked[free_slot];
}

static void consider( HWND hwnd )
{
    struct entry *e;
    RECT r;

    if (!(e = track( hwnd ))) return;
    GetWindowRect( hwnd, &r );
    if (EqualRect( &r, &e->rect )) e->stable++;
    else
    {
        /* A material size change after a nudge means a new layout; re-arm once. */
        int dw = (r.right - r.left) - (e->rect.right - e->rect.left);
        int dh = (r.bottom - r.top) - (e->rect.bottom - e->rect.top);
        if (dw < 0) dw = -dw;
        if (dh < 0) dh = -dh;
        if (e->poked && dw + dh > 4) e->poked = 0;
        e->rect = r;
        e->stable = 0;
    }
    if (!e->poked && e->stable >= 2)
    {
        poke( hwnd );
        GetWindowRect( hwnd, &e->rect );
        e->stable = 0;
        e->poked = 1;
    }
}

static void scan( HWND hwnd )
{
    char cls[128], title[160];
    HWND child;

    if (GetClassNameA( hwnd, cls, sizeof(cls) ))
    {
        title[0] = 0;
        GetWindowTextA( hwnd, title, sizeof(title) );
        if (title[0] && find_sub( title, "Ableton Live" )) live_seen = 1;
        if (!lstrcmpA( cls, "Chrome_WidgetWin_1" ) && title[0])
        {
            RECT r; GetWindowRect( hwnd, &r );
            /* skip tooltips/popups; the lesson pane and doc sidebar are big */
            if (r.right - r.left >= 200 && r.bottom - r.top >= 200) consider( hwnd );
        }
    }
    for (child = GetWindow( hwnd, GW_CHILD ); child; child = GetWindow( child, GW_HWNDNEXT )) scan( child );
}

static BOOL CALLBACK top( HWND h, LPARAM l ){ scan( h ); return TRUE; }

int mainCRTStartup(void)
{
    int i;
    for (;;)
    {
        live_seen = 0;
        EnumWindows( top, 0 );
        for (i = 0; i < MAX_TRACK; i++)
            if (tracked[i].hwnd && !IsWindow( tracked[i].hwnd )) tracked[i].hwnd = 0;
        if (live_seen) live_gone_scans = 0;
        else if (++live_gone_scans >= 60) break;
        Sleep( 1000 );
    }
    return 0;
}
