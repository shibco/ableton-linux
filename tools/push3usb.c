#define _POSIX_C_SOURCE 200809L

/*
 * Safe host-libusb probe for the Ableton Push 3 vendor interfaces.
 *
 * Push 3 exposes two vendor-specific interfaces: 0 (display) and 6 (xPort).
 * This probe never detaches a kernel driver, changes the USB configuration,
 * resets the device, or writes to either OUT endpoint.  Its strongest test
 * submits one bulk IN transfer and immediately cancels it.  The xPort
 * protocol is unknown, so the probe submits a transfer on the xPort IN
 * endpoint only when --cancel-in-xport requests it.
 */

#include <libusb.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define PUSH3_VENDOR_ID 0x2982
#define PUSH3_PRODUCT_ID 0x1969
#define PUSH3_MAX_PACKET_SIZE 512

struct vendor_interface
{
    int number;
    uint8_t in_endpoint;
    uint8_t out_endpoint;
    const char *name;
};

static const struct vendor_interface vendor_interfaces[] =
{
    { 0, 0x81, 0x01, "display" },
    { 6, 0x84, 0x04, "xport" },
};

#define VENDOR_INTERFACE_COUNT \
    (sizeof(vendor_interfaces) / sizeof(vendor_interfaces[0]))

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
    return 0;
}

static int check_vendor_interface(libusb_device *device,
        const struct vendor_interface *vi)
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
        config->bNumInterfaces <= vi->number ||
        !config->interface[vi->number].num_altsetting)
    {
        fprintf(stderr, "unexpected active configuration or interface table\n");
        libusb_free_config_descriptor(config);
        return LIBUSB_ERROR_NOT_FOUND;
    }

    descriptor = &config->interface[vi->number].altsetting[0];
    if (descriptor->bInterfaceNumber != vi->number ||
        descriptor->bInterfaceClass != LIBUSB_CLASS_VENDOR_SPEC)
    {
        fprintf(stderr, "interface %d is not the expected vendor interface\n",
                vi->number);
        libusb_free_config_descriptor(config);
        return LIBUSB_ERROR_NOT_FOUND;
    }

    for (i = 0; i < descriptor->bNumEndpoints; ++i)
    {
        const struct libusb_endpoint_descriptor *endpoint = &descriptor->endpoint[i];
        const uint8_t transfer_type = endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;

        if (transfer_type != LIBUSB_TRANSFER_TYPE_BULK ||
            endpoint->wMaxPacketSize != PUSH3_MAX_PACKET_SIZE)
            continue;
        if (endpoint->bEndpointAddress == vi->in_endpoint)
            found_in = true;
        if (endpoint->bEndpointAddress == vi->out_endpoint)
            found_out = true;
    }

    libusb_free_config_descriptor(config);

    if (!found_in || !found_out)
    {
        fprintf(stderr, "expected bulk endpoints on interface %d were not found\n",
                vi->number);
        return LIBUSB_ERROR_NOT_FOUND;
    }
    printf("interface=%d name=%s class=vendor endpoints=in:0x%02x,out:0x%02x packet=512\n",
            vi->number, vi->name, (unsigned int)vi->in_endpoint,
            (unsigned int)vi->out_endpoint);
    return 0;
}

static int cancel_in_transfer(libusb_context *context,
        libusb_device_handle *handle, uint8_t endpoint)
{
    struct completion_state *state = NULL;
    struct libusb_transfer *transfer = NULL;
    unsigned char *buffer = NULL;
    int64_t deadline, now;
    int cancel_ret, event_ret = 0, ret;

    state = calloc(1, sizeof(*state));
    buffer = calloc(PUSH3_MAX_PACKET_SIZE, 1);
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

    libusb_fill_bulk_transfer(transfer, handle, endpoint,
            buffer, PUSH3_MAX_PACKET_SIZE, transfer_complete, state, 1000);

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
         * The transfer may still be owned by libusb.  Deliberately leak all
         * USB state until process exit rather than freeing active storage.
         */
        fprintf(stderr, "terminal callback did not arrive; abandoning USB cleanup safely\n");
        return CANCEL_UNRESOLVED;
    }

    /* Keep callback storage alive for a 250 ms diagnostic drain window. */
    if (monotonic_milliseconds(&now) < 0)
        event_ret = LIBUSB_ERROR_OTHER;
    else
        deadline = now + 250;
    while (!event_ret)
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
        timeout.tv_usec = (deadline - now) * 1000;
        ret = libusb_handle_events_timeout(context, &timeout);
        if (ret == LIBUSB_ERROR_INTERRUPTED)
            continue;
        if (ret < 0)
            event_ret = ret;
    }

    printf("cancel-callback endpoint=0x%02x count=%u status=%s actual_length=%d\n",
            (unsigned int)endpoint, state->count,
            transfer_status_name(state->status), state->actual_length);

    libusb_free_transfer(transfer);

    if (cancel_ret < 0)
        ret = cancel_ret;
    else if (event_ret < 0)
        ret = event_ret;
    else if (state->count != 1 || state->status != LIBUSB_TRANSFER_CANCELLED ||
             state->actual_length != 0)
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
    fprintf(stderr, "usage: %s [--enumerate|--claim|--cancel-in|--cancel-in-xport]\n",
            program);
}

