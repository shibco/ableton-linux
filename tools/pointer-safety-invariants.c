#define _POSIX_C_SOURCE 200809L

/*
 * Deterministic source and maths checks for pointer-output safety.
 *
 * Wine is carried here as a patch stack rather than directly linkable source.
 * The checker reads guarded delivery from 0092, warp handling from 0094,
 * lifecycle rules from 0095, final gesture changes from 0097, and held LMB
 * control-drag isolation from 0098. It ignores removed lines and commit prose.
 */

#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#define WHEEL_DELTA_VALUE 120
#define MAX_FRAME_MS_VALUE 16
#define MAX_PACKET_VALUE 300
#define MAX_TRAVEL_VALUE (40 * WHEEL_DELTA_VALUE)
#define MAX_TOTAL_VALUE (60 * WHEEL_DELTA_VALUE)
#define MAX_MESSAGES_VALUE 384
#define MAX_SPEED_VALUE 19200.0
#define START_SPEED_VALUE 240.0
#define DEFAULT_INERTIA_RATE_VALUE 4.0
#define MIDDLE_THROW_HISTORY_MS_VALUE 100
#define MIDDLE_THROW_MAX_GAP_MS_VALUE 80
#define MIDDLE_THROW_FALLBACK_SPAN_MS_VALUE 24
#define MIDDLE_THROW_MIN_DISTANCE_VALUE 4.0
#define INERTIA_MIN_SPAN_MS_VALUE 10
#define MIDDLE_DRAG_STEP_VALUE 24.0

struct text
{
    char *data;
    size_t length;
    size_t capacity;
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

/* Append the source represented by context and added hunk lines. */
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
        if (!strncmp(line, "diff --git ", 11))
        {
            in_hunk = 0;
            continue;
        }
        if (!strncmp(line, "@@ ", 3) || !strncmp(line, "@@-", 3))
        {
            in_hunk = 1;
            continue;
        }
        if (!in_hunk || !length || line[0] == '-' || line[0] == '\\') continue;
        if ((line[0] == '+' && strncmp(line, "+++ ", 4)) || line[0] == ' ')
        {
            if (!append(result, line + 1, (size_t)length - 1))
            {
                ok = 0;
                break;
            }
        }
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

    while ((text = strstr(text, needle)))
    {
        count++;
        text += length;
    }
    return count;
}

static size_t count_occurrences_between(const char *text, const char *begin,
                                        const char *end, const char *needle)
{
    const char *first = strstr(text, begin), *last, *match;
    size_t count = 0, length = strlen(needle);

    if (!first || !(last = strstr(first, end))) return (size_t)-1;
    for (match = first; (match = strstr(match, needle)) && match < last; match += length)
        count++;
    return count;
}

static int require_text(const char *test, const char *text, const char *needle)
{
    if (!strstr(text, needle))
    {
        fail(test, needle);
        return 0;
    }
    return 1;
}

static int forbid_text(const char *test, const char *text, const char *needle)
{
    if (strstr(text, needle))
    {
        fail(test, needle);
        return 0;
    }
    return 1;
}

static int text_between_has(const char *text, const char *begin, const char *end,
                            const char *needle)
{
    const char *first = strstr(text, begin), *last;

    if (!first || !(last = strstr(first, end))) return -1;
    first = strstr(first, needle);
    return first && first < last;
}

static int require_text_between(const char *test, const char *text, const char *begin,
                                const char *end, const char *needle)
{
    int found = text_between_has(text, begin, end, needle);

    if (found == 1) return 1;
    fail(test, found < 0 ? "expected code section was not found" : needle);
    return 0;
}

static int forbid_text_between(const char *test, const char *text, const char *begin,
                               const char *end, const char *needle)
{
    int found = text_between_has(text, begin, end, needle);

    if (found == 0) return 1;
    fail(test, found < 0 ? "expected code section was not found" : needle);
    return 0;
}

static int require_order(const char *test, const char *text, const char *first,
                         const char *second)
{
    const char *a = strstr(text, first), *b;

    if (a && (b = strstr(a, second)) && b > a) return 1;
    fail(test, !a ? first : second);
    return 0;
}

static void check_pointer_setting_fallback(const char *stack, const char *safety,
                                           const char *lifecycle, const char *final)
{
    int ok = 1;

    ok &= require_text("pointer settings use safe source fallback", safety,
                       "staticconstchar*constsources[]={\"environment\",\"AppDefaultsregistry\","
                       "\"globalregistry\"};");
    ok &= require_text("application and global settings are read separately", safety,
                       "key=source_index==1?appkey:defkey;");
    if (count_occurrences(safety, "for(source_index=0;source_index<3;source_index++)") != 2)
    {
        fail("pointer settings try every available source",
             "expected one loop for named settings and one for InertiaRate");
        ok = 0;
    }
    if (count_occurrences(stack, "pointer_option_enum(defkey,appkey,") < 6)
    {
        fail("the original six named pointer settings use fallback",
             "one or more named settings bypass fallback");
        ok = 0;
    }
    ok &= require_text("SmoothScrolling uses named-setting fallback", stack,
                       "pointer_option_enum(defkey,appkey,\"SmoothScrolling\","
                       "\"WINE_X11_SMOOTH_SCROLLING\"");
    ok &= require_text("TouchpadInertia uses named-setting fallback", stack,
                       "pointer_option_enum(defkey,appkey,\"TouchpadInertia\","
                       "\"WINE_X11_TOUCHPAD_INERTIA\"");
    ok &= require_text("PinchZoom uses named-setting fallback", stack,
                       "pointer_option_enum(defkey,appkey,\"PinchZoom\",\"WINE_X11_PINCH_ZOOM\"");
    ok &= require_text("MiddleDrag uses named-setting fallback", stack,
                       "pointer_option_enum(defkey,appkey,\"MiddleDrag\",\"WINE_X11_MIDDLE_DRAG\"");
    ok &= require_text("InertiaCurve uses named-setting fallback", stack,
                       "pointer_option_enum(defkey,appkey,\"InertiaCurve\","
                       "\"WINE_X11_INERTIA_CURVE\"");
    ok &= require_text("WarpEmulation uses named-setting fallback", stack,
                       "pointer_option_enum(defkey,appkey,\"WarpEmulation\","
                       "\"WINE_X11_WARP_EMULATION\"");
    ok &= require_text("named settings are case-insensitive", lifecycle,
                       "if(strcasecmp(buffer,names[i]))continue;");
    ok &= require_text("off and zero alias a disabled setting", lifecycle,
                       "if(!strcasecmp(names[0],\"disabled\")&&"
                       "(!strcasecmp(buffer,\"off\")||!strcmp(buffer,\"0\")))");
    ok &= require_text("invalid named settings use the diagnostic channel", lifecycle,
                       "WARN_(winediag)(\"unrecognized%svalue%sfromthe%s,ignoringit\\n\","
                       "name,debugstr_a(buffer),source);");
    ok &= require_text("invalid inertia rates use the diagnostic channel", lifecycle,
                       "WARN_(winediag)(\"InertiaRatevalue%sfromthe%sisnotadecimalin[0.5,16.0],ignoringit\\n\","
                       "debugstr_a(buffer),source);continue;");
    ok &= require_text("a valid inertia rate ends the search", safety,
                       "pointer_config.inertia_rate=parsed;"
                       "TRACE(\"InertiaRate=%.2f(%s)\\n\",parsed,source);break;");
    ok &= require_text("disabled remains a valid inertia setting", stack,
                       "staticconstchar*constinertia_names[]={\"disabled\",\"auto\",\"enabled\"};");
    ok &= require_text("middle throw has an independent setting", lifecycle,
                       "pointer_option_enum(defkey,appkey,\"MiddleDragThrow\","
                       "\"WINE_X11_MIDDLE_DRAG_THROW\"");
    ok &= require_text("held-button wheel input has an independent setting", lifecycle,
                       "pointer_option_enum(defkey,appkey,\"WheelWhileButtonHeld\","
                       "\"WINE_X11_WHEEL_WHILE_BUTTON_HELD\"");
    ok &= require_text("fine inertia is enabled by default", lifecycle,
                       ".touchpad_inertia=POINTER_INERTIA_ENABLED");
    ok &= require_text("middle throw is enabled by default", lifecycle,
                       ".middle_drag_throw=POINTER_MIDDLE_DRAG_THROW_ENABLED");
    ok &= require_text("physical wheel input while held remains enabled by default", lifecycle,
                       ".wheel_while_button_held=POINTER_WHEEL_WHILE_BUTTON_HELD_ENABLED");
    ok &= require_text("the final default decay rate is four per second", final,
                       ".inertia_rate=4.0,");
    if (ok) pass("all eight named settings plus InertiaRate preserve safe source fallback");
}

static void check_warp_emulation(const char *stack, const char *warp)
{
    int ok = 1;

    ok &= require_text("warp state is process-wide and locked", warp,
                       "staticpthread_mutex_twarp_emulation_mutex=PTHREAD_MUTEX_INITIALIZER;");
    ok &= forbid_text("warp state does not return to the X11 thread struct", warp,
                      "warp_have_last");
    ok &= forbid_text("warp state has no event-count timeout", warp, "warp_idle");
    ok &= forbid_text("warp state has no polling-rate-dependent event limit", warp, ">512");

    ok &= require_text("warp emulation remains opt-in until the hardware matrix is complete", stack,
                       ".warp_emulation=POINTER_WARP_DISABLED");
    ok &= require_text("warp emulation has a registry setting and environment escape hatch", stack,
                       "pointer_option_enum(defkey,appkey,\"WarpEmulation\","
                       "\"WINE_X11_WARP_EMULATION\"");
    ok &= require_text("warp setting exposes disabled auto and forced modes", stack,
                       "staticconstchar*constwarp_names[]={\"disabled\",\"auto\",\"enabled\"};");
    ok &= require_text("automatic warp handling is limited to XWayland", warp,
                       "XQueryExtension(display,\"XWAYLAND\"");

    ok &= require_order("the pre-warp server point is sampled before XWarpPointer", warp,
                        "XQueryPointer(data->display,root_window", "XWarpPointer(data->display");
    ok &= require_text("extended held buttons survive the core-mask reconciliation", warp,
                       "buttons|=warp_emulation.buttons&~7u;");
    ok &= require_text("only one ordinary held button can arm a warp", warp,
                       "if(!(buttons&7u)||(buttons&(buttons-1)))");
    ok &= require_text_between("every new button press resets warp evidence", warp,
                               "staticvoidwarp_emulation_button_press(",
                               "staticvoidwarp_emulation_button_release(",
                               "warp_emulation.failed_votes=0;");
    ok &= require_text_between("every button release resets warp evidence", warp,
                               "staticvoidwarp_emulation_button_release(",
                               "staticBOOLwarp_emulation_available(",
                               "warp_emulation.failed_votes=0;");
    ok &= require_text_between("wheel presses cancel probes without becoming held buttons", warp,
                               "staticvoidwarp_emulation_button_press(",
                               "staticvoidwarp_emulation_button_release(",
                               "if(button_up_flags[index]){bit=1u<<index;"
                               "warp_emulation.buttons|=bit;}");
    ok &= require_text_between("wheel releases cannot disturb held-button ownership", warp,
                               "staticvoidwarp_emulation_button_release(",
                               "staticBOOLwarp_emulation_available(",
                               "if(button_up_flags[index]){bit=1u<<index;"
                               "warp_emulation.buttons&=~bit;}");
    ok &= require_text("every warp keeps a fixed pre-warp baseline", warp,
                       "warp_emulation.prewarp=prewarp;");
    ok &= require_text("raw correlation uses accelerated XI2 values", warp,
                       "warp_emulation_raw_motion(event->display,event->sourceid,event->time,"
                       "x_value*x_scale,y_value*y_scale);");
    ok &= require_text("failed-warp expectation includes the raw delta", warp,
                       "failed.x=warp_emulation.prewarp.x+round(warp_emulation.raw_dx);");
    ok &= require_text("server-applied expectation includes the same raw delta", warp,
                       "applied.x=warp_emulation.target.x+round(warp_emulation.raw_dx);");
    ok &= require_text("raw evidence is tied to one warp generation", warp,
                       "warp_emulation.raw_generation!=warp_emulation.generation");
    ok &= require_text("raw evidence is tied to the cooked event connection", warp,
                       "warp_emulation.raw_display!=display||warp_emulation.raw_time!=time");
    ok &= require_text("conflicting raw sources keep automatic mode native", warp,
                       "elsewarp_emulation.raw_conflict=TRUE;");
    ok &= require_text("automatic mode needs two failed correlations", warp,
                       "#defineWARP_EMULATION_FAILURE_VOTES2");
    ok &= require_text("successful or ambiguous evidence returns to native mapping", warp,
                       "warp_emulation.failed_votes=0;warp_emulation.reporting=FALSE;");
    ok &= require_text("mapped motion uses the fixed pre-warp point without losing a delta", warp,
                       "warp_emulation.reported.x=warp_emulation.target.x+pos.x-"
                       "warp_emulation.prewarp.x;");

    ok &= require_order("synthetic warp motion is rejected before it can vote", warp,
                        "if(is_old_motion_event(event->serial))", "warp_emulation_reconcile_motion");
    ok &= require_order("cross-thread synthetic warp motion is rejected before reconciliation", warp,
                        "if(warp_emulation_ignore_synthetic(pt))returnFALSE;",
                        "warp_emulation_reconcile_motion(event->state);");
    ok &= require_text("every cross-thread synthetic target copy is rejected", warp,
                       "warp_emulation.synthetic_pending&&pos.x==warp_emulation.target.x&&"
                       "pos.y==warp_emulation.target.y)ignore=TRUE;");
    ok &= require_text("the first non-target cooked motion ends synthetic filtering", warp,
                       "elseif(warp_emulation.synthetic_pending)"
                       "warp_emulation.synthetic_pending=FALSE;");
    ok &= require_order("middle navigation consumes native coordinates before warp mapping", warp,
                        "if(middle_drag_motion(event,pt,time))returnTRUE;",
                        "pt=map_emulated_warp_coords(event->display,pt,event->time,TRUE);");
    ok &= require_order("release coordinates are mapped before warp state is cleared", warp,
                        "pt=map_emulated_warp_coords(event->display,pt,event->time,FALSE);",
                        "warp_emulation_button_release(event->button);");
    ok &= require_order("middle release cannot leave warp emulation armed", warp,
                        "warp_emulation_button_release(event->button);",
                        "if(middle_drag_end(event,pt,time))");
    ok &= require_text("extended press buttons are checked before warp bookkeeping", warp,
                       "if(button>=NB_BUTTONS)warp_emulation_cancel();"
                       "elsewarp_emulation_button_press(event->button);");
    ok &= require_text("release mapping is limited to real held buttons", warp,
                       "if(button>=NB_BUTTONS)warp_emulation_cancel();else{"
                       "if(button_up_flags[button])"
                       "pt=map_emulated_warp_coords(event->display,pt,event->time,FALSE);"
                       "warp_emulation_button_release(event->button);}");
    ok &= require_order("extended release buttons are checked before array lookup", warp,
                        "if(button>=NB_BUTTONS)warp_emulation_cancel();else{",
                        "if(button_up_flags[button])");
    ok &= require_text("a keyboard-grab refusal disarms an older transform", warp,
                       "if(keyboard_grabbed){warp_emulation_disarm();"
                       "WARN(\"refusingtowarpto%u,%u\\n\",pos.x,pos.y);returnFALSE;}");
    ok &= require_text("a pointer-grab refusal disarms an older transform", warp,
                       "!=GrabSuccess){warp_emulation_disarm();"
                       "WARN(\"refusingtowarppointerto%u,%uwithoutexclusivegrab\\n\","
                       "pos.x,pos.y);returnFALSE;}");

    ok &= require_text("clip release cancels warp state before an early return", warp,
                       "warp_emulation_cancel();if(!clip_window)return;");
    ok &= require_text("capture transitions cancel before the flags early return", warp,
                       "warp_emulation_cancel();"
                       "if(!(flags&(GUI_INMOVESIZE|GUI_INMENUMODE)))return;");
    ok &= require_text("FocusOut cancellation runs before focus guards", warp,
                       "if(event->detail!=NotifyPointer)warp_emulation_cancel();"
                       "if(event->detail==NotifyPointer)");
    ok &= require_text("device replacement cancels warp state", warp,
                       "if(event->deviceid!=data->xinput2_pointer)returnFALSE;"
                       "warp_emulation_cancel();update_relative_valuators");
    ok &= require_text("thread detach cancels process warp state", warp,
                       "if(data){warp_emulation_cancel();");

    if (ok) pass("XWayland warp emulation activates only from correlated failed warps");
}

