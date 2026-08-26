/* apcprobe.c verifies alertable delays and user APC results for
 * performance/0001. The patch waits on the calling thread's NTSync alert event.
 * Wineserver drains the APC queue after a wake. Wineserver keeps APC routing.
 *
 * The cases provide the following evidence:
 *   case0  checks zero, relative finite and absolute finite delays
 *   case1  checks FIFO delivery for 8 user APCs
 *   case2  checks FIFO within each producer and records cross-producer timing
 *   case3  checks that NtTestAlert drains self-queued APCs
 *   case4  keeps APC delivery queued during a regular wait and runs it during
 *          an alertable wait
 *   case5  checks pipe completion APC order; SKIP records pipe setup results
 *   case6  checks special APC delivery and Wine's shared FIFO order
 *   case7  checks that a recycled handle reaches the replacement thread
 *   case8  checks waiter and queuer progress during suspend and resume calls
 *   case9  compares server access results for 3 thread handle rights
 *   case10 checks strict FIFO across normal and special APCs
 *   case11 checks that a queued user APC wakes an infinite alertable delay
 *
 * --relaxed-fifo uses wider rules for the earlier FIFO cases.
 * Focused alertable-delay checks retain their standard rules.
 *
 * Results go to apcprobe.txt and standard output as PASS, FAIL, SKIP, info and
 * SUMMARY lines. The exit code gives the FAIL count. Each case has a fixed
 * time limit.
 *
 * Build with build_apcprobe.sh in the current directory. Run inside the
 * Ableton prefix with: tools/run_in_prefix.sh apcprobe.exe
 */
#include <windows.h>

/* Manual declarations provide the ntdll entries used by the probe.
 * LONG supplies the NTSTATUS type for the direct entry points. */
#define QUEUE_USER_APC_FLAGS_SPECIAL_USER_APC 0x1
#define STATUS_ACCESS_DENIED ((LONG)0xc0000022)
typedef void (CALLBACK *NTAPCFUNC)( ULONG_PTR, ULONG_PTR, ULONG_PTR );
LONG WINAPI NtTestAlert( void );
LONG WINAPI NtDelayExecution( BOOLEAN alertable, const LARGE_INTEGER *timeout );
LONG WINAPI NtQueueApcThreadEx2( HANDLE handle, HANDLE reserve, ULONG flags,
                                 NTAPCFUNC func, ULONG_PTR arg1, ULONG_PTR arg2, ULONG_PTR arg3 );

static HANDLE g_out, g_con;
static char   buf[512];
static int    g_pass, g_fail, g_skip;

static void emit( const char *s )
{
    DWORD n;
    if (g_out) WriteFile( g_out, s, lstrlenA(s), &n, NULL );
    if (g_con) WriteFile( g_con, s, lstrlenA(s), &n, NULL );
}
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)
#define CHECK(cond, name) do { if (cond) { g_pass++; P( "PASS %s\n", name ); } \
                               else { g_fail++; P( "FAIL %s (line %d, lasterr %u)\n", name, __LINE__, (UINT)GetLastError() ); } } while (0)
#define SKIP(name, why) do { g_skip++; P( "SKIP %s: %s (lasterr %u)\n", name, why, (UINT)GetLastError() ); } while (0)

/* Callbacks add their payload to the shared delivery record. */
#define MAX_DELIV 32
static volatile LONG g_ndeliv;
static ULONG_PTR     g_deliv[MAX_DELIV];

static void CALLBACK apc_record( ULONG_PTR data )
{
    LONG i = InterlockedIncrement( &g_ndeliv );
    if (i >= 1 && i <= MAX_DELIV) g_deliv[i - 1] = data;
}

/* Declare the 3-argument callback used by NtQueueApcThreadEx2. */
static void CALLBACK apc_record3( ULONG_PTR a, ULONG_PTR b, ULONG_PTR c )
{
    (void)b; (void)c;
    apc_record( a );
}

static void reset_deliv( void ) { g_ndeliv = 0; }

static void print_order( const char *tag )
{
    char tmp[24];
    LONG i, n = g_ndeliv;
    P( "info %s delivered=%ld order=", tag, n );
    if (n > MAX_DELIV) n = MAX_DELIV;
    for (i = 0; i < n; i++)
    {
        wsprintfA( tmp, "%s%x", i ? "," : "", (UINT)g_deliv[i] );
        emit( tmp );
    }
    emit( "\n" );
}

static int order_is( const ULONG_PTR *exp, LONG n )
{
    LONG i;
    if (g_ndeliv != n) return 0;
    for (i = 0; i < n; i++) if (g_deliv[i] != exp[i]) return 0;
    return 1;
}

/* Return the payload index. A result of -1 marks a payload outside the record. */
static LONG pos_of( ULONG_PTR v )
{
    LONG i, n = g_ndeliv;
    if (n > MAX_DELIV) n = MAX_DELIV;
    for (i = 0; i < n; i++) if (g_deliv[i] == v) return i;
    return -1;
}

/* Scan the command line for --relaxed-fifo. */
static int cmdline_has( const char *needle )
{
    const char *s = GetCommandLineA();
    int i;
    for (; *s; s++)
    {
        for (i = 0; needle[i]; i++)
            if (s[i] != needle[i]) break;
        if (!needle[i]) return 1;
    }
    return 0;
}

