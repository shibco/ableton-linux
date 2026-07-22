/* showexp: mimic Live's "Show in Explorer" call exactly, for verifying the
 * explorer /select -> XDG OpenURI portal routing (Wine patch 0043, issue 41).
 * Live imports ShellExecute(Ex)W and runs explorer.exe /select,"<path>".
 * usage: showexp.exe WINPATH        (ShellExecuteExW, like Live)
 *        showexp.exe --plain WINPATH  (ShellExecuteW variant)
 * build: build_learnheal.sh recipe + -lshell32. */
#include <windows.h>
#include <shellapi.h>

static char buf[1024];
static void emit( const char *s ){ DWORD n; WriteFile( GetStdHandle(STD_OUTPUT_HANDLE), s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

int mainCRTStartup(void)
{
    WCHAR *cmd = GetCommandLineW();
    WCHAR params[600];
    const WCHAR *path;
    BOOL plain = FALSE;
    int i;

    /* skip argv[0] (possibly quoted) */
    if (*cmd == '"') { cmd++; while (*cmd && *cmd != '"') cmd++; if (*cmd) cmd++; }
    else while (*cmd && *cmd != ' ') cmd++;
    while (*cmd == ' ') cmd++;

    if (!wcsncmp( cmd, L"--plain ", 8 )) { plain = TRUE; cmd += 8; while (*cmd == ' ') cmd++; }
    if (!*cmd) { emit( "usage: showexp.exe [--plain] WINPATH\n" ); return 1; }
    path = cmd;

    wsprintfW( params, L"/select,\"%s\"", path );
    P( "file: explorer.exe\nparams: " );
    for (i = 0; params[i] && i < 500; i++) buf[i] = (char)params[i];
    buf[i] = '\n'; buf[i + 1] = 0; emit( buf );

    if (plain)
    {
        HINSTANCE ret = ShellExecuteW( NULL, NULL, L"explorer.exe", params, NULL, SW_SHOWNORMAL );
        P( "ShellExecuteW -> %d (>32 is success)\n", (int)(UINT_PTR)ret );
        return (UINT_PTR)ret > 32 ? 0 : 1;
    }
    else
    {
        SHELLEXECUTEINFOW sei;
        memset( &sei, 0, sizeof(sei) );
        sei.cbSize = sizeof(sei);
        sei.lpFile = L"explorer.exe";
        sei.lpParameters = params;
        sei.nShow = SW_SHOWNORMAL;
        if (ShellExecuteExW( &sei ))
        {
            P( "ShellExecuteExW -> TRUE, hInstApp=%d\n", (int)(UINT_PTR)sei.hInstApp );
            return 0;
        }
        P( "ShellExecuteExW -> FALSE, hInstApp=%d err=%u\n", (int)(UINT_PTR)sei.hInstApp, (unsigned)GetLastError() );
        return 1;
    }
}
