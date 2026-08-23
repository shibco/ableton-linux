#define _POSIX_C_SOURCE 200809L

/*
 * Safe host-libusb probe for the Ableton Push 2 and Push 3 vendor interfaces.
 *
 * The probe leaves kernel drivers and USB configurations unchanged. It reads
 * descriptors, claims selected vendor interfaces, and releases every claim.
 * Its transfer test submits one bulk IN request and cancels it. OUT endpoints
 * stay idle.
 */

#include <libusb.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define PUSH_VENDOR_ID 0x2982
#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))

#ifndef PUSHUSB_DEFAULT_MODEL
#define PUSHUSB_DEFAULT_MODEL 0
#endif

struct vendor_interface
{
    int number;
    uint8_t in_endpoint;
    uint8_t out_endpoint;
    uint16_t packet_size;
    bool continuous_input;
    const char *name;
};

struct push_model
{
    const char *argument;
    const char *name;
    uint16_t product_id;
    const struct vendor_interface *interfaces;
    size_t interface_count;
};

static const struct vendor_interface push2_interfaces[] =
{
    { 0, 0x81, 0x01, 512, false, "display" },
};

static const struct vendor_interface push3_interfaces[] =
{
    { 0, 0x81, 0x01, 512, false, "display" },
    { 6, 0x84, 0x04, 512, true,  "xport" },
};

static const struct push_model push_models[] =
{
    { "push2", "Push 2", 0x1967, push2_interfaces, ARRAY_SIZE(push2_interfaces) },
    { "push3", "Push 3", 0x1969, push3_interfaces, ARRAY_SIZE(push3_interfaces) },
};

enum probe_mode
{
    MODE_ENUMERATE,
    MODE_CLAIM,
    MODE_CANCEL_DISPLAY,
    MODE_CANCEL_XPORT,
};

struct completion_state
{
    int done;
    unsigned int count;
    enum libusb_transfer_status status;
    int actual_length;
};

enum cancel_result
{
    CANCEL_OK,
    CANCEL_UNRESOLVED,
};

static const struct push_model *find_model(const char *argument)
{
    size_t i;

    for (i = 0; i < ARRAY_SIZE(push_models); ++i)
    {
        if (!strcmp(argument, push_models[i].argument))
            return &push_models[i];
    }
    return NULL;
}

static const struct vendor_interface *find_interface(
        const struct push_model *model, const char *name)
{
    size_t i;

    for (i = 0; i < model->interface_count; ++i)
    {
        if (!strcmp(name, model->interfaces[i].name))
            return &model->interfaces[i];
    }
    return NULL;
}

static const char *transfer_status_name(enum libusb_transfer_status status)
{
    switch (status)
    {
        case LIBUSB_TRANSFER_COMPLETED: return "completed";
        case LIBUSB_TRANSFER_ERROR: return "error";
        case LIBUSB_TRANSFER_TIMED_OUT: return "timed out";
        case LIBUSB_TRANSFER_CANCELLED: return "cancelled";
        case LIBUSB_TRANSFER_STALL: return "stalled";
        case LIBUSB_TRANSFER_NO_DEVICE: return "no device";
        case LIBUSB_TRANSFER_OVERFLOW: return "overflow";
    }
    return "unknown";
}

static void LIBUSB_CALL transfer_complete(struct libusb_transfer *transfer)
{
    struct completion_state *state = transfer->user_data;

    state->count++;
    state->status = transfer->status;
    state->actual_length = transfer->actual_length;
    state->done = 1;
}

static int monotonic_milliseconds(int64_t *milliseconds)
{
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
        return LIBUSB_ERROR_OTHER;
    *milliseconds = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
    return LIBUSB_SUCCESS;
}

