/*
 * AOA bridge: expose an Android USB accessory as the existing Mirage TCP
 * client. The Mac helper keeps listening on 127.0.0.1:<port>; this process
 * switches the phone into Android Open Accessory mode and pumps bytes between
 * the accessory bulk endpoints and that TCP socket.
 *
 * Build (Homebrew libusb):
 *   cc -O2 -I/opt/homebrew/opt/libusb/include/libusb-1.0 tools/aoa_bridge.c \
 *      -L/opt/homebrew/opt/libusb/lib -lusb-1.0 -pthread -o build/aoa_bridge
 */
#include <arpa/inet.h>
#include <errno.h>
#include <libusb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define AOA_GET_PROTOCOL 51
#define AOA_SEND_STRING 52
#define AOA_START 53
#define AOA_VID 0x18D1
#define AOA_PID_ACCESSORY 0x2D00
#define AOA_PID_ACCESSORY_ADB 0x2D01
#define USB_BUFFER 16384

static volatile sig_atomic_t stopping = 0;
static volatile sig_atomic_t paused = 0;
static volatile sig_atomic_t graceful_stop = 0;
static volatile sig_atomic_t session_abort = 0;
static libusb_context *usb_ctx = NULL;
static libusb_device_handle *usb_handle = NULL;
static unsigned char endpoint_in = 0;
static unsigned char endpoint_out = 0;
static int tcp_fd = -1;
static int port_number = 7777;
static pthread_mutex_t tcp_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned char hello_data[USB_BUFFER];
static int hello_length = 0;

static void on_signal(int sig) {
    (void)sig;
    stopping = 1;
    graceful_stop = 1;
}

static int control_string(libusb_device_handle *handle, uint8_t index, const char *value) {
    return libusb_control_transfer(
        handle, 0x40, AOA_SEND_STRING, 0, index,
        (unsigned char *)value, (uint16_t)strlen(value), 1000
    );
}

static int aoa_version(libusb_device_handle *handle) {
    uint8_t data[2] = {0, 0};
    int rc = libusb_control_transfer(
        handle, 0xC0, AOA_GET_PROTOCOL, 0, 0, data, sizeof(data), 1000
    );
    return rc >= 2 ? (data[0] | (data[1] << 8)) : -1;
}

static libusb_device *find_aoa_device(int *version_out) {
    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(usb_ctx, &devices);
    libusb_device *found = NULL;

    for (ssize_t i = 0; i < count && !found; i++) {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(devices[i], &descriptor) != 0) continue;
        if (descriptor.idVendor == 0x05AC) continue; /* Apple */

        libusb_device_handle *handle = NULL;
        if (libusb_open(devices[i], &handle) != 0) continue;
        int version = aoa_version(handle);
        libusb_close(handle);
        if (version >= 1) {
            printf("aoa_device=%04x:%04x bus=%u addr=%u version=%d\n",
                   descriptor.idVendor, descriptor.idProduct,
                   libusb_get_bus_number(devices[i]),
                   libusb_get_device_address(devices[i]), version);
            fflush(stdout);
            *version_out = version;
            found = libusb_ref_device(devices[i]);
        }
    }
    libusb_free_device_list(devices, 1);
    return found;
}

static int connect_tcp(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int probe_tcp(int port) {
    int fd = connect_tcp(port);
    if (fd >= 0) close(fd);
    return fd >= 0 ? 0 : -1;
}

static libusb_device *find_accessory_device(void) {
    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(usb_ctx, &devices);
    libusb_device *found = NULL;
    for (ssize_t i = 0; i < count && !found; i++) {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(devices[i], &descriptor) != 0) continue;
        if (descriptor.idVendor == AOA_VID &&
            (descriptor.idProduct == AOA_PID_ACCESSORY ||
             descriptor.idProduct == AOA_PID_ACCESSORY_ADB)) {
            found = libusb_ref_device(devices[i]);
        }
    }
    libusb_free_device_list(devices, 1);
    return found;
}

static int wait_for_accessory(libusb_device **out) {
    for (int attempt = 0; attempt < 50; attempt++) {
        libusb_device **devices = NULL;
        ssize_t count = libusb_get_device_list(usb_ctx, &devices);
        for (ssize_t i = 0; i < count; i++) {
            struct libusb_device_descriptor descriptor;
            if (libusb_get_device_descriptor(devices[i], &descriptor) != 0) continue;
            if (descriptor.idVendor == AOA_VID &&
                (descriptor.idProduct == AOA_PID_ACCESSORY ||
                 descriptor.idProduct == AOA_PID_ACCESSORY_ADB)) {
                *out = libusb_ref_device(devices[i]);
                libusb_free_device_list(devices, 1);
                return 0;
            }
        }
        libusb_free_device_list(devices, 1);
        usleep(100000);
    }
    return -1;
}