static void check_held_and_direct_input(const char *stack, const char *safety,
                                        const char *lifecycle, const char *control)
{
    int ok = 1;

    ok &= require_text("held valuators advance the baseline and emit zero", stack,
                       "if(!axis->value_valid||reseed){axis->value=value;axis->value_valid=TRUE;return0;");
    ok &= require_text("XI and process LMB state control reseeding", control,
                       "buttons_down=xinput2_any_button_down(event)||held_control_drag_active();");
    ok &= require_text("horizontal held movement is reseeded", stack,
                       "smooth_scroll_delta(&src->scroll_x,value_x,buttons_down,quantize,&discontinuity);");
    ok &= require_text("vertical held movement is reseeded", stack,
                       "smooth_scroll_delta(&src->scroll_y,value_y,buttons_down,quantize,&discontinuity);");
    ok &= require_text("button state cannot select an output mode", stack,
                       "quantize=pointer_config.smooth_scrolling==POINTER_SCROLL_NOTCHED;");
    ok &= forbid_text("held movement cannot become notched output", safety,
                      "POINTER_SCROLL_NOTCHED||buttons_down");
    ok &= require_text("held wheel input requires enabled mode and exact provenance", lifecycle,
                       "if(pointer_config.wheel_while_button_held=="
                       "POINTER_WHEEL_WHILE_BUTTON_HELD_ENABLED&&event_button_mask&&"
                       "event_button_mask==held_button_mask&&"
                       "!x11drv_thread_data()->middle_drag.active)");
    ok &= require_text_between("only a stable held physical wheel uses the stock input path", lifecycle,
                               "staticBOOLsend_discrete_wheel_input(",
                               "/*Middle-dragnavigation",
                               "returnsend_mouse_input(hwnd,pt,MOUSEEVENTF_ABSOLUTE|flags,"
                               "delta,time,NULL);");
    ok &= require_text_between("the driver suppresses wheel input for mismatched held state", lifecycle,
                               "staticBOOLsend_discrete_wheel_input(",
                               "/*Middle-dragnavigation",
                               "if(event_button_mask||held_button_mask||"
                               "x11drv_thread_data()->middle_drag.active)");
    ok &= require_text_between("unheld physical wheel input retains guarded positioning", lifecycle,
                               "staticBOOLsend_discrete_wheel_input(",
                               "/*Middle-dragnavigation",
                               "returnsend_wheel_at_input(hwnd,pt,flags,delta,time,NULL,FALSE);");
    ok &= require_text("core wheel provenance includes core and extended-button masks", lifecycle,
                       "core_event_button_mask(event->state)|"
                       "(pointer_button_mask()&((1u<<3)|(1u<<4)))");
    ok &= require_text("native XI wheel provenance maps all ordinary buttons", lifecycle,
                       "staticconstunsignedintbuttons[]={1,2,3,8,9};");
    ok &= require_text("native XI wheel provenance preserves each mapped bit", lifecycle,
                       "XIMaskIsSet(event->buttons.mask,buttons[i]))mask|=1u<<i;");
    ok &= require_text("native XI wheel uses the full event button mask", lifecycle,
                       "send_discrete_wheel_input(hwnd,pt,button_down_flags[button],"
                       "(int)button_down_data[button],time,xinput2_ordinary_button_mask(event));");
    ok &= require_text("direct XI scroll separates cursor and wheel submission", safety,
                       "if(!send_mouse_input(hwnd,pt,MOUSEEVENTF_ABSOLUTE,0,time,NULL))returnFALSE;"
                       "returnsend_wheel_at_input(hwnd,pt,flags,delta,time,NULL,FALSE);");
    ok &= forbid_text_between("cursor movement cannot inherit fixed-wheel flags", safety,
                              "staticBOOLsend_xinput2_wheel_input(", "/*Addboundedinertia",
                              "MOUSEEVENTF_ABSOLUTE|flags");
    ok &= require_text("held smooth valuators still reseed without gesture output", lifecycle,
                       "if(buttons_down||discontinuity){");
    ok &= require_text("the driver forwards ordinary XI motion with no scroll axes", stack,
                       "if(!have_x&&!have_y)returnforward_xinput2_core_event(hwnd,event,FALSE);");
    ok &= require_order("the driver reads held state before handling pointer motion in a scroll report", control,
                        "buttons_down=xinput2_any_button_down(event)||held_control_drag_active();",
                        "if(saw_motion&&(!buttons_down||data->middle_drag.active||"
                        "held_control_drag_active()))");
    ok &= require_text("LMB scroll reports reach only the de-duplicating control channel", control,
                       "if(saw_motion&&(!buttons_down||data->middle_drag.active||"
                       "held_control_drag_active()))forward_xinput2_core_event(hwnd,event,TRUE);");
    if (ok) pass("physical wheel and held LMB motion have isolated delivery routes");
}

static void check_held_control_drag(const char *control)
{
    int ok = 1;

    ok &= require_text("held LMB state is process-wide and mutex protected", control,
                       "}held_control_drag;staticpthread_mutex_theld_control_drag_mutex="
                       "PTHREAD_MUTEX_INITIALIZER;");
    ok &= require_text_between("Button1 starts at the unmodified cooked press point", control,
                               "staticvoidheld_control_drag_button_press(",
                               "staticBOOLheld_control_drag_button_release(",
                               "held_control_drag.logical_x=point.x;"
                               "held_control_drag.logical_y=point.y;"
                               "held_control_drag.emitted=point;");
    ok &= require_text_between("wheel transitions do not terminate the control drag", control,
                               "staticvoidheld_control_drag_button_press(",
                               "staticBOOLheld_control_drag_button_release(",
                               "if(button>=Button4&&button<=7)return;");
    ok &= require_text_between("a chord cannot remain in the LMB-only channel", control,
                               "staticvoidheld_control_drag_button_press(",
                               "staticBOOLheld_control_drag_button_release(",
                               "if(button!=Button1||(state&(Button2Mask|Button3Mask)))");
    ok &= require_text("the release uses the last logical point before clearing state", control,
                       "*point=held_control_drag.emitted;TRACE("
                       "\"heldLMBcontroldragendsat%s\\n\",wine_dbgstr_point(point));}"
                       "held_control_drag_reset_locked();");

    ok &= require_text("the control channel records server-processed XI2 pointer deltas", control,
                       "held_control_drag_raw_motion(event->display,event->time,"
                       "x_value*x_scale,y_value*y_scale);");
    ok &= require_text("the raw delta comes from processed rather than WM_INPUT values", control,
                       "raw->x=*raw_values;x_value=*values;");
    ok &= require_text_between("each raw total is consumed only once", control,
                               "staticenumheld_control_motion_result"
                               "held_control_drag_apply_raw_locked(",
                               "staticenumheld_control_motion_result"
                               "held_control_drag_clipped_motion(",
                               "dx=held_control_drag.raw_dx-held_control_drag.raw_used_x;"
                               "dy=held_control_drag.raw_dy-held_control_drag.raw_used_y;"
                               "held_control_drag.raw_used_x=held_control_drag.raw_dx;"
                               "held_control_drag.raw_used_y=held_control_drag.raw_dy;");
    ok &= require_text_between("Wine applies raw control deltas with unit gain", control,
                               "staticenumheld_control_motion_result"
                               "held_control_drag_apply_raw_locked(",
                               "staticenumheld_control_motion_result"
                               "held_control_drag_clipped_motion(",
                               "held_control_drag.logical_x+=dx;"
                               "held_control_drag.logical_y+=dy;");
    ok &= forbid_text_between("the exact control-delta path has no configurable transfer", control,
                              "staticenumheld_control_motion_result"
                              "held_control_drag_apply_raw_locked(",
                              "staticenumheld_control_motion_result"
                              "held_control_drag_clipped_motion(", "pointer_config");
    ok &= require_text("attached X connections cannot multiply one raw frame", control,
                       "heldLMBcontroldragignoresduplicaterawframeonanotherconnection");
    ok &= require_text("a cooked-before-raw frame is marked consumed", control,
                       "if(held_control_drag.fallback_valid&&"
                       "held_control_drag.fallback_time==time){"
                       "held_control_drag.raw_used_x=held_control_drag.raw_dx;"
                       "held_control_drag.raw_used_y=held_control_drag.raw_dy;}");
    ok &= require_text("scroll-bearing frames without pointer deltas are suppressed", control,
                       "if(co_reported_scroll){held_control_drag.native=native;"
                       "held_control_drag.native_valid=TRUE;gotodone;}");
    ok &= require_text("cooked-only motion is an exact coordinate fallback", control,
                       "dx=native.x-held_control_drag.native.x;"
                       "dy=native.y-held_control_drag.native.y;");

    ok &= require_order("the LMB channel runs before optional warp mapping", control,
                        "held_result=held_control_drag_motion(",
                        "pt=map_emulated_warp_coords(event->display,pt,event->time,TRUE);");
    ok &= require_text("only a delivered held delta emits an absolute move", control,
                       "if(held_result==HELD_CONTROL_MOTION_DELIVERED)"
                       "send_mouse_input(hwnd,pt,MOUSEEVENTF_ABSOLUTE,0,time,NULL);");
    ok &= require_text("SetCursorPos reanchors the logical control point", control,
                       "held_control_drag_reanchor((POINT){x,y});");
    ok &= require_order("GetCursorPos gives the LMB point precedence over warp state", control,
                        "warp_emulation_get_position(pos);",
                        "held_control_drag_get_position(pos);");
    ok &= require_text("clipped input uses the same logical absolute channel", control,
                       "held_result=held_control_drag_clipped_motion(event->time,&held_pt);");
    ok &= require_text("clipped LMB input cannot also emit normal relative motion", control,
                       "if(held_result!=HELD_CONTROL_MOTION_INACTIVE){pointer_inertia_cancel();"
                       "if(held_result==HELD_CONTROL_MOTION_DELIVERED)"
                       "send_mouse_input(NULL,held_pt,MOUSEEVENTF_ABSOLUTE,0,time,&raw);"
                       "elsesend_mouse_input(NULL,(POINT){0},0,0,time,&raw);returnTRUE;}");

    ok &= require_order("LMB isolation precedes configurable physical-wheel routing", control,
                        "if(held_control_drag_active()){TRACE("
                        "\"discretewheel%dsuppressed:heldLMBcontroldragisisolated\\n\",delta);"
                        "returnTRUE;}",
                        "if(pointer_config.wheel_while_button_held==");
    ok &= require_text("pinch cannot enter during the process LMB channel", control,
                       "pinch_input_blocked()||pointer_button_down()||held_control_drag_active()");
    ok &= require_text("held control motion always cancels continuation", control,
                       "if(held_result!=HELD_CONTROL_MOTION_INACTIVE){"
                       "pointer_inertia_cancel();");
    ok &= require_text("capture acquisition preserves the active drag", control,
                       "pointer_inertia_cancel();if(!hwnd)held_control_drag_cancel();"
                       "warp_emulation_cancel();");
    ok &= require_text("device replacement cancels the active drag", control,
                       "if(event->deviceid!=data->xinput2_pointer)returnFALSE;"
                       "held_control_drag_cancel();warp_emulation_cancel();");
    ok &= require_text("thread teardown cancels the active drag", control,
                       "if(data){held_control_drag_cancel();warp_emulation_cancel();");
    ok &= require_text("focus loss cancels the active drag", control,
                       "held_control_drag_cancel();warp_emulation_cancel();"
                       "/*apinchinprogressdoesnotsurvivelosingtheinputfocus*/");
    if (ok) pass("held LMB control motion is exact-once and gesture-free");
}

