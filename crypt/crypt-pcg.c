#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <time.h>
#include <ctype.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>

#define ENCRYPT_ACTION 1
#define DECRYPT_ACTION 2

#define BUFSIZE (1024 * 32)
#define BITS_IN_BYTE 8
#define BYTES_IN_UINT64_T 8
#define BYTE_MASK 0xff
#define PCG32_STATE_SIZE 4

struct params_s {
    int in_file;
    int out_file;
    uint8_t *password;
    int action;
};


// https://www.pcg-random.org/download.html
// https://en.wikipedia.org/wiki/Permuted_congruential_generator
uint32_t pcg32_random_r(uint64_t state[]) {
    uint64_t oldstate = state[0];
    // Advance internal state
    state[0] = oldstate * 6364136223846793005ULL + (state[1]|1);
    // Calculate output function (XSH RR), uses old state for max ILP
    uint32_t xorshifted = ((oldstate >> 18u) ^ oldstate) >> 27u;
    uint32_t rot = oldstate >> 59u;
    return (xorshifted >> rot) | (xorshifted << ((-rot) & 31));
}

void usage(uint8_t *program_name) {
    printf("Usage: %s -i INPUT_FILE -o OUTPUT_FILE (-d | -e)\n", program_name);
    printf("  -e to encrypt\n");
    printf("  -d to decrypt\n");
    printf("  stdin is used if -i is not specified\n");
    printf("  stdout is used if -o is not specified\n");
    exit(1);
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

uint32_t get_random_uint32(uint64_t *state) {
    static uint32_t random_number = 0;
    uint32_t another_random_number = pcg32_random_r(state) ^ random_number;
    // if upper 4 bits of another_random_number are zero we generate new random_number
    // on average this should happen roughly every 16th call but distribution is pretty wide
    if ((another_random_number >> 28) == 0) {
        random_number = pcg32_random_r(state + 2);
    }
    return another_random_number;
}

void generate_state(uint64_t *state, uint64_t *initial_state) {
    struct timespec ts;
    uint64_t x1, x2, x3, x4, x5;

    // uptime
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        fprintf(stderr, "Error: clock_gettime(CLOCK_MONOTONIC) failed with %s\n", strerror(errno));
        exit(1);
    }
    x1 = ts.tv_sec;
    x2 = ts.tv_nsec;

    // seconds since epoch
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        fprintf(stderr, "Error: clock_gettime(CLOCK_REALTIME,) failed with %s\n", strerror(errno));
        exit(1);
    }
    x3 = ts.tv_sec;
    x4 = ts.tv_nsec;

    state[0] = x1 * x2;
    state[1] = x1 * x4;
    state[2] = x3 * x2;
    state[3] = x3 * x4;
    x5 = state[0] ^ state[1] ^ state[2] ^ state[3] ^ getpid();

    for (int i = 0; i < PCG32_STATE_SIZE; i++) {
        int shift = x5 % (BITS_IN_BYTE * BYTES_IN_UINT64_T);
        state[i] = state[i] ^ (state[i] << shift | (state[i] >> (BITS_IN_BYTE * BYTES_IN_UINT64_T - shift)));
        initial_state[i] = state[i];
        x5 /= (BITS_IN_BYTE * BYTES_IN_UINT64_T);
    }
}

void warm_up_generator(uint8_t *password, uint64_t *state) {
    uint64_t warm_up_count = 0;

    for (uint8_t *p = password; *p != 0; p++) {
        warm_up_count = (warm_up_count * 2) + (*p);
    }

    for (int i = 0; i < warm_up_count; i++) {
        for (int j = 0; j < PCG32_STATE_SIZE; j += 2) {
            pcg32_random_r(state + j);
        }
    }
}