static int find_endpoints(libusb_device *device, unsigned char *in, unsigned char *out) {
    struct libusb_config_descriptor *config = NULL;
    if (libusb_get_active_config_descriptor(device, &config) != 0 &&
        libusb_get_config_descriptor(device, 0, &config) != 0) {
        return -1;
    }

    unsigned char found_in = 0;
    unsigned char found_out = 0;
    for (uint8_t i = 0; i < config->bNumInterfaces && (!found_in || !found_out); i++) {
        const struct libusb_interface *interface = &config->interface[i];
        if (interface->num_altsetting == 0) continue;
        const struct libusb_interface_descriptor *alt = &interface->altsetting[0];
        for (uint8_t e = 0; e < alt->bNumEndpoints; e++) {
            const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[e];
            if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK) continue;
            if ((endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN) {
                found_in = endpoint->bEndpointAddress;
            } else {
                found_out = endpoint->bEndpointAddress;
            }
        }
    }
    libusb_free_config_descriptor(config);
    if (!found_in || !found_out) return -1;
    *in = found_in;
    *out = found_out;
    return 0;
}

static void send_bye_to_resync(void) {
    /* [u32 length=1][u8 BYE=8] forces an already-open Android client to
     * reconnect and send a fresh HELLO. The length counts the type byte, so a
     * zero here is a malformed frame and the client drops the session. */
    unsigned char bye[5] = {0, 0, 0, 1, 8};
    int transferred = 0;
    libusb_bulk_transfer(
        usb_handle, endpoint_out, bye, sizeof(bye), &transferred, 1000
    );
    printf("sent BYE to resync accessory client\n");
    fflush(stdout);
}

/* BSD signal() restarts interrupted syscalls, so a bare blocking send/recv
 * ignores SIGTERM and leaves an orphan holding the device in accessory mode.
 * Every socket wait polls with a timeout and re-checks stopping. */
static int wait_fd(int fd, short events) {
    for (;;) {
        if (stopping) return -1;
        struct pollfd pfd = {fd, events, 0};
        int ready = poll(&pfd, 1, 200);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (ready > 0 && (pfd.revents & (events | POLLHUP | POLLERR))) return 0;
    }
}

static int write_all(int fd, const unsigned char *data, size_t length) {
    size_t offset = 0;
    while (offset < length && !stopping) {
        if (wait_fd(fd, POLLOUT) != 0) return -1;
        ssize_t written = send(fd, data + offset, length - offset, MSG_NOSIGNAL);
        if (written <= 0) return -1;
        offset += (size_t)written;
    }
    return 0;
}

/* Keep the last HELLO the device sent so a restarted helper gets the current
 * orientation instead of the one from when the cable was plugged in. */
static void cache_hello(const unsigned char *data, size_t length) {
    size_t offset = 0;
    while (offset + 5 <= length) {
        uint32_t frame_length = ((uint32_t)data[offset] << 24) |
                                ((uint32_t)data[offset + 1] << 16) |
                                ((uint32_t)data[offset + 2] << 8) |
                                (uint32_t)data[offset + 3];
        if (frame_length < 1 || frame_length > 64 * 1024) return;
        if (offset + 4 + frame_length > length) return;
        if (data[offset + 4] == 1 && 4 + frame_length <= sizeof(hello_data)) {
            memcpy(hello_data, data + offset, 4 + frame_length);
            hello_length = (int)(4 + frame_length);
        }
        offset += 4 + frame_length;
    }
}