static void check_legacy_wheel_copy_guard(const char *final)
{
    int ok = 1;

    ok &= require_text("legacy wheel-copy correlation is per X11 thread", final,
                       "structx11drv_legacy_wheel_copylegacy_wheel_copy;");
    ok &= require_text_between("legacy wheel-copy tags retain raw X time", final,
                               "structx11drv_legacy_wheel_copy{",
                               "externvoidpointer_scroll_invalidate_baselines", "Timetime;");
    ok &= require_text_between("legacy wheel-copy tags retain expected directions", final,
                               "structx11drv_legacy_wheel_copy{",
                               "externvoidpointer_scroll_invalidate_baselines",
                               "unsignedintwheel_buttons;");
    ok &= require_text_between("legacy wheel-copy tags retain the held mask", final,
                               "structx11drv_legacy_wheel_copy{",
                               "externvoidpointer_scroll_invalidate_baselines",
                               "unsignedintheld_buttons;");
    ok &= require_text_between("legacy wheel-copy tags retain the X target window", final,
                               "structx11drv_legacy_wheel_copy{",
                               "externvoidpointer_scroll_invalidate_baselines", "Windowwindow;");
    ok &= require_text("an emulated XI report without held buttons cannot arm suppression", final,
                       "if(!held_buttons){legacy_wheel_copy_reset("
                       "\"emulatedXIreporthasnoheldordinarybutton\");return;}");
    ok &= require_text("vertical legacy directions come from the changed XI axis", final,
                       "legacy_wheel_copy_direction(&src->scroll_y,value_y,4,5)");
    ok &= require_text("horizontal legacy directions come from the changed XI axis", final,
                       "legacy_wheel_copy_direction(&src->scroll_x,value_x,6,7)");
    ok &= require_text("a tag generation is keyed by time held mask and target window", final,
                       "if(!copy->valid||copy->time!=event->time||"
                       "copy->held_buttons!=held_buttons||copy->window!=event->event)");
    ok &= require_text("a new tag generation clears all prior correlation state", final,
                       "if(copy->valid)legacy_wheel_copy_reset(\"newemulatedXIreport\");"
                       "copy->time=event->time;");
    ok &= require_text("a later directionless XI report expires an older tag", final,
                       "if(copy->valid&&copy->time!=event->time)legacy_wheel_copy_reset("
                       "\"newemulatedXIreporthasnolegacycopy\");");
    ok &= require_text("a tag stores the raw XI time mask and target", final,
                       "copy->time=event->time;copy->held_buttons=held_buttons;"
                       "copy->window=event->event;copy->wheel_buttons=0;copy->valid=TRUE;");
    ok &= require_order("the emulated XI tag is captured before baselines advance", final,
                        "legacy_wheel_copy_tag(event,src,have_x,value_x,have_y,value_y);",
                        "if(have_x)smooth_scroll_delta(&src->scroll_x,value_x,TRUE,FALSE,NULL);");
    ok &= require_text_between("only an emulated XI scroll report arms a legacy tag", final,
                               "if(emulated){", "/*Forwardco-reportedpointermotion",
                               "legacy_wheel_copy_tag(event,src,have_x,value_x,have_y,value_y);");

    ok &= require_text("a different raw X timestamp expires the tag", final,
                       "if(event->time!=copy->time){legacy_wheel_copy_reset("
                       "\"legacycorewheeltimechanged\");returnFALSE;}");
    ok &= require_text("only matching direction time window held state and server events suppress", final,
                       "if(event->send_event||event->window!=copy->window||"
                       "!(copy->wheel_buttons&button_bit)||!held_buttons||"
                       "held_buttons!=copy->held_buttons)");
    ok &= forbid_text_between("one same-time smooth report may suppress all of its legacy copies", final,
                              "staticBOOLlegacy_wheel_copy_suppress(",
                              "staticvoidlegacy_wheel_copy_button_release(",
                              "copy->wheel_buttons&=");
    ok &= require_text("tagged legacy copies are rejected before physical-wheel routing", final,
                       "if(legacy_wheel_copy_suppress(event,event_button_mask)){"
                       "pinch_button_release(event->button);returnTRUE;}"
                       "#endifsend_discrete_wheel_input(");

    ok &= require_text("ordinary button presses reset a pending legacy tag", final,
                       "if(!pinch_button_is_wheel(event->button))legacy_wheel_copy_reset("
                       "\"corebuttonpressboundary\");");
    ok &= require_text("button releases apply the legacy-tag boundary", final,
                       "legacy_wheel_copy_button_release(event);");
    ok &= require_text("later or non-wheel releases expire a legacy tag", final,
                       "if(!pinch_button_is_wheel(event->button)||event->time!=copy->time)"
                       "legacy_wheel_copy_reset(\"corebuttonreleaseboundary\");");
    ok &= require_text("scroll baseline invalidation expires a legacy tag", final,
                       "legacy_wheel_copy_reset(\"scrollbaselineinvalidation\");");
    ok &= require_text("scroll metadata changes expire a legacy tag", final,
                       "legacy_wheel_copy_reset(\"scrolldevicemetadatachanged\");");
    ok &= require_text("scroll device removal expires a legacy tag", final,
                       "legacy_wheel_copy_reset(\"scrolldeviceremovedordisabled\");");
    if (ok) pass("held-button legacy smooth-scroll copies require exact X event correlation");
}

static void check_direct_packet_bounds(const char *stack, const char *safety,
                                       const char *final)
{
    int ok = 1;

    if (count_occurrences(safety, "staticconstintmax_delta=WHEEL_DELTA;") != 2)
    {
        fail("smooth and pinch reports are each limited to one notch",
             "expected one exact limit in each final decoder");
        ok = 0;
    }
    ok &= require_text("large smooth jumps reset their baseline", safety,
                       "if(fabs(units)>2.0*max_delta){axis->value=value;"
                       "if(discontinuity)*discontinuity=TRUE;return0;}");
    ok &= require_text("smooth excess is discarded after one notch", stack,
                       "if((delta=round(units))>max_delta||delta<-max_delta){axis->value=value;"
                       "returndelta>0?max_delta:-max_delta;}");
    ok &= require_text("middle-drag horizontal input is inverted", final,
                       "move_x=drag->last.x-pt.x;");
    ok &= require_text("middle-drag vertical input is inverted", final,
                       "move_y=drag->last.y-pt.y;");
    ok &= require_text("middle-drag vertical movement is bounded before delivery", final,
                       "delta_y=middle_drag_delta(&drag->accum_y,notched);");
    ok &= require_text("middle-drag horizontal movement is bounded before delivery", final,
                       "delta_x=middle_drag_delta(&drag->accum_x,notched);");
    ok &= require_text_between("pinch reports are limited to one notch", stack,
                               "staticBOOLX11DRV_GesturePinchEvent(",
                               "pthread_mutex_lock(&pinch_mutex);",
                               "staticconstintmax_delta=WHEEL_DELTA;");
    ok &= require_text("pinch cancellation is limited to one notch", stack,
                       "if(delta>max_delta)delta=max_delta;elseif(delta<-max_delta)delta=-max_delta;");
    ok &= require_text("live pinch updates are limited to one notch", stack,
                       "if((delta=round(units))>max_delta)delta=max_delta;"
                       "elseif(delta<-max_delta)delta=-max_delta;");
    ok &= require_text("pinch output stays at its begin point", stack,
                       "send_wheel_control_input(hwnd,anchor,delta,time);");
    ok &= require_text("unknown mouse buttons also block pinch output", safety,
                       "returnpinch_state.buttons_down||pinch_state.other_buttons_down||"
                       "pinch_state.wheel_requests;");
    ok &= require_text("unknown button counts cannot wrap", safety,
                       "elseif(pinch_state.other_buttons_down!=~0u)pinch_state.other_buttons_down++;");
    if (ok) pass("direct scroll, middle drag, and pinch packets are bounded");
}

static void check_continuation_sources(const char *lifecycle, const char *final)
{
    int ok = 1;

    ok &= require_text("middle continuation has independent enablement", lifecycle,
                       "if(kind==POINTER_INERTIA_KIND_MIDDLE_DRAG)returnpointer_config."
                       "middle_drag_throw==POINTER_MIDDLE_DRAG_THROW_ENABLED;");
    ok &= require_text("fine continuation requires enabled mode", lifecycle,
                       "returnpointer_config.touchpad_inertia==POINTER_INERTIA_ENABLED;");
    ok &= require_text("middle throw records raw pointer movement", final,
                       "middle_drag_throw_sample(x11drv_thread_data(),drag->hwnd,drag->origin,"
                       "move_x,-move_y,time);");
    if (count_occurrences(final, "middle_drag_throw_sample(") != 1)
    {
        fail("the final override has one post-slop middle sample site",
             "a press anchor or additional motion sample site remains");
        ok = 0;
    }
    ok &= require_order("middle history begins only after drag slop is crossed", final,
                        "if(!drag->moved){", "if(move_x||move_y)middle_drag_throw_sample(");
    ok &= require_order("the slop-crossing motion becomes the first middle sample", final,
                        "drag->moved=TRUE;}", "if(move_x||move_y)middle_drag_throw_sample(");
    ok &= require_text("a completed middle drag evaluates its release", lifecycle,
                       "middle_drag_throw_release(data,drag->hwnd,time);");
    ok &= require_text("a middle click cancels continuation state", lifecycle,
                       "elsepointer_inertia_cancel();");
    ok &= require_text("middle throw uses an explicit Button2 release reason", lifecycle,
                       "pointer_inertia_release(data,POINTER_INERTIA_KIND_MIDDLE_DRAG,"
                       "INERTIA_SOURCE_MIDDLE_DRAG,hwnd,time,"
                       "POINTER_INERTIA_END_MIDDLE_RELEASE);");
    ok &= require_text("fine estimator retains its ten-millisecond timing floor", final,
                       "#defineINERTIA_MIN_SPAN_MS10");
    ok &= require_text("middle estimator uses a 100 ms terminal suffix", final,
                       "#defineMIDDLE_THROW_HISTORY_MS100");
    ok &= require_text("middle estimator permits at most an 80 ms terminal gap", final,
                       "#defineMIDDLE_THROW_MAX_GAP_MS80");
    ok &= require_text("untimed coalesced middle motion receives a 24 ms span", final,
                       "#defineMIDDLE_THROW_FALLBACK_SPAN_MS24");
    ok &= require_text("middle throw requires four pixels of net terminal motion", final,
                       "#defineMIDDLE_THROW_MIN_DISTANCE4.0");
    ok &= require_text("middle estimator starts at the newest raw sample", final,
                       "start=si->count-1;j=(si->pos+start)%INERTIA_HISTORY_SIZE;"
                       "last=previous=si->history[j].time;");
    ok &= require_text("middle estimator rejects release after its terminal gap", lifecycle,
                       "if(release_time-last>MIDDLE_THROW_MAX_GAP_MS)");
    ok &= require_text("middle estimator walks backward through one contiguous suffix", final,
                       "if(last-si->history[j].time>MIDDLE_THROW_HISTORY_MS||"
                       "previous-si->history[j].time>MIDDLE_THROW_MAX_GAP_MS)break;"
                       "previous=si->history[j].time;start--;");
    ok &= require_text("middle estimator sums every selected terminal delta", final,
                       "for(i=start;i<si->count;i++){"
                       "j=(si->pos+i)%INERTIA_HISTORY_SIZE;sum_x+=si->history[j].dx;"
                       "sum_y+=si->history[j].dy;}");
    ok &= require_text("only one or all-same-time samples enter the fallback", final,
                       "if(si->count-start<2||!span){distance=hypot(sum_x,sum_y);");
    ok &= require_text("the fallback alone applies distance and 24 ms", final,
                       "if(distance<MIDDLE_THROW_MIN_DISTANCE){"
                       "TRACE(\"middlethrowfallbackrejected:terminaldistance%.3fpixels\\n\",distance);"
                       "returnFALSE;}span=MIDDLE_THROW_FALLBACK_SPAN_MS;}"
                       "elseif(span<INERTIA_MIN_SPAN_MS)");
    if (count_occurrences(final, "distance=hypot(sum_x,sum_y);") != 1 ||
        count_occurrences(final, "span=MIDDLE_THROW_FALLBACK_SPAN_MS;") != 1)
    {
        fail("distance and fallback span apply only to untimed middle input",
             "the final override contains another distance or fallback path");
        ok = 0;
    }
    ok &= require_text("two or more timed samples require a ten-millisecond span", final,
                       "elseif(span<INERTIA_MIN_SPAN_MS){"
                       "TRACE(\"middlethrowrejected:%utimedsamplesover%ums\\n\","
                       "si->count-start,span);returnFALSE;}");
    ok &= require_text("fine velocity includes the first selected fractional delta", final,
                       "if(!used)first=si->history[j].time;last=si->history[j].time;"
                       "sum_x+=si->history[j].dx;sum_y+=si->history[j].dy;");
    ok &= require_text("raw middle motion converts to wheel units only after estimation", lifecycle,
                       "*vx=sum_x*1000.0*WHEEL_DELTA/(span*MIDDLE_DRAG_STEP);"
                       "*vy=sum_y*1000.0*WHEEL_DELTA/(span*MIDDLE_DRAG_STEP);");
    ok &= require_text("middle release uses its own terminal-gap gate", lifecycle,
                       "UINTrelease_gate=kind==POINTER_INERTIA_KIND_MIDDLE_DRAG?"
                       "MIDDLE_THROW_MAX_GAP_MS:INERTIA_RELEASE_GATE_MS;");
    ok &= require_text_between("middle tracking never arms the inactivity timer", lifecycle,
                               "staticvoidpointer_inertia_record(",
                               "staticvoidpointer_scroll_inertia_activity(",
                               "if(kind==POINTER_INERTIA_KIND_FINE_SCROLL)"
                               "inertia_nudge_arm(hwnd,si->input_serial,INERTIA_DEADLINE_MS);");
    ok &= require_text("stray timer ticks cannot release a middle throw", lifecycle,
                       "if(si->kind==POINTER_INERTIA_KIND_MIDDLE_DRAG){"
                       "TRACE(\"middlethrowignoresstraytimertick;awaitingButton2release\\n\");"
                       "return;}");

    ok &= require_text("unchanged scroll input remains the preferred explicit marker", lifecycle,
                       "stop_marker=(have_x||have_y)&&");
    ok &= require_text("changed cumulative valuators are tracked before baselines advance", final,
                       "scroll_changed=(have_x&&src->scroll_x.last_value_valid&&"
                       "value_x!=src->scroll_x.last_value)||"
                       "(have_y&&src->scroll_y.last_value_valid&&"
                       "value_y!=src->scroll_y.last_value);");
    ok &= require_order("changed-but-rounded-zero XI2 activity is not discarded", final,
                        "scroll_changed=(have_x&&", "if(have_x){src->scroll_x.last_value=value_x;");
    ok &= require_order("the driver records raw horizontal units before advancing their baseline", final,
                        "units_x=WHEEL_DELTA*(value_x-src->scroll_x.last_value)/"
                        "src->scroll_x.increment;",
                        "if(have_x){src->scroll_x.last_value=value_x;");
    ok &= require_order("the driver records raw vertical units before advancing their baseline", final,
                        "units_y=WHEEL_DELTA*(value_y-src->scroll_y.last_value)/"
                        "src->scroll_y.increment;",
                        "if(have_y){src->scroll_y.last_value=value_y;");
    ok &= require_text("explicit marker wins over changed-scroll activity", final,
                       "if(stop_marker)pointer_inertia_stop_marker(data,event->sourceid,hwnd,time);"
                       "elseif(scroll_changed)pointer_scroll_inertia_activity(");
    ok &= require_text("fine activity records raw fractional units rather than rounded output", final,
                       "pointer_scroll_inertia_activity(data,event->sourceid,hwnd,pt,"
                       "units_x,-units_y,time);");
    ok &= require_text("fine activity retains double-precision samples", lifecycle,
                       "staticvoidpointer_scroll_inertia_activity(structx11drv_thread_data*data,"
                       "intsourceid,HWNDhwnd,POINTanchor,doubledx,doubledy,UINTtime)");
    ok &= require_text("fine activity records every accepted fractional sample", lifecycle,
                       "pointer_inertia_record(data,POINTER_INERTIA_KIND_FINE_SCROLL,sourceid,hwnd,"
                       "anchor,dx,dy,time);");
    ok &= require_text_between("every accepted activity sample stores its terminal axis and time", lifecycle,
                               "staticvoidpointer_inertia_record(",
                               "staticvoidpointer_scroll_inertia_activity(",
                               "si->history[i].dy=dy;si->history[i].time=time;");
    ok &= require_text_between("a discontinuity cancels only prior fine-scroll history", lifecycle,
                               "if(buttons_down||discontinuity){",
                               "elseif(pointer_config.smooth_scrolling==POINTER_SCROLL_PRECISE)",
                               "if(!data->middle_drag.active)pointer_inertia_cancel();");
    ok &= require_text_between("a discontinuity zeros both output axes", lifecycle,
                               "if(buttons_down||discontinuity){",
                               "elseif(pointer_config.smooth_scrolling==POINTER_SCROLL_PRECISE)",
                               "if(discontinuity)delta_x=delta_y=0;");
    ok &= require_text("fine inactivity fallback requires enabled mode", lifecycle,
                       "if(si->kind==POINTER_INERTIA_KIND_FINE_SCROLL&&"
                       "pointer_inertia_enabled(POINTER_INERTIA_KIND_FINE_SCROLL)&&"
                       "now-si->last_time<=2*INERTIA_DEADLINE_MS)");
    ok &= require_text("late inactivity abandons rather than fabricating a coast", lifecycle,
                       "else{TRACE(\"%strackingabandonedafter%umsinactive\\n\",");
    ok &= require_text("inactivity fallback uses its distinct conservative reason", lifecycle,
                       "pointer_inertia_evaluate(data,now,POINTER_INERTIA_END_XI2_INACTIVITY);");
    ok &= require_text("inactivity needs twice the explicit-marker starting speed", lifecycle,
                       "if(reason==POINTER_INERTIA_END_XI2_INACTIVITY)start_speed*=2.0;");
    ok &= require_text("motion from the same scroll report keeps the continuation history", lifecycle,
                       "if(!co_reported_scroll)pointer_inertia_cancel();");
    ok &= require_text("the driver applies the held-button rule to native XI motion in its scroll report", final,
                       "if(saw_motion&&(!buttons_down||data->middle_drag.active))"
                       "forward_xinput2_core_event(hwnd,event,TRUE);");
    ok &= require_text("an emulated XI duplicate preserves an active middle throw", lifecycle,
                       "if(!data->middle_drag.active)pointer_inertia_cancel();returnTRUE;");
    if (ok) pass("fine inertia and middle throw have independent, explicit end policies");
}

