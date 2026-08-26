/* apcprobe.c: pin down the alertable-delay and user-APC semantics that
 * performance/0001 must preserve (PE, CRT-free).
 *
 * The retained patch changes only NtDelayExecution(alertable=TRUE): a
 * zero-handle delay waits on the calling thread's existing NTSync alert event,
 * then uses the ordinary wineserver drain when it wakes. It does not change
 * APC queueing or routing. The focused cases below cover zero, finite,
 * absolute, and infinite alertable delays. The older APC FIFO/access/lifetime
 * cases remain as defense-in-depth around the drain, but success there is not
 * evidence for any rejected same-process APC queue proposal.
 *
 * What it pins down:
 *   case0  no-APC zero, relative finite, and absolute finite delay contracts
 *   case1  FIFO delivery of 8 user APCs into another thread's alertable wait
 *   case2  per-producer FIFO with two racing producer threads (cross-producer
 *          interleave intentionally NOT asserted, racy by design)
 *   case3  NtTestAlert drains all self-queued APCs (via the dispatcher's
 *          NtContinueEx TEST_ALERT chain) and leaves the queue empty
 *   case4  alertability discipline: a non-alertable wait must not deliver,
 *          an alertable zero-timeout wait must
 *   case5  ReadFileEx/WriteFileEx completion routines are user APCs and drain
 *          from the same FIFO as QueueUserAPC, in issue order (reports SKIP,
 *          not FAIL, if the overlapped pipe setup fails)
 *   case6  NtQueueApcThreadEx2 QUEUE_USER_APC_FLAGS_SPECIAL_USER_APC is
 *          delivered at alertable points and keeps its FIFO position against
 *          normal APCs (Wine behaviour: one shared FIFO user queue)
 *   case7  a closed thread handle recycled by CreateThread for a different
 *          thread must resolve to the NEW thread (wineserver hands a freed
 *          handle slot straight back; retained as baseline coverage for the
 *          rejected client-side handle-cache proposal)
 *   case8  a SuspendThread/ResumeThread hammer against an alertable waiter
 *          and its queuer must not wedge either side (SIGUSR1 interrupts the
 *          retained NTSync wait and exercises linux_wait_objs' EINTR handling)
 *   case9  handles with and without THREAD_SET_CONTEXT retain the server's
 *          exact access checks; a query-only handle cannot smuggle an APC
 *          through any future client-side route (legacy rejected coverage)
 *   case10 a normal APC, synchronously server-routed special APC, then another
 *          normal APC retain strict FIFO (legacy rejected-routing coverage)
 *   case11 an infinite alertable delay wakes only after a queued user APC
 *
 * --relaxed-fifo remains only as a diagnostic mode for the legacy FIFO cases;
 * it does not relax any focused alertable-delay assertion.
 *
 * output: apcprobe.txt in cwd (also mirrored to stdout), "PASS"/"FAIL"/
 * "SKIP"/"info" lines + SUMMARY. exit code: number of failed assertions
 * (0 = pass). All waits are bounded; timeouts are FAILs with diagnostics.
 *
 * build: build_apcprobe.sh (this dir), then run inside the Ableton prefix:
 *   tools/run_in_prefix.sh apcprobe.exe
 */
#include <windows.h>

/* ntdll entries used directly; declared manually per probe convention
 * (avoids pulling in winternl.h; LONG is NTSTATUS, which bare windows.h
 * does not define). */
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

/* ---- shared delivery recorder: callbacks append their payload here ------- */
#define MAX_DELIV 32
static volatile LONG g_ndeliv;
static ULONG_PTR     g_deliv[MAX_DELIV];

static void CALLBACK apc_record( ULONG_PTR data )
{
    LONG i = InterlockedIncrement( &g_ndeliv );
    if (i >= 1 && i <= MAX_DELIV) g_deliv[i - 1] = data;
}

/* 3-arg variant for NtQueueApcThreadEx2 (PNTAPCFUNC signature) */
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