int main(int argc, char **argv)
{
    libusb_context *context = NULL;
    libusb_device **devices = NULL;
    libusb_device *push = NULL;
    libusb_device_handle *handle = NULL;
    struct libusb_device_descriptor descriptor;
    bool claimed[VENDOR_INTERFACE_COUNT] = { false };
    bool abandon_usb = false;
    enum probe_mode mode;
    size_t first, last, j;
    ssize_t count, i;
    int ret = EXIT_FAILURE, usb_ret;

    if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--enumerate")))
        mode = MODE_ENUMERATE;
    else if (argc == 2 && !strcmp(argv[1], "--claim"))
        mode = MODE_CLAIM;
    else if (argc == 2 && !strcmp(argv[1], "--cancel-in"))
        mode = MODE_CANCEL_DISPLAY;
    else if (argc == 2 && !strcmp(argv[1], "--cancel-in-xport"))
        mode = MODE_CANCEL_XPORT;
    else
    {
        usage(argv[0]);
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

    for (i = 0; i < count; ++i)
    {
        if (libusb_get_device_descriptor(devices[i], &descriptor) < 0)
            continue;
        if (descriptor.idVendor == PUSH3_VENDOR_ID &&
            descriptor.idProduct == PUSH3_PRODUCT_ID)
        {
            push = devices[i];
            break;
        }
    }

    if (!push)
    {
        fprintf(stderr, "Push 3 2982:1969 not found\n");
        goto done;
    }

    printf("device=2982:1969 bus=%03u address=%03u configurations=%u\n",
            libusb_get_bus_number(push), libusb_get_device_address(push),
            descriptor.bNumConfigurations);

    for (j = 0; j < VENDOR_INTERFACE_COUNT; ++j)
    {
        usb_ret = check_vendor_interface(push, &vendor_interfaces[j]);
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
        last = VENDOR_INTERFACE_COUNT - 1;
    }
    else if (mode == MODE_CANCEL_DISPLAY)
        first = last = 0;
    else
        first = last = 1;

    for (j = first; j <= last; ++j)
    {
        const struct vendor_interface *vi = &vendor_interfaces[j];

        usb_ret = libusb_kernel_driver_active(handle, vi->number);
        if (usb_ret < 0)
        {
            fprintf(stderr, "kernel driver query: %s\n", libusb_error_name(usb_ret));
            goto done;
        }
        if (usb_ret != 0)
        {
            fprintf(stderr, "refusing to detach kernel driver from interface %d\n",
                    vi->number);
            goto done;
        }

        usb_ret = libusb_claim_interface(handle, vi->number);
        if (usb_ret < 0)
        {
            fprintf(stderr, "claim interface %d: %s\n", vi->number,
                    libusb_error_name(usb_ret));
            goto done;
        }
        claimed[j] = true;
        printf("claim=ok interface=%d kernel-driver=none\n", vi->number);
    }

    if (mode == MODE_CANCEL_DISPLAY || mode == MODE_CANCEL_XPORT)
    {
        usb_ret = cancel_in_transfer(context, handle,
                vendor_interfaces[first].in_endpoint);
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

    for (j = VENDOR_INTERFACE_COUNT; j-- > 0;)
    {
        if (!claimed[j])
            continue;
        usb_ret = libusb_release_interface(handle, vendor_interfaces[j].number);
        printf("release=%s interface=%d\n",
                usb_ret < 0 ? libusb_error_name(usb_ret) : "ok",
                vendor_interfaces[j].number);
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
