/* fakectl.c — configurable ALSA-seq MIDI controller for hotplug tests.
 *
 * The default is compatible with the original probe: one duplex "FakeCtl"
 * port sends a note-on/note-off pair every 500 ms. Options allow tests to
 * create input-only, output-only, multi-port, and duplicate-name devices.
 * Restarting the process models a device replug; a zero-port instance can
 * reserve the old ALSA client id so the replacement must receive a new one.
 *
 * build: cc -O2 -Wall -Wextra -o fakectl fakectl.c -lasound
 */
#include <alsa/asoundlib.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_PORTS 32

enum port_mode
{
    MODE_WINMM_INPUT = 1,
    MODE_WINMM_OUTPUT = 2,
    MODE_DUPLEX = MODE_WINMM_INPUT | MODE_WINMM_OUTPUT
};

struct options
{
    const char *client_name;
    const char *port_name;
    enum port_mode mode;
    unsigned int ports;
    unsigned int interval_ms;
    unsigned int lifetime_ms;
    unsigned int note;
    int duplicate_names;
};

static void usage(const char *program)
{
    printf("usage: %s [options]\n"
           "  --name NAME          ALSA client name (default: FakeCtl)\n"
           "  --port-name NAME     base port name (default: FakeCtl MIDI)\n"
           "  --ports N            number of ports, 0..32 (default: 1)\n"
           "  --input-only         expose WinMM input ports and send notes\n"
           "  --output-only        expose WinMM output ports and receive notes\n"
           "  --duplex             expose both directions (default)\n"
           "  --duplicate-names    give every port the same name\n"
           "  --interval-ms N      note interval, 10..60000 (default: 500)\n"
           "  --lifetime-ms N      exit after N ms; 0 runs until killed\n"
           "  --note N             first MIDI note, 0..127 (default: 60)\n",
           program);
}

static int parse_uint(const char *text, unsigned int min, unsigned int max,
                      unsigned int *result)
{
    char *end;
    unsigned long value;

    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno || !text[0] || *end || value < min || value > max) return 0;
    *result = (unsigned int)value;
    return 1;
}

static int parse_options(int argc, char **argv, struct options *options)
{
    int i;

    options->client_name = "FakeCtl";
    options->port_name = "FakeCtl MIDI";
    options->mode = MODE_DUPLEX;
    options->ports = 1;
    options->interval_ms = 500;
    options->lifetime_ms = 0;
    options->note = 60;
    options->duplicate_names = 0;

    for (i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h"))
        {
            usage(argv[0]);
            exit(0);
        }
        else if (!strcmp(argv[i], "--name") && i + 1 < argc)
            options->client_name = argv[++i];
        else if (!strcmp(argv[i], "--port-name") && i + 1 < argc)
            options->port_name = argv[++i];
        else if (!strcmp(argv[i], "--ports") && i + 1 < argc)
        {
            if (!parse_uint(argv[++i], 0, MAX_PORTS, &options->ports)) return 0;
        }
        else if (!strcmp(argv[i], "--interval-ms") && i + 1 < argc)
        {
            if (!parse_uint(argv[++i], 10, 60000, &options->interval_ms)) return 0;
        }
        else if (!strcmp(argv[i], "--lifetime-ms") && i + 1 < argc)
        {
            if (!parse_uint(argv[++i], 0, 86400000, &options->lifetime_ms)) return 0;
        }
        else if (!strcmp(argv[i], "--note") && i + 1 < argc)
        {
            if (!parse_uint(argv[++i], 0, 127, &options->note)) return 0;
        }
        else if (!strcmp(argv[i], "--input-only"))
            options->mode = MODE_WINMM_INPUT;
        else if (!strcmp(argv[i], "--output-only"))
            options->mode = MODE_WINMM_OUTPUT;
        else if (!strcmp(argv[i], "--duplex"))
            options->mode = MODE_DUPLEX;
        else if (!strcmp(argv[i], "--duplicate-names"))
            options->duplicate_names = 1;
        else
            return 0;
    }

    return 1;
}

