#define _GNU_SOURCE

/* Record the NTSync alert-event wait used by performance/0001.
 * MOONSHOT_NTSYNC_ALERT_WAIT_FAULT=1 returns EIO for count=0 alert waits.
 * Wine then uses its regular wineserver route. Handle waits keep their
 * original route.
 */
#include <errno.h>
#include <linux/ntsync.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

static int fault_alert_wait;

__attribute__((constructor)) static void init_probe(void)
{
    const char *env = getenv( "MOONSHOT_NTSYNC_ALERT_WAIT_FAULT" );

    fault_alert_wait = env && strcmp( env, "0" ) && strcasecmp( env, "off" );
}

int ioctl( int fd, unsigned long request, ... )
{
    struct ntsync_wait_args *args;
    va_list ap;
    void *arg;

    va_start( ap, request );
    arg = va_arg( ap, void * );
    va_end( ap );

    if (request == NTSYNC_IOC_WAIT_ANY && arg)
    {
        args = arg;
        if (!args->count && args->alert)
        {
            dprintf( STDERR_FILENO,
                     "MOONSHOT_NTSYNC_ALERT_WAIT count=0 alert=%u owner=%u action=%s\n",
                     args->alert, args->owner, fault_alert_wait ? "fail-eio" : "observe" );
            if (fault_alert_wait)
            {
                errno = EIO;
                return -1;
            }
        }
    }

    return syscall( SYS_ioctl, fd, request, arg );
}
