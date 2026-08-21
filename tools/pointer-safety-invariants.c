#define _POSIX_C_SOURCE 200809L

/* Deterministic reducer and source checks for the consolidated input patches. */

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#define WHEEL_DELTA_VALUE 120

struct text
{
    char *data;
    size_t length;
    size_t capacity;
};

struct scroll_axis
{
    double increment;
    double value;
    int valid;
};

struct lease
{
    unsigned long window;
    unsigned int buttons;
    unsigned int restores;
};

static unsigned int failures;

static void fail(const char *name, const char *detail)
{
    fprintf(stderr, "FAIL: %s: %s\n", name, detail);
    failures++;
}

static void pass(const char *name)
{
    printf("PASS: %s\n", name);
}

static int append(struct text *text, const char *data, size_t length)
{
    size_t needed = text->length + length + 1;
    char *resized;

    if (needed > text->capacity)
    {
        size_t capacity = text->capacity ? text->capacity : 4096;

        while (capacity < needed) capacity *= 2;
        if (!(resized = realloc(text->data, capacity))) return 0;
        text->data = resized;
        text->capacity = capacity;
    }
    memcpy(text->data + text->length, data, length);
    text->length += length;
    text->data[text->length] = 0;
    return 1;
}

/* Reconstruct context and additions while excluding removed code and prose. */
static int read_patch_new_side(const char *path, struct text *result)
{
    FILE *file;
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    int in_hunk = 0, ok = 1;

    if (!(file = fopen(path, "r")))
    {
        fprintf(stderr, "FAIL: cannot open %s: %s\n", path, strerror(errno));
        return 0;
    }
    while ((length = getline(&line, &capacity, file)) >= 0)
    {
        if (!strncmp(line, "diff --git ", 11)) { in_hunk = 0; continue; }
        if (!strncmp(line, "@@ ", 3)) { in_hunk = 1; continue; }
        if (!in_hunk || !length || line[0] == '-' || line[0] == '\\') continue;
        if ((line[0] == '+' && strncmp(line, "+++ ", 4)) || line[0] == ' ')
            if (!append(result, line + 1, (size_t)length - 1)) { ok = 0; break; }
    }
    free(line);
    fclose(file);
    if (!ok) fprintf(stderr, "FAIL: out of memory while reading %s\n", path);
    return ok;
}

static char *compact(const char *source)
{
    size_t i, output = 0, length = strlen(source);
    char *result = malloc(length + 1);

    if (!result) return NULL;
    for (i = 0; i < length; i++)
        if (!isspace((unsigned char)source[i])) result[output++] = source[i];
    result[output] = 0;
    return result;
}

static size_t count_occurrences(const char *text, const char *needle)
{
    size_t count = 0, length = strlen(needle);

    while ((text = strstr(text, needle))) { count++; text += length; }
    return count;
}

static int require_source(const char *source, const char *needle)
{
    if (strstr(source, needle)) return 1;
    fail("source contract", needle);
    return 0;
}

static int forbid_source(const char *source, const char *needle)
{
    if (!strstr(source, needle)) return 1;
    fail("removed mechanism returned", needle);
    return 0;
}

/* Mirrors smooth_scroll_delta(): one bounded packet, residual retained. */
static int scroll_packet(struct scroll_axis *axis, double value, int notched)
{
    const int limit = notched ? SHRT_MAX / WHEEL_DELTA_VALUE * WHEEL_DELTA_VALUE : SHRT_MAX;
    double units;
    int delta;

    if (!axis->valid)
    {
        axis->value = value;
        axis->valid = 1;
        return 0;
    }
    units = WHEEL_DELTA_VALUE * (value - axis->value) / axis->increment;
    if (!isfinite(units)) { axis->value = value; return 0; }
    if (units > limit) delta = limit;
    else if (units < -limit) delta = -limit;
    else delta = (int)round(units);
    if (notched) delta = delta / WHEEL_DELTA_VALUE * WHEEL_DELTA_VALUE;
    axis->value += (double)delta * axis->increment / WHEEL_DELTA_VALUE;
    return delta;
}

static long long drain_scroll(struct scroll_axis *axis, double value, int notched)
{
    long long total = 0;
    int packet, count = 0;

    while ((packet = scroll_packet(axis, value, notched)))
    {
        if (abs(packet) > SHRT_MAX || ++count > 10000)
        {
            fail("bounded scroll drain", "invalid packet or non-terminating residual");
            break;
        }
        total += packet;
    }
    return total;
}