static int g_relaxed;

/* Wait alertably for the target APC count or the fixed time budget. */
static LONG drain_until( LONG target, DWORD budget_ms )
{
    DWORD t0 = GetTickCount();
    while (g_ndeliv < target && GetTickCount() - t0 < budget_ms)
        SleepEx( 1000, TRUE );
    return g_ndeliv;
}

/* Drain the thread APC queue between cases. A zero-time alertable wait returns
 * 0 when the drain finishes. */
static void drop_pending( void )
{
    int i;
    for (i = 0; i < 64 && SleepEx( 0, TRUE ) == WAIT_IO_COMPLETION; i++) {}
}

/* Case 0 checks delay results for the retained alert wait. */
static void case0_delay_contracts( void )
{
    ULARGE_INTEGER now;
    LARGE_INTEGER absolute;
    FILETIME filetime;
    ULONGLONG start, elapsed;
    DWORD ret;
    LONG status;

    drop_pending();

    start = GetTickCount64();
    ret = SleepEx( 0, TRUE );
    elapsed = GetTickCount64() - start;
    P( "info case0 zero ret=%lx elapsed=%lu-ms\n", ret, (DWORD)elapsed );
    CHECK( ret == 0, "case0-zero-no-apc-returns-success" );
    CHECK( elapsed < 1000, "case0-zero-no-apc-is-bounded" );

    start = GetTickCount64();
    ret = SleepEx( 80, TRUE );
    elapsed = GetTickCount64() - start;
    P( "info case0 relative ret=%lx elapsed=%lu-ms\n", ret, (DWORD)elapsed );
    CHECK( ret == 0, "case0-relative-no-apc-returns-success" );
    CHECK( elapsed >= 50 && elapsed < 3000, "case0-relative-no-apc-duration" );

    GetSystemTimeAsFileTime( &filetime );
    now.LowPart = filetime.dwLowDateTime;
    now.HighPart = filetime.dwHighDateTime;
    absolute.QuadPart = now.QuadPart + 80 * 10000;
    start = GetTickCount64();
    status = NtDelayExecution( TRUE, &absolute );
    elapsed = GetTickCount64() - start;
    P( "info case0 absolute status=%08x elapsed=%lu-ms\n", (UINT)status, (DWORD)elapsed );
    CHECK( status == 0, "case0-absolute-no-apc-returns-success" );
    CHECK( elapsed >= 50 && elapsed < 3000, "case0-absolute-no-apc-duration" );
}

/* Case 1 checks FIFO delivery into another thread's alertable wait. */
static HANDLE g_ready;

static DWORD WINAPI waiter_thread( LPVOID arg )
{
    (void)arg;
    SetEvent( g_ready );
    drain_until( 8, 6000 );
    return 0;
}

static void case1_fifo( void )
{
    static const ULONG_PTR exp[8] = { 0x100, 0x101, 0x102, 0x103, 0x104, 0x105, 0x106, 0x107 };
    HANDLE b;
    int i;

    reset_deliv();
    g_ready = CreateEventA( NULL, TRUE, FALSE, NULL );
    b = CreateThread( NULL, 0, waiter_thread, NULL, 0, NULL );
    if (!b || !g_ready)
    {
        g_fail++;
        P( "FAIL case1-fifo: setup (thread/event) failed (lasterr %u)\n", (UINT)GetLastError() );
        if (b) CloseHandle( b );
        if (g_ready) CloseHandle( g_ready );
        return;
    }

    if (WaitForSingleObject( g_ready, 5000 ) != WAIT_OBJECT_0)
    {
        g_fail++;
        P( "FAIL case1-fifo: waiter never signalled ready\n" );
    }
    else
    {
        Sleep( 100 );  /* Place the waiter in its alertable wait before APC 1. */
        for (i = 0; i < 8; i++)
            if (!QueueUserAPC( apc_record, b, exp[i] )) break;
        if (i < 8)
        {
            g_fail++;
            P( "FAIL case1-fifo: QueueUserAPC #%d failed (lasterr %u)\n", i, (UINT)GetLastError() );
        }
        else if (WaitForSingleObject( b, 12000 ) == WAIT_OBJECT_0)
        {
            print_order( "case1" );
            CHECK( g_ndeliv == 8, "case1-fifo-all-delivered" );
            CHECK( order_is( exp, 8 ), "case1-fifo-queue-order" );
        }
        else
        {
            g_fail++;
            P( "FAIL case1-fifo: waiter stuck 12s (delivered %ld/8)\n", g_ndeliv );
        }
    }
    if (WaitForSingleObject( b, 0 ) == WAIT_TIMEOUT)  /* Release the bounded waiter. */
    {
        TerminateThread( b, 0 );
        WaitForSingleObject( b, 5000 );
    }
    CloseHandle( b );
    CloseHandle( g_ready );
}

/* Case 2 checks each producer's FIFO order during concurrent work. */
static HANDLE g_start;
static HANDLE g_self;

