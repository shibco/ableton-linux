/*
 * Assert the DirectWrite glyph path: which form a glyph is rasterised from,
 * and whether a fractional origin moves it.
 *
 * Covers patches 0100 and 0101. Each check has a known failing value, so
 * no reference image is needed:
 *
 *   a bitmap strike carries one coverage sample per pixel. Expanded into a
 *   ClearType texture it sets every covered subpixel to exactly 255, so the
 *   count of distinct non-zero values collapses to 1. A rasterised outline
 *   spreads across dozens.
 *
 *   an origin quantised to whole pixels leaves the coverage centroid unmoved
 *   across a full pixel of requested travel. A sub-pixel origin moves it by
 *   the amount asked for.
 *
 * --check runs the battery and exits non-zero on the first failure. With no
 * arguments it prints one measurement per rendering mode for inspection.
 *
 * The prefix must have FontSmoothingType = 2. At 1 the greyscale checks read
 * as failures for a reason that has nothing to do with these patches.
 *
 * Built as a PE with mingw rather than winegcc: a winegcc object links against
 * the Wine that built it, and the whole point here is to run one binary
 * against several runtimes.
 */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <dwrite_2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Wine's bundled Tahoma carries strikes for 8..13, 15 and 16 ppem. 11 is
 * inside that range, 24 is outside it and acts as the control. */
#define STRIKE_EM   11.0f
#define OUTLINE_EM  24.0f

struct sample {
    int    ok;
    double centroid;
    int    distinct;
    int    saturated;
    LONG   left, right;
};

static IDWriteFactory2 *factory;
static IDWriteFontFace  *face;
static UINT16 glyph;
static int failures, checks;

static struct sample measure(float emsize, DWRITE_RENDERING_MODE mode,
        DWRITE_TEXT_ANTIALIAS_MODE aa, float originx)
{
    struct sample s = {0, 0.0, 0, 0, 0, 0};
    DWRITE_TEXTURE_TYPE ttype = (aa == DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE
            || mode == DWRITE_RENDERING_MODE_ALIASED)
            ? DWRITE_TEXTURE_ALIASED_1x1 : DWRITE_TEXTURE_CLEARTYPE_3x1;
    int bpp = (ttype == DWRITE_TEXTURE_CLEARTYPE_3x1) ? 3 : 1;
    IDWriteGlyphRunAnalysis *analysis = NULL;
    DWRITE_GLYPH_OFFSET offset = {0.0f, 0.0f};
    float advance = 0.0f;
    DWRITE_GLYPH_RUN run;
    double wsum = 0.0, csum = 0.0;
    int seen[256], i, x, y, w, h;
    UINT32 size;
    BYTE *tex;
    RECT b;

    memset(&run, 0, sizeof(run));
    run.fontFace = face; run.fontEmSize = emsize; run.glyphCount = 1;
    run.glyphIndices = &glyph; run.glyphAdvances = &advance; run.glyphOffsets = &offset;

    if (FAILED(IDWriteFactory2_CreateGlyphRunAnalysis(factory, &run, NULL, mode,
            DWRITE_MEASURING_MODE_NATURAL, DWRITE_GRID_FIT_MODE_DEFAULT, aa,
            originx, 0.0f, &analysis)))
        return s;
    if (FAILED(IDWriteGlyphRunAnalysis_GetAlphaTextureBounds(analysis, ttype, &b)))
        { IDWriteGlyphRunAnalysis_Release(analysis); return s; }

    w = b.right - b.left; h = b.bottom - b.top;
    if (w <= 0 || h <= 0) { IDWriteGlyphRunAnalysis_Release(analysis); return s; }

    size = (UINT32)(w * h * bpp);
    if (!(tex = calloc(1, size))) { IDWriteGlyphRunAnalysis_Release(analysis); return s; }
    if (FAILED(IDWriteGlyphRunAnalysis_CreateAlphaTexture(analysis, ttype, &b, tex, size)))
        { free(tex); IDWriteGlyphRunAnalysis_Release(analysis); return s; }

    memset(seen, 0, sizeof(seen));
    for (y = 0; y < h; y++)
        for (x = 0; x < w * bpp; x++) {
            BYTE v = tex[y * w * bpp + x];
            if (v) {
                wsum += v;
                csum += v * (b.left + (double)x / bpp);
                seen[v] = 1;
                if (v == 255) s.saturated++;
            }
        }
    for (i = 1; i < 256; i++) s.distinct += seen[i];

    s.centroid = wsum > 0 ? csum / wsum : 0.0;
    s.left = b.left; s.right = b.right;
    s.ok = wsum > 0;

    free(tex);
    IDWriteGlyphRunAnalysis_Release(analysis);
    return s;
}

static void check(int pass, const char *what, const char *detail)
{
    checks++;
    if (pass) {
        printf("  ok - %s\n", what);
    } else {
        printf("  not ok - %s\n", what);
        printf("    %s\n", detail);
        failures++;
    }
}

/* a glyph rasterised from an outline carries many coverage values; a strike
 * expanded into the texture carries exactly one */
static void check_form(const char *what, float em, DWRITE_RENDERING_MODE mode,
        DWRITE_TEXT_ANTIALIAS_MODE aa)
{
    struct sample s = measure(em, mode, aa, 0.0f);
    char detail[160];

    if (!s.ok) { check(0, what, "no coverage rendered"); return; }
    snprintf(detail, sizeof(detail),
             "distinct=%d saturated=%d; a strike gives distinct=1 with every "
             "covered sample at 255", s.distinct, s.saturated);
    check(s.distinct > 8, what, detail);
}