static void check_inertia_timer_initialization(const char *final)
{
    int ok = 1;

    ok &= require_text("the inertia condition starts as uninitialised storage", final,
                       "staticpthread_cond_tinertia_nudge_cond;");
    ok &= forbid_text("the inertia condition is not statically and dynamically initialised", final,
                      "PTHREAD_COND_INITIALIZER");
    if (count_occurrences(final, "pthread_cond_init(&inertia_nudge_cond,&attr)") != 1)
    {
        fail("the inertia condition is initialised exactly once",
             "expected one dynamic condition-variable initialisation");
        ok = 0;
    }

    ok &= require_order("condition attributes are created before selecting a clock", final,
                        "pthread_condattr_init(&attr)",
                        "pthread_condattr_setclock(&attr,CLOCK_MONOTONIC)");
    ok &= require_order("the monotonic clock is selected before condition initialisation", final,
                        "pthread_condattr_setclock(&attr,CLOCK_MONOTONIC)",
                        "pthread_cond_init(&inertia_nudge_cond,&attr)");
    ok &= require_order("condition attributes are destroyed after condition initialisation", final,
                        "pthread_cond_init(&inertia_nudge_cond,&attr)",
                        "pthread_condattr_destroy(&attr)");

    ok &= require_text("attribute initialisation failure disables the timer", final,
                       "if((ret=pthread_condattr_init(&attr))){"
                       "WARN(\"failedtoinitialiseinertiaconditionattributes(%d),"
                       "inertiadisabled\\n\",ret);inertia_nudge.failed=TRUE;}");
    ok &= require_text("clock or condition initialisation failure disables the timer", final,
                       "if((ret=pthread_condattr_setclock(&attr,CLOCK_MONOTONIC))||"
                       "(ret=pthread_cond_init(&inertia_nudge_cond,&attr))){"
                       "WARN(\"failedtoinitialisemonotonicinertiacondition(%d),"
                       "inertiadisabled\\n\",ret);inertia_nudge.failed=TRUE;}"
                       "pthread_condattr_destroy(&attr);");
    ok &= require_text("timer setup failure prevents worker creation", final,
                       "if(!inertia_nudge.failed&&NtCreateThreadEx(&thread,THREAD_ALL_ACCESS,NULL,"
                       "NtCurrentProcess(),inertia_nudge_thread,NULL,0,0,0,0,NULL))");
    ok &= require_text("a failed setup cannot enter the worker-success branch", final,
                       "elseif(!inertia_nudge.failed)");
    ok &= require_order("only the guarded worker-success branch marks the timer running", final,
                        "elseif(!inertia_nudge.failed)", "inertia_nudge.running=TRUE;");
    if (ok) pass("the inertia timer uses one monotonic condition and disables itself on failure");
}

static void check_one_shot_inertia_ticks(const char *final)
{
    static const char tick_begin[] =
        "voidpointer_inertia_tick(LONGinput_serial){"
        "structx11drv_thread_data*data=x11drv_thread_data();";
    static const char coast_begin[] = "caseINERTIA_COASTING:break;}";
    static const char tick_end[] = "UINTtime=EVENT_x11_time_to_win32_time(event->time);";
    size_t count;
    int ok = 1;

    ok &= require_text_between("each timer slot carries its tracker generation", final,
                               "staticpthread_cond_tinertia_nudge_cond;staticstruct{",
                               "for(i=0;i<INERTIA_NUDGE_SLOTS;i++)", "LONGinput_serial;");
    ok &= forbid_text_between("timer slots carry no repeating interval", final,
                              "staticpthread_cond_tinertia_nudge_cond;staticstruct{",
                              "for(i=0;i<INERTIA_NUDGE_SLOTS;i++)", "UINTinterval;");
    ok &= forbid_text_between("timer slots carry no repeating mode", final,
                              "staticpthread_cond_tinertia_nudge_cond;staticstruct{",
                              "for(i=0;i<INERTIA_NUDGE_SLOTS;i++)", "BOOLrepeating;");
    ok &= forbid_text("the final timer has no repeating scheduler state", final, "repeating");
    ok &= require_text("timer arms require an explicit generation", final,
                       "staticvoidinertia_nudge_arm(HWNDhwnd,LONGinput_serial,UINTinterval)");
    ok &= forbid_text("the repeating timer signature cannot return", final,
                      "inertia_nudge_arm(HWNDhwnd,UINTinterval,BOOL");
    ok &= forbid_text("coast arms cannot request a repeating timer", final,
                      "INERTIA_TICK_MS,TRUE");
    ok &= forbid_text("tracking arms cannot use the former Boolean timer mode", final,
                      "INERTIA_DEADLINE_MS,FALSE");

    ok &= require_text_between("the worker snapshots a due slot generation", final,
                               "for(i=0;i<INERTIA_NUDGE_SLOTS;i++){"
                               "HWNDhwnd=inertia_nudge.slots[i].hwnd;LONGinput_serial;BOOLok;",
                               "staticvoidinertia_nudge_arm(",
                               "input_serial=inertia_nudge.slots[i].input_serial;");
    ok &= require_order("the worker snapshots the generation before consuming its slot", final,
                        "input_serial=inertia_nudge.slots[i].input_serial;",
                        "inertia_nudge.slots[i].hwnd=0;");
    ok &= require_order("the worker consumes the slot before posting", final,
                        "inertia_nudge.slots[i].hwnd=0;",
                        "NtUserPostMessage(hwnd,WM_X11DRV_POINTER_TICK,"
                        "(WPARAM)(ULONG)input_serial,0)");
    ok &= require_text("the posted tick carries the captured generation in WPARAM", final,
                       "ok=NtUserPostMessage(hwnd,WM_X11DRV_POINTER_TICK,"
                       "(WPARAM)(ULONG)input_serial,0);");
    ok &= require_text("a post failure only records the consumed generation", final,
                       "if(!ok)TRACE(\"failedtopostpointertickforhwnd%pserial%ld\\n\","
                       "hwnd,(long)input_serial);");
    ok &= forbid_text_between("a post failure cannot clear a replacement schedule", final,
                              "if(!ok)TRACE(", "staticvoidinertia_nudge_arm(",
                              "inertia_nudge.slots[");

    ok &= require_text("the real tick handler accepts a generation", final, tick_begin);
    ok &= forbid_text("the untagged tick handler signature cannot return", final,
                      "pointer_inertia_tick(void)");
    ok &= require_text("the public tick declaration carries the generation", final,
                       "externvoidpointer_inertia_tick(LONGinput_serial);");
    ok &= require_text("the window dispatcher forwards the tick generation", final,
                       "caseWM_X11DRV_POINTER_TICK:pointer_inertia_tick((LONG)wp);return0;");
    ok &= require_text("idle or locally stale ticks return without touching state", final,
                       "if(si->state==INERTIA_IDLE||si->input_serial!=input_serial){"
                       "TRACE(\"stalepointertickserial%ld,current%ldstate%u\\n\","
                       "(long)input_serial,(long)si->input_serial,si->state);return;}");
    ok &= require_order("local stale-tick rejection precedes the process generation check", final,
                        "if(si->state==INERTIA_IDLE||si->input_serial!=input_serial)",
                        "if(si->input_serial!=InterlockedCompareExchange("
                        "&pointer_input_serial,0,0))");
    ok &= forbid_text_between("local stale-tick rejection cannot mutate tracker state", final,
                              "if(si->state==INERTIA_IDLE||si->input_serial!=input_serial)",
                              "if(si->input_serial!=InterlockedCompareExchange(",
                              "si->state=INERTIA_");

    if (count_occurrences(final, "inertia_nudge_arm(") != 6 ||
        count_occurrences(final, "inertia_nudge_arm(hwnd,si->input_serial,") != 1 ||
        count_occurrences(final, "inertia_nudge_arm(si->hwnd,si->input_serial,") != 4)
    {
        fail("every timer arm carries the current tracker generation",
             "expected one definition and five generation-tagged arm calls");
        ok = 0;
    }
    ok &= require_text("a new fine-scroll deadline carries its generation", final,
                       "inertia_nudge_arm(hwnd,si->input_serial,INERTIA_DEADLINE_MS);");
    ok &= require_text("a newly accepted coast tick carries its generation", final,
                       "inertia_nudge_arm(si->hwnd,si->input_serial,INERTIA_TICK_MS);");
    ok &= require_text("an early tracking tick rearms its generation only", final,
                       "inertia_nudge_arm(si->hwnd,si->input_serial,"
                       "INERTIA_DEADLINE_MS-(now-si->last_time));return;");

    ok &= require_text("an elapsed-zero coast rearms before returning", final,
                       "if(!(elapsed_ms=now-si->last_tick)){"
                       "inertia_nudge_arm(si->hwnd,si->input_serial,INERTIA_TICK_MS);return;}");
    ok &= require_text("a continuing coast rearms only at the handler end", final,
                       "elseinertia_nudge_arm(si->hwnd,si->input_serial,INERTIA_TICK_MS);}");
    count = count_occurrences_between(final, coast_begin, tick_end,
                                      "inertia_nudge_arm(si->hwnd,si->input_serial,"
                                      "INERTIA_TICK_MS)");
    if (count != 2)
    {
        fail("coasting rearms only for elapsed-zero and continued output",
             count == (size_t)-1 ? "coasting handler section was not found" :
                                   "unexpected coast rearm site count");
        ok = 0;
    }
    count = count_occurrences_between(final, tick_begin, tick_end, "inertia_nudge_arm(");
    if (count != 3)
    {
        fail("the tick handler has only tracking, elapsed-zero, and terminal rearm sites",
             count == (size_t)-1 ? "tick handler section was not found" :
                                   "unexpected tick-handler arm site count");
        ok = 0;
    }
    if (ok) pass("generation-tagged one-shot ticks cannot backlog or perturb replacement state");
}