static void *usb_to_tcp(void *unused) {
    (void)unused;
    unsigned char buffer[USB_BUFFER];
    while (!stopping && !paused && !session_abort) {
        int transferred = 0;
        int rc = libusb_bulk_transfer(
            usb_handle, endpoint_in, buffer, sizeof(buffer), &transferred, 1000
        );
        // Same as the OUT path: bytes moved before the timeout still count, or
        // the helper's frame parser loses them and desyncs.
        if (rc == LIBUSB_ERROR_TIMEOUT && transferred <= 0) continue;
        if (rc != 0 && transferred <= 0) {
            fprintf(stderr, "usb read stopped rc=%d transferred=%d\n", rc, transferred);
            session_abort = 1;
            break;
        }

        cache_hello(buffer, (size_t)transferred);

        pthread_mutex_lock(&tcp_lock);
        int fd = tcp_fd;
        if (fd < 0) {
            pthread_mutex_unlock(&tcp_lock);
            usleep(10000);
            continue;
        }
        if (write_all(fd, buffer, (size_t)transferred) != 0) {
            fprintf(stderr, "tcp write stopped; waiting for helper\n");
            shutdown(fd, SHUT_RDWR);
            if (tcp_fd == fd) tcp_fd = -1;
        }
        pthread_mutex_unlock(&tcp_lock);
    }
    if (!paused) session_abort = 1;
    pthread_mutex_lock(&tcp_lock);
    if (tcp_fd >= 0) shutdown(tcp_fd, SHUT_RDWR);
    pthread_mutex_unlock(&tcp_lock);
    return NULL;
}

static int connect_helper_with_retry(void) {
    while (!stopping && !paused && !session_abort) {
        int fd = connect_tcp(port_number);
        if (fd >= 0) {
            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            return fd;
        }
        usleep(200000);
    }
    return -1;
}

static void *tcp_to_usb(void *unused) {
    (void)unused;
    unsigned char buffer[USB_BUFFER];
    int fd = tcp_fd;
    /* The client can close the accessory while the cable stays attached; the
     * device then stops draining OUT and every transfer times out forever.
     * Exit so the supervisor re-does the AOA handshake for a fresh session. */
    int out_timeouts = 0;

    while (!stopping && !paused && !session_abort) {
        if (fd < 0) {
            fd = connect_helper_with_retry();
            if (fd < 0) break;
            if (hello_length > 0 && write_all(fd, hello_data, (size_t)hello_length) != 0) {
                close(fd);
                fd = -1;
                continue;
            }
            pthread_mutex_lock(&tcp_lock);
            tcp_fd = fd;
            pthread_mutex_unlock(&tcp_lock);
            printf("helper reconnected\n");
            fflush(stdout);
        }

        ssize_t read_count;
        if (wait_fd(fd, POLLIN) != 0) {
            if (!stopping) session_abort = 1;
            break;
        }
        read_count = recv(fd, buffer, sizeof(buffer), 0);
        if (read_count <= 0) {
            fprintf(stderr, "tcp read stopped count=%zd; reconnecting\n", read_count);
            int old_fd = fd;
            close(old_fd);
            pthread_mutex_lock(&tcp_lock);
            if (tcp_fd == old_fd) tcp_fd = -1;
            pthread_mutex_unlock(&tcp_lock);
            fd = -1;
            if (!stopping && !paused && !session_abort) usleep(200000);
            continue;
        }

        size_t offset = 0;
        while (offset < (size_t)read_count && !stopping && !paused) {
            int transferred = 0;
            int rc = libusb_bulk_transfer(
                usb_handle, endpoint_out, buffer + offset,
                (int)((size_t)read_count - offset), &transferred, 1000
            );
            /* A timed-out transfer that still moved bytes is progress. Treating
             * it as a stall re-sent the same bytes from `offset` on the next
             * attempt, which duplicated them into the stream and desynced the
             * client's frame parser. */
            if (transferred > 0) {
                offset += (size_t)transferred;
                out_timeouts = 0;
                if (rc == LIBUSB_ERROR_TIMEOUT) continue;
            }
            if (rc == LIBUSB_ERROR_TIMEOUT) {
                if (++out_timeouts >= 3) {
                    fprintf(stderr, "accessory not draining; restarting AOA"
                        " (chunk=%zd off=%zu first=%02x%02x%02x%02x type=%02x)\n",
                        read_count, offset, read_count > 4 ? buffer[0] : 0,
                        read_count > 4 ? buffer[1] : 0, read_count > 4 ? buffer[2] : 0,
                        read_count > 4 ? buffer[3] : 0, read_count > 4 ? buffer[4] : 0);
                    fflush(stderr);
                    session_abort = 1;
                    break;
                }
                continue;
            }
            out_timeouts = 0;
            if (rc != 0 || transferred <= 0) {
                fprintf(stderr, "usb write stopped rc=%d transferred=%d\n", rc, transferred);
                session_abort = 1;
                break;
            }
        }
    }

    if (fd >= 0) close(fd);
    if (!paused) session_abort = 1;
    pthread_mutex_lock(&tcp_lock);
    if (tcp_fd >= 0) shutdown(tcp_fd, SHUT_RDWR);
    pthread_mutex_unlock(&tcp_lock);
    return NULL;
}