/* GDI-compatible and aliased modes retain the embedded strike. This is the
 * other half of selecting the form by rendering mode, and prevents a broad
 * "anything antialiased uses outlines" rule from silently changing GDI text. */
static void check_strike(const char *what, DWRITE_RENDERING_MODE mode,
        DWRITE_TEXT_ANTIALIAS_MODE aa)
{
    struct sample s = measure(STRIKE_EM, mode, aa, 0.0f);
    char detail[160];

    if (!s.ok) { check(0, what, "no coverage rendered"); return; }
    snprintf(detail, sizeof(detail),
             "distinct=%d saturated=%d; the embedded strike has one non-zero "
             "coverage value and saturated samples", s.distinct, s.saturated);
    check(s.distinct == 1 && s.saturated > 0, what, detail);
}

/* a natural rendering mode must move the ink by the fraction asked for; every
 * other mode must not move it at all */
static void check_position(const char *what, DWRITE_RENDERING_MODE mode,
        DWRITE_TEXT_ANTIALIAS_MODE aa, int expect_movement)
{
    struct sample a = measure(OUTLINE_EM, mode, aa, 0.0f);
    struct sample b = measure(OUTLINE_EM, mode, aa, 0.5f);
    double moved;
    char detail[160];

    if (!a.ok || !b.ok) { check(0, what, "no coverage rendered"); return; }
    moved = b.centroid - a.centroid;
    snprintf(detail, sizeof(detail),
             "centroid moved %.4f px for a requested 0.5 px (%.4f -> %.4f)",
             moved, a.centroid, b.centroid);

    if (expect_movement)
        check(moved > 0.3 && moved < 0.7, what, detail);
    else
        check(moved == 0.0, what, detail);
}

int main(int argc, char **argv)
{
    int run_checks = argc > 1 && !strcmp(argv[1], "--check");
    IDWriteFontCollection *coll = NULL;
    IDWriteFontFamily *family = NULL;
    IDWriteFont *font = NULL;
    UINT32 index = 0, cp = 'n';
    BOOL exists = FALSE;

    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory2,
            (IUnknown **)&factory)))
    { printf("not ok - IDWriteFactory2 unavailable\n"); return 2; }
    IDWriteFactory2_GetSystemFontCollection(factory, &coll, FALSE);
    if (FAILED(IDWriteFontCollection_FindFamilyName(coll, L"Tahoma", &index, &exists)) || !exists)
    { printf("not ok - Tahoma is not in the prefix; the strike checks need it\n"); return 2; }
    IDWriteFontCollection_GetFontFamily(coll, index, &family);
    IDWriteFontFamily_GetFirstMatchingFont(family, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, &font);
    IDWriteFont_CreateFontFace(font, &face);
    IDWriteFontFace_GetGlyphIndices(face, &cp, 1, &glyph);

    if (!run_checks) {
        struct sample s;
        int m;
        printf("# Tahoma 'n', origin 0.0, one measurement per mode\n");
        printf("# %-22s %-9s %-9s %s\n", "mode", "centroid", "distinct", "saturated");
        for (m = 1; m <= 5; m++) {
            static const char *names[] = {"", "ALIASED", "GDI_CLASSIC", "GDI_NATURAL",
                                          "NATURAL", "NATURAL_SYMMETRIC"};
            s = measure(STRIKE_EM, (DWRITE_RENDERING_MODE)m,
                        DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE, 0.0f);
            printf("  em11 cleartype %-8s %-9.4f %-9d %d\n", names[m],
                   s.centroid, s.distinct, s.saturated);
        }
        s = measure(STRIKE_EM, DWRITE_RENDERING_MODE_NATURAL,
                    DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, 0.0f);
        printf("  em11 greyscale NATURAL  %-9.4f %-9d %d\n",
               s.centroid, s.distinct, s.saturated);
        return 0;
    }

    printf("# dwrite glyph path\n");

    /* 0100: a ClearType texture must not be built from a strike */
    check_form("cleartype at a strike size rasterises the outline",
               STRIKE_EM, DWRITE_RENDERING_MODE_NATURAL,
               DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE);

    /* the form follows the natural rendering mode, not the texture type */
    check_form("greyscale at a strike size rasterises the outline",
               STRIKE_EM, DWRITE_RENDERING_MODE_NATURAL,
               DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE);

    check_form("natural symmetric at a strike size rasterises the outline",
               STRIKE_EM, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
               DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE);

    check_strike("gdi classic keeps the strike with ClearType",
                 DWRITE_RENDERING_MODE_GDI_CLASSIC,
                 DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE);
    check_strike("gdi natural keeps the strike with greyscale",
                 DWRITE_RENDERING_MODE_GDI_NATURAL,
                 DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    check_strike("aliased rendering keeps the strike",
                 DWRITE_RENDERING_MODE_ALIASED,
                 DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE);

    /* the control: above the strike range every mode already used the outline */
    check_form("cleartype above the strike range rasterises the outline",
               OUTLINE_EM, DWRITE_RENDERING_MODE_NATURAL,
               DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE);

    /* 0101: sub-pixel positioning, and its gate */
    check_position("natural rendering positions sub-pixel",
                   DWRITE_RENDERING_MODE_NATURAL,
                   DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE, 1);
    check_position("natural symmetric positions sub-pixel",
                   DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
                   DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE, 1);
    check_position("gdi classic stays on whole pixels",
                   DWRITE_RENDERING_MODE_GDI_CLASSIC,
                   DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE, 0);
    check_position("gdi natural stays on whole pixels",
                   DWRITE_RENDERING_MODE_GDI_NATURAL,
                   DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE, 0);
    check_position("aliased stays on whole pixels",
                   DWRITE_RENDERING_MODE_ALIASED,
                   DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE, 0);

    printf("# %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
