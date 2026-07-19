/* setsyscolors.c — apply win32 system colors from the command line, for the
 * launcher's unified-top-bar watcher (issue #32). SetSysColors persists the
 * entries to the registry AND broadcasts WM_SYSCOLORCHANGE with a full redraw,
 * so a RUNNING Live repaints with the new colors — a plain registry write only
 * reaches processes started afterwards, which is why this must run in-prefix.
 * usage:  setsyscolors.exe Name=R,G,B [Name=R,G,B ...]
 * Names mirror the [Control Panel\Colors] value names the launcher syncs.
 * build:  tools/build_setsyscolors.sh (real PE via clang, wine headers, no CRT) */
#include <windows.h>

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#endif

static const struct { const char *name; int index; } color_map[] = {
    { "MenuBar",             COLOR_MENUBAR },
    { "Menu",                COLOR_MENU },
    { "MenuText",            COLOR_MENUTEXT },
    { "MenuHilight",         COLOR_MENUHILIGHT },
    { "Hilight",             COLOR_HIGHLIGHT },
    { "HilightText",         COLOR_HIGHLIGHTTEXT },
    { "ActiveTitle",         COLOR_ACTIVECAPTION },
    { "GradientActiveTitle", COLOR_GRADIENTACTIVECAPTION },
    { "TitleText",           COLOR_CAPTIONTEXT },
    { "ButtonFace",          COLOR_BTNFACE },
    { "ButtonText",          COLOR_BTNTEXT },
};

/* no CRT: the few string helpers needed, spelled out */
static int name_matches( const char *name, const char *tok, int len )
{
    int i;
    for (i = 0; i < len; i++)
        if (!name[i] || name[i] != tok[i]) return 0;
    return !name[i];
}

static int parse_byte( const char **p, int *out )   /* 0-255, advances *p */
{
    int v = 0, digits = 0;
    while (**p >= '0' && **p <= '9')
    {
        v = v * 10 + (**p - '0');
        if (v > 255) return 0;
        (*p)++; digits++;
    }
    if (!digits) return 0;
    *out = v;
    return 1;
}

int mainCRTStartup( void )
{
    INT idx[ARRAY_SIZE(color_map)];
    COLORREF val[ARRAY_SIZE(color_map)];
    int n = 0;
    const char *p = GetCommandLineA();

    /* skip the (possibly quoted) program token */
    if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; }
    else while (*p && *p != ' ') p++;

    while (*p)
    {
        const char *tok;
        int len, i, r, g, b;

        while (*p == ' ') p++;
        if (!*p) break;
        tok = p;
        while (*p && *p != '=' && *p != ' ') p++;
        if (*p != '=') return 1;
        len = (int)(p - tok);
        p++;
        if (!parse_byte( &p, &r ) || *p++ != ',' ||
            !parse_byte( &p, &g ) || *p++ != ',' ||
            !parse_byte( &p, &b )) return 1;
        if (*p && *p != ' ') return 1;

        for (i = 0; i < ARRAY_SIZE(color_map); i++)
            if (name_matches( color_map[i].name, tok, len )) break;
        if (i == ARRAY_SIZE(color_map)) return 1;   /* unknown name: refuse the lot */
        if (n < ARRAY_SIZE(color_map))
        {
            idx[n] = color_map[i].index;
            val[n] = RGB( r, g, b );
            n++;
        }
    }

    if (!n) return 1;
    return SetSysColors( n, idx, val ) ? 0 : 2;
}