/* 控制通道：helper 在 Wi-Fi 客户端在线时发 pause，避免桥上电切走设备；
 * AUTO 需要 USB 时发 resume；停止服务时发 stop。一行一条命令。 */
static void *control_thread(void *unused) {
    (void)unused;
    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) return NULL;
    int one = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(7780);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(listen_fd, 4) != 0) {
        fprintf(stderr, "bridge control port 7780 unavailable (errno=%d)\n", errno);
        close(listen_fd);
        return NULL;
    }
    while (!stopping) {
        struct pollfd pfd = {listen_fd, POLLIN, 0};
        if (poll(&pfd, 1, 500) <= 0) continue;
        int fd = accept(listen_fd, NULL, NULL);
        if (fd < 0) continue;
        char buffer[64];
        memset(buffer, 0, sizeof(buffer));
        ssize_t count = read(fd, buffer, sizeof(buffer) - 1);
        close(fd);
        if (count <= 0) continue;
        if (strncmp(buffer, "pause", 5) == 0) {
            paused = 1;
            printf("bridge paused\n");
            fflush(stdout);
        } else if (strncmp(buffer, "resume", 6) == 0) {
            paused = 0;
            printf("bridge resumed\n");
            fflush(stdout);
        } else if (strncmp(buffer, "stop", 4) == 0) {
            stopping = 1;
            graceful_stop = 1;
        }
    }
    close(listen_fd);
    return NULL;
}

