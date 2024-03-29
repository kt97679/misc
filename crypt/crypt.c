#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/time.h>
#include <ctype.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>

#define ENCRYPT_ACTION 1
#define DECRYPT_ACTION 2

#define BUFSIZE (1024 * 32)
#define XOSHIRO256SS_STATE_SIZE 4
#define BITS_IN_BYTE 8
#define BYTES_IN_UINT64_T 8
#define BYTE_MASK 0xff

struct params_s {
    int in_file;
    int out_file;
    uint8_t *password;
    int action;
};

uint64_t rol64(uint64_t x, int k) {
    return (x << k) | (x >> (64 - k));
}

struct xoshiro256ss_state {
    uint64_t s[XOSHIRO256SS_STATE_SIZE];
};

// https://en.wikipedia.org/wiki/Xorshift#xoshiro256**
uint64_t xoshiro256ss(struct xoshiro256ss_state *state) {
    uint64_t *s = state->s;
    uint64_t const result = rol64(s[1] * 5, 7) * 9;
    uint64_t const t = s[1] << 17;

    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];

    s[2] ^= t;
    s[3] = rol64(s[3], 45);

    return result;
}

void usage(uint8_t *program_name) {
    printf("Usage: %s -i INPUT_FILE -o OUTPUT_FILE (-d | -e)\n", program_name);
    printf("  -e to encrypt\n");
    printf("  -d to decrypt\n");
    printf("  stdin is used if -i is not specified\n");
    printf("  stdout is used if -o is not specified\n");
    exit(1);
}

uint64_t generate_initial_state() {
    struct timeval t;
    gettimeofday(&t, NULL);
    return (uint64_t)(t.tv_usec * t.tv_sec);
}

int parse_args(int argc, char *argv[], struct params_s *params ) {
    params->action = 0;
    params->in_file = -1;
    params->out_file = -1;
    char *in_file = NULL;
    char *out_file = NULL;
    int c;

    while ((c = getopt (argc, argv, "edi:o:")) != -1) {
        switch (c) {
            case 'e':
                params->action |= ENCRYPT_ACTION;
                break;
            case 'd':
                params->action |= DECRYPT_ACTION;
                break;
            case 'i':
                if (in_file != NULL) {
                    fprintf(stderr, "Error: input file already specified\n");
                    exit(1);
                }
                in_file = optarg;
                break;
            case 'o':
                if (out_file != NULL) {
                    fprintf(stderr, "Error: output file already specified\n");
                    exit(1);
                }
                out_file = optarg;
                break;
            case '?':
                return 1;
            default:
                fprintf(stderr, "Error: unexpected failure while parsing command line\n");
                return 1;
        }
    }

    if (optind < argc) {
        fprintf(stderr, "Error: unrecognised non-option arguments\n");
        return 1;
    }

    if (params->action != ENCRYPT_ACTION && params->action != DECRYPT_ACTION) {
        fprintf(stderr, "Error: either -e OR -d should be provided\n");
        return 1;
    }
    if (in_file != NULL) {
        params->in_file = open(in_file, O_RDONLY);
        if (params->in_file == -1) {
            fprintf(stderr, "Error: failed to open input file \"%s\". %s\n", in_file, strerror(errno));
            exit(1);
        }
    } else {
        params->in_file = 0; // stdin
    }
    if (out_file != NULL) {
        params->out_file = open(out_file, O_WRONLY|O_CREAT|O_TRUNC, 0600); // -rw-----
        if (params->out_file == -1) {
            fprintf(stderr, "Error: failed to open output file \"%s\". %s\n", out_file, strerror(errno));
            exit(1);
        }
    } else {
        params->out_file = 1; // stdout
    }
    return 0;
}

uint8_t get_random_byte(struct xoshiro256ss_state *state) {
    static uint64_t cache = 0;
    uint8_t result;

    if (cache == 0) {
        cache = xoshiro256ss(state) >> BITS_IN_BYTE; // least significant bits are of low quality
    }
    result = cache & BYTE_MASK;
    cache >>= BITS_IN_BYTE;
    return result;
}

void prepare_state(uint8_t *password, struct xoshiro256ss_state *state, uint64_t initial_state) {
    int byte_index = 0;
    int word_index = 0;
    uint64_t warm_up_count = 0;
    int i = 0;

    for (i = 0; i < XOSHIRO256SS_STATE_SIZE; i++) {
        state->s[i] = initial_state;
    }
    i = 0;
    for (uint8_t *p = password; *p != 0; p++) {
        word_index = i % XOSHIRO256SS_STATE_SIZE;
        byte_index = i / XOSHIRO256SS_STATE_SIZE;
        state->s[word_index] ^= ((uint64_t)(*p) << (BITS_IN_BYTE * byte_index));
        warm_up_count = (warm_up_count * 2) + (*p);
        i = (i + 1) % (XOSHIRO256SS_STATE_SIZE * BYTES_IN_UINT64_T);
    }
    for (i = 0; i < warm_up_count; i++) {
        xoshiro256ss(state);
    }
}