static void check_scroll_reducer(void)
{
    static const int boundaries[] =
    {
        -480, -241, -240, -239, -121, -120, -119, -30, -1,
        1, 30, 119, 120, 121, 239, 240, 241, 480
    };
    size_t i;

    for (i = 0; i < sizeof(boundaries) / sizeof(boundaries[0]); i++)
    {
        struct scroll_axis axis = {.increment = 1.0, .value = 0.0, .valid = 1};
        long long output = drain_scroll(&axis, (double)boundaries[i] / WHEEL_DELTA_VALUE, 0);

        if (output != boundaries[i])
        {
            fail("precise scroll conservation", "a threshold changed or discarded output");
            break;
        }
    }
    if (i == sizeof(boundaries) / sizeof(boundaries[0]))
        pass("precise scroll conserves threshold and coalesced deltas");

    for (i = 1; i <= 600; i++)
    {
        struct scroll_axis axis = {.increment = 1.0, .value = 0.0, .valid = 1};
        if (drain_scroll(&axis, (double)i / WHEEL_DELTA_VALUE, 0) != (long long)i)
        {
            fail("monotonic direct transfer", "larger same-direction input reduced output");
            break;
        }
    }
    if (i == 601) pass("direct scroll transfer is monotonic");

    {
        struct scroll_axis coalesced = {.increment = 1.0, .value = 0.0, .valid = 1};
        struct scroll_axis sampled = {.increment = 1.0, .value = 0.0, .valid = 1};
        long long one = drain_scroll(&coalesced, 4.0, 0), many = 0;

        for (i = 1; i <= 4; i++) many += drain_scroll(&sampled, (double)i, 0);
        if (one != 480 || many != one) fail("coalescing invariance", "480 != 4 * 120");
        else pass("coalescing changes packet count, not direct distance");
    }

    {
        struct scroll_axis precise = {.increment = 1.0, .value = 0.0, .valid = 1};
        struct scroll_axis notched = {.increment = 1.0, .value = 0.0, .valid = 1};
        long long precise_total = 0, notched_total = 0;

        for (i = 1; i <= 4; i++)
        {
            precise_total += drain_scroll(&precise, (double)i / 4.0, 0);
            notched_total += drain_scroll(&notched, (double)i / 4.0, 1);
        }
        if (precise_total != 120 || notched_total != 120)
            fail("fractional residual", "four 30-unit reports did not total 120");
        else pass("precise and notched modes retain fractional residuals");
    }

    {
        struct scroll_axis axis = {.increment = 1.0, .value = 0.0, .valid = 1};
        long long expected = 4LL * SHRT_MAX;

        if (drain_scroll(&axis, (double)expected / WHEEL_DELTA_VALUE, 0) != expected)
            fail("large report chunking", "signed packet bounds discarded distance");
        else pass("large reports split at packet width without losing distance");
    }
}

static int middle_delta(long long *accum, int notched)
{
    const int quantum = notched ? WHEEL_DELTA_VALUE : WHEEL_DELTA_VALUE / 24;
    const int limit = SHRT_MAX / quantum * quantum;
    long long units = *accum * WHEEL_DELTA_VALUE / 24;
    int delta;

    if (notched) units = units / WHEEL_DELTA_VALUE * WHEEL_DELTA_VALUE;
    if (units > limit) delta = limit;
    else if (units < -limit) delta = -limit;
    else delta = (int)units;
    *accum -= delta * 24 / WHEEL_DELTA_VALUE;
    return delta;
}

static long long drain_middle(long long *accum, int notched)
{
    long long total = 0;
    int delta;

    while ((delta = middle_delta(accum, notched))) total += delta;
    return total;
}

static void check_middle_reducer(void)
{
    long long once = 48, twice = 24, total;
    long long pixels = 0, precise = 0, large = 4LL * SHRT_MAX;
    int i;

    total = drain_middle(&twice, 0);
    twice += 24;
    total += drain_middle(&twice, 0);
    if (drain_middle(&once, 0) != total || total != 240)
        fail("middle coalescing", "one 48-pixel report differs from two 24-pixel reports");
    else pass("middle navigation conserves coalesced movement");

    for (i = 0; i < 24; i++) { pixels++; precise += middle_delta(&pixels, 0); }
    if (precise != 120 || pixels)
        fail("middle residual", "one-pixel reports did not conserve one notch");
    else pass("middle navigation retains sub-notch movement");

    {
        long long expected = 4LL * SHRT_MAX * 5;
        long long output = drain_middle(&large, 0);

        if (output != expected || large)
        {
            char detail[128];

            snprintf(detail, sizeof(detail), "output=%lld expected=%lld residual=%lld",
                     output, expected, large);
            fail("middle large-report chunking", detail);
        }
        else pass("middle navigation splits large reports without losing distance");
    }
}

static int pinch_delta(double *delivered_log_scale, double scale)
{
    const double step = 1.1;
    double units = WHEEL_DELTA_VALUE * (log(scale) - *delivered_log_scale) / log(step);
    int delta = (int)round(units);

    if (delta) *delivered_log_scale += (double)delta / WHEEL_DELTA_VALUE * log(step);
    return delta;
}

