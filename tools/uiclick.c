/* uiclick — emit one left mouse click at absolute (x,y) via /dev/uinput.
 * Wayland-level input (compositor dispatches to the focused/Xwayland window),
 * unlike XTest which never reaches Wine windows under this session.
 * usage: uiclick X Y     build: gcc -O2 -o uiclick uiclick.c
 */
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void emit(int fd, unsigned short type, unsigned short code, int val)
{
    struct input_event ev = {0};
    ev.type = type;
    ev.code = code;
    ev.value = val;
    write(fd, &ev, sizeof(ev));
}

int main(int argc, char **argv)
{
    if (argc < 3)
    {
        fprintf(stderr, "usage: uiclick X Y\n");
        return 1;
    }
    int x = atoi(argv[1]), y = atoi(argv[2]);
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0)
    {
        perror("open /dev/uinput");
        return 1;
    }
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_ABSBIT, ABS_X);
    ioctl(fd, UI_SET_ABSBIT, ABS_Y);
    ioctl(fd, UI_SET_EVBIT, EV_SYN);

    struct uinput_setup us = {0};
    snprintf(us.name, sizeof(us.name), "uiclick-mouse");
    us.id.bustype = BUS_USB;
    us.id.vendor = 0x1;
    us.id.product = 0x1;
    if (ioctl(fd, UI_DEV_SETUP, &us) < 0)
        perror("UI_DEV_SETUP");
    /* absolute pointer coords need the input abs range; mutter maps ABS to
     * screen pixels 1:1 when max matches the output resolution. Read it from
     * xsettle-known geometry: primary is 3440x1440? Use generous max. */
    struct uinput_abs_setup ax = {0}, ay = {0};
    ax.code = ABS_X;
    ax.absinfo.minimum = 0;
    ax.absinfo.maximum = 65535;
    ay.code = ABS_Y;
    ay.absinfo.minimum = 0;
    ay.absinfo.maximum = 65535;
    ioctl(fd, UI_ABS_SETUP, &ax);
    ioctl(fd, UI_ABS_SETUP, &ay);
    if (ioctl(fd, UI_DEV_CREATE) < 0)
    {
        perror("UI_DEV_CREATE");
        return 1;
    }
    sleep(1); /* let the compositor adopt the device */

    /* Query the real screen size via xdpyinfo? Keep it simple: pass normalized
     * 0..65535 scaled by a screen size read from the environment. */
    int sw = getenv("UICLICK_W") ? atoi(getenv("UICLICK_W")) : 3440;
    int sh = getenv("UICLICK_H") ? atoi(getenv("UICLICK_H")) : 2880;
    long ax_v = (long)x * 65535 / sw;
    long ay_v = (long)y * 65535 / sh;

    emit(fd, EV_ABS, ABS_X, ax_v);
    emit(fd, EV_ABS, ABS_Y, ay_v);
    emit(fd, EV_SYN, SYN_REPORT, 0);
    usleep(50000);
    emit(fd, EV_KEY, BTN_LEFT, 1);
    emit(fd, EV_SYN, SYN_REPORT, 0);
    usleep(60000);
    emit(fd, EV_KEY, BTN_LEFT, 0);
    emit(fd, EV_SYN, SYN_REPORT, 0);
    usleep(100000);

    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    return 0;
}