static int check_vendor_interface(libusb_device *device,
        const struct vendor_interface *interface)
{
    struct libusb_config_descriptor *config = NULL;
    const struct libusb_interface_descriptor *descriptor;
    bool found_in = false, found_out = false;
    int ret, i;

    ret = libusb_get_active_config_descriptor(device, &config);
    if (ret < 0)
    {
        fprintf(stderr, "active configuration: %s\n", libusb_error_name(ret));
        return ret;
    }

    if (config->bConfigurationValue != 1 ||
        config->bNumInterfaces <= interface->number ||
        !config->interface[interface->number].num_altsetting)
    {
        fprintf(stderr, "unexpected active configuration or interface table\n");
        libusb_free_config_descriptor(config);
        return LIBUSB_ERROR_NOT_FOUND;
    }

    descriptor = &config->interface[interface->number].altsetting[0];
    if (descriptor->bInterfaceNumber != interface->number ||
        descriptor->bInterfaceClass != LIBUSB_CLASS_VENDOR_SPEC)
    {
        fprintf(stderr, "interface %d differs from the expected vendor interface\n",
                interface->number);
        libusb_free_config_descriptor(config);
        return LIBUSB_ERROR_NOT_FOUND;
    }

    for (i = 0; i < descriptor->bNumEndpoints; ++i)
    {
        const struct libusb_endpoint_descriptor *endpoint = &descriptor->endpoint[i];
        const uint8_t transfer_type = endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;

        if (transfer_type != LIBUSB_TRANSFER_TYPE_BULK ||
            endpoint->wMaxPacketSize != interface->packet_size)
            continue;
        if (endpoint->bEndpointAddress == interface->in_endpoint)
            found_in = true;
        if (endpoint->bEndpointAddress == interface->out_endpoint)
            found_out = true;
    }

    libusb_free_config_descriptor(config);

    if (!found_in || !found_out)
    {
        fprintf(stderr, "expected bulk endpoints on interface %d were not found\n",
                interface->number);
        return LIBUSB_ERROR_NOT_FOUND;
    }

    printf("interface=%d name=%s class=vendor endpoints=in:0x%02x,out:0x%02x packet=%u\n",
            interface->number, interface->name, interface->in_endpoint,
            interface->out_endpoint, interface->packet_size);
    return LIBUSB_SUCCESS;
}

static int cancel_in_transfer(libusb_context *context,
        libusb_device_handle *handle, const struct vendor_interface *interface)
{
    struct completion_state *state = NULL;
    struct libusb_transfer *transfer = NULL;
    unsigned char *buffer = NULL;
    int64_t deadline = 0, now;
    int cancel_ret, event_ret = 0, ret;

    state = calloc(1, sizeof(*state));
    buffer = calloc(interface->packet_size, 1);
    transfer = libusb_alloc_transfer(0);
    if (!state || !buffer || !transfer)
    {
        fprintf(stderr, "could not allocate cancellation state\n");
        if (transfer)
            libusb_free_transfer(transfer);
        free(buffer);
        free(state);
        return LIBUSB_ERROR_NO_MEM;
    }

    libusb_fill_bulk_transfer(transfer, handle, interface->in_endpoint,
            buffer, interface->packet_size, transfer_complete, state, 1000);

    ret = libusb_submit_transfer(transfer);
    if (ret < 0)
    {
        fprintf(stderr, "submit IN transfer: %s\n", libusb_error_name(ret));
        libusb_free_transfer(transfer);
        free(buffer);
        free(state);
        return ret;
    }

    cancel_ret = libusb_cancel_transfer(transfer);
    if (cancel_ret < 0)
        fprintf(stderr, "cancel IN transfer: %s; awaiting terminal callback\n",
                libusb_error_name(cancel_ret));

    if (monotonic_milliseconds(&now) < 0)
        event_ret = LIBUSB_ERROR_OTHER;
    else
        deadline = now + 6000;

    while (!state->done && !event_ret)
    {
        struct timeval timeout;

        if (monotonic_milliseconds(&now) < 0)
        {
            event_ret = LIBUSB_ERROR_OTHER;
            break;
        }
        if (now >= deadline)
            break;

        timeout.tv_sec = 0;
        timeout.tv_usec = (deadline - now > 100 ? 100 : deadline - now) * 1000;
        ret = libusb_handle_events_timeout_completed(context, &timeout, &state->done);
        if (ret == LIBUSB_ERROR_INTERRUPTED)
            continue;
        if (ret < 0)
        {
            fprintf(stderr, "handle events: %s\n", libusb_error_name(ret));
            event_ret = ret;
        }
    }

    if (!state->done)
    {
        /*
         * libusb can still own the transfer. Process exit safely releases the
         * retained USB objects and callback storage.
         */
        fprintf(stderr, "terminal callback timed out; preserving USB state until exit\n");
        return CANCEL_UNRESOLVED;
    }

    printf("cancel-callback endpoint=0x%02x count=%u status=%s actual_length=%d\n",
            interface->in_endpoint, state->count,
            transfer_status_name(state->status), state->actual_length);

    libusb_free_transfer(transfer);

    if (cancel_ret < 0)
        ret = cancel_ret;
    else if (event_ret < 0)
        ret = event_ret;
    else if (state->count != 1 || state->status != LIBUSB_TRANSFER_CANCELLED)
        ret = LIBUSB_ERROR_OTHER;
    else if (!interface->continuous_input && state->actual_length != 0)
        ret = LIBUSB_ERROR_OTHER;
    else if (interface->continuous_input &&
             (state->actual_length < 0 || state->actual_length > interface->packet_size))
        ret = LIBUSB_ERROR_OTHER;
    else
        ret = CANCEL_OK;

    if (ret == CANCEL_OK)
        printf("cancel-test=ok\n");

    free(buffer);
    free(state);
    return ret;
}