static DWORD WINAPI producer_thread( LPVOID arg )
{
    ULONG_PTR id = (ULONG_PTR)arg;
    int i;
    if (WaitForSingleObject( g_start, 5000 ) != WAIT_OBJECT_0) return 1;
    for (i = 0; i < 4; i++)
        if (!QueueUserAPC( apc_record, g_self, (id << 8) | (ULONG_PTR)i )) return 2;
    return 0;
}

static int per_producer_order_ok( void )
{
    int next[2] = { 0, 0 }, count[2] = { 0, 0 };
    LONG i;
    for (i = 0; i < g_ndeliv; i++)
    {
        int id = (int)(g_deliv[i] >> 8), seq = (int)(g_deliv[i] & 0xff);
        if (id < 0 || id > 1 || seq != next[id]) return 0;  /* Validate source and order. */
        next[id]++;
        count[id]++;
    }
    return count[0] == 4 && count[1] == 4;
}

static void case2_two_producers( void )
{
    HANDLE p[2];
    DWORD rc[2] = { 9, 9 };

    drop_pending();
    reset_deliv();
    g_start = CreateEventA( NULL, TRUE, FALSE, NULL );
    p[0] = CreateThread( NULL, 0, producer_thread, (LPVOID)0, 0, NULL );
    p[1] = CreateThread( NULL, 0, producer_thread, (LPVOID)1, 0, NULL );
    if (!g_start || !p[0] || !p[1])
    {
        g_fail++;
        P( "FAIL case2-per-producer-fifo: setup failed (lasterr %u)\n", (UINT)GetLastError() );
        if (p[0]) CloseHandle( p[0] );
        if (p[1]) CloseHandle( p[1] );
        if (g_start) CloseHandle( g_start );
        return;
    }

    SetEvent( g_start );
    drain_until( 8, 8000 );
    WaitForMultipleObjects( 2, p, TRUE, 5000 );
    GetExitCodeThread( p[0], &rc[0] );
    GetExitCodeThread( p[1], &rc[1] );

    print_order( "case2" );
    P( "info case2 producer-exit rc=%lu,%lu\n", rc[0], rc[1] );
    CHECK( rc[0] == 0 && rc[1] == 0, "case2-producers-queued-all" );
    CHECK( g_ndeliv == 8, "case2-all-delivered" );
    CHECK( per_producer_order_ok(), "case2-per-producer-fifo" );

    CloseHandle( p[0] );
    CloseHandle( p[1] );
    CloseHandle( g_start );
}

/* Case 3 checks self-queued APC delivery through NtTestAlert.
 * GetCurrentThread() refers to the calling thread. OpenThread() supplies a
 * transferable handle, which matches the form used by APC consumers. */
static void case3_testalert( void )
{
    static const ULONG_PTR exp[4] = { 0x30, 0x31, 0x32, 0x33 };
    LONG st;
    DWORD after;
    int i;

    drop_pending();
    reset_deliv();
    for (i = 0; i < 4; i++)
        if (!QueueUserAPC( apc_record, g_self, exp[i] )) break;
    if (i < 4)
    {
        g_fail++;
        P( "FAIL case3-nttestalert: QueueUserAPC #%d failed (lasterr %u)\n", i, (UINT)GetLastError() );
        return;
    }

    st = NtTestAlert();
    after = SleepEx( 0, TRUE );

    print_order( "case3" );
    P( "info case3 NtTestAlert-status=%08x SleepEx-after=%lx\n", (UINT)st, after );
    CHECK( g_ndeliv == 4, "case3-nttestalert-drains-all" );
    CHECK( order_is( exp, 4 ), "case3-nttestalert-fifo" );
    CHECK( after == 0, "case3-queue-empty-after" );
}

/* Case 4 compares APC delivery in regular and alertable waits. */
static void case4_alertable_discipline( void )
{
    DWORD r1, r2;

    drop_pending();
    reset_deliv();
    if (!QueueUserAPC( apc_record, g_self, 0x51 ))
    {
        g_fail++;
        P( "FAIL case4-alertable-gating: QueueUserAPC failed (lasterr %u)\n", (UINT)GetLastError() );
        return;
    }
    r1 = SleepEx( 0, FALSE );  /* The regular wait keeps delivery queued. */
    CHECK( r1 == 0 && g_ndeliv == 0, "case4-nonalertable-skips-apc" );
    r2 = SleepEx( 0, TRUE );   /* The alertable wait runs the delivery. */
    print_order( "case4" );
    P( "info case4 nonalert-ret=%lx alert-ret=%lx\n", r1, r2 );
    CHECK( r2 == WAIT_IO_COMPLETION && g_ndeliv == 1 && g_deliv[0] == 0x51,
           "case4-alertable-delivers" );
}

/* Case 5 checks FIFO order for input and output completion APCs.
 * The 100 ms steps establish queue order after each pipe operation. The final
 * assertion checks the order recorded during the drain. */
static DWORD g_io_err[2];
static DWORD g_io_len[2];

static void CALLBACK write_done( DWORD err, DWORD bytes, LPOVERLAPPED ov )
{
    (void)ov;
    g_io_err[0] = err;
    g_io_len[0] = bytes;
    apc_record( 0x22 );
}