void apply_password_to_initial_state(uint8_t *password, uint64_t *initial_state) {
    int byte_index = 0;
    int word_index = 0;
    int i = 0;

    for (uint8_t *p = password; *p != 0; p++) {
        word_index = i % PCG32_STATE_SIZE;
        byte_index = i / PCG32_STATE_SIZE;
        initial_state[word_index] ^= ((uint64_t)(*p) << (BITS_IN_BYTE * byte_index));
        i = (i + 1) % (PCG32_STATE_SIZE * BYTES_IN_UINT64_T);
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

void read_xor_write(int in_file, int out_file, uint64_t *state, uint8_t *buf, int action) {
    int bytes_read_count = 0;
    int shift = 0;
    uint32_t random32 = 0;
    uint8_t random8 = 0;

    while (1) {
        bytes_read_count = read_or_die(in_file, buf, BUFSIZE, "Error: failed to read data.");
        if (bytes_read_count == 0) break;
        for (int i = 0; i < bytes_read_count; i++) {
            random32 = get_random_uint32(state);
            random8 = random32 & BYTE_MASK;
            shift = (random32 >> BITS_IN_BYTE) % BITS_IN_BYTE;
            if (action == DECRYPT_ACTION) {
                buf[i] = (buf[i] << shift)| (buf[i] >> (BITS_IN_BYTE - shift));
            }
            buf[i] ^= random8;
            if (action == ENCRYPT_ACTION) {
                buf[i] = (buf[i] >> shift)| (buf[i] << (BITS_IN_BYTE - shift));
            }
        }
        write_or_die(out_file, buf, bytes_read_count, "Error: failed to write data.");
    }
}

int generate_head(uint64_t *state, uint8_t *buf, uint64_t *initial_state, char *password) {
    int head_length = (get_random_uint32(state) & BYTE_MASK) + 1; // 1-256 random bytes at the head of the file

    for (int j = 0; j < PCG32_STATE_SIZE; j++) {
        for (int i = 0; i < BYTES_IN_UINT64_T; i++) {
            buf[i + j * BYTES_IN_UINT64_T] = (initial_state[j] >> ((BYTES_IN_UINT64_T - 1 - i) * BITS_IN_BYTE)) & BYTE_MASK;
        }
    }
    // to avoid continuous data in the header we skip bytes while filling in the buffer
    for (int i = 0; i < head_length; i++) {
        for (int j = (get_random_uint32(state) & BYTE_MASK); j > 0; j--) {
            get_random_uint32(state);
        }
        buf[i + BYTES_IN_UINT64_T * PCG32_STATE_SIZE] = (get_random_uint32(state) & BYTE_MASK);
    }
    return head_length + BYTES_IN_UINT64_T * PCG32_STATE_SIZE;
}

void encrypt(struct params_s *params) {
    uint64_t state[PCG32_STATE_SIZE];
    uint64_t initial_state[PCG32_STATE_SIZE];
    uint8_t buf[BUFSIZE];
    int head_length;

    generate_state(state, initial_state);
    apply_password_to_initial_state(params->password, initial_state);
    warm_up_generator(params->password, state);
    head_length = generate_head(state, buf, initial_state, params->password);
    write_or_die(params->out_file, buf, head_length, "Error: failed to write head data.");
    read_xor_write(params->in_file, params->out_file, state, buf, params->action);
}

void read_initial_state(int in_file, uint64_t *initial_state) {
    uint8_t buf[BYTES_IN_UINT64_T * PCG32_STATE_SIZE];
    int bytes_read_count = 0;
    int i = 0;

    bytes_read_count = read_or_die(in_file, buf, BYTES_IN_UINT64_T * PCG32_STATE_SIZE, "Error: failed to read initial state.");
    if (bytes_read_count != BYTES_IN_UINT64_T * PCG32_STATE_SIZE) {
        fprintf(stderr, "Error: initial state should be %d bytes, got %d bytes instead.\n", BYTES_IN_UINT64_T * PCG32_STATE_SIZE, bytes_read_count);
        exit(1);
    }
    for (int j = 0; j < PCG32_STATE_SIZE; j++) {
        for (int i = 0; i < BYTES_IN_UINT64_T; i++) {
            initial_state[j] = (initial_state[j] << BITS_IN_BYTE) | buf[i + j * BYTES_IN_UINT64_T];
        }
    }
}

void decrypt(struct params_s *params) {
    uint64_t state[PCG32_STATE_SIZE];
    uint8_t buf[BUFSIZE];
    int head_length;
    int bytes_read_count = 0;

    read_initial_state(params->in_file, state);
    apply_password_to_initial_state(params->password, state);
    warm_up_generator(params->password, state);
    // we use same generate_head() function as in encrypt() to have same state
    head_length = generate_head(state, buf, state, params->password) - BYTES_IN_UINT64_T * PCG32_STATE_SIZE; // - (BYTES_IN_UINT64_T * PCG32_STATE_SIZE) because of read_initial_state() above
    bytes_read_count = read_or_die(params->in_file, buf, head_length, "Error: failed to read head data.");
    if (bytes_read_count != head_length) {
        fprintf(stderr, "Error: head data should be %d bytes, got %d bytes instead.\n", head_length, bytes_read_count);
        exit(1);
    }
    read_xor_write(params->in_file, params->out_file, state, buf, params->action);
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
