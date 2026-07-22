/* ukey: synthetic keyboard via /dev/uinput.  XTest never reaches Wine
 * windows in this session (see uiclick.c).
 * usage: ukey TOKEN...   tokens: alt+f8  f10  down  up  left  right  enter
 *                                esc  v  h  down*12 (repeat)  sleep:300 (ms)
 * build: gcc -O2 -o ukey ukey.c
 */
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int ufd;

static void emit(unsigned short type, unsigned short code, int val)
{
    struct input_event ev = {0};
    ev.type = type; ev.code = code; ev.value = val;
    write(ufd, &ev, sizeof(ev));
}

static void tap(int mod, int key)
{
    if (mod) { emit(EV_KEY, mod, 1); emit(EV_SYN, SYN_REPORT, 0); usleep(30000); }
    emit(EV_KEY, key, 1); emit(EV_SYN, SYN_REPORT, 0); usleep(40000);
    emit(EV_KEY, key, 0); emit(EV_SYN, SYN_REPORT, 0); usleep(40000);
    if (mod) { emit(EV_KEY, mod, 0); emit(EV_SYN, SYN_REPORT, 0); usleep(30000); }
}

static int keyof(const char *t, int *mod)
{
    *mod = 0;
    if (!strncmp(t, "alt+", 4)) { *mod = KEY_LEFTALT; t += 4; }
    if (!strcmp(t, "f8")) return KEY_F8;
    if (!strcmp(t, "down")) return KEY_DOWN;
    if (!strcmp(t, "up")) return KEY_UP;
    if (!strcmp(t, "left")) return KEY_LEFT;
    if (!strcmp(t, "right")) return KEY_RIGHT;
    if (!strcmp(t, "enter")) return KEY_ENTER;
    if (!strcmp(t, "esc")) return KEY_ESC;
    if (!strcmp(t, "v")) return KEY_V;
    if (!strcmp(t, "h")) return KEY_H;
    if (!strcmp(t, "f10")) return KEY_F10;
    return 0;
}

int main(int argc, char **argv)
{
    int i, keys[] = { KEY_LEFTALT, KEY_F8, KEY_F10, KEY_DOWN, KEY_UP, KEY_LEFT,
                      KEY_RIGHT, KEY_ENTER, KEY_ESC, KEY_V, KEY_H };

    if (argc < 2) { fprintf(stderr, "usage: ukey TOKEN...\n"); return 1; }
    ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (ufd < 0) { perror("open /dev/uinput"); return 1; }
    ioctl(ufd, UI_SET_EVBIT, EV_KEY);
    for (i = 0; i < (int)(sizeof(keys)/sizeof(*keys)); i++) ioctl(ufd, UI_SET_KEYBIT, keys[i]);
    ioctl(ufd, UI_SET_EVBIT, EV_SYN);

    struct uinput_setup us = {0};
    snprintf(us.name, sizeof(us.name), "ukey-kbd");
    us.id.bustype = BUS_USB; us.id.vendor = 0x1; us.id.product = 0x3;
    ioctl(ufd, UI_DEV_SETUP, &us);
    if (ioctl(ufd, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); return 1; }
    sleep(1);

    for (i = 1; i < argc; i++)
    {
        char tok[64]; int rep = 1, mod, key;
        snprintf(tok, sizeof(tok), "%s", argv[i]);
        char *star = strchr(tok, '*');
        if (star) { rep = atoi(star + 1); *star = 0; }
        if (!strncmp(tok, "sleep:", 6)) { usleep(atoi(tok + 6) * 1000); continue; }
        if (!(key = keyof(tok, &mod))) { fprintf(stderr, "ukey: bad token %s\n", tok); continue; }
        while (rep-- > 0) tap(mod, key);
    }
    ioctl(ufd, UI_DEV_DESTROY);
    close(ufd);
    return 0;
}