static void CALLBACK read_done( DWORD err, DWORD bytes, LPOVERLAPPED ov )
{
    (void)ov;
    g_io_err[1] = err;
    g_io_len[1] = bytes;
    apc_record( 0x33 );
}

static void case5_io_completion_order( void )
{
    static const ULONG_PTR exp[4] = { 0x11, 0x22, 0x33, 0x44 };
    char name[64], wbuf[2] = { 'a', 'b' }, rbuf[4];
    HANDLE srv, cli;
    OVERLAPPED wov, rov;

    drop_pending();
    reset_deliv();

    wsprintfA( name, "\\\\.\\pipe\\apcprobe_io_%u", (UINT)GetCurrentProcessId() );
    srv = CreateNamedPipeA( name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
                            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 4096, 4096, 0, NULL );
    if (srv == INVALID_HANDLE_VALUE) { SKIP( "case5-io-order", "CreateNamedPipeA failed" ); return; }
    cli = CreateFileA( name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                       FILE_FLAG_OVERLAPPED, NULL );
    if (cli == INVALID_HANDLE_VALUE)
    {
        CloseHandle( srv );
        SKIP( "case5-io-order", "CreateFileA(client) failed" );
        return;
    }

    ZeroMemory( &wov, sizeof wov );
    ZeroMemory( &rov, sizeof rov );

    if (!QueueUserAPC( apc_record, g_self, 0x11 ))
    {
        g_fail++;
        P( "FAIL case5-io-order: QueueUserAPC failed (lasterr %u)\n", (UINT)GetLastError() );
    }
    else if (!WriteFileEx( cli, wbuf, 2, &wov, write_done ))
    {
        SKIP( "case5-io-order", "WriteFileEx failed" );
    }
    else
    {
        Sleep( 100 );  /* Let the write completion APC enter the queue. */
        if (!ReadFileEx( srv, rbuf, 2, &rov, read_done ))
        {
            SKIP( "case5-io-order", "ReadFileEx failed" );
        }
        else
        {
            Sleep( 100 );  /* Queue the read completion APC before payload 0x44. */
            if (!QueueUserAPC( apc_record, g_self, 0x44 ))
            {
                g_fail++;
                P( "FAIL case5-io-order: QueueUserAPC(D) failed (lasterr %u)\n", (UINT)GetLastError() );
            }
            else
            {
                drain_until( 4, 8000 );
                print_order( "case5" );
                P( "info case5 write err=%lu bytes=%lu read err=%lu bytes=%lu\n",
                   g_io_err[0], g_io_len[0], g_io_err[1], g_io_len[1] );
                CHECK( g_ndeliv == 4, "case5-io-all-delivered" );
                if (g_relaxed)
                    CHECK( pos_of( 0x11 ) >= 0 && pos_of( 0x44 ) > pos_of( 0x11 ) &&
                           pos_of( 0x22 ) >= 0 && pos_of( 0x33 ) > pos_of( 0x22 ),
                           "case5-io-relaxed-per-class-fifo" );
                else
                    CHECK( order_is( exp, 4 ), "case5-io-fifo-issue-order" );
            }
        }
    }
    CloseHandle( cli );
    CloseHandle( srv );
}

/* Case 6 checks special user APC delivery and Wine FIFO order.
 * Windows gives special APCs earlier service. Wine adds them to its shared
 * user queue and delivers them at alertable points. The probe checks Wine's
 * current order against normal APCs. */
static void case6_special_apc( void )
{
    static const ULONG_PTR exp[3] = { 0x61, 0x62, 0x63 };
    LONG st;

    drop_pending();
    reset_deliv();
    if (!QueueUserAPC( apc_record, g_self, 0x61 ))
    {
        g_fail++;
        P( "FAIL case6-special-apc: QueueUserAPC(before) failed (lasterr %u)\n", (UINT)GetLastError() );
        return;
    }
    st = NtQueueApcThreadEx2( g_self, NULL, QUEUE_USER_APC_FLAGS_SPECIAL_USER_APC,
                              apc_record3, 0x62, 0, 0 );
    if (st)
    {
        g_fail++;
        P( "FAIL case6-special-apc: NtQueueApcThreadEx2 status=%08x\n", (UINT)st );
        drop_pending();
        return;
    }
    if (!QueueUserAPC( apc_record, g_self, 0x63 ))
    {
        g_fail++;
        P( "FAIL case6-special-apc: QueueUserAPC(after) failed (lasterr %u)\n", (UINT)GetLastError() );
        return;
    }

    drain_until( 3, 5000 );

    print_order( "case6" );
    CHECK( g_ndeliv == 3, "case6-special-delivered-at-alertable-wait" );
    if (g_relaxed)
        CHECK( pos_of( 0x61 ) >= 0 && pos_of( 0x63 ) > pos_of( 0x61 ) && pos_of( 0x62 ) >= 0,
               "case6-special-relaxed-normal-fifo" );
    else
        CHECK( order_is( exp, 3 ), "case6-special-fifo-position" );
}

/* Case 7 checks a recycled thread handle.
 * Wineserver can reuse a freed handle value for a replacement thread. The
 * queued payload must reach the replacement thread. The original thread keeps
 * its earlier priming payload. */