int main(int argc, char **argv) {
    int port = 7777;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);
    port_number = port;

    if (libusb_init(&usb_ctx) != 0) {
        fprintf(stderr, "libusb_init failed\n");
        return 1;
    }

    pthread_t control;
    pthread_create(&control, NULL, control_thread, NULL);

    int bye_sent = 0;
    int paused_reset_done = 0;
    while (!stopping) {
        if (paused) {
            if (!paused_reset_done) {
                // Leave accessory mode while paused so the phone shows a usable
                // USB accessory only when the bridge can actually serve it.
                paused_reset_done = 1;
                libusb_device *acc = find_accessory_device();
                if (acc != NULL) {
                    libusb_device_handle *handle = NULL;
                    if (libusb_open(acc, &handle) == 0) {
                        libusb_reset_device(handle);
                        libusb_close(handle);
                    }
                    libusb_unref_device(acc);
                }
            }
            usleep(200000);
            continue;
        }
        paused_reset_done = 0;

        libusb_device *accessory = find_accessory_device();
        int existing_accessory = accessory != NULL;
        if (accessory == NULL) {
            int version = 0;
            libusb_device *device = find_aoa_device(&version);
            if (device == NULL) {
                usleep(500000);
                continue;
            }
            if (libusb_open(device, &usb_handle) != 0) {
                fprintf(stderr, "cannot open device\n");
                libusb_unref_device(device);
                usleep(500000);
                continue;
            }
            int string_error = 0;
            if (control_string(usb_handle, 0, "Mirage") < 0) string_error = 1;
            if (control_string(usb_handle, 1, "Mirage Display") < 0) string_error = 1;
            if (control_string(usb_handle, 2, "Mirage USB display") < 0) string_error = 1;
            if (control_string(usb_handle, 3, "1") < 0) string_error = 1;
            if (string_error) {
                fprintf(stderr, "AOA string transfer failed\n");
                libusb_close(usb_handle);
                usb_handle = NULL;
                libusb_unref_device(device);
                usleep(500000);
                continue;
            }
            printf("switching device to accessory mode...\n");
            fflush(stdout);
            libusb_control_transfer(usb_handle, 0x40, AOA_START, 0, 0, NULL, 0, 1000);
            libusb_close(usb_handle);
            usb_handle = NULL;
            libusb_unref_device(device);
            if (wait_for_accessory(&accessory) != 0) {
                fprintf(stderr, "accessory did not enumerate\n");
                usleep(500000);
                continue;
            }
        } else {
            printf("using existing accessory\n");
            fflush(stdout);
        }

        if (paused || stopping) {
            libusb_unref_device(accessory);
            continue;
        }

        if (probe_tcp(port_number) != 0) {
            fprintf(stderr, "helper is not listening on 127.0.0.1:%d\n", port_number);
            libusb_unref_device(accessory);
            usleep(500000);
            continue;
        }

        if (libusb_open(accessory, &usb_handle) != 0) {
            fprintf(stderr, "cannot open accessory\n");
            libusb_unref_device(accessory);
            usleep(500000);
            continue;
        }
        if (libusb_claim_interface(usb_handle, 0) != 0) {
            fprintf(stderr, "cannot claim accessory interface\n");
            libusb_close(usb_handle);
            usb_handle = NULL;
            libusb_unref_device(accessory);
            usleep(500000);
            continue;
        }
        if (find_endpoints(accessory, &endpoint_in, &endpoint_out) != 0) {
            fprintf(stderr, "accessory bulk endpoints not found\n");
            libusb_release_interface(usb_handle, 0);
            libusb_close(usb_handle);
            usb_handle = NULL;
            libusb_unref_device(accessory);
            usleep(500000);
            continue;
        }
        libusb_unref_device(accessory);

        if (existing_accessory && !bye_sent) {
            bye_sent = 1;
            send_bye_to_resync();
        }

        hello_length = 0;
        printf("waiting for Android accessory client...\n");
        fflush(stdout);
        unsigned char first[USB_BUFFER];
        int first_length = 0;
        while (!stopping && !paused && !session_abort && first_length <= 0) {
            int rc_bulk = libusb_bulk_transfer(
                usb_handle, endpoint_in, first, sizeof(first), &first_length, 1000
            );
            if (rc_bulk == LIBUSB_ERROR_TIMEOUT) continue;
            if (rc_bulk != 0) {
                fprintf(stderr, "accessory read failed: %d\n", rc_bulk);
                first_length = 0;
                break;
            }
        }
        if (paused || stopping || first_length <= 0) {
            libusb_release_interface(usb_handle, 0);
            libusb_close(usb_handle);
            usb_handle = NULL;
            if (!paused && !stopping) usleep(200000);
            continue;
        }
        memcpy(hello_data, first, (size_t)first_length);
        hello_length = first_length;

        tcp_fd = connect_tcp(port_number);
        if (tcp_fd < 0) {
            fprintf(stderr, "cannot connect helper on 127.0.0.1:%d\n", port_number);
            libusb_release_interface(usb_handle, 0);
            libusb_close(usb_handle);
            usb_handle = NULL;
            usleep(500000);
            continue;
        }
        int one = 1;
        setsockopt(tcp_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        if (write_all(tcp_fd, first, (size_t)first_length) != 0) {
            close(tcp_fd);
            tcp_fd = -1;
            libusb_release_interface(usb_handle, 0);
            libusb_close(usb_handle);
            usb_handle = NULL;
            usleep(500000);
            continue;
        }

        printf("bridging accessory in=%02x out=%02x to tcp=%d\n", endpoint_in, endpoint_out, tcp_fd);
        fflush(stdout);

        pthread_t reader;
        pthread_t writer;
        pthread_create(&reader, NULL, usb_to_tcp, NULL);
        pthread_create(&writer, NULL, tcp_to_usb, NULL);
        pthread_join(reader, NULL);
        pthread_join(writer, NULL);

        if (tcp_fd >= 0) {
            close(tcp_fd);
            tcp_fd = -1;
        }
        if (stopping && graceful_stop && usb_handle != NULL) {
            int reset_rc = libusb_reset_device(usb_handle);
            fprintf(stderr, "usb reset rc=%d\n", reset_rc);
            fflush(stderr);
        }
        if (usb_handle != NULL) {
            libusb_release_interface(usb_handle, 0);
            libusb_close(usb_handle);
            usb_handle = NULL;
        }
        if (session_abort) {
            // Restart just this session: exit accessory mode so the phone can
            // re-enumerate, but keep the process and control port alive.
            session_abort = 0;
            libusb_device *acc = find_accessory_device();
            if (acc != NULL) {
                libusb_device_handle *handle = NULL;
                if (libusb_open(acc, &handle) == 0) {
                    libusb_reset_device(handle);
                    libusb_close(handle);
                }
                libusb_unref_device(acc);
            }
            usleep(300000);
            continue;
        }
        if (!paused && !stopping) usleep(200000);
    }

    // 暂停期间被停止（SIGTERM/stop）也要把设备 reset 回普通 USB，
    // 否则平板会一直停在配件模式。
    if (graceful_stop) {
        libusb_device *acc = find_accessory_device();
        if (acc != NULL) {
            libusb_device_handle *handle = NULL;
            if (libusb_open(acc, &handle) == 0) {
                libusb_reset_device(handle);
                libusb_close(handle);
            }
            libusb_unref_device(acc);
        }
    }
    libusb_exit(usb_ctx);
    return 0;
}