/* index of a payload in the delivery record, or -1 */
static LONG pos_of( ULONG_PTR v )
{
    LONG i, n = g_ndeliv;
    if (n > MAX_DELIV) n = MAX_DELIV;
    for (i = 0; i < n; i++) if (g_deliv[i] == v) return i;
    return -1;
}

/* CRT-free substring scan for the --relaxed-fifo command-line flag */
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

/* alertable-wait until target APCs have been delivered or the budget is spent */
static LONG drain_until( LONG target, DWORD budget_ms )
{
    DWORD t0 = GetTickCount();
    while (g_ndeliv < target && GetTickCount() - t0 < budget_ms)
        SleepEx( 1000, TRUE );
    return g_ndeliv;
}

/* drop anything left in this thread's queue between cases (bounded: a
 * zero-timeout alertable sleep returns 0 once the queue is empty) */
static void drop_pending( void )
{
    int i;
    for (i = 0; i < 64 && SleepEx( 0, TRUE ) == WAIT_IO_COMPLETION; i++) {}
}

/* ---- case 0: direct contracts of the retained alertable-delay path -------- */
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

/* ---- case 1: FIFO delivery into another thread's alertable wait ---------- */
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
        Sleep( 100 );  /* bias: waiter already blocked in the alertable wait, so
                          APC #1 must wake it through the alert-event path */
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
    if (WaitForSingleObject( b, 0 ) == WAIT_TIMEOUT)  /* don't leave a stuck waiter */
    {
        TerminateThread( b, 0 );
        WaitForSingleObject( b, 5000 );
    }
    CloseHandle( b );
    CloseHandle( g_ready );
}

/* ---- case 2: per-producer FIFO with two racing producers ----------------- */
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
        if (id < 0 || id > 1 || seq != next[id]) return 0;  /* foreign payload or reorder */
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

/* ---- case 3: self-queue + NtTestAlert drains the whole queue -------------
 * GetCurrentThread() is a pseudo-handle: it always means *the calling
 * thread*, so it happens to work for self-targeted QueueUserAPC on Wine
 * (dlls/kernel32/tests/pipe.c relies on that), but it cannot be handed to
 * another thread and is not what real APC consumers hold. OpenThread()
 * returns a real handle to self; that is what this probe exercises. */
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

/* ---- case 4: alertability discipline ------------------------------------- */
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
    r1 = SleepEx( 0, FALSE );  /* non-alertable: must NOT deliver */
    CHECK( r1 == 0 && g_ndeliv == 0, "case4-nonalertable-skips-apc" );
    r2 = SleepEx( 0, TRUE );   /* alertable: must deliver */
    print_order( "case4" );
    P( "info case4 nonalert-ret=%lx alert-ret=%lx\n", r1, r2 );
    CHECK( r2 == WAIT_IO_COMPLETION && g_ndeliv == 1 && g_deliv[0] == 0x51,
           "case4-alertable-delivers" );
}