static HANDLE g_c7_ready;
static HANDLE g_c7_done;
static HANDLE g_c7_exit_a, g_c7_exit_b;
static volatile LONG g_c7_tag;
static volatile LONG g_c7_tid;

static void CALLBACK apc_record_tid( ULONG_PTR data )
{
    InterlockedExchange( &g_c7_tag, (LONG)data );
    InterlockedExchange( &g_c7_tid, (LONG)GetCurrentThreadId() );
    if (data == 0x77) SetEvent( g_c7_done );
}

static DWORD WINAPI c7_idle_thread( LPVOID arg )
{
    DWORD ret;

    SetEvent( g_c7_ready );
    /* An APC makes an alertable wait return WAIT_IO_COMPLETION. The loop keeps
       thread A alive for the later handle-reuse assertion. */
    do ret = WaitForSingleObjectEx( (HANDLE)arg, INFINITE, TRUE );
    while (ret == WAIT_IO_COMPLETION);
    return 0;
}

static void case7_recycled_handle( void )
{
    HANDLE hA, hB = NULL, spare[32];
    DWORD tidA, tidB = 0;
    int i, nspare = 0, reused = -1;

    g_c7_ready = CreateEventA( NULL, TRUE, FALSE, NULL );
    g_c7_done = CreateEventA( NULL, FALSE, FALSE, NULL );
    g_c7_exit_a = CreateEventA( NULL, TRUE, FALSE, NULL );
    g_c7_exit_b = CreateEventA( NULL, TRUE, FALSE, NULL );
    hA = g_c7_ready && g_c7_done && g_c7_exit_a && g_c7_exit_b
         ? CreateThread( NULL, 0, c7_idle_thread, g_c7_exit_a, 0, &tidA ) : NULL;
    if (!hA)
    {
        g_fail++;
        P( "FAIL case7-recycled-handle: setup failed (lasterr %u)\n", (UINT)GetLastError() );
        goto out;
    }
    if (WaitForSingleObject( g_c7_ready, 5000 ) != WAIT_OBJECT_0)
    {
        g_fail++;
        P( "FAIL case7-recycled-handle: thread A never signalled ready\n" );
        CloseHandle( hA );
        goto out;
    }

    /* Queue one priming APC through hA. The delivery confirms that hA targets
       thread A. The wait loop keeps thread A alive while Wine reuses the
       handle value. */
    if (!QueueUserAPC( apc_record_tid, hA, 0x70 ))
        P( "info case7 priming QueueUserAPC failed (lasterr %u)\n", (UINT)GetLastError() );
    Sleep( 200 );  /* Let thread A run the priming APC. */
    CloseHandle( hA );

    /* Create replacement threads until Wine reuses the freed handle slot. */
    for (i = 0; i < 32; i++)
    {
        HANDLE h = CreateThread( NULL, 0, c7_idle_thread, g_c7_exit_b, CREATE_SUSPENDED, &tidB );
        if (!h) break;
        if (h == hA) { hB = h; reused = i; break; }
        spare[nspare++] = h;  /* Resume the spare threads together below. */
    }
    if (!hB)
    {
        SKIP( "case7-recycled-handle", "handle value was not recycled" );
        goto resume_spares;
    }

    ResetEvent( g_c7_ready );
    ResumeThread( hB );
    if (WaitForSingleObject( g_c7_ready, 5000 ) != WAIT_OBJECT_0)
    {
        g_fail++;
        P( "FAIL case7-recycled-handle: thread B never signalled ready\n" );
        goto resume_spares;
    }
    Sleep( 100 );  /* Place thread B in its alertable wait. */

    InterlockedExchange( &g_c7_tag, 0 );
    InterlockedExchange( &g_c7_tid, 0 );
    if (!QueueUserAPC( apc_record_tid, hB, 0x77 ))
    {
        g_fail++;
        P( "FAIL case7-recycled-handle: QueueUserAPC failed (lasterr %u)\n", (UINT)GetLastError() );
        goto resume_spares;
    }
    CHECK( WaitForSingleObject( g_c7_done, 5000 ) == WAIT_OBJECT_0,
           "case7-recycled-handle-delivers" );
    P( "info case7 handle recycled on attempt %d, tidA=%lu tidB=%lu delivered-to=%ld\n",
       reused, tidA, tidB, g_c7_tid );
    CHECK( g_c7_tid == (LONG)tidB, "case7-recycled-handle-hits-new-thread" );
    CHECK( g_c7_tid != (LONG)tidA, "case7-recycled-handle-misses-old-thread" );

resume_spares:
    for (i = 0; i < nspare; i++) ResumeThread( spare[i] );
    SetEvent( g_c7_exit_a );
    SetEvent( g_c7_exit_b );
    if (hB) { WaitForSingleObject( hB, 5000 ); CloseHandle( hB ); }
    for (i = 0; i < nspare; i++) { WaitForSingleObject( spare[i], 5000 ); CloseHandle( spare[i] ); }
out:
    if (g_c7_ready) CloseHandle( g_c7_ready );
    if (g_c7_done) CloseHandle( g_c7_done );
    if (g_c7_exit_a) CloseHandle( g_c7_exit_a );
    if (g_c7_exit_b) CloseHandle( g_c7_exit_b );
}

