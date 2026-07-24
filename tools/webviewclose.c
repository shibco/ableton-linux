/* webviewclose.c — reproducer for issue #52 (Live crashes when a WebView2
 * plugin editor closes).
 *
 * Mirrors the anatomy fakeplugin.c established for Live 12's VST3 hosting:
 *  - main window: overlapped, per-monitor-v2 (Live's IFEO dpiAwareness=2)
 *  - "plugin editor" window created while the thread DPI context is UNAWARE
 *    (the VST3-host trick), owned by the main window, WS_CAPTION|WS_SYSMENU
 *    + WS_EX_TOOLWINDOW like Live's Vst3PlugWindow
 * then hosts a windowed-mode WebView2 controller in the editor window and
 * tears it down in a selectable order. A vectored exception handler reports
 * the faulting address and module, so a crash names the guilty DLL instead
 * of dying silently.
 *
 * Usage: webviewclose.exe <variant> [loader.dll path]
 *   variant 'a' — polite: put_IsVisible(FALSE); Close(); Release; DestroyWindow
 *   variant 'b' — abrupt: DestroyWindow(editor) with the controller alive,
 *                 then Release without Close (what many plugin hosts do)
 *   variant 'c' — release-only: Release all refs without Close, pump 3 s,
 *                 then DestroyWindow
 *   variant 'd' — park: hide + reparent the editor under a hidden helper
 *                 toplevel (Live's Learn View close), pump 10 s, then exit
 *   variant 'e' — JUCE-style: RevokeDragDrop on every descendant of the
 *                 editor (HWNDComponentPeer teardown does exactly this),
 *                 then Close/Release/DestroyWindow. Under Wine this hits
 *                 ole32's cross-process RevokeDragDrop use-after-free when
 *                 the WebView2 helper registered a drop target on its own
 *                 parented-in Chrome_WidgetWin child (issue #52 suspect,
 *                 cf. giang17/wine commit fafb443f85e)
 * Default loader path: C:\ProgramData\Ableton\Live 12 Beta\Program\WebView2Loader.dll
 *
 * Writes webviewclose-report.txt (cwd) mirroring stdout. Exit code 0 = clean,
 * 2 = a setup/teardown step failed, 3 = exception caught.
 *
 * Build: build_webviewclose.sh (fetches the public WebView2 SDK header, not
 * committed here).
 */

#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <ole2.h>
#include <stdarg.h>

#include "WebView2.h"

int _vsnprintf( char *buf, SIZE_T size, const char *fmt, va_list args ); /* ntdll */

static HANDLE report = INVALID_HANDLE_VALUE;

static void out( const char *fmt, ... )
{
    va_list ap;
    char buf[1024];
    int len;
    DWORD n;

    va_start( ap, fmt );
    len = _vsnprintf( buf, sizeof(buf) - 2, fmt, ap );
    va_end( ap );
    if (len < 0) len = sizeof(buf) - 2;
    buf[len] = '\n';
    buf[len + 1] = 0;
    WriteFile( GetStdHandle( STD_OUTPUT_HANDLE ), buf, len + 1, &n, NULL );
    if (report != INVALID_HANDLE_VALUE)
    {
        WriteFile( report, buf, len + 1, &n, NULL );
        FlushFileBuffers( report );
    }
}

/* ---- crash reporting ----------------------------------------------------- */

static LONG CALLBACK crash_handler( EXCEPTION_POINTERS *info )
{
    DWORD code = info->ExceptionRecord->ExceptionCode;
    void *addr = info->ExceptionRecord->ExceptionAddress;
    HMODULE mod = NULL;
    WCHAR name[MAX_PATH] = {0};

    /* only fatal ones; first-chance C++ exceptions (0xE06D7363) and RPC
     * disconnects are business as usual for a closing browser stack */
    if (code != EXCEPTION_ACCESS_VIOLATION && code != EXCEPTION_ILLEGAL_INSTRUCTION
            && code != EXCEPTION_STACK_OVERFLOW && code != EXCEPTION_INT_DIVIDE_BY_ZERO)
        return EXCEPTION_CONTINUE_SEARCH;

    GetModuleHandleExW( GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                        | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                        (LPCWSTR)addr, &mod );
    if (mod) GetModuleFileNameW( mod, name, MAX_PATH );

    out( "!! EXCEPTION %08x at %I64x (module %S + %I64x)",
         (unsigned int)code, (unsigned __int64)(ULONG_PTR)addr, name[0] ? name : L"<none>",
         mod ? (unsigned __int64)((ULONG_PTR)addr - (ULONG_PTR)mod) : 0 );
    if (code == EXCEPTION_ACCESS_VIOLATION)
        out( "!!   %s at %I64x",
             info->ExceptionRecord->ExceptionInformation[0] ? "write" : "read",
             (unsigned __int64)info->ExceptionRecord->ExceptionInformation[1] );

    if (report != INVALID_HANDLE_VALUE) CloseHandle( report );
    ExitProcess( 3 );
    return EXCEPTION_CONTINUE_SEARCH;
}