static void check_pinch_reducer(void)
{
    double one_scale = 0.0, split_scale = 0.0, large_scale = 0.0;
    int one = pinch_delta(&one_scale, 2.0);
    int split = pinch_delta(&split_scale, sqrt(2.0));
    int large;

    split += pinch_delta(&split_scale, 2.0);
    large = pinch_delta(&large_scale, 1e100);
    if (abs(one - split) > 1 ||
        fabs(WHEEL_DELTA_VALUE * (log(2.0) - one_scale) / log(1.1)) > 0.5)
        fail("pinch conservation", "split updates changed the logarithmic total");
    else pass("pinch retains complete logarithmic scale movement");
    if (abs(large) <= WHEEL_DELTA_VALUE ||
        fabs(WHEEL_DELTA_VALUE * (log(1e100) - large_scale) / log(1.1)) > 0.5)
        fail("large final pinch", "the final update was capped or left unreported scale");
    else pass("one large final pinch update is not capped to one notch");
}

static void lease_restore(struct lease *lease)
{
    if (!lease->window) return;
    lease->window = 0;
    lease->buttons = 0;
    lease->restores++;
}

static void lease_transition(struct lease *lease, unsigned long window,
                             unsigned int bit, int down)
{
    if (down)
    {
        if (lease->buttons && lease->window != window) lease_restore(lease);
        if (!lease->buttons) lease->window = window;
        lease->buttons |= bit;
    }
    else if (lease->window != window || !(lease->buttons & bit)) lease_restore(lease);
    else
    {
        lease->buttons &= ~bit;
        if (!lease->buttons) lease_restore(lease);
    }
}

static void check_lease_reducer(void)
{
    struct lease lease = {0};

    lease_transition(&lease, 10, 1, 1);
    lease_transition(&lease, 11, 1, 0);
    if (lease.window || lease.buttons || lease.restores != 1)
        fail("release mismatch recovery", "the lease remained suspended");
    else pass("a release on another window restores the drag lease");

    lease_transition(&lease, 10, 1, 1);
    lease_transition(&lease, 10, 2, 1);
    lease_transition(&lease, 10, 1, 0);
    if (!lease.window || lease.buttons != 2) fail("multi-button lease", "released too early");
    lease_restore(&lease);
    if (lease.window || lease.buttons || lease.restores != 2)
        fail("lifecycle lease recovery", "focus/capture cleanup left state behind");
    else pass("lifecycle cancellation restores a multi-button lease exactly once");

    lease_transition(&lease, 10, 1, 1);
    lease_restore(&lease); /* later input reports that no physical button remains */
    if (lease.window || lease.buttons || lease.restores != 3)
        fail("lost release recovery", "physical state reconciliation left the lease suspended");
    else pass("later input recovers a completely lost drag release");
}

static double regression_velocity(const double *position, const int *time, size_t count)
{
    double sw = 0, st = 0, sp = 0, mt, mp, covariance = 0, variance = 0;
    size_t i;

    for (i = 0; i < count; i++)
    {
        double weight = i + 1;

        sw += weight;
        st += weight * time[i] / 1000.0;
        sp += weight * position[i];
    }
    mt = st / sw;
    mp = sp / sw;
    for (i = 0; i < count; i++)
    {
        double weight = i + 1;
        double dt = time[i] / 1000.0 - mt;

        covariance += weight * dt * (position[i] - mp);
        variance += weight * dt * dt;
    }
    return covariance / variance;
}

static void check_inertia_reducer(void)
{
    static const int time[] = {0, 10, 20, 30};
    static const double position[] = {0, 10, 20, 30};
    static const int schedules[][5] =
    {
        {8, 16, 24, 500, 1000},
        {16, 32, 48, 64, 1000},
        {100, 250, 500, 750, 1000},
    };
    const double velocity = 1200.0, rate = 4.0;
    double expected = velocity * (1.0 - exp(-rate)) / rate;
    size_t i, j;

    if (fabs(regression_velocity(position, time, 4) - 1000.0) > 0.001)
        fail("inertia estimator", "constant cumulative motion has sampling-rate bias");
    else pass("inertia estimates velocity from cumulative position and time");

    for (i = 0; i < sizeof(schedules) / sizeof(schedules[0]); i++)
    {
        double model = 0, delivered = 0;

        for (j = 0; j < 5; j++)
        {
            double seconds = schedules[i][j] / 1000.0;
            double target = velocity * (1.0 - exp(-rate * seconds)) / rate;

            delivered += target - model;
            model = target;
        }
        if (fabs(delivered - expected) > 0.001)
        {
            fail("analytic inertia", "timer cadence changed final coast distance");
            return;
        }
    }
    pass("analytic inertia distance is independent of timer cadence and stalls");
}

