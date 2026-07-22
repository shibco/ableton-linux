/* uidrag: real-input button-1 drag, targeted in X-space coordinates.
 * Positioning: XWarpPointer, corrected by uinput EV_REL moves in a closed
 * loop over XQueryPointer, so the real compositor pointer is on the target
 * before any button event.  XTest never reaches Wine windows in this
 * session and mutter does not map uinput EV_ABS (see uiclick.c).
 * usage: uidrag X1 Y1 X2 Y2 STEPS [STEP_MS]
 *        uidrag move X Y
 *        uidrag click X Y
 *        uidrag kbstart 0xWINID
 *        uidrag mresize X1 Y1 X2 Y2 STEPS [STEP_MS]
 *        uidrag resize 0xWINID DIR X1 Y1 X2 Y2 STEPS [STEP_MS]
 *          (press at X1,Y1, start a WM interactive resize via
 *           _NET_WM_MOVERESIZE direction DIR, drive it with real pointer
 *           motion; the same WM grab as a user edge drag)
 * build: gcc -O2 -o uidrag uidrag.c -lX11
 */
#include <X11/Xlib.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int ufd;
static Display *dpy;

static void emit(unsigned short type, unsigned short code, int val)
{
    struct input_event ev = {0};
    ev.type = type; ev.code = code; ev.value = val;
    write(ufd, &ev, sizeof(ev));
}

static void rel(int dx, int dy)
{
    if (dx) emit(EV_REL, REL_X, dx);
    if (dy) emit(EV_REL, REL_Y, dy);
    emit(EV_SYN, SYN_REPORT, 0);
}

static void query(int *x, int *y)
{
    Window r, c; int rx, ry, wx, wy; unsigned m;
    XQueryPointer(dpy, DefaultRootWindow(dpy), &r, &c, &rx, &ry, &wx, &wy, &m);
    *x = rx; *y = ry;
}

/* Land the real pointer on (tx,ty): warp, confirm with a real REL move (the
 * compositor re-asserts the true position on real input), then correct with
 * REL deltas until the query matches.  Returns 0 on success. */
static int goto_x(int tx, int ty)
{
    int px, py, i;
    XWarpPointer(dpy, None, DefaultRootWindow(dpy), 0, 0, 0, 0, tx, ty);
    XFlush(dpy);
    usleep(40000);
    for (i = 0; i < 40; i++)
    {
        rel(1, 0); usleep(25000); rel(-1, 0); usleep(25000);
        query(&px, &py);
        if (abs(px - tx) <= 2 && abs(py - ty) <= 2) return 0;
        /* REL deltas pass through pointer accel; move in bounded steps and
         * let the loop converge on the query. */
        int dx = tx - px, dy = ty - py;
        if (dx > 300) dx = 300; if (dx < -300) dx = -300;
        if (dy > 300) dy = 300; if (dy < -300) dy = -300;
        rel(dx, dy);
        usleep(30000);
    }
    query(&px, &py);
    fprintf(stderr, "uidrag: wanted %d,%d got %d,%d\n", tx, ty, px, py);
    return 1;
}

/* During the drag (button held) avoid warps: the grab tracks real device
 * motion.  Closed loop with REL; if the query freezes, send the remaining
 * delta blind in chunks. */
static void drag_to(int tx, int ty)
{
    int px, py, lx = -9999, ly = -9999, i, frozen = 0;
    for (i = 0; i < 30; i++)
    {
        query(&px, &py);
        if (abs(px - tx) <= 2 && abs(py - ty) <= 2) return;
        if (px == lx && py == ly && ++frozen >= 2)
        {
            int dx = tx - px, dy = ty - py;
            while (dx || dy)
            {
                int sx = dx > 40 ? 40 : dx < -40 ? -40 : dx;
                int sy = dy > 40 ? 40 : dy < -40 ? -40 : dy;
                rel(sx, sy); dx -= sx; dy -= sy;
                usleep(15000);
            }
            return;
        }
        lx = px; ly = py;
        int dx = tx - px, dy = ty - py;
        if (dx > 120) dx = 120; if (dx < -120) dx = -120;
        if (dy > 120) dy = 120; if (dy < -120) dy = -120;
        rel(dx, dy);
        usleep(18000);
    }
}

static void send_wm_moveresize(Window win, int x_root, int y_root, int dir)
{
    XEvent ev = {0};
    ev.xclient.type = ClientMessage;
    ev.xclient.window = win;
    ev.xclient.message_type = XInternAtom(dpy, "_NET_WM_MOVERESIZE", False);
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = x_root;
    ev.xclient.data.l[1] = y_root;
    ev.xclient.data.l[2] = dir;
    ev.xclient.data.l[3] = 1; /* button */
    ev.xclient.data.l[4] = 1; /* source: normal application */
    XSendEvent(dpy, DefaultRootWindow(dpy), False,
               SubstructureRedirectMask | SubstructureNotifyMask, &ev);
    XFlush(dpy);
}

