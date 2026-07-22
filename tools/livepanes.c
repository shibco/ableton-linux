/* livepanes: list Live's main window, WebView2 panes and menu popups with
 * class and rect from a sibling Wine process, or watch the lesson pane
 * rect change.
 * usage: livepanes.exe windows
 *        livepanes.exe watch SECONDS
 * build: build_learnheal.sh recipe. */
#include <windows.h>

static char buf[512];
static void emit( const char *s ){ DWORD n; WriteFile( GetStdHandle(STD_OUTPUT_HANDLE), s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

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

static int interesting( const char *cls, const char *title )
{
    if (find_sub( title, "Ableton Live" )) return 1;
    if (find_sub( cls, "Chrome_WidgetWin" )) return 1;
    if (find_sub( cls, "32768" )) return 1;
    if (find_sub( title, "Learn View" )) return 1;
    return 0;
}

static void describe( HWND hwnd, int depth )
{
    char cls[128], title[160];
    RECT r;
    HWND child;

    cls[0] = title[0] = 0;
    GetClassNameA( hwnd, cls, sizeof(cls) );
    GetWindowTextA( hwnd, title, sizeof(title) );
    GetWindowRect( hwnd, &r );
    if (interesting( cls, title ))
        P( "%d %p cls=\"%s\" title=\"%s\" rect=(%d,%d)-(%d,%d) %s\n", depth, hwnd, cls, title,
           (int)r.left, (int)r.top, (int)r.right, (int)r.bottom,
           IsWindowVisible( hwnd ) ? "vis" : "hid" );
    for (child = GetWindow( hwnd, GW_CHILD ); child; child = GetWindow( child, GW_HWNDNEXT ))
        describe( child, depth + 1 );
}

static BOOL CALLBACK list_cb( HWND hwnd, LPARAM l ) { describe( hwnd, 0 ); return TRUE; }

static HWND watch_pane;
static BOOL CALLBACK find_pane_cb( HWND hwnd, LPARAM l )
{
    char cls[128], title[160];
    HWND child;
    cls[0] = title[0] = 0;
    GetClassNameA( hwnd, cls, sizeof(cls) );
    GetWindowTextA( hwnd, title, sizeof(title) );
    if (find_sub( cls, "Chrome_WidgetWin_1" ) && find_sub( title, "Learn View" ))
    {
        watch_pane = hwnd;
        return FALSE;
    }
    for (child = GetWindow( hwnd, GW_CHILD ); child; child = GetWindow( child, GW_HWNDNEXT ))
        if (!find_pane_cb( child, 0 )) return FALSE;
    return TRUE;
}

int mainCRTStartup(void)
{
    char *cmd = GetCommandLineA();
    if (*cmd == '"') { cmd++; while (*cmd && *cmd != '"') cmd++; if (*cmd) cmd++; }
    else while (*cmd && *cmd != ' ') cmd++;
    while (*cmd == ' ') cmd++;

    if (find_sub( cmd, "watch" ))
    {
        int secs = 20, i;
        RECT last = {0};
        const char *sp = find_sub( cmd, " " );
        if (sp)
        {
            secs = 0;
            sp++;
            while (*sp >= '0' && *sp <= '9') secs = secs * 10 + (*sp++ - '0');
            if (!secs) secs = 20;
        }
        for (i = 0; i < secs * 4; i++)
        {
            watch_pane = 0;
            EnumWindows( find_pane_cb, 0 );
            if (watch_pane)
            {
                RECT r; GetWindowRect( watch_pane, &r );
                if (!EqualRect( &r, &last ))
                {
                    P( "t+%dms pane %p rect=(%d,%d)-(%d,%d) %dx%d\n", i * 250, watch_pane,
                       (int)r.left, (int)r.top, (int)r.right, (int)r.bottom,
                       (int)(r.right - r.left), (int)(r.bottom - r.top) );
                    last = r;
                }
            }
            Sleep( 250 );
        }
        return 0;
    }

    EnumWindows( list_cb, 0 );
    return 0;
}
