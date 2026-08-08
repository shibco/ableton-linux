/* pinchgen.c - create a virtual multitouch touchpad and perform one pinch.
 *
 * libinput turns the two-finger movement into a pinch gesture, the compositor
 * forwards it to the surface under the pointer, and XWayland reports it as an
 * XInput2 gesture. This exercises patch 0071 without a physical touchpad: put
 * the pointer over a window of the application under test, then run this.
 *
 * Needs write access to /dev/uinput, which a desktop session normally grants
 * the logged-in user. The virtual device disappears when the program exits.
 *
 * build: gcc -O2 -o pinchgen pinchgen.c
 * usage: ./pinchgen [out|in] [steps]
 *
 * See notes/ABLETON-WINE-POINTER-GESTURES.md.
 */
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int fd;

static void emit( int type, int code, int value )
{
    struct input_event ev = { .type = type, .code = code, .value = value };
    if (write( fd, &ev, sizeof ev ) != sizeof ev) perror( "write" );
}

static void syn( void )
{
    emit( EV_SYN, SYN_REPORT, 0 );
}

static void nap( long ms )
{
    struct timespec ts = { .tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000 };
    nanosleep( &ts, NULL );
}

static void abs_setup( int code, int min, int max, int res )
{
    struct uinput_abs_setup as = { .code = code };
    as.absinfo.minimum = min;
    as.absinfo.maximum = max;
    as.absinfo.resolution = res;
    if (ioctl( fd, UI_ABS_SETUP, &as ) < 0) perror( "UI_ABS_SETUP" );
}

static void finger( int slot, int x, int y )
{
    emit( EV_ABS, ABS_MT_SLOT, slot );
    emit( EV_ABS, ABS_MT_POSITION_X, x );
    emit( EV_ABS, ABS_MT_POSITION_Y, y );
    emit( EV_ABS, ABS_MT_PRESSURE, 60 );
}

int main( int argc, char **argv )
{
    int out = argc < 2 || strcmp( argv[1], "in" );
    int steps = argc > 2 ? atoi( argv[2] ) : 30;
    struct uinput_setup setup = { .name = "pinchgen virtual touchpad" };
    int i;

    if ((fd = open( "/dev/uinput", O_WRONLY | O_NONBLOCK )) < 0)
    {
        perror( "/dev/uinput" );
        return 1;
    }

    ioctl( fd, UI_SET_EVBIT, EV_KEY );
    ioctl( fd, UI_SET_EVBIT, EV_ABS );
    ioctl( fd, UI_SET_EVBIT, EV_SYN );
    ioctl( fd, UI_SET_KEYBIT, BTN_LEFT );
    ioctl( fd, UI_SET_KEYBIT, BTN_TOUCH );
    ioctl( fd, UI_SET_KEYBIT, BTN_TOOL_FINGER );
    ioctl( fd, UI_SET_KEYBIT, BTN_TOOL_DOUBLETAP );
    ioctl( fd, UI_SET_PROPBIT, INPUT_PROP_POINTER );
    ioctl( fd, UI_SET_PROPBIT, INPUT_PROP_BUTTONPAD );
    ioctl( fd, UI_SET_ABSBIT, ABS_X );
    ioctl( fd, UI_SET_ABSBIT, ABS_Y );
    ioctl( fd, UI_SET_ABSBIT, ABS_PRESSURE );
    ioctl( fd, UI_SET_ABSBIT, ABS_MT_SLOT );
    ioctl( fd, UI_SET_ABSBIT, ABS_MT_POSITION_X );
    ioctl( fd, UI_SET_ABSBIT, ABS_MT_POSITION_Y );
    ioctl( fd, UI_SET_ABSBIT, ABS_MT_PRESSURE );
    ioctl( fd, UI_SET_ABSBIT, ABS_MT_TRACKING_ID );

    /* 100 mm x 70 mm at 40 units/mm, the shape libinput expects of a touchpad */
    abs_setup( ABS_X, 0, 4000, 40 );
    abs_setup( ABS_Y, 0, 2800, 40 );
    abs_setup( ABS_PRESSURE, 0, 255, 0 );
    abs_setup( ABS_MT_SLOT, 0, 4, 0 );
    abs_setup( ABS_MT_POSITION_X, 0, 4000, 40 );
    abs_setup( ABS_MT_POSITION_Y, 0, 2800, 40 );
    abs_setup( ABS_MT_PRESSURE, 0, 255, 0 );
    abs_setup( ABS_MT_TRACKING_ID, 0, 65535, 0 );

    setup.id.bustype = BUS_I8042;
    setup.id.vendor = 0x0002;
    setup.id.product = 0x0007;
    setup.id.version = 0x01b1;
    if (ioctl( fd, UI_DEV_SETUP, &setup ) < 0) perror( "UI_DEV_SETUP" );
    if (ioctl( fd, UI_DEV_CREATE ) < 0)
    {
        perror( "UI_DEV_CREATE" );
        return 1;
    }
    printf( "virtual touchpad created, settling\n" );
    nap( 1500 );  /* let libinput and the compositor pick the device up */

    /* two fingers down, 20 mm apart when pinching out, 60 mm when pinching in */
    {
        int start = out ? 400 : 1200;
        emit( EV_ABS, ABS_MT_SLOT, 0 );
        emit( EV_ABS, ABS_MT_TRACKING_ID, 1 );
        finger( 0, 2000 - start, 1400 );
        emit( EV_ABS, ABS_MT_SLOT, 1 );
        emit( EV_ABS, ABS_MT_TRACKING_ID, 2 );
        finger( 1, 2000 + start, 1400 );
        emit( EV_KEY, BTN_TOUCH, 1 );
        emit( EV_KEY, BTN_TOOL_DOUBLETAP, 1 );
        emit( EV_ABS, ABS_X, 2000 - start );
        emit( EV_ABS, ABS_Y, 1400 );
        emit( EV_ABS, ABS_PRESSURE, 60 );
        syn();
        nap( 60 );

        for (i = 1; i <= steps; i++)
        {
            int span = out ? start + (800 * i) / steps : start - (800 * i) / steps;
            finger( 0, 2000 - span, 1400 );
            finger( 1, 2000 + span, 1400 );
            emit( EV_ABS, ABS_X, 2000 - span );
            emit( EV_ABS, ABS_Y, 1400 );
            syn();
            nap( 12 );
        }

        emit( EV_ABS, ABS_MT_SLOT, 0 );
        emit( EV_ABS, ABS_MT_TRACKING_ID, -1 );
        emit( EV_ABS, ABS_MT_SLOT, 1 );
        emit( EV_ABS, ABS_MT_TRACKING_ID, -1 );
        emit( EV_KEY, BTN_TOUCH, 0 );
        emit( EV_KEY, BTN_TOOL_DOUBLETAP, 0 );
        syn();
    }

    printf( "pinch %s done\n", out ? "out" : "in" );
    nap( 400 );
    ioctl( fd, UI_DEV_DESTROY );
    close( fd );
    return 0;
}
