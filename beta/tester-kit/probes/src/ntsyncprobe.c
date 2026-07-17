/* ntsyncprobe.c: are NT sync primitives correct and fast in this runtime? (PE, CRT-free)
 *
 * Asserts the semantics that change when Wine uses ntsync instead of
 * wineserver round trips: wait-all atomicity, auto-reset single-wake,
 * abandoned mutexes, APC delivery, cross-process named objects. Then
 * measures event ping-pong and semaphore churn, which proxy Live's
 * per-buffer audio-worker wakeups; a build without ntsync lands an order
 * of magnitude lower (notes/ABLETON-WINE-NTSYNC-REGRESSION.md).
 *
 * output: ntsyncprobe.txt in cwd, "ok"/"FAIL"/"info" lines + SUMMARY.
 * exit code: number of failed assertions.  "--child": cross-process helper.
 * build: build-maintainer-probes.sh
 */
#include <windows.h>

static HANDLE g_out;
static char buf[512];
static int g_pass, g_fail;
static void emit( const char *s ){ DWORD n; WriteFile( g_out, s, lstrlenA(s), &n, NULL ); }
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)
#define CHECK(cond, name) do { if (cond) { g_pass++; P( "ok %s\n", name ); } \
                               else { g_fail++; P( "FAIL %s (line %d, lasterr %u)\n", name, __LINE__, (UINT)GetLastError() ); } } while (0)

#define MTX_NAME   "Local\\ntsyncprobe_m"
#define SEM_NAME   "Local\\ntsyncprobe_s"
#define READY_NAME "Local\\ntsyncprobe_ready"

/* ---- cross-process helper: opened named objects, contends with parent ---- */
static void child_main( void )
{
    HANDLE m = OpenMutexA( SYNCHRONIZE, FALSE, MTX_NAME );
    HANDLE s = OpenSemaphoreA( SEMAPHORE_MODIFY_STATE, FALSE, SEM_NAME );
    HANDLE r = OpenEventA( EVENT_MODIFY_STATE, FALSE, READY_NAME );
    if (!m || !s || !r) ExitProcess( 2 );
    SetEvent( r );
    if (WaitForSingleObject( m, 100 ) != WAIT_TIMEOUT) ExitProcess( 3 );  /* parent must still hold it */
    if (WaitForSingleObject( m, 5000 ) != WAIT_OBJECT_0) ExitProcess( 1 );
    ReleaseMutex( m );
    ReleaseSemaphore( s, 1, NULL );
    ExitProcess( 0 );
}

/* ---- waiter threads ---- */
static HANDLE g_ev;
static LONG g_woken;
static DWORD WINAPI wait_and_count( LPVOID arg )
{
    (void)arg;
    if (WaitForSingleObject( g_ev, 5000 ) == WAIT_OBJECT_0) InterlockedIncrement( &g_woken );
    return 0;
}

static DWORD WINAPI grab_and_abandon( LPVOID arg )
{
    WaitForSingleObject( (HANDLE)arg, 5000 );
    return 0;  /* exits owning the mutex */
}

static void CALLBACK apc_fn( ULONG_PTR arg ) { (void)arg; }
static DWORD g_apc_wait_ret;
static DWORD WINAPI alertable_waiter( LPVOID arg )
{
    g_apc_wait_ret = WaitForSingleObjectEx( (HANDLE)arg, 5000, TRUE );
    return 0;
}

/* ---- ping-pong partner for the throughput counter ---- */
static HANDLE g_ping, g_pong;
static int g_rounds;
static DWORD WINAPI pong_thread( LPVOID arg )
{
    int i;
    (void)arg;
    for (i = 0; i < g_rounds; i++)
    {
        if (WaitForSingleObject( g_ping, 10000 ) != WAIT_OBJECT_0) return 1;
        SetEvent( g_pong );
    }
    return 0;
}

