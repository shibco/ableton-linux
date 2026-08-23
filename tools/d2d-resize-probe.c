/*
 * Assert what an hwnd render target keeps across Resize: patch 0104.
 *
 * Resize recreates the target bitmap. Two properties of the original target
 * have to survive it, and each has a known failing value, so no reference image
 * is needed:
 *
 *   an opaque target keeps D2D1_ALPHA_MODE_IGNORE, which
 *   d2d_device_context_can_draw_cleartype() requires. Lose it and text drops to
 *   greyscale, where every pixel has r == g == b and the per-channel spread is
 *   exactly zero.
 *
 *   a target created D2D1_RENDER_TARGET_USAGE_GDI_COMPATIBLE keeps
 *   D2D1_BITMAP_OPTIONS_GDI_COMPATIBLE. Lose it and GetDC returns
 *   D2DERR_TARGET_NOT_GDI_COMPATIBLE. Nothing fails earlier:
 *   d2d_bitmap_check_options_with_surface() only rejects requesting the flag
 *   when the surface lacks it, never the reverse.
 *
 * Each check draws or calls GetDC before the resize as well. That arm must
 * succeed on every runtime, or the probe is measuring something other than
 * Resize.
 *
 * --check runs both and exits non-zero on the first failure. Needs a display;
 * the suite starts one when DISPLAY is unset. The prefix needs
 * FontSmoothingType = 2 for the ClearType check, or its control arm fails on
 * pixel geometry for reasons unrelated to this patch.
 */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <d2d1.h>
#include <d2d1_1.h>
#include <dwrite.h>
#include <stdio.h>
#include <string.h>

static ID2D1Factory *factory;
static int failures, checks;

static void check(int pass, const char *what, const char *detail)
{
    checks++;
    if (pass) printf("  ok - %s\n", what);
    else { printf("  not ok - %s\n", what); printf("    %s\n", detail); failures++; }
}

static HWND make_window(const WCHAR *cls)
{
    WNDCLASSW wc = {0};
    HWND h;
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = cls;
    RegisterClassW(&wc);
    h = CreateWindowExW(0, cls, cls, WS_OVERLAPPEDWINDOW, 0, 0, 520, 160,
            NULL, NULL, wc.hInstance, NULL);
    if (h) ShowWindow(h, SW_SHOW);
    return h;
}

static HRESULT make_target(HWND hwnd, D2D1_RENDER_TARGET_USAGE usage,
        D2D1_SIZE_U size, ID2D1HwndRenderTarget **rt)
{
    D2D1_RENDER_TARGET_PROPERTIES rtd;
    D2D1_HWND_RENDER_TARGET_PROPERTIES hd;

    memset(&rtd, 0, sizeof(rtd));
    rtd.type = D2D1_RENDER_TARGET_TYPE_DEFAULT;
    rtd.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    rtd.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
    rtd.usage = usage;
    memset(&hd, 0, sizeof(hd));
    hd.hwnd = hwnd;
    hd.pixelSize = size;
    return ID2D1Factory_CreateHwndRenderTarget(factory, &rtd, &hd, rt);
}