static void check_inertia_lifecycle_cancellation(const char *final)
{
    int ok = 1;

    ok &= require_text("DestroyWindow cancels continuation before an unknown-window return", final,
                       "structx11drv_thread_data*thread_data=x11drv_thread_data();"
                       "structx11drv_win_data*data;pointer_inertia_cancel();"
                       "if(!(data=get_win_data(hwnd)))return;");
    ok &= require_text("DestroyNotify cancels continuation before an unknown-window return", final,
                       "structx11drv_win_data*data;BOOLembedded;pointer_inertia_cancel();"
                       "if(!(data=get_win_data(hwnd)))returnFALSE;");
    ok &= require_text("every capture transition cancels continuation before early return", final,
                       "TRACE(\"hwnd%p,flags%#x,previous%p\\n\",hwnd,flags,previous);"
                       "pointer_inertia_cancel();warp_emulation_cancel();"
                       "if(!(flags&(GUI_INMOVESIZE|GUI_INMENUMODE)))return;");
    if (ok) pass("capture and window destruction unconditionally cancel continuation state");
}

static void check_accumulator_routing(const char *safety)
{
    int ok = 1;

    ok &= require_text("accumulated motion has an explicit pending state", safety,
                       "BOOLmouse_motion_pending;");
    ok &= require_text("accumulated motion remembers its routing flags", safety,
                       "UINTmouse_motion_flags;");
    ok &= require_text("empty pending state is checked explicitly", safety,
                       "if(!info->mouse_motion_pending)returnSTATUS_SUCCESS;");
    ok &= require_text("pending motion is flushed with its own flags", safety,
                       "if(info->mouse_motion_pending&&flags!=info->mouse_motion_flags){"
                       "NTSTATUSstatus=send_mouse_motion(info->mouse_motion_flags);if(status)returnstatus;}");
    ok &= require_text("new pending motion stores its flags", safety,
                       "info->mouse_motion_flags=flags;info->mouse_motion_pending=TRUE;");
    ok &= require_text("submitted motion clears its pending state", safety,
                       "info->mouse_motion_flags=0;info->mouse_motion_pending=FALSE;");
    if (ok) pass("queued cursor movement keeps its own routing flags");
}

static void check_inertia_limits(const char *stack, const char *lifecycle, const char *final)
{
    int ok = 1;

    ok &= require_text("coast integration is limited to 16 ms", final,
                       "#defineINERTIA_MAX_FRAME_MS16");
    ok &= require_text("the driver limits one coast packet to 300 units", final,
                       "#defineINERTIA_MAX_PACKET300");
    ok &= require_text("the driver limits each coast axis to 4,800 units", final,
                       "#defineINERTIA_MAX_TRAVEL(40*WHEEL_DELTA)");
    ok &= require_text("the driver limits combined coast travel to 7,200 units", final,
                       "#defineINERTIA_MAX_TOTAL_TRAVEL(60*WHEEL_DELTA)");
    ok &= require_text("the driver limits one coast to 384 messages", final,
                       "#defineINERTIA_MAX_MESSAGES384");
    ok &= require_text("both continuation sources use the configured decay rate directly", stack,
                       "doubleelapsed_dt,frame_dt,k=pointer_config.inertia_rate;");
    ok &= require_text("the final policy selects the rate-four default", final,
                       ".inertia_rate=4.0,");
    ok &= forbid_text("middle throw has no hidden decay-scale constant", stack,
                      "MIDDLE_THROW_DECAY_SCALE");
    ok &= forbid_text_between("middle throw has no direct conditional rate multiplier", lifecycle,
                              "voidpointer_inertia_tick(LONGinput_serial){"
                              "structx11drv_thread_data*data=x11drv_thread_data();",
                              "BOOLstop_marker=FALSE,scroll_changed=FALSE;",
                              "POINTER_INERTIA_KIND_MIDDLE_DRAG?k");
    ok &= forbid_text_between("middle throw has no conditional rate-assignment block", lifecycle,
                              "voidpointer_inertia_tick(LONGinput_serial){"
                              "structx11drv_thread_data*data=x11drv_thread_data();",
                              "BOOLstop_marker=FALSE,scroll_changed=FALSE;",
                              "POINTER_INERTIA_KIND_MIDDLE_DRAG){k");
    if (count_occurrences_between(lifecycle, "voidpointer_inertia_tick(LONGinput_serial){"
                                  "structx11drv_thread_data*data=x11drv_thread_data();",
                                  "BOOLstop_marker=FALSE,scroll_changed=FALSE;",
                                  "si->kind==POINTER_INERTIA_KIND_MIDDLE_DRAG") != 3)
    {
        fail("the tick has no extra middle-specific decay branch",
             "expected only tracking and diagnostic middle-kind checks");
        ok = 0;
    }
    ok &= require_text("the final policy uses the shared-travel packet helper", final,
                       "staticintpointer_inertia_packet(double*remainder,double*velocity,"
                       "int*travel,int*travel_total)");
    ok &= require_text("the final policy retains the guarded timer tick", lifecycle,
                       "voidpointer_inertia_tick(LONGinput_serial)");
    ok &= require_text("the driver limits coast starting speed to 19,200 units per second", final,
                       "#defineINERTIA_MAX_SPEED19200.0");
    ok &= require_text("the coast state stores one shared message counter", final,
                       "unsignedintmessage_count;");
    ok &= require_text("combined coast travel has explicit state", final,
                       "inttravel_total;");
    ok &= require_text("a new coast resets axis total and message counts", final,
                       "si->travel_x=si->travel_y=0;si->travel_total=0;"
                       "si->message_count=0;");
    ok &= require_text("the packet helper discards whole-unit excess", final,
                       "intavailable=(int)*remainder;"
                       "intremaining=min(INERTIA_MAX_TRAVEL-*travel,"
                       "INERTIA_MAX_TOTAL_TRAVEL-*travel_total);intdelta;"
                       "*remainder-=available;");
    ok &= require_text("packet output uses the configured limit", stack,
                       "if(available>INERTIA_MAX_PACKET)delta=INERTIA_MAX_PACKET;"
                       "elseif(available<-INERTIA_MAX_PACKET)delta=-INERTIA_MAX_PACKET;");
    ok &= require_text("the packet helper counts travel per axis and across both axes", final,
                       "*travel+=abs(delta);*travel_total+=abs(delta);"
                       "if(*travel>=INERTIA_MAX_TRAVEL||"
                       "*travel_total>=INERTIA_MAX_TOTAL_TRAVEL)"
                       "*remainder=*velocity=0.0;");
    ok &= require_text("measured starting speed is clamped before coasting", stack,
                       "if(speed>INERTIA_MAX_SPEED){vx*=INERTIA_MAX_SPEED/speed;"
                       "vy*=INERTIA_MAX_SPEED/speed;}");
    ok &= require_text("an elapsed-zero tick returns only after rearming", lifecycle,
                       "if(!(elapsed_ms=now-si->last_tick)){"
                       "inertia_nudge_arm(si->hwnd,si->input_serial,INERTIA_TICK_MS);return;}");
    ok &= require_text("the tick integrates only the newest bounded frame", lifecycle,
                       "frame_ms=elapsed_ms>INERTIA_MAX_FRAME_MS?INERTIA_MAX_FRAME_MS:elapsed_ms;"
                       "elapsed_dt=elapsed_ms/1000.0;frame_dt=frame_ms/1000.0;");
    ok &= require_text("vertical output checks the message and combined-travel budgets", final,
                       "if(si->message_count<INERTIA_MAX_MESSAGES&&"
                       "(delta=pointer_inertia_packet(&si->rem_y,&si->vy,"
                       "&si->travel_y,&si->travel_total)))"
                       "{si->message_count++;");
    ok &= require_text("horizontal output checks the remaining shared budgets", final,
                       "if(si->message_count<INERTIA_MAX_MESSAGES&&"
                       "(delta=pointer_inertia_packet(&si->rem_x,&si->vx,"
                       "&si->travel_x,&si->travel_total)))"
                       "{si->message_count++;");
    if (count_occurrences(final, "si->message_count++;") != 2)
    {
        fail("each coast packet consumes one total message slot", "expected exactly two guarded send paths");
        ok = 0;
    }
    ok &= require_text("coasting stops when the message limit is used", final,
                       "if(si->message_count>=INERTIA_MAX_MESSAGES||");
    ok &= require_text("coasting retains the independent four-second limit", lifecycle,
                       "now-si->start_time>INERTIA_CAP_MS+1000");
    if (ok) pass("coasting retains frame, packet, axis, total-travel, and message limits");
}

static void check_inertia_generation(const char *stack, const char *safety,
                                     const char *final)
{
    int ok = 1;

    ok &= require_text("pointer input uses one process-wide generation", stack,
                       "staticpthread_mutex_tpointer_input_mutex=PTHREAD_MUTEX_INITIALIZER;"
                       "staticvolatileLONGpointer_input_serial;");
    ok &= require_text("a sample compares its prior generation and continuation kind", final,
                       "previous_serial=InterlockedCompareExchange(&pointer_input_serial,0,0);"
                       "current=si->state==INERTIA_TRACKING&&si->kind==kind&&si->sourceid==sourceid&&"
                       "si->hwnd==hwnd&&si->input_serial==previous_serial;");
    ok &= require_text("an accepted sample advances the generation", final,
                       "input_serial=InterlockedIncrement(&pointer_input_serial);"
                       "pthread_mutex_unlock(&pointer_input_mutex);");
    ok &= require_text("a non-current sample clears old history", safety,
                       "if(!current&&si->state!=INERTIA_IDLE){HWNDold_hwnd=si->hwnd;"
                       "si->state=INERTIA_IDLE;si->count=0;si->pos=0;");
    ok &= require_text("a new sequence stores only its own point", safety,
                       "if(new_sequence)si->anchor=anchor;");
    ok &= require_text("release validates kind source window and generation", final,
                       "current=si->state==INERTIA_TRACKING&&si->kind==kind&&"
                       "si->sourceid==sourceid&&si->hwnd==hwnd&&si->input_serial==input_serial;"
                       "input_serial=InterlockedIncrement(&pointer_input_serial);");
    ok &= require_text("ticks reject a superseded process generation", final,
                       "if(si->input_serial!=InterlockedCompareExchange(&pointer_input_serial,0,0)){"
                       "si->state=INERTIA_IDLE;si->count=0;");
    ok &= require_text("superseded process generations stop their scheduled tracker", stack,
                       "si->state=INERTIA_IDLE;si->count=0;"
                       "inertia_nudge_stop(si->hwnd);return;");
    ok &= require_text("guarded submission rejects a stale generation", safety,
                       "if(*expected_serial!=InterlockedCompareExchange(&pointer_input_serial,0,0))"
                       "{pthread_mutex_unlock(&pointer_input_mutex);returnFALSE;}");
    ok &= require_text("hardware-input status is normalised to Boolean success", safety,
                       "ret=!NtUserSendHardwareInput(hwnd,SEND_HWMSG_RAWINPUT|SEND_HWMSG_FIXED_POSITION|");
    ok &= require_text("vertical coast output carries the saved generation", safety,
                       "send_wheel_at_input(si->hwnd,si->anchor,MOUSEEVENTF_WHEEL,delta,now,"
                       "&si->input_serial,FALSE)");
    ok &= require_text("horizontal coast output carries the saved generation", safety,
                       "send_wheel_at_input(si->hwnd,si->anchor,MOUSEEVENTF_HWHEEL,delta,now,"
                       "&si->input_serial,FALSE)");
    ok &= forbid_text_between("stale output cannot invalidate newer input", safety,
                              "staticBOOLsend_wheel_at_input(", "staticBOOLpointer_button_down(",
                              "InterlockedIncrement(");
    if (ok) pass("new pointer input invalidates older tracking and coast output");
}