/* ---- minimal COM completed-handlers -------------------------------------- */

static ICoreWebView2Environment *g_env;
static ICoreWebView2Controller *g_controller;
static HRESULT g_env_hr = S_FALSE, g_ctl_hr = S_FALSE;
static HWND g_editor;

static HRESULT STDMETHODCALLTYPE handler_QI( void *iface, REFIID iid, void **out_iface )
{
    *out_iface = iface;   /* IUnknown + whichever handler IID: same object */
    return S_OK;
}
static ULONG STDMETHODCALLTYPE handler_AddRef( void *iface )  { return 2; }
static ULONG STDMETHODCALLTYPE handler_Release( void *iface ) { return 1; }

static HRESULT STDMETHODCALLTYPE env_completed_Invoke(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *iface,
        HRESULT hr, ICoreWebView2Environment *env )
{
    g_env_hr = hr;
    g_env = env;
    if (env) ICoreWebView2Environment_AddRef( env );
    out( "env completed: hr=%08x env=%I64x", (unsigned int)hr, (unsigned __int64)(ULONG_PTR)env );
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE ctl_completed_Invoke(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *iface,
        HRESULT hr, ICoreWebView2Controller *controller )
{
    g_ctl_hr = hr;
    g_controller = controller;
    if (controller) ICoreWebView2Controller_AddRef( controller );
    out( "controller completed: hr=%08x controller=%I64x",
         (unsigned int)hr, (unsigned __int64)(ULONG_PTR)controller );
    return S_OK;
}

static const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl env_vtbl =
{
    (void *)handler_QI, (void *)handler_AddRef, (void *)handler_Release,
    env_completed_Invoke,
};
static const ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl ctl_vtbl =
{
    (void *)handler_QI, (void *)handler_AddRef, (void *)handler_Release,
    ctl_completed_Invoke,
};
static ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler env_handler =
    { (ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl *)&env_vtbl };
static ICoreWebView2CreateCoreWebView2ControllerCompletedHandler ctl_handler =
    { (ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl *)&ctl_vtbl };

/* ---- minimal IDropTarget (host-side registration, JUCE hosts have one) --- */

static HRESULT STDMETHODCALLTYPE dt_QI( IDropTarget *iface, REFIID iid, void **out_iface )
{
    *out_iface = iface;
    return S_OK;
}
static ULONG STDMETHODCALLTYPE dt_AddRef( IDropTarget *iface )  { return 2; }
static ULONG STDMETHODCALLTYPE dt_Release( IDropTarget *iface ) { return 1; }
static HRESULT STDMETHODCALLTYPE dt_DragEnter( IDropTarget *iface, IDataObject *obj,
        DWORD state, POINTL pt, DWORD *effect ) { *effect = DROPEFFECT_NONE; return S_OK; }
static HRESULT STDMETHODCALLTYPE dt_DragOver( IDropTarget *iface,
        DWORD state, POINTL pt, DWORD *effect ) { *effect = DROPEFFECT_NONE; return S_OK; }
static HRESULT STDMETHODCALLTYPE dt_DragLeave( IDropTarget *iface ) { return S_OK; }
static HRESULT STDMETHODCALLTYPE dt_Drop( IDropTarget *iface, IDataObject *obj,
        DWORD state, POINTL pt, DWORD *effect ) { *effect = DROPEFFECT_NONE; return S_OK; }

static const IDropTargetVtbl dt_vtbl =
{
    dt_QI, dt_AddRef, dt_Release, dt_DragEnter, dt_DragOver, dt_DragLeave, dt_Drop,
};
static IDropTarget host_drop_target = { (IDropTargetVtbl *)&dt_vtbl };

/* JUCE HWNDComponentPeer teardown revokes drag-drop on every descendant it
 * can enumerate — including the WebView2 helper's own Chrome_WidgetWin
 * children parented into the host tree. Log ownership so the report shows
 * which windows carry a foreign drop-target registration. */
static BOOL CALLBACK revoke_enum_proc( HWND hwnd, LPARAM lp )
{
    WCHAR cls[64] = {0};
    DWORD pid = 0;
    HANDLE marshalled = GetPropW( hwnd, L"WineMarshalledDropTarget" );
    void *raw = GetPropW( hwnd, L"OleDropTargetInterface" );
    HRESULT hr;

    GetClassNameW( hwnd, cls, 64 );
    GetWindowThreadProcessId( hwnd, &pid );
    out( "  child %I64x class %S pid %u%s droptarget_prop=%I64x marshalled=%I64x",
         (unsigned __int64)(ULONG_PTR)hwnd, cls, (unsigned int)pid,
         pid == GetCurrentProcessId() ? " (ours)" : " (FOREIGN)",
         (unsigned __int64)(ULONG_PTR)raw, (unsigned __int64)(ULONG_PTR)marshalled );

    out( "  RevokeDragDrop(%I64x)...", (unsigned __int64)(ULONG_PTR)hwnd );
    hr = RevokeDragDrop( hwnd );
    out( "  RevokeDragDrop(%I64x) -> %08x", (unsigned __int64)(ULONG_PTR)hwnd, (unsigned int)hr );
    return TRUE;
}

/* ---- window plumbing ------------------------------------------------------ */

static LRESULT CALLBACK plain_wndproc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_DESTROY && hwnd == g_editor)
        out( "editor WM_DESTROY" );
    return DefWindowProcW( hwnd, msg, wp, lp );
}