/* Case 8 checks progress while suspend and resume calls repeat.
 * SIGUSR1 can interrupt the NTSync kernel wait. The patch uses Wine's existing
 * EINTR retry path. The test requires progress from the waiter and queuer. */
static volatile LONG g_c8_stop;
static volatile LONG g_c8_waits;
static volatile LONG g_c8_queued;
static volatile LONG g_c8_deliv;

static void CALLBACK apc_c8_noop( ULONG_PTR data )
{
    (void)data;
    InterlockedIncrement( &g_c8_deliv );
}

static DWORD WINAPI c8_worker( LPVOID arg )
{
    (void)arg;
    while (!g_c8_stop)
    {
        SleepEx( 1, TRUE );
        InterlockedIncrement( &g_c8_waits );
    }
    return 0;
}

static DWORD WINAPI c8_queuer( LPVOID arg )
{
    HANDLE target = (HANDLE)arg;
    while (!g_c8_stop)
    {
        if (QueueUserAPC( apc_c8_noop, target, 0 ))
            InterlockedIncrement( &g_c8_queued );
        if (g_c8_queued - g_c8_deliv > 4096) Sleep( 1 );  /* Keep backlog within 4096. */
    }
    return 0;
}

static DWORD WINAPI c8_hammer( LPVOID arg )
{
    HANDLE target = (HANDLE)arg;
    while (!g_c8_stop)
    {
        if (SuspendThread( target ) != (DWORD)-1) ResumeThread( target );
        Sleep( 0 );
    }
    return 0;
}

static void case8_suspend_hammer( void )
{
    HANDLE w, q, s;
    LONG delivered0, queued0;

    g_c8_stop = 0;
    w = CreateThread( NULL, 0, c8_worker, NULL, 0, NULL );
    if (!w)
    {
        g_fail++;
        P( "FAIL case8-suspend-hammer: worker setup failed (lasterr %u)\n", (UINT)GetLastError() );
        return;
    }
    q = CreateThread( NULL, 0, c8_queuer, w, 0, NULL );
    s = CreateThread( NULL, 0, c8_hammer, w, 0, NULL );
    if (!q || !s)
    {
        g_fail++;
        P( "FAIL case8-suspend-hammer: setup failed (lasterr %u)\n", (UINT)GetLastError() );
    }
    else
    {
        Sleep( 500 );  /* Start the queue and wait cycle. */
        delivered0 = g_c8_deliv;
        queued0 = g_c8_queued;
        Sleep( 3000 );  /* Repeat suspend and resume for 3 seconds. */
        /* A full APC queue can keep one SleepEx call returning
           WAIT_IO_COMPLETION. Delivery and queue counts show progress from
           both threads. */
        CHECK( g_c8_deliv > delivered0, "case8-waiter-progresses" );
        CHECK( g_c8_queued > queued0, "case8-queuer-progresses" );
    }
    InterlockedExchange( &g_c8_stop, 1 );
    if (q) CHECK( WaitForSingleObject( q, 10000 ) == WAIT_OBJECT_0, "case8-queuer-joins" );
    if (s) CHECK( WaitForSingleObject( s, 10000 ) == WAIT_OBJECT_0, "case8-hammer-joins" );
    CHECK( WaitForSingleObject( w, 10000 ) == WAIT_OBJECT_0, "case8-worker-joins" );
    P( "info case8 waits=%ld queued=%ld delivered=%ld\n",
       g_c8_waits, g_c8_queued, g_c8_deliv );
    if (q) CloseHandle( q );
    if (s) CloseHandle( s );
    CloseHandle( w );
}

/* Case 9 checks server access results for 3 thread handles.
 * eligible adds query access to THREAD_SET_CONTEXT. set_only uses the Windows
 * minimum. denied provides query access. The first calls record
 * STATUS_ACCESS_DENIED and ERROR_ACCESS_DENIED. Payload 0x92 marks the order
 * boundary for earlier payload 0x91.
 * set_only confirms the minimum right through the server route.
 * performance/0001 keeps QueueUserAPC routing in wineserver. */
static HANDLE g_c9_ready, g_c9_done, g_c9_exit;

static void CALLBACK apc_c9_record( ULONG_PTR data )
{
    apc_record( data );
    if (data == 0x92 || data == 0x93) SetEvent( g_c9_done );
}

static DWORD WINAPI c9_waiter( LPVOID arg )
{
    DWORD ret;

    (void)arg;
    SetEvent( g_c9_ready );
    do ret = WaitForSingleObjectEx( g_c9_exit, INFINITE, TRUE );
    while (ret == WAIT_IO_COMPLETION);
    return 0;
}