static void check_button_serial_and_middle_mode(const char *safety)
{
    int ok = 1;

    ok &= require_text("the driver reports every physical button early", safety,
                       "SERVER_START_REQ(update_driver_button){req->win=wine_server_user_handle(hwnd);"
                       "req->button=button;req->state=pinch_button_is_wheel(button)?-1:down;");
    ok &= require_text_between("every core press is recorded before range handling", safety,
                               "TRACE(\"hwnd%p/%lxbutton%upos%s\\n\"",
                               "if(button>=NB_BUTTONS)returnFALSE;",
                               "notify_button_transition(hwnd,event->button,TRUE);");
    if (count_occurrences(safety, "notify_button_transition(hwnd,event->button,FALSE);") != 3)
    {
        fail("every core release path clears early state",
             "expected unknown-button, middle-drag, and ordinary release notifications");
        ok = 0;
    }
    ok &= require_text("the server accepts early button updates", safety,
                       "DECL_HANDLER(update_driver_button)");
    ok &= require_text("invalid early button reports are rejected", safety,
                       "if(!req->button||req->state<-1||req->state>1){"
                       "set_error(STATUS_INVALID_PARAMETER);return;}");
    ok &= require_text("all physical buttons map to a tracked bucket", safety,
                       "case1:return0;case2:return1;case3:return2;case8:return3;"
                       "case9:return4;default:return5;");
    ok &= require_text("early button counts cannot wrap to released", safety,
                       "if(shared->driver_button_count[bucket]!=0xff)"
                       "shared->driver_button_count[bucket]++;"
                       "elseshared->driver_button_overflow|=1u<<bucket;");
    ok &= require_text("overflowed early state remains held", safety,
                       "elseif(!(shared->driver_button_overflow&(1u<<bucket))&&"
                       "shared->driver_button_count[bucket])shared->driver_button_count[bucket]--;");
    ok &= require_text("every early report advances the serial", safety,
                       "advance_mouse_button_serial(desktop);release_object(desktop);");

    if (count_occurrences(safety, "time,NULL,TRUE);") != 2)
    {
        fail("only two live middle-drag sends request the exception",
             "expected vertical and horizontal middle_drag_motion sends only");
        ok = 0;
    }
    ok &= require_text("vertical live middle drag requests the exception", safety,
                       "send_wheel_at_input(drag->hwnd,drag->origin,MOUSEEVENTF_WHEEL,-delta_y,"
                       "time,NULL,TRUE)");
    ok &= require_text("horizontal live middle drag requests the exception", safety,
                       "send_wheel_at_input(drag->hwnd,drag->origin,MOUSEEVENTF_HWHEEL,delta_x,"
                       "time,NULL,TRUE)");
    ok &= require_text("the helper adds the middle-drag flag only on request", safety,
                       "(middle_drag?SEND_HWMSG_MIDDLE_DRAG:0),&input,0);");
    ok &= require_text("the server derives the narrow middle-drag mode", safety,
                       "boolmiddle_drag=!!(req->flags&SEND_HWMSG_MIDDLE_DRAG);"
                       "unsignedintfixed_position=req->flags&SEND_HWMSG_FIXED_POSITION?"
                       "(middle_drag?HWMSG_FIXED_POSITION_MIDDLE_DRAG:"
                       "HWMSG_FIXED_POSITION_NO_BUTTONS):HWMSG_FIXED_POSITION_NONE;");
    ok &= require_text("invalid middle-drag flag combinations are rejected", safety,
                       "if(middle_drag&&(!(req->flags&SEND_HWMSG_FIXED_POSITION)||force_mk_control||"
                       "origin!=IMO_HARDWARE||req->input.type!=INPUT_MOUSE||"
                       "(req->input.mouse.flags!=MOUSEEVENTF_WHEEL&&"
                       "req->input.mouse.flags!=MOUSEEVENTF_HWHEEL))){"
                       "set_error(STATUS_INVALID_PARAMETER);return;}");
    ok &= require_text("ordinary fixed output requires no early buttons", safety,
                       "if(fixed_position==HWMSG_FIXED_POSITION_NO_BUTTONS)expected_mask=0;");
    ok &= require_text("middle-drag output requires exactly the middle mask", safety,
                       "elseif(fixed_position==HWMSG_FIXED_POSITION_MIDDLE_DRAG)expected_mask=1u<<1;"
                       "elsereturn1;");
    ok &= require_text("server gates require unchanged serial and exact mask", safety,
                       "if(button_serial!=current_serial||desktop_shm->driver_button_mask!=expected_mask)"
                       "return1;");
    ok &= require_text("server gates reject all Win32 button state", safety,
                       "(desktop_shm->keystate[VK_LBUTTON]|desktop_shm->keystate[VK_MBUTTON]|"
                       "desktop_shm->keystate[VK_RBUTTON]|desktop_shm->keystate[VK_XBUTTON1]|"
                       "desktop_shm->keystate[VK_XBUTTON2])&0x80)return1;");
    ok &= require_text("server middle mode requires one non-overflowed Button2", safety,
                       "if(expected_mask&&(desktop_shm->driver_button_count[1]!=1||"
                       "(desktop_shm->driver_button_overflow&expected_mask)))return1;");
    ok &= require_text("client gates require the same exact mask", safety,
                       "stale=desktop_shm->mouse_button_serial!=button_serial||"
                       "desktop_shm->driver_button_mask!=expected_mask||");
    ok &= require_text("client middle mode requires one non-overflowed Button2", safety,
                       "(expected_mask&&(desktop_shm->driver_button_count[1]!=1||"
                       "(desktop_shm->driver_button_overflow&expected_mask)));");
    if (count_occurrences(safety, "fixed_wheel_is_stale(fixed_position,fixed_button_serial)") != 4)
    {
        fail("client delivery rechecks fixed wheel mode after every delay",
             "expected entry, two process-return, and post-hook checks");
        ok = 0;
    }
    if (count_occurrences(safety, "fixed_wheel_is_stale(") < 8)
    {
        fail("server and client both enforce fixed wheel mode",
             "expected definitions plus initial, post-hook, dequeue, and client checks");
        ok = 0;
    }
    ok &= require_text("fixed messages carry their mode and button serial", safety,
                       "msg->fixed_button_serial=desktop->mouse_button_serial;"
                       "msg_data->fixed_position=fixed_position;"
                       "msg_data->fixed_button_serial=msg->fixed_button_serial;");
    if (ok) pass("only an exact live Button2 drag can use the middle-drag exception");
}

struct safe_axis
{
    double velocity;
    double remainder;
    unsigned int travel;
};

enum reference_warp_probe
{
    REFERENCE_WARP_AMBIGUOUS,
    REFERENCE_WARP_FAILED,
    REFERENCE_WARP_APPLIED,
};

static double reference_warp_distance(double ax, double ay, double bx, double by)
{
    return fmax(fabs(ax - bx), fabs(ay - by));
}

static enum reference_warp_probe reference_warp_probe(
    double pre_x, double pre_y, double target_x, double target_y,
    double raw_x, double raw_y, double cooked_x, double cooked_y,
    int raw_seen, unsigned int raw_time, unsigned int cooked_time)
{
    double span = reference_warp_distance(pre_x, pre_y, target_x, target_y);
    double failed_x, failed_y, applied_x, applied_y;
    double failed_error, applied_error, tolerance;

    if (span < 8.0 || !raw_seen || raw_time != cooked_time) return REFERENCE_WARP_AMBIGUOUS;
    failed_x = pre_x + round(raw_x);
    failed_y = pre_y + round(raw_y);
    applied_x = target_x + round(raw_x);
    applied_y = target_y + round(raw_y);
    failed_error = reference_warp_distance(cooked_x, cooked_y, failed_x, failed_y);
    applied_error = reference_warp_distance(cooked_x, cooked_y, applied_x, applied_y);
    tolerance = fmin(8.0, fmax(2.0, span / 8.0));
    if (failed_error <= tolerance && applied_error >= failed_error + span / 2.0)
        return REFERENCE_WARP_FAILED;
    if (applied_error <= tolerance && failed_error >= applied_error + span / 2.0)
        return REFERENCE_WARP_APPLIED;
    return REFERENCE_WARP_AMBIGUOUS;
}

static int reference_ignore_synthetic(
    double target_x, double target_y, double cooked_x, double cooked_y,
    int *pending)
{
    if (!*pending) return 0;
    if (cooked_x == target_x && cooked_y == target_y) return 1;
    *pending = 0;
    return 0;
}

static void check_warp_probe_math(void)
{
    unsigned int votes = 0;
    enum reference_warp_probe probe;
    int synthetic_pending = 1;
    double mapped;

    probe = reference_warp_probe(100, 20, 50, 20, 5, 0, 105, 20, 1, 10, 10);
    mapped = 50 + 105 - 100;
    if (probe != REFERENCE_WARP_FAILED || mapped != 55)
        fail("a failed warp preserves its first physical delta",
             "the first cooked motion was lost or classified incorrectly");
    else
        pass("a failed warp preserves its first physical delta");

    /* At steady velocity a server-applied cooked point can equal the old
     * pre-warp point. Coordinate proximity alone misclassifies this case;
     * the shared raw delta identifies target + delta correctly. */
    probe = reference_warp_probe(60, 20, 50, 20, 10, 0, 60, 20, 1, 11, 11);
    if (probe != REFERENCE_WARP_APPLIED)
        fail("server-handled steady motion is not double-emulated",
             "raw/cooked correlation did not identify target plus delta");
    else
        pass("server-handled steady motion is not double-emulated");

    if (!reference_ignore_synthetic(50, 20, 50, 20, &synthetic_pending) ||
        !reference_ignore_synthetic(50, 20, 50, 20, &synthetic_pending) ||
        reference_ignore_synthetic(50, 20, 51, 20, &synthetic_pending) || synthetic_pending ||
        reference_ignore_synthetic(50, 20, 50, 20, &synthetic_pending))
        fail("cross-thread synthetic warps are isolated", "copies survived or filtering stayed armed");
    else
        pass("cross-thread synthetic warps are isolated");

    if (reference_warp_probe(100, 20, 50, 20, 5, 0, 105, 20, 0, 12, 12) !=
            REFERENCE_WARP_AMBIGUOUS ||
        reference_warp_probe(100, 20, 50, 20, 5, 0, 105, 20, 1, 12, 13) !=
            REFERENCE_WARP_AMBIGUOUS ||
        reference_warp_probe(55, 20, 50, 20, 5, 0, 60, 20, 1, 14, 14) !=
            REFERENCE_WARP_AMBIGUOUS)
        fail("incomplete warp evidence stays native", "an unavailable correlation activated emulation");
    else
        pass("incomplete warp evidence stays native");

    probe = reference_warp_probe(100, 20, 50, 20, 5, 0, 105, 20, 1, 15, 15);
    if (probe == REFERENCE_WARP_FAILED) votes++;
    if (votes >= 2)
        fail("one failed correlation cannot activate automatic emulation", "hysteresis was bypassed");
    else
        pass("one failed correlation cannot activate automatic emulation");
    if (probe == REFERENCE_WARP_FAILED) votes++;
    if (votes != 2)
        fail("two failed correlations activate automatic emulation", "failure votes did not converge");
    else
        pass("two failed correlations activate automatic emulation");
}

/* Apply the production limits to one axis. */
static int safe_axis_tick(struct safe_axis *axis, unsigned int *total_travel,
                          unsigned int elapsed_ms, double rate)
{
    unsigned int frame_ms, remaining;
    double post_velocity, pre_frame_velocity, displacement;
    int raw, packet;

    if (!elapsed_ms || !axis->velocity) return 0;
    if (axis->travel >= MAX_TRAVEL_VALUE || *total_travel >= MAX_TOTAL_VALUE)
    {
        axis->velocity = axis->remainder = 0.0;
        return 0;
    }
    frame_ms = elapsed_ms < MAX_FRAME_MS_VALUE ? elapsed_ms : MAX_FRAME_MS_VALUE;
    post_velocity = axis->velocity * exp(-rate * elapsed_ms / 1000.0);
    pre_frame_velocity = post_velocity * exp(rate * frame_ms / 1000.0);
    displacement = (pre_frame_velocity - post_velocity) / rate;
    axis->velocity = post_velocity;
    axis->remainder += displacement;

    raw = (int)axis->remainder;
    if (raw > MAX_PACKET_VALUE)
    {
        packet = MAX_PACKET_VALUE;
        axis->remainder = 0.0;
    }
    else if (raw < -MAX_PACKET_VALUE)
    {
        packet = -MAX_PACKET_VALUE;
        axis->remainder = 0.0;
    }
    else
    {
        packet = raw;
        axis->remainder -= raw;
    }
    remaining = MAX_TRAVEL_VALUE - axis->travel;
    if (remaining > MAX_TOTAL_VALUE - *total_travel)
        remaining = MAX_TOTAL_VALUE - *total_travel;
    if ((unsigned int)abs(packet) > remaining)
    {
        packet = packet < 0 ? -(int)remaining : (int)remaining;
        axis->remainder = 0.0;
    }
    axis->travel += (unsigned int)abs(packet);
    *total_travel += (unsigned int)abs(packet);
    if (axis->travel == MAX_TRAVEL_VALUE || *total_travel == MAX_TOTAL_VALUE)
        axis->velocity = axis->remainder = 0.0;
    return packet;
}

struct reference_control_drag
{
    double logical_x;
    double logical_y;
    double raw_x;
    double raw_y;
    double used_x;
    double used_y;
    int emitted_x;
    int emitted_y;
    int native_valid;
    int native_x;
    int native_y;
};

static void reference_control_begin(struct reference_control_drag *drag, int x, int y)
{
    memset(drag, 0, sizeof(*drag));
    drag->logical_x = drag->emitted_x = drag->native_x = x;
    drag->logical_y = drag->emitted_y = drag->native_y = y;
    drag->native_valid = 1;
}

static void reference_control_record_raw(struct reference_control_drag *drag,
                                         double dx, double dy)
{
    drag->raw_x += dx;
    drag->raw_y += dy;
}

static int reference_control_consume_raw(struct reference_control_drag *drag)
{
    double dx = drag->raw_x - drag->used_x;
    double dy = drag->raw_y - drag->used_y;
    int x, y;

    drag->used_x = drag->raw_x;
    drag->used_y = drag->raw_y;
    if (!dx && !dy) return 0;
    drag->logical_x += dx;
    drag->logical_y += dy;
    x = round(drag->logical_x);
    y = round(drag->logical_y);
    if (x == drag->emitted_x && y == drag->emitted_y) return 0;
    drag->emitted_x = x;
    drag->emitted_y = y;
    return 1;
}

static int reference_control_cooked(struct reference_control_drag *drag,
                                    int x, int y, int co_reported_scroll)
{
    int dx, dy, emitted_x, emitted_y;

    if (co_reported_scroll)
    {
        drag->native_x = x;
        drag->native_y = y;
        drag->native_valid = 1;
        return 0;
    }
    if (!drag->native_valid)
    {
        drag->native_x = x;
        drag->native_y = y;
        drag->native_valid = 1;
        return 0;
    }
    dx = x - drag->native_x;
    dy = y - drag->native_y;
    drag->native_x = x;
    drag->native_y = y;
    drag->logical_x += dx;
    drag->logical_y += dy;
    emitted_x = round(drag->logical_x);
    emitted_y = round(drag->logical_y);
    if (emitted_x == drag->emitted_x && emitted_y == drag->emitted_y) return 0;
    drag->emitted_x = emitted_x;
    drag->emitted_y = emitted_y;
    return 1;
}

static void reference_control_reanchor(struct reference_control_drag *drag, int x, int y)
{
    drag->logical_x = drag->emitted_x = x;
    drag->logical_y = drag->emitted_y = y;
    drag->raw_x = drag->raw_y = drag->used_x = drag->used_y = 0.0;
    drag->native_valid = 0;
}

static void check_held_control_motion_math(void)
{
    struct reference_control_drag drag;
    int ok = 1;

    reference_control_begin(&drag, 100, 100);
    reference_control_record_raw(&drag, 0.25, -0.25);
    if (reference_control_consume_raw(&drag) ||
        reference_control_consume_raw(&drag))
        ok = 0;
    reference_control_record_raw(&drag, 0.25, -0.25);
    reference_control_record_raw(&drag, 3.0, -1.5);
    if (!reference_control_consume_raw(&drag) ||
        reference_control_consume_raw(&drag) ||
        fabs(drag.logical_x - 103.5) > 1e-12 ||
        fabs(drag.logical_y - 98.0) > 1e-12 ||
        drag.emitted_x != 104 || drag.emitted_y != 98)
        ok = 0;

    reference_control_reanchor(&drag, 400, 300);
    reference_control_record_raw(&drag, -2.25, 1.25);
    if (!reference_control_consume_raw(&drag) ||
        fabs(drag.logical_x - 397.75) > 1e-12 ||
        fabs(drag.logical_y - 301.25) > 1e-12 ||
        drag.emitted_x != 398 || drag.emitted_y != 301)
        ok = 0;

    reference_control_begin(&drag, 10, 20);
    if (!reference_control_cooked(&drag, 12, 15, 0) ||
        reference_control_cooked(&drag, 200, 200, 1) ||
        !reference_control_cooked(&drag, 201, 202, 0) ||
        drag.emitted_x != 13 || drag.emitted_y != 17)
        ok = 0;
    reference_control_reanchor(&drag, 50, 50);
    if (reference_control_cooked(&drag, 500, 500, 0) ||
        !reference_control_cooked(&drag, 502, 497, 0) ||
        drag.emitted_x != 52 || drag.emitted_y != 47)
        ok = 0;

    if (!ok)
        fail("held LMB reference motion is exact and duplicate-free",
             "gain, fractional carry, reanchor, duplicate, or scroll isolation changed");
    else
        pass("held LMB reference motion is exact and duplicate-free");
}