static void pump_ms( DWORD ms )
{
    DWORD end = GetTickCount() + ms;
    MSG msg;

    for (;;)
    {
        DWORD now = GetTickCount();
        if ((int)(end - now) <= 0) break;
        MsgWaitForMultipleObjects( 0, NULL, FALSE, end - now, QS_ALLINPUT );
        while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE ))
        {
            TranslateMessage( &msg );
            DispatchMessageW( &msg );
        }
    }
}

typedef HRESULT (STDAPICALLTYPE *create_env_fn)(
        PCWSTR browser_dir, PCWSTR user_data_dir, void *options,
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *handler );

int mainCRTStartup( void )
{
    char variant = 'a';
    WCHAR loader_buf[MAX_PATH] =
        L"C:\\ProgramData\\Ableton\\Live 12 Beta\\Program\\WebView2Loader.dll";
    WCHAR *cmdline = GetCommandLineW();
    WNDCLASSW wc = {0};
    HWND main_win, helper = NULL;
    HMODULE loader;
    create_env_fn create_env;
    WCHAR data_dir[MAX_PATH];
    RECT rc;
    HRESULT hr;
    DPI_AWARENESS_CONTEXT prev_ctx;
    int failed = 0;
    DWORD t0;

    report = CreateFileA( "webviewclose-report.txt", GENERIC_WRITE, FILE_SHARE_READ,
                          NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    AddVectoredExceptionHandler( 1, crash_handler );
    SetProcessDpiAwarenessContext( DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 );
    OleInitialize( NULL );  /* JUCE/Live hosts are OLE-initialized STA */

    /* crude arg parse: first token after the exe is the variant letter,
     * optional second token a loader path */
    {
        WCHAR *p = cmdline;
        int in_quote = 0;
        while (*p && (in_quote || *p != L' ')) { if (*p == L'"') in_quote = !in_quote; p++; }
        while (*p == L' ') p++;
        if (*p) { variant = (char)*p; while (*p && *p != L' ') p++; while (*p == L' ') p++; }
        if (*p)
        {
            int i = 0;
            WCHAR quote = 0;
            if (*p == L'"') quote = *p++;
            while (*p && i < MAX_PATH - 1 && (quote ? *p != quote : *p != L' '))
                loader_buf[i++] = *p++;
            loader_buf[i] = 0;
        }
    }
    out( "variant '%c', loader %S", variant, loader_buf );

    wc.lpfnWndProc = plain_wndproc;
    wc.hInstance = GetModuleHandleW( NULL );
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"WvcMain";
    RegisterClassW( &wc );

    main_win = CreateWindowExW( 0, L"WvcMain", L"webviewclose host",
                                WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                80, 80, 900, 600, NULL, NULL, wc.hInstance, NULL );

    /* the VST3-host trick: editor window born in an UNAWARE thread context */
    prev_ctx = SetThreadDpiAwarenessContext( DPI_AWARENESS_CONTEXT_UNAWARE );
    g_editor = CreateWindowExW( WS_EX_TOOLWINDOW, L"WvcMain", L"Fake plugin editor",
                                WS_CAPTION | WS_SYSMENU | WS_VISIBLE,
                                140, 140, 700, 480, main_win, NULL, wc.hInstance, NULL );
    SetThreadDpiAwarenessContext( prev_ctx );

    hr = RegisterDragDrop( g_editor, &host_drop_target );
    out( "RegisterDragDrop(editor) -> %08x", (unsigned int)hr );

    loader = LoadLibraryW( loader_buf );
    if (!loader)
    {
        out( "!! LoadLibrary(WebView2Loader) failed, err %u", (unsigned int)GetLastError() );
        return 2;
    }
    create_env = (create_env_fn)GetProcAddress( loader, "CreateCoreWebView2EnvironmentWithOptions" );
    if (!create_env)
    {
        out( "!! no CreateCoreWebView2EnvironmentWithOptions export" );
        return 2;
    }

    GetEnvironmentVariableW( L"TEMP", data_dir, MAX_PATH );
    lstrcatW( data_dir, L"\\webviewclose-data" );

    hr = create_env( NULL, data_dir, NULL, &env_handler );
    out( "CreateCoreWebView2EnvironmentWithOptions -> %08x", (unsigned int)hr );
    if (FAILED( hr )) return 2;

    t0 = GetTickCount();
    while (g_env_hr == S_FALSE && GetTickCount() - t0 < 15000) pump_ms( 50 );
    if (!g_env) { out( "!! environment never arrived (hr=%08x)", (unsigned int)g_env_hr ); return 2; }

    hr = ICoreWebView2Environment_CreateCoreWebView2Controller( g_env, g_editor, &ctl_handler );
    out( "CreateCoreWebView2Controller -> %08x", (unsigned int)hr );
    t0 = GetTickCount();
    while (g_ctl_hr == S_FALSE && GetTickCount() - t0 < 15000) pump_ms( 50 );
    if (!g_controller) { out( "!! controller never arrived (hr=%08x)", (unsigned int)g_ctl_hr ); return 2; }

    GetClientRect( g_editor, &rc );
    ICoreWebView2Controller_put_Bounds( g_controller, rc );
    ICoreWebView2Controller_put_IsVisible( g_controller, TRUE );

    {
        ICoreWebView2 *wv = NULL;
        if (SUCCEEDED( ICoreWebView2Controller_get_CoreWebView2( g_controller, &wv ) ) && wv)
        {
            ICoreWebView2_Navigate( wv, L"about:blank" );
            ICoreWebView2_Release( wv );
        }
    }

    out( "webview up; settling 3 s" );
    pump_ms( 3000 );

    out( "-- teardown variant '%c' --", variant );
    switch (variant)
    {
    case 'a':
        out( "put_IsVisible(FALSE)" );
        ICoreWebView2Controller_put_IsVisible( g_controller, FALSE );
        pump_ms( 200 );
        out( "Close()" );
        hr = ICoreWebView2Controller_Close( g_controller );
        out( "Close -> %08x", (unsigned int)hr );
        if (FAILED( hr )) failed = 1;
        pump_ms( 500 );
        out( "Release(controller)" );
        ICoreWebView2Controller_Release( g_controller );
        out( "Release(env)" );
        ICoreWebView2Environment_Release( g_env );
        pump_ms( 500 );
        out( "DestroyWindow(editor)" );
        DestroyWindow( g_editor );
        break;

    case 'b':
        out( "DestroyWindow(editor) with live controller" );
        DestroyWindow( g_editor );
        pump_ms( 1000 );
        out( "Release(controller) without Close" );
        ICoreWebView2Controller_Release( g_controller );
        out( "Release(env)" );
        ICoreWebView2Environment_Release( g_env );
        break;

    case 'c':
        out( "Release(controller) without Close, window kept" );
        ICoreWebView2Controller_Release( g_controller );
        ICoreWebView2Environment_Release( g_env );
        out( "pumping 3 s" );
        pump_ms( 3000 );
        out( "DestroyWindow(editor)" );
        DestroyWindow( g_editor );
        break;

    case 'd':
        out( "parking: hide editor, reparent under hidden helper" );
        helper = CreateWindowExW( 0, L"WvcMain", L"HiddenHelper",
                                  WS_OVERLAPPEDWINDOW, /* never shown */
                                  0, 0, 100, 100, NULL, NULL, wc.hInstance, NULL );
        ICoreWebView2Controller_put_IsVisible( g_controller, FALSE );
        ShowWindow( g_editor, SW_HIDE );
        SetParent( g_editor, helper );
        out( "parked; pumping 10 s (watch for stray blits/flicker)" );
        pump_ms( 10000 );
        break;

    case 'e':
        out( "JUCE-style teardown: RevokeDragDrop over all descendants" );
        EnumChildWindows( g_editor, revoke_enum_proc, 0 );
        out( "RevokeDragDrop(editor itself)..." );
        hr = RevokeDragDrop( g_editor );
        out( "RevokeDragDrop(editor) -> %08x", (unsigned int)hr );
        out( "Close()" );
        hr = ICoreWebView2Controller_Close( g_controller );
        out( "Close -> %08x", (unsigned int)hr );
        pump_ms( 500 );
        ICoreWebView2Controller_Release( g_controller );
        ICoreWebView2Environment_Release( g_env );
        out( "DestroyWindow(editor)" );
        DestroyWindow( g_editor );
        break;

    default:
        out( "!! unknown variant" );
        return 2;
    }

    out( "pumping 3 s post-teardown" );
    pump_ms( 3000 );
    out( failed ? "DONE (teardown step failed)" : "DONE clean" );
    if (report != INVALID_HANDLE_VALUE) CloseHandle( report );
    return failed ? 2 : 0;
}
