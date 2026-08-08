/* apcprobe.c: pin down the Windows-compatible user APC semantics that the
 * moonshot P5 idle-CPU APC fast path must preserve (PE, CRT-free).
 *
 * Baseline for the same-process APC fast path in
 * notes/ABLETON-WINE-APC-COALESCING.md: today every same-process user APC
 * costs two wineserver round trips (queue + drain) and every alertable sleep
 * or NtTestAlert costs another; the patch moves same-process user APCs onto
 * the per-thread ntsync alert event. This probe MUST PASS on the unpatched
 * build (it records the observable semantics) and must then pass
 * identically on the patched build (no-regression proof).
 *
 * What it pins down:
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
 *          handle slot straight back; the fast path's handle cache forgets a
 *          handle at close)
 *   case8  a SuspendThread/ResumeThread hammer against an alertable waiter
 *          and its queuer must not wedge either side (SIGUSR1 re-enters the
 *          fast path; apc_mutex sections run with signals blocked)
 *
 * For the GetUpdateRect empty-rectangle regression from the same review
 * round, see updateprobe.c (this dir).
 *
 * Two FIFO regimes: with no arguments the probe pins the UNPATCHED strict
 * global FIFO across QueueUserAPC, I/O completion routines and special APCs.
 * The WINE_APC_FASTPATH runtime deliberately relaxes exactly that cross-queue
 * ordering: same-process user APCs drain from a client-side queue before the
 * server-side queue (I/O completions, special APCs), so a server-routed APC
 * queued between two client APCs is delivered after them. Run with
 * --relaxed-fifo on a fastpath-enabled runtime: case5/case6 then assert full
 * delivery plus per-class relative FIFO (client APCs among themselves, I/O
 * completions among themselves) instead of the global interleave order.
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
typedef void (CALLBACK *NTAPCFUNC)( ULONG_PTR, ULONG_PTR, ULONG_PTR );
LONG WINAPI NtTestAlert( void );
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
 * reuses the same handle value for a different thread. The fast path's
 * handle cache must forget a handle at close: queueing through the recycled
 * handle must reach the NEW thread, never the old one. */
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
       priming APC would terminate it and deregistration would erase the stale
       cache entry that this case is meant to expose. */
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

    /* Prime any client-side handle cache with hA -> tidA, then close hA.
       Thread A stays alive in its alertable-wait loop after running this APC,
       so the pre-fix cache entry remains valid by tid/generation and can be
       caught when the handle value is recycled for B. */
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
 * an APC wait) interrupts the target at any point and re-enters the fast
 * path through usr1_handler -> wait_suspend -> server_select. The fast path
 * takes apc_mutex only under server_enter_uninterrupted_section, so a signal
 * frame can never find the mutex held by the interrupted thread; a pre-fix
 * build self-deadlocks here, with queuer and waiter frozen for the life of
 * the process. */
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

void mainCRTStartup( void )
{
    g_out = CreateFileA( "apcprobe.txt", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    if (g_out == INVALID_HANDLE_VALUE) g_out = NULL;
    g_con = GetStdHandle( STD_OUTPUT_HANDLE );
    if (g_con == INVALID_HANDLE_VALUE) g_con = NULL;

    g_relaxed = cmdline_has( "--relaxed-fifo" );
    P( "apcprobe: user APC semantics baseline (the moonshot P5 APC fast path must preserve)%s\n",
       g_relaxed ? " [relaxed-fifo mode: fastpath runtime expected]" : " [strict fifo mode]" );

    g_self = OpenThread( THREAD_ALL_ACCESS, FALSE, GetCurrentThreadId() );
    if (!g_self)
    {
        g_fail++;
        P( "FAIL setup-open-self: OpenThread failed (lasterr %u)\n", (UINT)GetLastError() );
    }
    else
    {
        case1_fifo();
        case2_two_producers();
        case3_testalert();
        case4_alertable_discipline();
        case5_io_completion_order();
        case6_special_apc();
        case7_recycled_handle();
        case8_suspend_hammer();
        CloseHandle( g_self );
    }

    P( "SUMMARY pass=%d fail=%d skip=%d\n", g_pass, g_fail, g_skip );
    if (g_out) CloseHandle( g_out );
    ExitProcess( g_fail );
}