static void case9_restricted_handles( void )
{
    HANDLE thread = NULL, eligible = NULL, set_only = NULL, denied = NULL;
    HANDLE process = GetCurrentProcess();
    DWORD queued, err = ERROR_SUCCESS;
    LONG status;

    drop_pending();
    reset_deliv();
    g_c9_ready = CreateEventA( NULL, TRUE, FALSE, NULL );
    g_c9_done  = CreateEventA( NULL, TRUE, FALSE, NULL );
    g_c9_exit  = CreateEventA( NULL, TRUE, FALSE, NULL );
    if (g_c9_ready && g_c9_done && g_c9_exit)
        thread = CreateThread( NULL, 0, c9_waiter, NULL, 0, NULL );
    if (!thread || WaitForSingleObject( g_c9_ready, 5000 ) != WAIT_OBJECT_0)
    {
        g_fail++;
        P( "FAIL case9-restricted-handles: waiter setup failed (lasterr %u)\n",
           (UINT)GetLastError() );
        goto out;
    }

    if (!DuplicateHandle( process, thread, process, &eligible,
                          THREAD_SET_CONTEXT | THREAD_QUERY_LIMITED_INFORMATION,
                          FALSE, 0 ) ||
        !DuplicateHandle( process, thread, process, &set_only,
                          THREAD_SET_CONTEXT, FALSE, 0 ) ||
        !DuplicateHandle( process, thread, process, &denied,
                          THREAD_QUERY_LIMITED_INFORMATION, FALSE, 0 ))
    {
        g_fail++;
        P( "FAIL case9-restricted-handles: DuplicateHandle failed (lasterr %u)\n",
           (UINT)GetLastError() );
        goto out;
    }

    status = NtQueueApcThreadEx2( denied, NULL, 0, apc_record3, 0x91, 0, 0 );
    CHECK( status == STATUS_ACCESS_DENIED,
           "case9-query-only-native-status-access-denied" );

    SetLastError( 0xdeadbeef );
    queued = QueueUserAPC( apc_c9_record, denied, 0x91 );
    err = GetLastError();
    CHECK( queued == 0, "case9-query-only-queueuserapc-rejected" );
    CHECK( err == ERROR_ACCESS_DENIED, "case9-query-only-win32-access-denied" );

    queued = QueueUserAPC( apc_c9_record, eligible, 0x92 );
    CHECK( queued != 0, "case9-set-query-handle-accepted" );
    if (queued)
        CHECK( WaitForSingleObject( g_c9_done, 5000 ) == WAIT_OBJECT_0,
               "case9-allowed-apc-delivered" );

    print_order( "case9" );
    CHECK( g_ndeliv == 1 && g_deliv[0] == 0x92,
           "case9-denied-handle-never-delivers" );

    reset_deliv();
    ResetEvent( g_c9_done );
    queued = QueueUserAPC( apc_c9_record, set_only, 0x93 );
    CHECK( queued != 0, "case9-set-context-only-handle-accepted" );
    if (queued)
        CHECK( WaitForSingleObject( g_c9_done, 5000 ) == WAIT_OBJECT_0,
               "case9-set-context-only-apc-delivered" );
    print_order( "case9-set-only" );
    CHECK( g_ndeliv == 1 && g_deliv[0] == 0x93,
           "case9-set-context-only-access-exact" );

out:
    if (g_c9_exit) SetEvent( g_c9_exit );
    if (thread)
    {
        if (WaitForSingleObject( thread, 5000 ) != WAIT_OBJECT_0)
        {
            g_fail++;
            P( "FAIL case9-restricted-handles: waiter did not exit\n" );
            TerminateThread( thread, 0 );
            WaitForSingleObject( thread, 5000 );
        }
        CloseHandle( thread );
    }
    if (eligible) CloseHandle( eligible );
    if (set_only) CloseHandle( set_only );
    if (denied) CloseHandle( denied );
    if (g_c9_ready) CloseHandle( g_c9_ready );
    if (g_c9_done) CloseHandle( g_c9_done );
    if (g_c9_exit) CloseHandle( g_c9_exit );
    g_c9_ready = g_c9_done = g_c9_exit = NULL;
}

/* Case 10 checks strict FIFO across normal and special APCs.
 * A regular wait keeps all 3 APCs queued before release. The release gives a
 * direct order check. performance/0001 changes the wait route. Wineserver
 * retains normal and special APC routing. */
static HANDLE g_c10_ready, g_c10_release;

static DWORD WINAPI c10_waiter( LPVOID arg )
{
    (void)arg;
    SetEvent( g_c10_ready );
    if (WaitForSingleObject( g_c10_release, 5000 ) != WAIT_OBJECT_0) return 1;
    return drain_until( 3, 8000 ) == 3 ? 0 : 2;
}

