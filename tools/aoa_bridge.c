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
#include <libusb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
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
static volatile sig_atomic_t graceful_stop = 0;
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
    /* [u32 length=0][u8 BYE=8] forces an already-open Android client to
     * reconnect and send a fresh HELLO. */
    unsigned char bye[5] = {0, 0, 0, 0, 8};
    int transferred = 0;
    libusb_bulk_transfer(
        usb_handle, endpoint_out, bye, sizeof(bye), &transferred, 1000
    );
    printf("sent BYE to resync accessory client\n");
    fflush(stdout);
}

static int write_all(int fd, const unsigned char *data, size_t length) {
    size_t offset = 0;
    while (offset < length && !stopping) {
        ssize_t written = send(fd, data + offset, length - offset, MSG_NOSIGNAL);
        if (written <= 0) return -1;
        offset += (size_t)written;
    }
    return 0;
}

static void *usb_to_tcp(void *unused) {
    (void)unused;
    unsigned char buffer[USB_BUFFER];
    while (!stopping) {
        int transferred = 0;
        int rc = libusb_bulk_transfer(
            usb_handle, endpoint_in, buffer, sizeof(buffer), &transferred, 1000
        );
        if (rc == LIBUSB_ERROR_TIMEOUT) continue;
        if (rc != 0 || transferred <= 0) {
            fprintf(stderr, "usb read stopped rc=%d transferred=%d\n", rc, transferred);
            break;
        }

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
    stopping = 1;
    pthread_mutex_lock(&tcp_lock);
    if (tcp_fd >= 0) shutdown(tcp_fd, SHUT_RDWR);
    pthread_mutex_unlock(&tcp_lock);
    return NULL;
}

static int connect_helper_with_retry(void) {
    while (!stopping) {
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

    while (!stopping) {
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

        ssize_t read_count = recv(fd, buffer, sizeof(buffer), 0);
        if (read_count <= 0) {
            fprintf(stderr, "tcp read stopped count=%zd; reconnecting\n", read_count);
            int old_fd = fd;
            close(old_fd);
            pthread_mutex_lock(&tcp_lock);
            if (tcp_fd == old_fd) tcp_fd = -1;
            pthread_mutex_unlock(&tcp_lock);
            fd = -1;
            continue;
        }

        size_t offset = 0;
        while (offset < (size_t)read_count && !stopping) {
            int transferred = 0;
            int rc = libusb_bulk_transfer(
                usb_handle, endpoint_out, buffer + offset,
                (int)((size_t)read_count - offset), &transferred, 1000
            );
            if (rc == LIBUSB_ERROR_TIMEOUT) continue;
            if (rc != 0 || transferred <= 0) {
                fprintf(stderr, "usb write stopped rc=%d transferred=%d\n", rc, transferred);
                stopping = 1;
                break;
            }
            offset += (size_t)transferred;
        }
    }

    if (fd >= 0) close(fd);
    stopping = 1;
    pthread_mutex_lock(&tcp_lock);
    if (tcp_fd >= 0) shutdown(tcp_fd, SHUT_RDWR);
    pthread_mutex_unlock(&tcp_lock);
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

    int version = 0;
    libusb_device *device = find_aoa_device(&version);
    if (device == NULL) {
        fprintf(stderr, "no AOA device found\n");
        libusb_exit(usb_ctx);
        return 1;
    }

    int preflight_fd = probe_tcp(port);
    if (preflight_fd != 0) {
        fprintf(stderr, "helper is not listening on 127.0.0.1:%d\n", port);
        libusb_exit(usb_ctx);
        return 1;
    }

    libusb_device *accessory = find_accessory_device();
    int existing_accessory = accessory != NULL;
    if (accessory == NULL) {
        int version = 0;
        libusb_device *device = find_aoa_device(&version);
        if (device == NULL) {
            fprintf(stderr, "no AOA device found\n");
            libusb_exit(usb_ctx);
            return 1;
        }

        if (libusb_open(device, &usb_handle) != 0) {
            fprintf(stderr, "cannot open device\n");
            libusb_unref_device(device);
            libusb_exit(usb_ctx);
            return 1;
        }

        int string_error = 0;
        if (control_string(usb_handle, 0, "Mirage") < 0) string_error = 1;
        if (control_string(usb_handle, 1, "Mirage Display") < 0) string_error = 1;
        if (control_string(usb_handle, 2, "Mirage USB display") < 0) string_error = 1;
        if (control_string(usb_handle, 3, "1") < 0) string_error = 1;
        if (string_error) {
            fprintf(stderr, "AOA string transfer failed\n");
            libusb_close(usb_handle);
            libusb_unref_device(device);
            libusb_exit(usb_ctx);
            return 1;
        }

        printf("switching device to accessory mode...\n");
        fflush(stdout);
        libusb_control_transfer(usb_handle, 0x40, AOA_START, 0, 0, NULL, 0, 1000);
        libusb_close(usb_handle);
        usb_handle = NULL;
        libusb_unref_device(device);

        if (wait_for_accessory(&accessory) != 0) {
            fprintf(stderr, "accessory did not enumerate\n");
            libusb_exit(usb_ctx);
            return 1;
        }
    } else {
        printf("using existing accessory\n");
        fflush(stdout);
    }

    if (libusb_open(accessory, &usb_handle) != 0) {
        fprintf(stderr, "cannot open accessory\n");
        libusb_unref_device(accessory);
        libusb_exit(usb_ctx);
        return 1;
    }
    if (libusb_claim_interface(usb_handle, 0) != 0) {
        fprintf(stderr, "cannot claim accessory interface\n");
        libusb_close(usb_handle);
        libusb_unref_device(accessory);
        libusb_exit(usb_ctx);
        return 1;
    }
    if (find_endpoints(accessory, &endpoint_in, &endpoint_out) != 0) {
        fprintf(stderr, "accessory bulk endpoints not found\n");
        libusb_release_interface(usb_handle, 0);
        libusb_close(usb_handle);
        libusb_unref_device(accessory);
        libusb_exit(usb_ctx);
        return 1;
    }
    libusb_unref_device(accessory);

    if (existing_accessory) {
        send_bye_to_resync();
    }

    printf("waiting for Android accessory client...\n");
    fflush(stdout);
    unsigned char first[USB_BUFFER];
    int first_length = 0;
    while (!stopping && first_length <= 0) {
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
    if (first_length <= 0) {
        libusb_release_interface(usb_handle, 0);
        libusb_close(usb_handle);
        libusb_exit(usb_ctx);
        return 1;
    }
    memcpy(hello_data, first, (size_t)first_length);
    hello_length = first_length;

    tcp_fd = connect_tcp(port);
    if (tcp_fd < 0) {
        fprintf(stderr, "cannot connect helper on 127.0.0.1:%d\n", port);
        libusb_release_interface(usb_handle, 0);
        libusb_close(usb_handle);
        libusb_exit(usb_ctx);
        return 1;
    }
    int one = 1;
    setsockopt(tcp_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    if (write_all(tcp_fd, first, (size_t)first_length) != 0) {
        close(tcp_fd);
        libusb_release_interface(usb_handle, 0);
        libusb_close(usb_handle);
        libusb_exit(usb_ctx);
        return 1;
    }

    printf("bridging accessory in=%02x out=%02x to tcp=%d\n", endpoint_in, endpoint_out, tcp_fd);
    fflush(stdout);

    pthread_t reader;
    pthread_t writer;
    pthread_create(&reader, NULL, usb_to_tcp, NULL);
    pthread_create(&writer, NULL, tcp_to_usb, NULL);
    pthread_join(reader, NULL);
    pthread_join(writer, NULL);

    close(tcp_fd);
    tcp_fd = -1;
    if (graceful_stop) {
        /* Ask the phone to leave accessory mode; it re-enumerates as
         * charging/MTP instead of staying in ACCESSORY until a cable replug. */
        int reset_rc = libusb_reset_device(usb_handle);
        fprintf(stderr, "usb reset rc=%d\n", reset_rc);
        fflush(stderr);
    }
    libusb_release_interface(usb_handle, 0);
    libusb_close(usb_handle);
    usb_handle = NULL;
    libusb_exit(usb_ctx);
    return 0;
}