static void check_source_contracts(const char *pointer, const char *dnd)
{
    static const char *const required[] =
    {
        "pointer_config.enabled=FALSE;",
        ".touchpad_inertia=POINTER_INERTIA_ENABLED,",
        ".middle_drag_throw=POINTER_MIDDLE_DRAG_THROW_ENABLED,",
        "xinput2_gestures=pointer_config.enabled&&",
        "xinput2_smooth_scroll=pointer_config.enabled&&",
        "if(pointer_config.enabled&&pinch_button_is_wheel(event->button)&&",
        "if(xinput2_smooth_scroll){unsignedcharhier_bits",
        "if(pointer_config.enabled)ungrab_clipping_window();",
        "src->scroll_y.value=src->scroll_y.last_value=val->value;",
        "while(have_y&&(delta_y=smooth_scroll_delta(",
        "xinput2_core_drag_restore(display,\"release-mismatch\");",
        "xinput2_core_drag_reconcile(event->display,\"wheel-release-without-buttons\");",
        "xinput2_core_drag_restore(event->display,\"motion-without-buttons\");",
        "send_mouse_input(hwnd,pt,MOUSEEVENTF_ABSOLUTE|flags,delta,time,NULL);",
        "send_mouse_input(hwnd,(POINT){0},MOUSEEVENTF_WHEEL,packet,time,NULL);",
        "pinch_hold_control_locked(event->display)",
        "pinch_reset_locked(event->display);",
        "log(event->scale)-pinch.log_scale",
        "while((delta_y=middle_drag_delta(&drag->accum_y,notched)))",
        "pointer_inertia_evaluate(si,now,\"inactivity\");",
        "target_x=si->v0x*(1.0-factor)/k;",
        "WM_X11DRV_POINTER_TICK",
        "pointer_input_reset();",
    };
    static const char *const forbidden[] =
    {
        "SEND_HWMSG_FIXED_POSITION", "update_driver_button", "notify_button_transition",
        "pointer_scroll_resync", "INERTIA_NUDGE_SLOTS", "nudge_thread",
        "pointer_input_serial", "pinch_keyboard", "send_message(hwnd,WM_MOUSEWHEEL"
    };
    size_t i;

    for (i = 0; i < sizeof(required) / sizeof(required[0]); i++) require_source(pointer, required[i]);
    for (i = 0; i < sizeof(forbidden) / sizeof(forbidden[0]); i++) forbid_source(pointer, forbidden[i]);
    if (!failures) pass("pointer source keeps one compact interaction owner without private protocol state");

    require_source(dnd, "object->target_effect=target_effect;");
    require_source(dnd, "data_object_release_drop_target(object,TRUE);");
    require_source(dnd, "data_object_release_drop_target(object,FALSE);");
    if (count_occurrences(dnd, "data_object_release_drop_target(object,TRUE);") < 3 ||
        count_occurrences(dnd, "data_object_release_drop_target(object,FALSE);") < 2)
        fail("drop-target lifecycle", "not every leave/drop path uses the shared terminal helper");
    else if (!failures) pass("drag target acceptance and lifetime share one terminal path");
}

int main(int argc, char **argv)
{
    const char *pointer_path = "patches/0100-winex11-conserve-pointer-input-and-recover-core-drags.patch";
    const char *dnd_path = "patches/0101-user32-release-drop-target-and-store-DragEnter-effect.patch";
    struct text pointer_text = {0}, dnd_text = {0};
    char *pointer, *dnd;

    if (argc != 1 && argc != 3)
    {
        fprintf(stderr, "usage: %s [pointer-patch dnd-patch]\n", argv[0]);
        return 2;
    }
    if (argc == 3) { pointer_path = argv[1]; dnd_path = argv[2]; }
    if (!read_patch_new_side(pointer_path, &pointer_text) || !read_patch_new_side(dnd_path, &dnd_text))
        return 2;
    pointer = compact(pointer_text.data ? pointer_text.data : "");
    dnd = compact(dnd_text.data ? dnd_text.data : "");
    if (!pointer || !dnd)
    {
        fprintf(stderr, "FAIL: out of memory while compacting patch source\n");
        return 2;
    }

    check_scroll_reducer();
    check_middle_reducer();
    check_pinch_reducer();
    check_lease_reducer();
    check_inertia_reducer();
    check_source_contracts(pointer, dnd);

    free(pointer_text.data);
    free(dnd_text.data);
    free(pointer);
    free(dnd);
    if (failures)
    {
        fprintf(stderr, "%u pointer safety check(s) failed\n", failures);
        return 1;
    }
    puts("All pointer safety checks passed.");
    return 0;
}