static void case10_route_transition_fifo( void )
{
    static const ULONG_PTR exp[3] = { 0xa1, 0xa2, 0xa3 };
    HANDLE thread = NULL;
    DWORD exit_code = 9;
    LONG status;
    BOOL queued_a = FALSE, queued_c = FALSE;

    drop_pending();
    reset_deliv();
    g_c10_ready   = CreateEventA( NULL, TRUE, FALSE, NULL );
    g_c10_release = CreateEventA( NULL, TRUE, FALSE, NULL );
    if (g_c10_ready && g_c10_release)
        thread = CreateThread( NULL, 0, c10_waiter, NULL, 0, NULL );
    if (!thread || WaitForSingleObject( g_c10_ready, 5000 ) != WAIT_OBJECT_0)
    {
        g_fail++;
        P( "FAIL case10-route-transition: waiter setup failed (lasterr %u)\n",
           (UINT)GetLastError() );
        goto out;
    }

    queued_a = QueueUserAPC( apc_record, thread, 0xa1 ) != 0;
    status = NtQueueApcThreadEx2( thread, NULL, QUEUE_USER_APC_FLAGS_SPECIAL_USER_APC,
                                  apc_record3, 0xa2, 0, 0 );
    queued_c = QueueUserAPC( apc_record, thread, 0xa3 ) != 0;
    CHECK( queued_a, "case10-first-normal-apc-queued" );
    CHECK( status == 0, "case10-server-route-special-apc-queued" );
    CHECK( queued_c, "case10-post-transition-apc-queued" );

    SetEvent( g_c10_release );
    if (WaitForSingleObject( thread, 12000 ) == WAIT_OBJECT_0)
        GetExitCodeThread( thread, &exit_code );
    else
    {
        g_fail++;
        P( "FAIL case10-route-transition: waiter stuck (delivered %ld/3)\n", g_ndeliv );
    }

    print_order( "case10" );
    CHECK( exit_code == 0 && g_ndeliv == 3, "case10-all-routes-delivered" );
    CHECK( order_is( exp, 3 ), "case10-strict-normal-special-fifo" );

out:
    if (g_c10_release) SetEvent( g_c10_release );
    if (thread)
    {
        if (WaitForSingleObject( thread, 0 ) == WAIT_TIMEOUT)
        {
            TerminateThread( thread, 0 );
            WaitForSingleObject( thread, 5000 );
        }
        CloseHandle( thread );
    }
    if (g_c10_ready) CloseHandle( g_c10_ready );
    if (g_c10_release) CloseHandle( g_c10_release );
    g_c10_ready = g_c10_release = NULL;
}

/* Case 11 checks a user APC wake from an infinite alertable delay. */
static HANDLE g_c11_ready;

static DWORD WINAPI c11_waiter( LPVOID arg )
{
    (void)arg;
    SetEvent( g_c11_ready );
    return SleepEx( INFINITE, TRUE );
}

static void case11_infinite_alertable_wake( void )
{
    HANDLE thread = NULL;
    DWORD exit_code = 9;
    BOOL queued = FALSE;

    drop_pending();
    reset_deliv();
    g_c11_ready = CreateEventA( NULL, TRUE, FALSE, NULL );
    if (g_c11_ready) thread = CreateThread( NULL, 0, c11_waiter, NULL, 0, NULL );
    if (!thread || WaitForSingleObject( g_c11_ready, 5000 ) != WAIT_OBJECT_0)
    {
        g_fail++;
        P( "FAIL case11-infinite-alertable: setup failed (lasterr %u)\n", (UINT)GetLastError() );
        goto out;
    }

    Sleep( 50 );  /* Place the target in the infinite wait. */
    queued = QueueUserAPC( apc_record, thread, 0xb1 ) != 0;
    CHECK( queued, "case11-infinite-apc-queued" );
    if (queued && WaitForSingleObject( thread, 5000 ) == WAIT_OBJECT_0)
        GetExitCodeThread( thread, &exit_code );
    else
    {
        g_fail++;
        P( "FAIL case11-infinite-alertable: waiter did not wake\n" );
    }

    print_order( "case11" );
    CHECK( exit_code == WAIT_IO_COMPLETION, "case11-infinite-returns-io-completion" );
    CHECK( g_ndeliv == 1 && g_deliv[0] == 0xb1, "case11-infinite-delivers-apc" );

out:
    if (thread)
    {
        if (WaitForSingleObject( thread, 0 ) == WAIT_TIMEOUT)
        {
            TerminateThread( thread, 0 );
            WaitForSingleObject( thread, 5000 );
        }
        CloseHandle( thread );
    }
    if (g_c11_ready) CloseHandle( g_c11_ready );
    g_c11_ready = NULL;
}

void mainCRTStartup( void )
{
    g_out = CreateFileA( "apcprobe.txt", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    if (g_out == INVALID_HANDLE_VALUE) g_out = NULL;
    g_con = GetStdHandle( STD_OUTPUT_HANDLE );
    if (g_con == INVALID_HANDLE_VALUE) g_con = NULL;

    g_relaxed = cmdline_has( "--relaxed-fifo" );
    P( "apcprobe: retained NTSync alertable-delay semantics%s\n",
       g_relaxed ? " [legacy relaxed-fifo diagnostic mode]" : " [strict fifo mode]" );

    g_self = OpenThread( THREAD_ALL_ACCESS, FALSE, GetCurrentThreadId() );
    if (!g_self)
    {
        g_fail++;
        P( "FAIL setup-open-self: OpenThread failed (lasterr %u)\n", (UINT)GetLastError() );
    }
    else
    {
        case0_delay_contracts();
        case1_fifo();
        case2_two_producers();
        case3_testalert();
        case4_alertable_discipline();
        case5_io_completion_order();
        case6_special_apc();
        case7_recycled_handle();
        case8_suspend_hammer();
        case9_restricted_handles();
        case10_route_transition_fifo();
        case11_infinite_alertable_wake();
        CloseHandle( g_self );
    }

    P( "SUMMARY pass=%d fail=%d skip=%d\n", g_pass, g_fail, g_skip );
    if (g_out) CloseHandle( g_out );
    ExitProcess( g_fail );
}
