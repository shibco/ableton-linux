/* menucmd: find a menu item by substring in Live's main-window menu and
 * post its WM_COMMAND.  Limitation: menu items cannot be read from another
 * process in this Wine (GetMenuItemCount returns -1), so matching only
 * works in-process; kept as a probe.
 * usage: menucmd.exe SUBSTRING   (unquoted; rest of command line)
 *        menucmd.exe --dump
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

static const char *needle;
static HWND target;
static UINT found_id;

static void walk_menu( HMENU menu, int depth )
{
    int i, n = GetMenuItemCount( menu );
    char text[256];

    for (i = 0; i < n && !found_id; i++)
    {
        HMENU sub = GetSubMenu( menu, i );
        text[0] = 0;
        GetMenuStringA( menu, i, text, sizeof(text), MF_BYPOSITION );
        if (needle[0] == '-' && text[0]) P( "menu[%d] \"%s\" id %u %s\n", depth, text,
                                           GetMenuItemID( menu, i ), sub ? "(sub)" : "" );
        if (needle[0] != '-' && text[0] && find_sub( text, needle ))
        {
            UINT id = GetMenuItemID( menu, i );
            P( "menucmd: match \"%s\" id %u depth %d\n", text, id, depth );
            if (id != (UINT)-1) { found_id = id; return; }
        }
        if (sub) walk_menu( sub, depth + 1 );
    }
}

static BOOL CALLBACK top( HWND hwnd, LPARAM l )
{
    char title[256];
    HMENU menu;

    title[0] = 0;
    GetWindowTextA( hwnd, title, sizeof(title) );
    if (!title[0] || !find_sub( title, "Ableton Live" )) return TRUE;
    menu = GetMenu( hwnd );
    P( "menucmd: window %p \"%s\" menu %p items %d\n", hwnd, title, menu,
       menu ? GetMenuItemCount( menu ) : -1 );
    if (!menu) return TRUE;
    target = hwnd;
    walk_menu( menu, 0 );
    return !found_id;
}

int mainCRTStartup(void)
{
    char *cmd = GetCommandLineA();
    /* skip argv[0] (possibly quoted) */
    if (*cmd == '"') { cmd++; while (*cmd && *cmd != '"') cmd++; if (*cmd) cmd++; }
    else while (*cmd && *cmd != ' ') cmd++;
    while (*cmd == ' ') cmd++;
    if (!*cmd) { P( "usage: menucmd.exe SUBSTRING\n" ); return 1; }
    needle = cmd;

    EnumWindows( top, 0 );
    if (!found_id || !target) { P( "menucmd: no match for \"%s\"\n", needle ); return 1; }
    PostMessageA( target, WM_COMMAND, found_id, 0 );
    P( "menucmd: posted WM_COMMAND %u to %p\n", found_id, target );
    return 0;
}