static unsigned long long monotonic_ms(void)
{
    struct timespec value;

    clock_gettime(CLOCK_MONOTONIC, &value);
    return (unsigned long long)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static void send_note_pair(snd_seq_t *seq, int port, unsigned int note)
{
    snd_seq_event_t event;

    snd_seq_ev_clear(&event);
    snd_seq_ev_set_direct(&event);
    snd_seq_ev_set_source(&event, port);
    snd_seq_ev_set_subs(&event);
    snd_seq_ev_set_noteon(&event, 0, note, 100);
    snd_seq_event_output_direct(seq, &event);
    snd_seq_ev_set_noteoff(&event, 0, note, 0);
    snd_seq_event_output_direct(seq, &event);
}

static void drain_input(snd_seq_t *seq)
{
    snd_seq_event_t *event;
    int result;

    while ((result = snd_seq_event_input(seq, &event)) >= 0)
    {
        printf("RX port=%d source=%d:%d type=%d",
               event->dest.port, event->source.client, event->source.port,
               event->type);
        if (event->type == SND_SEQ_EVENT_NOTEON || event->type == SND_SEQ_EVENT_NOTEOFF)
            printf(" channel=%u note=%u velocity=%u", event->data.note.channel,
                   event->data.note.note, event->data.note.velocity);
        putchar('\n');
        fflush(stdout);
        snd_seq_free_event(event);
    }

    if (result != -EAGAIN)
    {
        fprintf(stderr, "cannot read ALSA sequencer event: %s\n", snd_strerror(result));
        exit(1);
    }
}

int main(int argc, char **argv)
{
    struct options options;
    snd_seq_t *seq;
    unsigned long long started, next_note;
    unsigned int sequence = 0, i;
    int ports[MAX_PORTS];
    int capabilities = 0;

    if (!parse_options(argc, argv, &options))
    {
        usage(argv[0]);
        return 2;
    }

    if (snd_seq_open(&seq, "default", SND_SEQ_OPEN_DUPLEX, SND_SEQ_NONBLOCK) < 0)
    {
        fprintf(stderr, "cannot open ALSA sequencer\n");
        return 1;
    }
    if (snd_seq_set_client_name(seq, options.client_name) < 0)
    {
        fprintf(stderr, "cannot set ALSA client name\n");
        snd_seq_close(seq);
        return 1;
    }

    if (options.mode & MODE_WINMM_INPUT)
        capabilities |= SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_SUBS_READ;
    if (options.mode & MODE_WINMM_OUTPUT)
        capabilities |= SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_SUBS_WRITE;

    for (i = 0; i < options.ports; i++)
    {
        char name[128];

        if (options.ports == 1 || options.duplicate_names)
            snprintf(name, sizeof(name), "%s", options.port_name);
        else
            snprintf(name, sizeof(name), "%s %u", options.port_name, i + 1);
        ports[i] = snd_seq_create_simple_port(seq, name, capabilities,
                SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_HARDWARE |
                SND_SEQ_PORT_TYPE_PORT);
        if (ports[i] < 0)
        {
            fprintf(stderr, "cannot create port %u: %s\n", i, snd_strerror(ports[i]));
            snd_seq_close(seq);
            return 1;
        }
        printf("PORT index=%u id=%d name=%s\n", i, ports[i], name);
    }

    printf("READY client=%d ports=%u mode=%s duplicate_names=%d name=%s\n",
           snd_seq_client_id(seq), options.ports,
           options.mode == MODE_DUPLEX ? "duplex" :
           options.mode == MODE_WINMM_INPUT ? "input" : "output",
           options.duplicate_names, options.client_name);
    fflush(stdout);

    started = next_note = monotonic_ms();
    for (;;)
    {
        unsigned long long now = monotonic_ms();
        struct timespec pause = {0, 10000000};

        drain_input(seq);
        if ((options.mode & MODE_WINMM_INPUT) && options.ports && now >= next_note)
        {
            for (i = 0; i < options.ports; i++)
                send_note_pair(seq, ports[i], (options.note + i) & 0x7f);
            printf("TX sequence=%u ports=%u\n", ++sequence, options.ports);
            fflush(stdout);
            next_note = now + options.interval_ms;
        }
        if (options.lifetime_ms && now - started >= options.lifetime_ms) break;
        nanosleep(&pause, NULL);
    }

    printf("EXIT client=%d elapsed_ms=%llu\n", snd_seq_client_id(seq),
           monotonic_ms() - started);
    snd_seq_close(seq);
    return 0;
}