static void usage(const char *program)
{
#if PUSHUSB_DEFAULT_MODEL
    fprintf(stderr, "usage: %s [--enumerate|--claim|--cancel-in|--cancel-in-xport]\n",
            program);
#else
    fprintf(stderr, "usage: %s push2|push3 [--enumerate|--claim|--cancel-in|--cancel-in-xport]\n",
            program);
#endif
}

int main(int argc, char **argv)
{
    libusb_context *context = NULL;
    libusb_device **devices = NULL;
    libusb_device *push = NULL;
    libusb_device_handle *handle = NULL;
    const struct vendor_interface *cancel_interface = NULL;
    const struct push_model *model = NULL;
    struct libusb_device_descriptor descriptor;
    bool claimed[ARRAY_SIZE(push3_interfaces)] = { false };
    bool abandon_usb = false;
    enum probe_mode mode = MODE_ENUMERATE;
    size_t first, last, i;
    ssize_t count, device_index;
    int argument = 1, ret = EXIT_FAILURE, usb_ret;

#if PUSHUSB_DEFAULT_MODEL == 2
    model = find_model("push2");
#elif PUSHUSB_DEFAULT_MODEL == 3
    model = find_model("push3");
#elif PUSHUSB_DEFAULT_MODEL
#error PUSHUSB_DEFAULT_MODEL must be 0, 2, or 3
#else
    if (argc < 2 || !(model = find_model(argv[argument++])))
    {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
#endif

    if (argc > argument + 1)
    {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
    if (argc == argument + 1)
    {
        if (!strcmp(argv[argument], "--claim"))
            mode = MODE_CLAIM;
        else if (!strcmp(argv[argument], "--cancel-in"))
            mode = MODE_CANCEL_DISPLAY;
        else if (!strcmp(argv[argument], "--cancel-in-xport"))
            mode = MODE_CANCEL_XPORT;
        else if (strcmp(argv[argument], "--enumerate"))
        {
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }

    if (mode == MODE_CANCEL_DISPLAY)
        cancel_interface = find_interface(model, "display");
    else if (mode == MODE_CANCEL_XPORT)
        cancel_interface = find_interface(model, "xport");
    if ((mode == MODE_CANCEL_DISPLAY || mode == MODE_CANCEL_XPORT) && !cancel_interface)
    {
        fprintf(stderr, "%s has no requested interface\n", model->name);
        return EXIT_FAILURE;
    }

    usb_ret = libusb_init(&context);
    if (usb_ret < 0)
    {
        fprintf(stderr, "libusb_init: %s\n", libusb_error_name(usb_ret));
        return EXIT_FAILURE;
    }

    count = libusb_get_device_list(context, &devices);
    if (count < 0)
    {
        fprintf(stderr, "device list: %s\n", libusb_error_name((int)count));
        goto done;
    }

    for (device_index = 0; device_index < count; ++device_index)
    {
        if (libusb_get_device_descriptor(devices[device_index], &descriptor) < 0)
            continue;
        if (descriptor.idVendor == PUSH_VENDOR_ID &&
            descriptor.idProduct == model->product_id)
        {
            push = devices[device_index];
            break;
        }
    }

    if (!push)
    {
        fprintf(stderr, "%s 2982:%04x not found\n", model->name, model->product_id);
        goto done;
    }

    printf("device=2982:%04x bus=%03u address=%03u configurations=%u\n",
            model->product_id, libusb_get_bus_number(push),
            libusb_get_device_address(push), descriptor.bNumConfigurations);

    for (i = 0; i < model->interface_count; ++i)
    {
        usb_ret = check_vendor_interface(push, &model->interfaces[i]);
        if (usb_ret < 0)
            goto done;
    }

    if (mode == MODE_ENUMERATE)
    {
        ret = EXIT_SUCCESS;
        goto done;
    }

    usb_ret = libusb_open(push, &handle);
    if (usb_ret < 0)
    {
        fprintf(stderr, "open: %s\n", libusb_error_name(usb_ret));
        goto done;
    }

    if (mode == MODE_CLAIM)
    {
        first = 0;
        last = model->interface_count - 1;
    }
    else
    {
        first = cancel_interface - model->interfaces;
        last = first;
    }

    for (i = first; i <= last; ++i)
    {
        const struct vendor_interface *interface = &model->interfaces[i];

        usb_ret = libusb_kernel_driver_active(handle, interface->number);
        if (usb_ret < 0)
        {
            fprintf(stderr, "kernel driver query: %s\n", libusb_error_name(usb_ret));
            goto done;
        }
        if (usb_ret)
        {
            fprintf(stderr, "kernel driver owns interface %d; leaving it attached\n",
                    interface->number);
            goto done;
        }

        usb_ret = libusb_claim_interface(handle, interface->number);
        if (usb_ret < 0)
        {
            fprintf(stderr, "claim interface %d: %s\n", interface->number,
                    libusb_error_name(usb_ret));
            goto done;
        }
        claimed[i] = true;
        printf("claim=ok interface=%d kernel-driver=none\n", interface->number);
    }

    if (cancel_interface)
    {
        usb_ret = cancel_in_transfer(context, handle, cancel_interface);
        if (usb_ret == CANCEL_UNRESOLVED)
        {
            abandon_usb = true;
            goto done;
        }
        if (usb_ret < 0)
            goto done;
    }

    ret = EXIT_SUCCESS;

done:
    if (abandon_usb)
        return EXIT_FAILURE;

    for (i = model->interface_count; i-- > 0;)
    {
        if (!claimed[i])
            continue;
        usb_ret = libusb_release_interface(handle, model->interfaces[i].number);
        printf("release=%s interface=%d\n",
                usb_ret < 0 ? libusb_error_name(usb_ret) : "ok",
                model->interfaces[i].number);
        if (usb_ret < 0)
            ret = EXIT_FAILURE;
    }
    if (handle)
        libusb_close(handle);
    if (devices)
        libusb_free_device_list(devices, 1);
    libusb_exit(context);
    return ret;
}
