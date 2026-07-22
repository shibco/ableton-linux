/* xdrag.c — synthetic button-1 drag via XTest (for interactive-style move/resize tests).
 * usage: xdrag x1 y1 x2 y2 steps
 * build: gcc -O2 -o xdrag xdrag.c -lX11 -lXtst
 */
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main( int argc, char **argv )
{
    Display *dpy;
    int x1, y1, x2, y2, steps, i;

    if (argc != 6) { fprintf( stderr, "usage: xdrag x1 y1 x2 y2 steps\n" ); return 1; }
    x1 = atoi( argv[1] ); y1 = atoi( argv[2] );
    x2 = atoi( argv[3] ); y2 = atoi( argv[4] );
    steps = atoi( argv[5] );
    if (!(dpy = XOpenDisplay( NULL ))) { fprintf( stderr, "no display\n" ); return 1; }

    XTestFakeMotionEvent( dpy, -1, x1, y1, 0 );
    XFlush( dpy ); usleep( 100000 );
    XTestFakeButtonEvent( dpy, 1, True, 0 );
    XFlush( dpy ); usleep( 100000 );
    for (i = 1; i <= steps; i++)
    {
        XTestFakeMotionEvent( dpy, -1, x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps, 0 );
        XFlush( dpy ); usleep( 60000 );
    }
    usleep( 150000 );
    XTestFakeButtonEvent( dpy, 1, False, 0 );
    XFlush( dpy );
    XCloseDisplay( dpy );
    return 0;
}