enum reference_wheel_route
{
    REFERENCE_WHEEL_FIXED,
    REFERENCE_WHEEL_STOCK,
    REFERENCE_WHEEL_SUPPRESSED,
};

static enum reference_wheel_route reference_wheel_route(
    int enabled, unsigned int event_mask, unsigned int held_mask,
    int middle_drag, int control_drag)
{
    if (control_drag) return REFERENCE_WHEEL_SUPPRESSED;
    if (enabled && event_mask && event_mask == held_mask && !middle_drag)
        return REFERENCE_WHEEL_STOCK;
    if (event_mask || held_mask || middle_drag) return REFERENCE_WHEEL_SUPPRESSED;
    return REFERENCE_WHEEL_FIXED;
}

static void check_held_wheel_provenance(void)
{
    unsigned int i;
    int ok = 1;

    for (i = 0; i < 5; i++)
        if (reference_wheel_route(1, 1u << i, 1u << i, 0, 0) != REFERENCE_WHEEL_STOCK)
            ok = 0;
    if (reference_wheel_route(1, 5u, 5u, 0, 0) != REFERENCE_WHEEL_STOCK ||
        reference_wheel_route(1, 1u, 2u, 0, 0) != REFERENCE_WHEEL_SUPPRESSED ||
        reference_wheel_route(1, 1u, 0u, 0, 0) != REFERENCE_WHEEL_SUPPRESSED ||
        reference_wheel_route(1, 0u, 1u, 0, 0) != REFERENCE_WHEEL_SUPPRESSED ||
        reference_wheel_route(0, 1u, 1u, 0, 0) != REFERENCE_WHEEL_SUPPRESSED ||
        reference_wheel_route(1, 2u, 2u, 1, 0) != REFERENCE_WHEEL_SUPPRESSED ||
        reference_wheel_route(1, 1u, 1u, 0, 1) != REFERENCE_WHEEL_SUPPRESSED ||
        reference_wheel_route(1, 0u, 0u, 0, 0) != REFERENCE_WHEEL_FIXED)
        ok = 0;
    if (!ok)
        fail("held-wheel routing requires exact physical provenance",
             "an unstable, disabled, middle-drag, or LMB-control case reached stock delivery");
    else
        pass("held-wheel routing requires exact physical provenance");
}

static int reference_legacy_copy_suppress(
    int valid, unsigned int tag_time, unsigned int event_time,
    unsigned long tag_window, unsigned long event_window,
    unsigned int wheel_buttons, unsigned int tag_held, unsigned int event_held,
    unsigned int button, int send_event)
{
    unsigned int button_bit;

    if (!valid || event_time != tag_time) return 0;
    button_bit = button <= 7 ? 1u << button : 0;
    return !send_event && event_window == tag_window &&
           (wheel_buttons & button_bit) && event_held && event_held == tag_held;
}

static void check_legacy_wheel_copy_model(void)
{
    const unsigned int vertical_up = 1u << 4;
    const unsigned int horizontal_left = 1u << 6;
    const unsigned int held = 1u << 0;
    int ok = 1;

    /* Direction bits deliberately survive repeated generated notches carrying
     * the same X timestamp. All other identity fields remain exact. */
    if (!reference_legacy_copy_suppress(1, 100, 100, 9, 9, vertical_up, held, held, 4, 0) ||
        !reference_legacy_copy_suppress(1, 100, 100, 9, 9, vertical_up, held, held, 4, 0) ||
        !reference_legacy_copy_suppress(1, 100, 100, 9, 9, horizontal_left, held, held, 6, 0) ||
        reference_legacy_copy_suppress(0, 100, 100, 9, 9, vertical_up, held, held, 4, 0) ||
        reference_legacy_copy_suppress(1, 100, 101, 9, 9, vertical_up, held, held, 4, 0) ||
        reference_legacy_copy_suppress(1, 100, 100, 9, 10, vertical_up, held, held, 4, 0) ||
        reference_legacy_copy_suppress(1, 100, 100, 9, 9, vertical_up, held, held, 5, 0) ||
        reference_legacy_copy_suppress(1, 100, 100, 9, 9, vertical_up, held, 2u, 4, 0) ||
        reference_legacy_copy_suppress(1, 100, 100, 9, 9, vertical_up, held, 0u, 4, 0) ||
        reference_legacy_copy_suppress(1, 100, 100, 9, 9, vertical_up, held, held, 4, 1) ||
        reference_legacy_copy_suppress(1, 100, 100, 9, 9, vertical_up, held, held, 8, 0))
        ok = 0;
    if (!ok)
        fail("legacy wheel-copy model admits only an exact generated event",
             "time, window, direction, held mask, or send_event isolation failed");
    else
        pass("legacy wheel-copy model admits only an exact generated event");
}

enum reference_touchpad_inertia_mode
{
    REFERENCE_TOUCHPAD_INERTIA_DISABLED,
    REFERENCE_TOUCHPAD_INERTIA_AUTO,
    REFERENCE_TOUCHPAD_INERTIA_ENABLED,
};

enum reference_middle_throw_mode
{
    REFERENCE_MIDDLE_THROW_DISABLED,
    REFERENCE_MIDDLE_THROW_ENABLED,
};

static int reference_continuation_enabled(
    int middle_drag, enum reference_touchpad_inertia_mode touchpad,
    enum reference_middle_throw_mode middle_throw)
{
    if (middle_drag) return middle_throw == REFERENCE_MIDDLE_THROW_ENABLED;
    return touchpad == REFERENCE_TOUCHPAD_INERTIA_ENABLED;
}

static void check_default_continuation_matrix(void)
{
    const enum reference_touchpad_inertia_mode default_touchpad =
        REFERENCE_TOUCHPAD_INERTIA_ENABLED;
    const enum reference_middle_throw_mode default_middle =
        REFERENCE_MIDDLE_THROW_ENABLED;

    if (!reference_continuation_enabled(0, default_touchpad, default_middle) ||
        !reference_continuation_enabled(1, default_touchpad, default_middle) ||
        reference_continuation_enabled(0, REFERENCE_TOUCHPAD_INERTIA_AUTO, default_middle) ||
        reference_continuation_enabled(0, REFERENCE_TOUCHPAD_INERTIA_DISABLED, default_middle) ||
        reference_continuation_enabled(1, default_touchpad, REFERENCE_MIDDLE_THROW_DISABLED) ||
        !reference_continuation_enabled(0, REFERENCE_TOUCHPAD_INERTIA_ENABLED,
                                        REFERENCE_MIDDLE_THROW_DISABLED) ||
        !reference_continuation_enabled(1, REFERENCE_TOUCHPAD_INERTIA_DISABLED,
                                        REFERENCE_MIDDLE_THROW_ENABLED))
        fail("default continuation matrix enables both independent sources",
             "a default was disabled, auto became active, or source controls were coupled");
    else
        pass("default continuation matrix enables fine inertia and middle throw; auto stays inert");
}

struct reference_middle_sample
{
    double dx;
    double dy;
    unsigned int time;
};

/* Apply the middle-drag estimator to chronological samples. */
static int reference_middle_throw_velocity(const struct reference_middle_sample *samples,
                                           size_t count, unsigned int release_time,
                                           double *vx, double *vy, unsigned int *measured_span)
{
    double sum_x = 0.0, sum_y = 0.0, distance;
    unsigned int first, last, previous, span;
    size_t i, start;

    if (!count) return 0;
    start = count - 1;
    last = previous = samples[start].time;
    if (release_time - last > MIDDLE_THROW_MAX_GAP_MS_VALUE) return 0;
    while (start)
    {
        const struct reference_middle_sample *sample = &samples[start - 1];

        if (last - sample->time > MIDDLE_THROW_HISTORY_MS_VALUE ||
            previous - sample->time > MIDDLE_THROW_MAX_GAP_MS_VALUE)
            break;
        previous = sample->time;
        start--;
    }

    first = samples[start].time;
    span = last - first;
    for (i = start; i < count; i++)
    {
        sum_x += samples[i].dx;
        sum_y += samples[i].dy;
    }

    if (count - start < 2 || !span)
    {
        distance = hypot(sum_x, sum_y);
        if (distance < MIDDLE_THROW_MIN_DISTANCE_VALUE) return 0;
        span = MIDDLE_THROW_FALLBACK_SPAN_MS_VALUE;
    }
    else if (span < INERTIA_MIN_SPAN_MS_VALUE) return 0;

    *vx = sum_x * 1000.0 * WHEEL_DELTA_VALUE / (span * MIDDLE_DRAG_STEP_VALUE);
    *vy = sum_y * 1000.0 * WHEEL_DELTA_VALUE / (span * MIDDLE_DRAG_STEP_VALUE);
    if (measured_span) *measured_span = span;
    return 1;
}

static int reference_middle_throw_starts(const struct reference_middle_sample *samples,
                                         size_t count, unsigned int release_time)
{
    double vx, vy;

    return reference_middle_throw_velocity(samples, count, release_time, &vx, &vy, NULL) &&
           hypot(vx, vy) >= START_SPEED_VALUE;
}

static void check_middle_throw_estimator_math(void)
{
    static const struct reference_middle_sample single[] =
    {
        {6.0, 0.0, 200},
    };
    static const struct reference_middle_sample same_time[] =
    {
        {3.0, 0.0, 100}, {3.0, 0.0, 100},
    };
    static const struct reference_middle_sample two_timed[] =
    {
        {8.0, 0.0, 0}, {8.0, 0.0, 16},
    };
    static const struct reference_middle_sample three_timed[] =
    {
        {5.0, 0.0, 0}, {5.0, 0.0, 8}, {5.0, 0.0, 16},
    };
    static const struct reference_middle_sample short_timed[] =
    {
        {8.0, 0.0, 0}, {8.0, 0.0, 9},
    };
    static const struct reference_middle_sample three_pixels[] =
    {
        {3.0, 0.0, 100},
    };
    static const struct reference_middle_sample four_pixels[] =
    {
        {4.0, 0.0, 100},
    };
    static const struct reference_middle_sample release_boundary[] =
    {
        {6.0, 0.0, 100},
    };
    static const struct reference_middle_sample below_start_speed[] =
    {
        {1.5, 0.0, 0}, {1.5, 0.0, 80},
    };
    static const struct reference_middle_sample short_distance_timed[] =
    {
        {0.5, 0.0, 0}, {0.5, 0.0, 10},
    };
    static const struct reference_middle_sample terminal_suffix[] =
    {
        {-50.0, 0.0, 0}, {6.0, 0.0, 200},
    };
    double vx, vy;
    unsigned int span;

    if (!reference_middle_throw_velocity(single, 1, 250, &vx, &vy, &span) ||
        span != MIDDLE_THROW_FALLBACK_SPAN_MS_VALUE || fabs(vx - 1250.0) > 0.000001 || vy)
        fail("one movement update can seed a middle throw",
             "the estimator lost its 24 ms assignment");
    else
        pass("one movement update uses the 24 ms assignment");

    if (!reference_middle_throw_velocity(same_time, 2, 180, &vx, &vy, &span) ||
        span != MIDDLE_THROW_FALLBACK_SPAN_MS_VALUE || fabs(vx - 1250.0) > 0.000001 || vy)
        fail("same-time middle samples retain a finite velocity", "the estimator used a zero span");
    else
        pass("same-time middle samples use the 24 ms assignment");

    if (!reference_middle_throw_velocity(two_timed, 2, 50, &vx, &vy, &span) ||
        span != 16 || fabs(vx - 5000.0) > 0.000001 || vy ||
        !reference_middle_throw_velocity(three_timed, 3, 50, &vx, &vy, &span) ||
        span != 16 || fabs(vx - 4687.5) > 0.000001 || vy)
        fail("timed middle samples include every selected delta", "the measured speed changed");
    else
        pass("timed middle samples include every selected delta");

    if (reference_middle_throw_velocity(short_timed, 2, 20, &vx, &vy, NULL))
        fail("distinct timestamps require ten milliseconds", "a nine-millisecond span passed");
    else
        pass("distinct timestamps require ten milliseconds");

    if (reference_middle_throw_velocity(three_pixels, 1, 100, &vx, &vy, NULL) ||
        !reference_middle_throw_velocity(four_pixels, 1, 100, &vx, &vy, NULL))
        fail("untimed movement requires four pixels", "the four-pixel boundary changed");
    else
        pass("untimed movement requires four pixels");

    if (!reference_middle_throw_velocity(release_boundary, 1, 180, &vx, &vy, NULL) ||
        reference_middle_throw_velocity(release_boundary, 1, 181, &vx, &vy, NULL))
        fail("middle release has an exact 80 ms freshness boundary",
             "the estimator did not accept 80 ms and reject 81 ms");
    else
        pass("middle release accepts 80 ms of rest and rejects 81 ms");

    if (!reference_middle_throw_velocity(below_start_speed, 2, 80, &vx, &vy, NULL) ||
        reference_middle_throw_starts(below_start_speed, 2, 80) ||
        !reference_middle_throw_velocity(short_distance_timed, 2, 10, &vx, &vy, NULL) ||
        fabs(vx - 500.0) > 0.000001)
        fail("timed movement uses speed rather than the untimed distance rule",
             "a slow timed path started or a short fast timed path failed");
    else
        pass("timed movement uses speed rather than the untimed distance rule");

    if (!reference_middle_throw_velocity(terminal_suffix, 2, 250, &vx, &vy, &span) ||
        span != MIDDLE_THROW_FALLBACK_SPAN_MS_VALUE || vx <= 0.0 || vy)
        fail("middle throw uses the newest suffix after a pause",
             "old opposite motion contaminated the terminal estimate");
    else
        pass("a pause discards old motion before the newest terminal suffix");
}

