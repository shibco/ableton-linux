/* pinchgen.c - create a virtual multitouch touchpad and perform one gesture.
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
 * usage: ./pinchgen [out|in|up|down|left|right] [steps]
 *
 * See notes/ABLETON-WINE-POINTER-GESTURES.md.
 */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int fd;

enum gesture
{
    PINCH_OUT,
    PINCH_IN,
    PAN_UP,
    PAN_DOWN,
    PAN_LEFT,
    PAN_RIGHT,
};

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

static void set_bit( int request, int bit )
{
    if (ioctl( fd, request, bit ) < 0)
    {
        perror( "UI_SET_*" );
        exit( 1 );
    }
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
    const char *name = argc > 1 ? argv[1] : "out";
    enum gesture gesture;
    int steps = argc > 2 ? atoi( argv[2] ) : 30;
    struct uinput_setup setup = { .name = "pinchgen virtual touchpad" };
    int i;

    if (!strcmp( name, "out" )) gesture = PINCH_OUT;
    else if (!strcmp( name, "in" )) gesture = PINCH_IN;
    else if (!strcmp( name, "up" )) gesture = PAN_UP;
    else if (!strcmp( name, "down" )) gesture = PAN_DOWN;
    else if (!strcmp( name, "left" )) gesture = PAN_LEFT;
    else if (!strcmp( name, "right" )) gesture = PAN_RIGHT;
    else
    {
        fprintf( stderr, "usage: %s [out|in|up|down|left|right] [steps]\n", argv[0] );
        return 2;
    }
    if (steps < 1)
    {
        fprintf( stderr, "steps must be positive\n" );
        return 2;
    }

    if ((fd = open( "/dev/uinput", O_WRONLY | O_NONBLOCK )) < 0)
    {
        perror( "/dev/uinput" );
        return 1;
    }

    set_bit( UI_SET_EVBIT, EV_KEY );
    set_bit( UI_SET_EVBIT, EV_ABS );
    set_bit( UI_SET_EVBIT, EV_SYN );
    set_bit( UI_SET_KEYBIT, BTN_LEFT );
    set_bit( UI_SET_KEYBIT, BTN_TOUCH );
    set_bit( UI_SET_KEYBIT, BTN_TOOL_FINGER );
    set_bit( UI_SET_KEYBIT, BTN_TOOL_DOUBLETAP );
    set_bit( UI_SET_PROPBIT, INPUT_PROP_POINTER );
    set_bit( UI_SET_PROPBIT, INPUT_PROP_BUTTONPAD );
    set_bit( UI_SET_ABSBIT, ABS_X );
    set_bit( UI_SET_ABSBIT, ABS_Y );
    set_bit( UI_SET_ABSBIT, ABS_PRESSURE );
    set_bit( UI_SET_ABSBIT, ABS_MT_SLOT );
    set_bit( UI_SET_ABSBIT, ABS_MT_POSITION_X );
    set_bit( UI_SET_ABSBIT, ABS_MT_POSITION_Y );
    set_bit( UI_SET_ABSBIT, ABS_MT_PRESSURE );
    set_bit( UI_SET_ABSBIT, ABS_MT_TRACKING_ID );

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

    /* Two fingers down: start wider for pinch-in, then change their span or
     * move their centre together for two-finger panning. */
    {
        int start = gesture == PINCH_IN ? 1200 : 400;
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
            int distance = (800 * i) / steps;
            int span = start, x = 2000, y = 1400;

            if (gesture == PINCH_OUT) span += distance;
            else if (gesture == PINCH_IN) span -= distance;
            else if (gesture == PAN_UP) y -= distance;
            else if (gesture == PAN_DOWN) y += distance;
            else if (gesture == PAN_LEFT) x -= distance;
            else if (gesture == PAN_RIGHT) x += distance;
            finger( 0, x - span, y );
            finger( 1, x + span, y );
            emit( EV_ABS, ABS_X, x - span );
            emit( EV_ABS, ABS_Y, y );
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

    printf( "%s gesture done\n", name );
    nap( 400 );
    ioctl( fd, UI_DEV_DESTROY );
    close( fd );
    return 0;
}