static DWORD elapsed_ms( LARGE_INTEGER t0, LARGE_INTEGER freq )
{
    LARGE_INTEGER t1;
    QueryPerformanceCounter( &t1 );
    return (DWORD)((t1.QuadPart - t0.QuadPart) * 1000 / freq.QuadPart);
}

void mainCRTStartup( void )
{
    HANDLE h, m, threads[2], child_m, child_s, child_r;
    HANDLE ev3[3];
    LARGE_INTEGER freq, t0;
    DWORD ms, i;
    LONG prev;

    if (lstrcmpA( GetCommandLineA() + lstrlenA( GetCommandLineA() ) - 7, "--child" ) == 0)
        child_main();

    g_out = CreateFileA( "ntsyncprobe.txt", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    QueryPerformanceFrequency( &freq );

    /* semaphore: count, max, over-release */
    h = CreateSemaphoreA( NULL, 0, 3, NULL );
    CHECK( WaitForSingleObject( h, 0 ) == WAIT_TIMEOUT, "sem-starts-empty" );
    CHECK( ReleaseSemaphore( h, 2, &prev ) && prev == 0, "sem-release-2" );
    CHECK( WaitForSingleObject( h, 0 ) == WAIT_OBJECT_0 &&
           WaitForSingleObject( h, 0 ) == WAIT_OBJECT_0 &&
           WaitForSingleObject( h, 0 ) == WAIT_TIMEOUT, "sem-count-consumed" );
    CHECK( !ReleaseSemaphore( h, 4, NULL ) && GetLastError() == ERROR_TOO_MANY_POSTS, "sem-max-enforced" );
    CloseHandle( h );

    /* mutex: recursion + over-release */
    m = CreateMutexA( NULL, TRUE, NULL );
    CHECK( WaitForSingleObject( m, 0 ) == WAIT_OBJECT_0 &&
           WaitForSingleObject( m, 0 ) == WAIT_OBJECT_0, "mutex-recursive" );
    CHECK( ReleaseMutex( m ) && ReleaseMutex( m ) && ReleaseMutex( m ), "mutex-release-x3" );
    CHECK( !ReleaseMutex( m ), "mutex-over-release-fails" );
    CloseHandle( m );

    /* abandoned mutex must report WAIT_ABANDONED to the next waiter */
    m = CreateMutexA( NULL, FALSE, NULL );
    threads[0] = CreateThread( NULL, 0, grab_and_abandon, m, 0, NULL );
    WaitForSingleObject( threads[0], 5000 );
    CloseHandle( threads[0] );
    CHECK( WaitForSingleObject( m, 1000 ) == WAIT_ABANDONED, "mutex-abandoned" );
    ReleaseMutex( m );
    CloseHandle( m );

    /* auto-reset event wakes exactly one of two waiters */
    g_ev = CreateEventA( NULL, FALSE, FALSE, NULL );
    g_woken = 0;
    threads[0] = CreateThread( NULL, 0, wait_and_count, NULL, 0, NULL );
    threads[1] = CreateThread( NULL, 0, wait_and_count, NULL, 0, NULL );
    Sleep( 100 );                      /* both inside the wait */
    SetEvent( g_ev );
    Sleep( 100 );
    CHECK( g_woken == 1, "event-auto-single-wake" );
    SetEvent( g_ev );
    WaitForMultipleObjects( 2, threads, TRUE, 5000 );
    CHECK( g_woken == 2, "event-auto-second-wake" );
    CloseHandle( threads[0] ); CloseHandle( threads[1] ); CloseHandle( g_ev );

    /* manual-reset event releases all waiters and stays signaled */
    g_ev = CreateEventA( NULL, TRUE, FALSE, NULL );
    g_woken = 0;
    threads[0] = CreateThread( NULL, 0, wait_and_count, NULL, 0, NULL );
    threads[1] = CreateThread( NULL, 0, wait_and_count, NULL, 0, NULL );
    Sleep( 100 );
    SetEvent( g_ev );
    WaitForMultipleObjects( 2, threads, TRUE, 5000 );
    CHECK( g_woken == 2, "event-manual-broadcast" );
    CHECK( WaitForSingleObject( g_ev, 0 ) == WAIT_OBJECT_0, "event-manual-stays-signaled" );
    ResetEvent( g_ev );
    CHECK( WaitForSingleObject( g_ev, 0 ) == WAIT_TIMEOUT, "event-reset" );
    CloseHandle( threads[0] ); CloseHandle( threads[1] );

    /* PulseEvent releases a blocked waiter, then the event is unsignaled */
    g_woken = 0;
    threads[0] = CreateThread( NULL, 0, wait_and_count, NULL, 0, NULL );
    Sleep( 100 );
    PulseEvent( g_ev );
    WaitForSingleObject( threads[0], 5000 );
    CHECK( g_woken == 1 && WaitForSingleObject( g_ev, 0 ) == WAIT_TIMEOUT, "event-pulse" );
    CloseHandle( threads[0] ); CloseHandle( g_ev );

    /* WaitForMultipleObjects: lowest-index rule, wait-all atomicity */
    for (i = 0; i < 3; i++) ev3[i] = CreateEventA( NULL, TRUE, FALSE, NULL );
    SetEvent( ev3[1] );
    CHECK( WaitForMultipleObjects( 3, ev3, FALSE, 0 ) == WAIT_OBJECT_0 + 1, "wfmo-any-hits-signaled" );
    SetEvent( ev3[0] ); SetEvent( ev3[2] );
    CHECK( WaitForMultipleObjects( 3, ev3, FALSE, 0 ) == WAIT_OBJECT_0, "wfmo-any-lowest-index" );
    ResetEvent( ev3[1] );
    CHECK( WaitForMultipleObjects( 3, ev3, TRUE, 0 ) == WAIT_TIMEOUT, "wfmo-all-incomplete-times-out" );
    CHECK( WaitForSingleObject( ev3[0], 0 ) == WAIT_OBJECT_0 &&
           WaitForSingleObject( ev3[2], 0 ) == WAIT_OBJECT_0, "wfmo-all-no-partial-consume" );
    for (i = 0; i < 3; i++) CloseHandle( ev3[i] );
    for (i = 0; i < 3; i++) ev3[i] = CreateEventA( NULL, FALSE, TRUE, NULL );   /* auto, signaled */
    CHECK( WaitForMultipleObjects( 3, ev3, TRUE, 0 ) == WAIT_OBJECT_0, "wfmo-all-succeeds" );
    CHECK( WaitForSingleObject( ev3[0], 0 ) == WAIT_TIMEOUT &&
           WaitForSingleObject( ev3[1], 0 ) == WAIT_TIMEOUT &&
           WaitForSingleObject( ev3[2], 0 ) == WAIT_TIMEOUT, "wfmo-all-consumes-atomically" );
    for (i = 0; i < 3; i++) CloseHandle( ev3[i] );

    /* APC lands in an alertable wait */
    g_ev = CreateEventA( NULL, FALSE, FALSE, NULL );
    g_apc_wait_ret = 0xdeadbeef;
    threads[0] = CreateThread( NULL, 0, alertable_waiter, g_ev, 0, NULL );
    Sleep( 100 );
    QueueUserAPC( apc_fn, threads[0], 0 );
    WaitForSingleObject( threads[0], 5000 );
    CHECK( g_apc_wait_ret == WAIT_IO_COMPLETION, "apc-interrupts-alertable-wait" );
    CloseHandle( threads[0] ); CloseHandle( g_ev );

    /* cross-process named objects: hold mutex, spawn child, hand it over */
    child_m = CreateMutexA( NULL, TRUE, MTX_NAME );
    child_s = CreateSemaphoreA( NULL, 0, 1, SEM_NAME );
    child_r = CreateEventA( NULL, TRUE, FALSE, READY_NAME );
    {
        char exe[MAX_PATH], cmd[MAX_PATH + 16];
        STARTUPINFOA si; PROCESS_INFORMATION pi;
        DWORD code = 0xff;
        GetModuleFileNameA( NULL, exe, sizeof exe );
        wsprintfA( cmd, "\"%s\" --child", exe );
        ZeroMemory( &si, sizeof si ); si.cb = sizeof si;
        if (CreateProcessA( exe, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi ))
        {
            CHECK( WaitForSingleObject( child_r, 5000 ) == WAIT_OBJECT_0, "xproc-child-opened-objects" );
            Sleep( 300 );              /* child's 100ms probe of the held mutex runs here */
            ReleaseMutex( child_m );
            CHECK( WaitForSingleObject( child_s, 5000 ) == WAIT_OBJECT_0, "xproc-sem-signaled-by-child" );
            WaitForSingleObject( pi.hProcess, 5000 );
            GetExitCodeProcess( pi.hProcess, &code );
            CHECK( code == 0, "xproc-child-mutex-handoff" );
            CloseHandle( pi.hProcess ); CloseHandle( pi.hThread );
        }
        else { g_fail++; P( "FAIL xproc-spawn (lasterr %u)\n", (UINT)GetLastError() ); }
    }
    CloseHandle( child_m ); CloseHandle( child_s ); CloseHandle( child_r );

    /* timeout accuracy: ten 5ms waits, informational */
    g_ev = CreateEventA( NULL, FALSE, FALSE, NULL );
    QueryPerformanceCounter( &t0 );
    for (i = 0; i < 10; i++) WaitForSingleObject( g_ev, 5 );
    ms = elapsed_ms( t0, freq );
    CHECK( ms >= 40 && ms < 500, "timeout-5ms-sane" );
    P( "info timeout_10x5ms_ms=%u\n", (UINT)ms );
    CloseHandle( g_ev );

    /* throughput: event ping-pong (proxies per-buffer audio-worker wakeups) */
    g_ping = CreateEventA( NULL, FALSE, FALSE, NULL );
    g_pong = CreateEventA( NULL, FALSE, FALSE, NULL );
    g_rounds = 20000;
    threads[0] = CreateThread( NULL, 0, pong_thread, NULL, 0, NULL );
    QueryPerformanceCounter( &t0 );
    for (i = 0; i < (DWORD)g_rounds; i++)
    {
        SetEvent( g_ping );
        if (WaitForSingleObject( g_pong, 10000 ) != WAIT_OBJECT_0) break;
    }
    ms = elapsed_ms( t0, freq );
    CHECK( i == (DWORD)g_rounds, "pingpong-completed" );
    WaitForSingleObject( threads[0], 5000 );
    CloseHandle( threads[0] ); CloseHandle( g_ping ); CloseHandle( g_pong );
    P( "info pingpong_roundtrips_per_s=%u\n", ms ? (UINT)(20000u * 1000u / ms) : 0 );

    /* throughput: uncontended semaphore release+acquire pairs */
    h = CreateSemaphoreA( NULL, 0, 1000000, NULL );
    QueryPerformanceCounter( &t0 );
    for (i = 0; i < 50000; i++)
    {
        ReleaseSemaphore( h, 1, NULL );
        if (WaitForSingleObject( h, 0 ) != WAIT_OBJECT_0) break;
    }
    ms = elapsed_ms( t0, freq );
    CHECK( i == 50000, "sem-churn-completed" );
    CloseHandle( h );
    P( "info sem_pairs_per_s=%u\n", ms ? (UINT)(50000u * 1000u / ms) : 0 );

    P( "SUMMARY pass=%d fail=%d\n", g_pass, g_fail );
    CloseHandle( g_out );
    ExitProcess( g_fail );
}
