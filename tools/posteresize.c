/* posteresize — programmatic splitter-nudge: resize the WebView widget
 * window (Chrome_WidgetWin_1 "Learn View 12") by +1px and back, forcing
 * Chromium to re-layout and re-render the pane. */
#include <windows.h>

static char buf[512];
static void emit(const char *s){ DWORD n; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, lstrlenA(s), &n, NULL); }
#define P(...) do { wsprintfA(buf, __VA_ARGS__); emit(buf); } while (0)

static void poke(HWND hwnd, const char *what)
{
    RECT r; GetWindowRect(hwnd, &r);
    int w = r.right - r.left, h = r.bottom - r.top;
    P("%s %p %dx%d -> +1 and back\n", what, hwnd, w, h);
    SetWindowPos(hwnd, 0, 0, 0, w + 1, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    Sleep(600);
    SetWindowPos(hwnd, 0, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

static void scan(HWND hwnd)
{
    char cls[128], title[128]; HWND child;
    if (GetClassNameA(hwnd, cls, sizeof(cls)))
    {
        GetWindowTextA(hwnd, title, sizeof(title));
        if (!lstrcmpA(cls, "Chrome_WidgetWin_1") && !lstrcmpA(title, "Learn View 12"))
            poke(hwnd, "widgetwin1");
    }
    for (child = GetWindow(hwnd, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) scan(child);
}
static BOOL CALLBACK t1(HWND h, LPARAM l){ scan(h); return TRUE; }
int mainCRTStartup(void){ EnumWindows(t1, 0); return 0; }