ssize_t read_or_die(int fd, void *buf, size_t count, char *message) {
    ssize_t read_count = read(fd, buf, count);
    if (read_count == -1) {
        fprintf(stderr, "%s %s\n", message, strerror(errno));
        exit(1);
    }
    return read_count;
}

ssize_t write_or_die(int fd, void *buf, size_t count, char *message) {
    ssize_t write_count = write(fd, buf, count);
    if (write_count == -1) {
        fprintf(stderr, "%s %s\n", message, strerror(errno));
        exit(1);
    }
    return write_count;
}

void read_xor_write(int in_file, int out_file, struct xoshiro256ss_state *state, uint8_t *buf) {
    int bytes_read_count = 0;

    while (1) {
        bytes_read_count = read_or_die(in_file, buf, BUFSIZE, "Error: failed to read data.");
        if (bytes_read_count == 0) break;
        for (int i = 0; i < bytes_read_count; i++) {
            buf[i] ^= get_random_byte(state);
        }
        write_or_die(out_file, buf, bytes_read_count, "Error: failed to write data.");
    }
}

int generate_head(struct xoshiro256ss_state *state, uint8_t *buf, uint64_t initial_state) {
    int head_length = get_random_byte(state) + 1; // 1-256 random bytes at the head of the file

    for (int i = 0; i < BYTES_IN_UINT64_T; i++) {
        buf[i] = (initial_state >> ((BYTES_IN_UINT64_T - 1 - i) * BITS_IN_BYTE)) & BYTE_MASK;
    }
    // to avoid continuous data in the header we skip bytes while filling in the buffer
    for (int i = 0; i < head_length; i++) {
        for (int j = get_random_byte(state); j > 0; j--) {
            get_random_byte(state);
        }
        buf[i + BYTES_IN_UINT64_T] = get_random_byte(state);
    }
    return head_length + BYTES_IN_UINT64_T;
}

void encrypt(struct params_s *params) {
    uint64_t initial_state = generate_initial_state();
    struct xoshiro256ss_state state;
    uint8_t buf[BUFSIZE];
    int head_length;

    prepare_state(params->password, &state, initial_state);
    head_length = generate_head(&state, buf, initial_state);
    write_or_die(params->out_file, buf, head_length, "Error: failed to write head data.");
    read_xor_write(params->in_file, params->out_file, &state, buf);
}

uint64_t read_initial_state(int in_file) {
    uint64_t initial_state = 0;
    uint8_t buf[BYTES_IN_UINT64_T];
    int bytes_read_count = 0;

    bytes_read_count = read_or_die(in_file, buf, BYTES_IN_UINT64_T, "Error: failed to read initial state.");
    if (bytes_read_count != BYTES_IN_UINT64_T) {
        fprintf(stderr, "Error: initial state should be %d bytes, got %d bytes instead.\n", BYTES_IN_UINT64_T, bytes_read_count);
        exit(1);
    }
    for (int i = 0; i < BYTES_IN_UINT64_T; i++) {
        initial_state = (initial_state << BITS_IN_BYTE) | buf[i];
    }
    return initial_state;
}

void decrypt(struct params_s *params) {
    uint64_t initial_state = read_initial_state(params->in_file);
    struct xoshiro256ss_state state;
    uint8_t buf[BUFSIZE];
    int head_length;
    int bytes_read_count = 0;

    prepare_state(params->password, &state, initial_state);
    // we use same generate_head() function as in encrypt() to have rng in the same state
    head_length = generate_head(&state, buf, initial_state) - BYTES_IN_UINT64_T; // - BYTES_IN_UINT64_T because of read_initial_state() above
    bytes_read_count = read_or_die(params->in_file, buf, head_length, "Error: failed to read head data.");
    if (bytes_read_count != head_length) {
        fprintf(stderr, "Error: head data should be %d bytes, got %d bytes instead.\n", head_length, bytes_read_count);
        exit(1);
    }
    read_xor_write(params->in_file, params->out_file, &state, buf);
}

int main(int argc, char *argv[]) {
    struct params_s params;
    params.password = getenv("PASSWORD");
    if (params.password == NULL) {
        params.password = getpass("Password: ");
    }

    if (parse_args(argc, argv, &params) != 0) {
        usage(argv[0]);
    }
    switch(params.action) {
        case ENCRYPT_ACTION:
            encrypt(&params);
            break;
        case DECRYPT_ACTION:
            decrypt(&params);
            break;
        default:
            fprintf(stderr, "Error: unknown action");
    }
    close(params.in_file);
    close(params.out_file);
}