/* mean per-channel spread over lit pixels; <0 if the target cannot be read */
static double draw_and_measure(ID2D1HwndRenderTarget *rt, IDWriteTextFormat *fmt,
        ID2D1SolidColorBrush *brush, UINT32 w, UINT32 h)
{
    static const WCHAR sample[] = L"Handgloves Illinois 1080 mmmm";
    D2D1_COLOR_F black = {0.0f, 0.0f, 0.0f, 1.0f};
    D2D1_RECT_F layout = {4.0f, 4.0f, 0.0f, 0.0f};
    D2D1_BITMAP_PROPERTIES1 cpu_desc;
    D2D1_POINT_2U origin = {0, 0};
    D2D1_MAPPED_RECT mapped;
    D2D1_SIZE_U size = {w, h};
    ID2D1DeviceContext *ctx = NULL;
    ID2D1Bitmap1 *cpu = NULL;
    IUnknown *target = NULL;
    ID2D1Bitmap *src = NULL;
    unsigned int x, y, lit = 0, sum = 0;
    double out = -1.0;

    layout.right = (float)w - 4.0f; layout.bottom = (float)h - 4.0f;

    if (FAILED(ID2D1HwndRenderTarget_QueryInterface(rt, &IID_ID2D1DeviceContext, (void **)&ctx)))
        return -1.0;

    ID2D1RenderTarget_BeginDraw((ID2D1RenderTarget *)rt);
    ID2D1RenderTarget_Clear((ID2D1RenderTarget *)rt, &black);
    ID2D1RenderTarget_SetTextAntialiasMode((ID2D1RenderTarget *)rt,
            D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
    ID2D1RenderTarget_DrawText((ID2D1RenderTarget *)rt, sample,
            (UINT32)(sizeof(sample)/sizeof(WCHAR) - 1), fmt, &layout,
            (ID2D1Brush *)brush, D2D1_DRAW_TEXT_OPTIONS_NONE, DWRITE_MEASURING_MODE_NATURAL);
    if (FAILED(ID2D1RenderTarget_EndDraw((ID2D1RenderTarget *)rt, NULL, NULL)))
        { IUnknown_Release((IUnknown *)ctx); return -1.0; }

    memset(&cpu_desc, 0, sizeof(cpu_desc));
    cpu_desc.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    cpu_desc.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
    cpu_desc.bitmapOptions = D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW;
    if (SUCCEEDED(ctx->lpVtbl->CreateBitmap(ctx, size, NULL, 0, &cpu_desc, &cpu)))
    {
        ctx->lpVtbl->GetTarget(ctx, (struct ID2D1Image **)&target);
        if (target && SUCCEEDED(IUnknown_QueryInterface(target, &IID_ID2D1Bitmap, (void **)&src))
                && SUCCEEDED(ID2D1Bitmap_CopyFromBitmap((ID2D1Bitmap *)cpu, &origin, src, NULL))
                && SUCCEEDED(cpu->lpVtbl->Map(cpu, D2D1_MAP_OPTIONS_READ, &mapped)))
        {
            for (y = 0; y < h; y++) {
                const BYTE *row = mapped.bits + (size_t)y * mapped.pitch;
                for (x = 0; x < w; x++) {
                    BYTE b = row[x*4], g = row[x*4+1], r = row[x*4+2];
                    BYTE mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
                    BYTE mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
                    if (mx) { lit++; sum += (unsigned)(mx - mn); }
                }
            }
            cpu->lpVtbl->Unmap(cpu);
            out = lit ? (double)sum / lit : -1.0;
        }
        if (src) ID2D1Bitmap_Release(src);
        if (target) IUnknown_Release(target);
        IUnknown_Release((IUnknown *)cpu);
    }
    IUnknown_Release((IUnknown *)ctx);
    return out;
}

static HRESULT try_getdc(ID2D1HwndRenderTarget *rt)
{
    ID2D1GdiInteropRenderTarget *gdi = NULL;
    RECT dirty = {0, 0, 0, 0};
    HRESULT hr;
    HDC hdc;

    if (FAILED(hr = ID2D1HwndRenderTarget_QueryInterface(rt,
            &IID_ID2D1GdiInteropRenderTarget, (void **)&gdi)))
        return hr;
    ID2D1RenderTarget_BeginDraw((ID2D1RenderTarget *)rt);
    hr = ID2D1GdiInteropRenderTarget_GetDC(gdi, D2D1_DC_INITIALIZE_MODE_COPY, &hdc);
    if (SUCCEEDED(hr)) ID2D1GdiInteropRenderTarget_ReleaseDC(gdi, &dirty);
    ID2D1RenderTarget_EndDraw((ID2D1RenderTarget *)rt, NULL, NULL);
    ID2D1GdiInteropRenderTarget_Release(gdi);
    return hr;
}

int main(int argc, char **argv)
{
    int run_checks = argc > 1 && !strcmp(argv[1], "--check");
    D2D1_SIZE_U sz = {480, 120}, big = {600, 160};
    ID2D1HwndRenderTarget *rt = NULL;
    ID2D1SolidColorBrush *white = NULL;
    D2D1_COLOR_F wcol = {1.0f, 1.0f, 1.0f, 1.0f};
    IDWriteTextFormat *fmt = NULL;
    IDWriteFactory *dw = NULL;
    double before, after;
    HRESULT gdi_before, gdi_after;
    char detail[200];
    HWND hwnd;
    HRESULT hr;

    if (FAILED(hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory,
            NULL, (void **)&factory)))
    { printf("not ok - D2D1CreateFactory hr=%#lx\n", hr); return 2; }
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory,
            (IUnknown **)&dw)))
    { printf("not ok - DWriteCreateFactory failed\n"); return 2; }
    IDWriteFactory_CreateTextFormat(dw, L"Tahoma", NULL, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 24.0f, L"en-us", &fmt);

    printf("# hwnd render target across Resize\n");

    /* 1. an opaque target keeps its alpha mode, so ClearType survives */
    if (!(hwnd = make_window(L"d2dprobe_ct"))) { printf("not ok - no window\n"); return 2; }
    if (FAILED(hr = make_target(hwnd, D2D1_RENDER_TARGET_USAGE_NONE, sz, &rt)))
    { printf("not ok - CreateHwndRenderTarget hr=%#lx\n", hr); return 2; }
    ID2D1RenderTarget_CreateSolidColorBrush((ID2D1RenderTarget *)rt, &wcol, NULL, &white);

    before = draw_and_measure(rt, fmt, white, sz.width, sz.height);
    if (before <= 0.5) {
        printf("not ok - control: no ClearType before the resize (spread %.2f)\n", before);
        printf("    the prefix needs FontSmoothingType=2, or can_draw_cleartype() fails on pixel geometry\n");
        return 2;
    }
    if (FAILED(hr = ID2D1HwndRenderTarget_Resize(rt, &big)))
    { printf("not ok - Resize hr=%#lx\n", hr); return 2; }
    after = draw_and_measure(rt, fmt, white, big.width, big.height);
    snprintf(detail, sizeof(detail),
             "per-channel spread %.2f before the resize, %.2f after; greyscale gives exactly 0",
             before, after);
    if (run_checks) check(after > 0.5, "an opaque target keeps ClearType across Resize", detail);
    else printf("  cleartype: %s\n", detail);
    ID2D1SolidColorBrush_Release(white);
    ID2D1HwndRenderTarget_Release(rt);
    DestroyWindow(hwnd);

    /* 2. a GDI-compatible target keeps its bitmap option, so GetDC survives */
    rt = NULL;
    if (!(hwnd = make_window(L"d2dprobe_gdi"))) { printf("not ok - no window\n"); return 2; }
    if (FAILED(hr = make_target(hwnd, D2D1_RENDER_TARGET_USAGE_GDI_COMPATIBLE, sz, &rt)))
    { printf("not ok - CreateHwndRenderTarget(GDI_COMPATIBLE) hr=%#lx\n", hr); return 2; }

    gdi_before = try_getdc(rt);
    if (FAILED(gdi_before)) {
        printf("not ok - control: GetDC failed before the resize, hr=%#lx\n", gdi_before);
        return 2;
    }
    if (FAILED(hr = ID2D1HwndRenderTarget_Resize(rt, &big)))
    { printf("not ok - Resize hr=%#lx\n", hr); return 2; }
    gdi_after = try_getdc(rt);
    snprintf(detail, sizeof(detail),
             "GetDC after the resize returned %#lx%s", gdi_after,
             (unsigned long)gdi_after == D2DERR_TARGET_NOT_GDI_COMPATIBLE
                 ? " (D2DERR_TARGET_NOT_GDI_COMPATIBLE)" : "");
    if (run_checks)
        check(SUCCEEDED(gdi_after), "a GDI-compatible target keeps GetDC across Resize", detail);
    else
        printf("  gdi: %s\n", detail);
    ID2D1HwndRenderTarget_Release(rt);
    DestroyWindow(hwnd);

    if (run_checks) printf("# %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