struct coast_result
{
    struct safe_axis axes[2];
    unsigned int total_travel;
    unsigned int messages;
    unsigned int elapsed_ms;
    unsigned int maximum_packet;
    int first_packets[2];
    int stopped_by_speed;
    int stopped_by_travel;
    int stopped_by_messages;
    int stopped_by_time;
};

static struct coast_result run_reference_coast(double vx, double vy, double rate)
{
    struct coast_result result = {0};
    unsigned int i, axis;

    result.axes[0].velocity = vx;
    result.axes[1].velocity = vy;
    for (i = 0; i < 1000; i++)
    {
        double tick_rate;

        if (hypot(result.axes[0].velocity, result.axes[1].velocity) < 60.0)
        {
            result.stopped_by_speed = 1;
            break;
        }
        if (result.messages >= MAX_MESSAGES_VALUE)
        {
            result.stopped_by_messages = 1;
            break;
        }
        if (result.total_travel >= MAX_TOTAL_VALUE)
        {
            result.stopped_by_travel = 1;
            break;
        }
        if (result.elapsed_ms > 4000)
        {
            result.stopped_by_time = 1;
            break;
        }

        result.elapsed_ms += 8;
        tick_rate = result.elapsed_ms > 3000 && rate < 14.0 ? 14.0 : rate;
        for (axis = 0; axis < 2 && result.messages < MAX_MESSAGES_VALUE; axis++)
        {
            int packet = safe_axis_tick(&result.axes[axis], &result.total_travel, 8, tick_rate);
            unsigned int magnitude = (unsigned int)abs(packet);

            if (i == 0) result.first_packets[axis] = packet;
            if (!packet) continue;
            if (magnitude > result.maximum_packet) result.maximum_packet = magnitude;
            result.messages++;
        }
    }
    if (result.messages >= MAX_MESSAGES_VALUE) result.stopped_by_messages = 1;
    if (result.total_travel >= MAX_TOTAL_VALUE) result.stopped_by_travel = 1;
    if (result.elapsed_ms > 4000) result.stopped_by_time = 1;
    return result;
}

static int coast_within_limits(const struct coast_result *result)
{
    return result->maximum_packet <= MAX_PACKET_VALUE &&
           result->axes[0].travel <= MAX_TRAVEL_VALUE &&
           result->axes[1].travel <= MAX_TRAVEL_VALUE &&
           result->total_travel <= MAX_TOTAL_VALUE &&
           result->messages <= MAX_MESSAGES_VALUE && result->elapsed_ms <= 4000;
}

static void check_math_limits(void)
{
    const double diagonal = MAX_SPEED_VALUE / sqrt(2.0);
    struct safe_axis normal = {MAX_SPEED_VALUE, 0.0, 0};
    struct safe_axis full_frame = {MAX_SPEED_VALUE, 0.0, 0};
    struct safe_axis stalled = {MAX_SPEED_VALUE, 0.0, 0};
    struct safe_axis overflow = {1000000000.0, 0.0, 0};
    struct safe_axis reverse = {-1000000000.0, 0.0, 0};
    struct coast_result medium, fast, default_single, default_diagonal, slow_diagonal, message_limited;
    double expected_velocity, expected_normal;
    unsigned int total = 0, angle, largest_default_messages = 0;
    int packet, next;

    packet = safe_axis_tick(&normal, &total, 8, DEFAULT_INERTIA_RATE_VALUE);
    expected_normal = MAX_SPEED_VALUE / DEFAULT_INERTIA_RATE_VALUE *
                      (1.0 - exp(-DEFAULT_INERTIA_RATE_VALUE * 0.008));
    if (packet != (int)expected_normal || abs(packet) > MAX_PACKET_VALUE)
        fail("maximum starting speed stays below the packet ceiling", "normal first packet was too large");
    else
        pass("maximum starting speed produces a bounded normal first packet");

    total = 0;
    packet = safe_axis_tick(&full_frame, &total, 16, DEFAULT_INERTIA_RATE_VALUE);
    if (packet != 297 || packet > MAX_PACKET_VALUE)
        fail("a full accepted frame stays within the packet limit", "the maximum frame changed");
    else
        pass("a full accepted frame stays within the packet limit");

    total = 0;
    packet = safe_axis_tick(&stalled, &total, 1000, DEFAULT_INERTIA_RATE_VALUE);
    expected_velocity = MAX_SPEED_VALUE * exp(-DEFAULT_INERTIA_RATE_VALUE);
    if (abs(packet) > MAX_PACKET_VALUE || fabs(stalled.velocity - expected_velocity) > 0.000001)
        fail("a delayed tick cannot catch up missed movement", "the delayed tick exceeded its limits");
    else
        pass("a delayed tick decays fully without replaying missed frames");

    total = 0;
    packet = safe_axis_tick(&overflow, &total, 8, DEFAULT_INERTIA_RATE_VALUE);
    overflow.velocity = 0.0;
    next = safe_axis_tick(&overflow, &total, 8, DEFAULT_INERTIA_RATE_VALUE);
    if (packet != MAX_PACKET_VALUE || next || overflow.remainder != 0.0)
        fail("positive packet excess is discarded", "excess survived as later output");
    else
        pass("positive packet excess is discarded");

    total = 0;
    packet = safe_axis_tick(&reverse, &total, 8, DEFAULT_INERTIA_RATE_VALUE);
    reverse.velocity = 0.0;
    next = safe_axis_tick(&reverse, &total, 8, DEFAULT_INERTIA_RATE_VALUE);
    if (packet != -MAX_PACKET_VALUE || next || reverse.remainder != 0.0)
        fail("negative packet excess is discarded", "excess survived as later output");
    else
        pass("negative packet excess is discarded");

    medium = run_reference_coast(4000.0, 0.0, DEFAULT_INERTIA_RATE_VALUE);
    fast = run_reference_coast(9600.0, 0.0, DEFAULT_INERTIA_RATE_VALUE);
    default_single = run_reference_coast(MAX_SPEED_VALUE, 0.0, DEFAULT_INERTIA_RATE_VALUE);
    default_diagonal = run_reference_coast(diagonal, diagonal, DEFAULT_INERTIA_RATE_VALUE);
    if (!coast_within_limits(&medium) || !medium.stopped_by_speed ||
        medium.first_packets[0] != 31 || medium.elapsed_ms < 1048 || medium.elapsed_ms > 1064 ||
        medium.axes[0].travel < 984 || medium.axes[0].travel > 986 ||
        !coast_within_limits(&fast) || !fast.stopped_by_speed ||
        fast.first_packets[0] != 75 || fast.elapsed_ms < 1264 || fast.elapsed_ms > 1280 ||
        fast.axes[0].travel < 2384 || fast.axes[0].travel > 2386 ||
        !coast_within_limits(&default_single) || !default_single.stopped_by_speed ||
        default_single.stopped_by_messages || default_single.stopped_by_travel ||
        default_single.first_packets[0] != 151 ||
        default_single.elapsed_ms < 1440 || default_single.elapsed_ms > 1456 ||
        default_single.axes[0].travel < 4784 || default_single.axes[0].travel > 4786 ||
        default_single.messages < 170 || default_single.messages > 178 ||
        !coast_within_limits(&default_diagonal) || !default_diagonal.stopped_by_speed ||
        default_diagonal.stopped_by_messages || default_diagonal.stopped_by_travel ||
        default_diagonal.elapsed_ms < 1440 || default_diagonal.elapsed_ms > 1456 ||
        default_diagonal.axes[0].travel < 3382 || default_diagonal.axes[0].travel > 3384 ||
        default_diagonal.axes[1].travel < 3382 || default_diagonal.axes[1].travel > 3384 ||
        default_diagonal.total_travel < 6764 || default_diagonal.total_travel > 6768 ||
        default_diagonal.messages < 330 || default_diagonal.messages > 338)
        fail("rate-four coasting keeps the expected packet, time, travel and update counts",
             "a first packet, duration, travel, or message count changed");
    else
        pass("rate-four coasting keeps the expected packet, time, travel and update counts");

    for (angle = 0; angle <= 90; angle++)
    {
        double radians = angle * 3.14159265358979323846 / 180.0;
        struct coast_result result = run_reference_coast(MAX_SPEED_VALUE * cos(radians),
                                                         MAX_SPEED_VALUE * sin(radians),
                                                         DEFAULT_INERTIA_RATE_VALUE);

        if (!coast_within_limits(&result) || !result.stopped_by_speed ||
            result.stopped_by_messages || result.stopped_by_travel)
        {
            fail("every default direction reaches its stop speed", "a limit shortened the movement");
            break;
        }
        if (result.messages > largest_default_messages) largest_default_messages = result.messages;
    }
    if (angle > 90)
    {
        if (largest_default_messages > 336)
            fail("default directions stay below the message limit", "the message count increased");
        else
            pass("default directions stay below the message limit");
    }

    slow_diagonal = run_reference_coast(diagonal, diagonal, 0.5);
    if (!coast_within_limits(&slow_diagonal) || !slow_diagonal.stopped_by_travel ||
        slow_diagonal.total_travel != MAX_TOTAL_VALUE)
        fail("slow custom curves stop at the combined travel limit", "the travel limit changed");
    else
        pass("slow custom curves stop at the combined travel limit");

    message_limited = run_reference_coast(240.0 * cos(18.0 * 3.14159265358979323846 / 180.0),
                                          240.0 * sin(18.0 * 3.14159265358979323846 / 180.0),
                                          0.5);
    if (!coast_within_limits(&message_limited) || !message_limited.stopped_by_messages ||
        message_limited.messages != MAX_MESSAGES_VALUE)
        fail("the message limit stops long custom curves", "the model did not reach 384 messages");
    else
        pass("the message limit stops long custom curves");
}

int main(int argc, char **argv)
{
    static const char *const defaults[] =
    {
        "patches/0090-winex11-preserve-precision-scrolling-from-XInput2-scroll-.patch",
        "patches/0091-winex11-coast-scrolling-and-thrown-middle-drags-after-rel.patch",
        "patches/0074-winex11-server-report-a-touchpad-pinch-as-Ctrl-tagged-whe.patch",
        "patches/0072-winex11-registry-pointer-settings-and-middle-button-dra.patch",
        "patches/0092-winex11-bound-and-isolate-pointer-gesture-output.patch",
        "patches/0093-winex11-release-stale-cursor-clipping-state-when-X-f.patch",
        "patches/0094-winex11-emulate-only-observed-failed-pointer-warps-o.patch",
        "patches/0095-winex11-separate-pointer-coast-sources.patch",
        "patches/0097-winex11-restore-pointer-inertia-and-ignore-held-scroll.patch",
        "patches/0098-winex11-isolate-held-LMB-control-motion-from-gestures.patch"
    };
    struct text stack_source = {0}, safety_source = {0}, warp_source = {0};
    struct text lifecycle_source = {0}, final_source = {0}, control_source = {0};
    const char *paths[10];
    char *stack, *safety, *warp, *lifecycle, *final, *control;
    int i;

    if (argc != 1 && argc != 11)
    {
        fprintf(stderr, "usage: %s [0090 0091 0074 0072 0092 0093 0094 0095 0097 0098]\n",
                argv[0]);
        return 2;
    }
    for (i = 0; i < 10; i++) paths[i] = argc == 11 ? argv[i + 1] : defaults[i];
    for (i = 0; i < 10; i++)
        if (!read_patch_new_side(paths[i], &stack_source)) return 2;
    if (!read_patch_new_side(paths[4], &safety_source)) return 2;
    if (!read_patch_new_side(paths[6], &warp_source)) return 2;
    if (!read_patch_new_side(paths[7], &lifecycle_source)) return 2;
    if (!read_patch_new_side(paths[8], &final_source)) return 2;
    if (!read_patch_new_side(paths[9], &control_source)) return 2;

    stack = compact(stack_source.data ? stack_source.data : "");
    safety = compact(safety_source.data ? safety_source.data : "");
    warp = compact(warp_source.data ? warp_source.data : "");
    lifecycle = compact(lifecycle_source.data ? lifecycle_source.data : "");
    final = compact(final_source.data ? final_source.data : "");
    control = compact(control_source.data ? control_source.data : "");
    if (!stack || !safety || !warp || !lifecycle || !final || !control)
    {
        fprintf(stderr, "FAIL: out of memory while compacting patch sources\n");
        free(stack_source.data);
        free(safety_source.data);
        free(warp_source.data);
        free(lifecycle_source.data);
        free(final_source.data);
        free(control_source.data);
        free(stack);
        free(safety);
        free(warp);
        free(lifecycle);
        free(final);
        free(control);
        return 2;
    }

    check_pointer_setting_fallback(stack, safety, lifecycle, final);
    check_warp_emulation(stack, warp);
    check_held_and_direct_input(stack, safety, lifecycle, control);
    check_held_control_drag(control);
    check_legacy_wheel_copy_guard(lifecycle);
    check_direct_packet_bounds(stack, safety, final);
    check_continuation_sources(lifecycle, final);
    check_inertia_timer_initialization(lifecycle);
    check_one_shot_inertia_ticks(lifecycle);
    check_inertia_lifecycle_cancellation(lifecycle);
    check_accumulator_routing(safety);
    check_inertia_limits(stack, lifecycle, final);
    check_inertia_generation(stack, safety, lifecycle);
    check_button_serial_and_middle_mode(safety);
    check_held_wheel_provenance();
    check_legacy_wheel_copy_model();
    check_default_continuation_matrix();
    check_middle_throw_estimator_math();
    check_warp_probe_math();
    check_held_control_motion_math();
    check_math_limits();

    free(stack_source.data);
    free(safety_source.data);
    free(warp_source.data);
    free(lifecycle_source.data);
    free(final_source.data);
    free(control_source.data);
    free(stack);
    free(safety);
    free(warp);
    free(lifecycle);
    free(final);
    free(control);
    if (failures)
    {
        fprintf(stderr, "pointer safety checks: %u failure%s\n",
                failures, failures == 1 ? "" : "s");
        return 1;
    }
    puts("pointer safety checks: PASS");
    return 0;
}