int main(int argc, char **argv)
{
    int x1, y1, x2, y2, steps, step_ms = 25, i, move_only = 0, mresize = 0;
    Window resize_win = 0; int resize_dir = 4;

    if (argc >= 7 && !strcmp(argv[1], "mresize"))
    {
        /* GNOME resize gesture: Super plus middle-button drag, consumed by
         * mutter, never reaching the app; the same grab as an edge drag. */
        mresize = 1;
        x1 = atoi(argv[2]); y1 = atoi(argv[3]);
        x2 = atoi(argv[4]); y2 = atoi(argv[5]);
        steps = atoi(argv[6]);
        if (argc > 7) step_ms = atoi(argv[7]);
    }
    else if (argc >= 9 && !strcmp(argv[1], "resize"))
    {
        resize_win = strtoul(argv[2], NULL, 16);
        resize_dir = atoi(argv[3]);
        x1 = atoi(argv[4]); y1 = atoi(argv[5]);
        x2 = atoi(argv[6]); y2 = atoi(argv[7]);
        steps = atoi(argv[8]);
        if (argc > 9) step_ms = atoi(argv[9]);
    }
    else if (argc >= 4 && !strcmp(argv[1], "move")) { move_only = 1; x1 = atoi(argv[2]); y1 = atoi(argv[3]); }
    else if (argc >= 4 && !strcmp(argv[1], "click")) { move_only = 2; x1 = atoi(argv[2]); y1 = atoi(argv[3]); }
    else if (argc >= 3 && !strcmp(argv[1], "kbstart"))
    {
        /* Begin a WM keyboard resize on the window (dir 9), no button, no
         * focus needed; mutter's grab then receives the arrow keys. */
        if (!(dpy = XOpenDisplay(NULL))) return 1;
        send_wm_moveresize(strtoul(argv[2], NULL, 16), 0, 0, 9);
        return 0;
    }
    else if (argc >= 6)
    {
        x1 = atoi(argv[1]); y1 = atoi(argv[2]);
        x2 = atoi(argv[3]); y2 = atoi(argv[4]);
        steps = atoi(argv[5]);
        if (argc > 6) step_ms = atoi(argv[6]);
    }
    else { fprintf(stderr, "usage: uidrag X1 Y1 X2 Y2 STEPS [STEP_MS] | uidrag move X Y\n"); return 1; }

    if (!(dpy = XOpenDisplay(NULL))) { fprintf(stderr, "no display\n"); return 1; }
    ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (ufd < 0) { perror("open /dev/uinput"); return 1; }

    ioctl(ufd, UI_SET_EVBIT, EV_KEY);
    ioctl(ufd, UI_SET_KEYBIT, BTN_LEFT);
    ioctl(ufd, UI_SET_KEYBIT, BTN_MIDDLE);
    ioctl(ufd, UI_SET_KEYBIT, KEY_LEFTMETA);
    ioctl(ufd, UI_SET_EVBIT, EV_REL);
    ioctl(ufd, UI_SET_RELBIT, REL_X);
    ioctl(ufd, UI_SET_RELBIT, REL_Y);
    ioctl(ufd, UI_SET_EVBIT, EV_SYN);

    struct uinput_setup us = {0};
    snprintf(us.name, sizeof(us.name), "uidrag-mouse");
    us.id.bustype = BUS_USB; us.id.vendor = 0x1; us.id.product = 0x2;
    ioctl(ufd, UI_DEV_SETUP, &us);
    if (ioctl(ufd, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); return 1; }
    sleep(1); /* compositor adopts the device */

    if (goto_x(x1, y1)) { fprintf(stderr, "uidrag: positioning failed, no press\n"); ioctl(ufd, UI_DEV_DESTROY); return 1; }
    if (move_only == 2)
    {
        usleep(80000);
        emit(EV_KEY, BTN_LEFT, 1); emit(EV_SYN, SYN_REPORT, 0); usleep(70000);
        emit(EV_KEY, BTN_LEFT, 0); emit(EV_SYN, SYN_REPORT, 0); usleep(80000);
    }
    if (move_only) { ioctl(ufd, UI_DEV_DESTROY); return 0; }

    usleep(120000);
    if (mresize) { emit(EV_KEY, KEY_LEFTMETA, 1); emit(EV_SYN, SYN_REPORT, 0); usleep(120000); }
    emit(EV_KEY, mresize ? BTN_MIDDLE : BTN_LEFT, 1);
    emit(EV_SYN, SYN_REPORT, 0);
    usleep(180000);
    if (resize_win) { send_wm_moveresize(resize_win, x1, y1, resize_dir); usleep(150000); }
    for (i = 1; i <= steps; i++)
    {
        drag_to(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps);
        usleep(step_ms * 1000);
    }
    usleep(250000);
    emit(EV_KEY, mresize ? BTN_MIDDLE : BTN_LEFT, 0);
    emit(EV_SYN, SYN_REPORT, 0);
    usleep(150000);
    if (mresize) { emit(EV_KEY, KEY_LEFTMETA, 0); emit(EV_SYN, SYN_REPORT, 0); }
    usleep(250000);
    ioctl(ufd, UI_DEV_DESTROY);
    close(ufd);
    XCloseDisplay(dpy);
    return 0;
}