/* ---- case 5: I/O completion routines share the user-APC FIFO -------------
 * The Sleep(100) barriers after each I/O only order the *queueing* of the
 * completion APCs (the write completes as soon as the bytes hit the pipe
 * buffer; the read then completes at once). The assertion itself is the
 * drained order, not any timing. */
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
        Sleep( 100 );  /* let the write completion APC land in the queue */
        if (!ReadFileEx( srv, rbuf, 2, &rov, read_done ))
        {
            SKIP( "case5-io-order", "ReadFileEx failed" );
        }
        else
        {
            Sleep( 100 );  /* let the read completion APC land before queueing 0x44 */
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

/* ---- case 6: special user APC delivery + ordering -------------------------
 * NtQueueApcThreadEx2 with QUEUE_USER_APC_FLAGS_SPECIAL_USER_APC: native
 * Windows runs special user APCs ahead of normal ones; Wine sets
 * SERVER_USER_APC_SPECIAL but queues onto the same FIFO user queue
 * (server/thread.c:1482 list_add_tail) and delivers at alertable points like
 * a normal APC (the dispatcher only FIXMEs the flag). The pinned Wine
 * behaviour this probe enforces: delivered at the alertable wait, FIFO
 * position preserved against normal APCs. */
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

/* ---- case 7: a recycled thread handle must resolve to the new thread ------
 * wineserver hands a freed handle slot straight back (server/handle.c:
 * alloc_entry starts at table->free), so CloseHandle + CreateThread commonly
 * reuses the same handle value for a different thread. This is authoritative
 * server-routing coverage retained from the rejected client handle-cache
 * experiment: queueing through the recycled handle must reach the NEW thread,
 * never the old one. */
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
    /* An APC makes an alertable wait return WAIT_IO_COMPLETION. Keep the
       original thread alive until its exit event is signalled; otherwise the
       priming APC would terminate it before the handle-reuse assertion. */
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

    /* Queue once through hA before closing it. This primed the rejected
       experiment's client-side cache; on the retained server route it simply
       establishes the same handle-lifetime sequence for baseline comparison.
       Thread A stays alive in its alertable-wait loop while hA is recycled. */
    if (!QueueUserAPC( apc_record_tid, hA, 0x70 ))
        P( "info case7 priming QueueUserAPC failed (lasterr %u)\n", (UINT)GetLastError() );
    Sleep( 200 );  /* let the priming APC run on A */
    CloseHandle( hA );

    /* the first CreateThread after the close reuses the freed slot; retry a
       few times in case something else grabs it first */
    for (i = 0; i < 32; i++)
    {
        HANDLE h = CreateThread( NULL, 0, c7_idle_thread, g_c7_exit_b, CREATE_SUSPENDED, &tidB );
        if (!h) break;
        if (h == hA) { hB = h; reused = i; break; }
        spare[nspare++] = h;  /* still suspended; mass-resumed below */
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
    Sleep( 100 );  /* bias: B blocked in its alertable wait */

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

/* ---- case 8: suspend/resume hammer must not wedge the APC machinery -------
 * SIGUSR1 (SuspendThread, or a system APC queued to a thread not already in
 * an APC wait) can interrupt the retained NTSync ioctl. The retained patch
 * deliberately reuses linux_wait_objs(), including its EINTR retry. The old
 * apc_mutex-specific deadlock rationale belonged to the rejected client APC
 * queue; this branch introduces no such mutex. */
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
        if (g_c8_queued - g_c8_deliv > 4096) Sleep( 1 );  /* bound the backlog */
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
        Sleep( 500 );  /* warm up */
        delivered0 = g_c8_deliv;
        queued0 = g_c8_queued;
        Sleep( 3000 );  /* hammer window */
        /* A continuously non-empty APC queue may keep one SleepEx call
           dispatching callbacks for the whole window, so completed callbacks
           are the reliable proof that the waiter itself is still running. */
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

/* ---- case 9: exact access checks on restricted thread handles -----------
 * The eligible handle has THREAD_SET_CONTEXT plus query access, set_only has
 * the Win32-documented minimum THREAD_SET_CONTEXT access, and denied is
 * query-only. The denied attempts happen first; the eligible APC then acts as
 * a deterministic delivery fence: by the time payload 0x92 runs, any
 * incorrectly accepted earlier payload 0x91 must also have run because both
 * the client and server queues are FIFO. set_only separately proves that a
 * handle with no query access still succeeds through the authoritative server
 * route. This is legacy coverage for the rejected client handle-cache design;
 * performance/0001 does not change QueueUserAPC routing. */
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

/* ---- case 10: strict FIFO across normal and special APCs ------------------
 * The target remains in a non-alertable wait while all three APCs are queued,
 * so no timing sleeps are needed and nothing can drain early. This was the
 * transition test for the rejected client APC queue. In the retained branch
 * performance/0001 changes only the wait: normal and special APC routing stays
 * authoritative in wineserver. Strict FIFO remains useful baseline coverage,
 * but it does not establish safety of a client-side routing proposal. */
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

/* ---- case 11: an infinite alertable delay wakes for a user APC ------------ */
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

    Sleep( 50 );  /* establish that the target is blocked in the infinite wait */
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
