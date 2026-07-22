/* xclose.c — ask the WM to close a window gracefully (_NET_CLOSE_WINDOW).
 * usage: xclose 0xWINDOWID
 * build: gcc -O2 -o xclose xclose.c -lX11
 */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>

int main( int argc, char **argv )
{
    Display *dpy;
    Window w;
    XEvent ev;
    Atom close_atom, net_wm;

    if (argc != 2) { fprintf( stderr, "usage: xclose 0xWINDOWID\n" ); return 1; }
    if (!(dpy = XOpenDisplay( NULL ))) { fprintf( stderr, "no display\n" ); return 1; }
    w = strtoul( argv[1], NULL, 0 );
    close_atom = XInternAtom( dpy, "_NET_CLOSE_WINDOW", False );
    net_wm = XInternAtom( dpy, "_NET_WM_STATE", False );
    (void)net_wm;

    ev.xclient.type = ClientMessage;
    ev.xclient.window = w;
    ev.xclient.message_type = close_atom;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = CurrentTime;
    ev.xclient.data.l[1] = 2; /* source: direct pager/tool request */
    XSendEvent( dpy, DefaultRootWindow( dpy ), False,
                SubstructureRedirectMask | SubstructureNotifyMask, &ev );
    XFlush( dpy );
    XCloseDisplay( dpy );
    return 0;
}
