#include "usb_transport.h"

#include <fcntl.h>
#include <hilog/log.h>
#include <poll.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Domain 0 is dropped by the log service, so the OH_LOG_* macros would print
// nothing in a hilog dump. Keep this in sync with the ArkTS side.
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0200
#define LOG_TAG "MirageNative"

namespace {

// The accessory fd is not a socket and fileIo rejects it; only poll/read/write work.
// Driver caps a single read at 16384 bytes (65536 returns EINVAL).
constexpr size_t kReadSize = 16384;
// Short enough that a stopped reader exits quickly: it must be gone before the
// accessory fd is closed, or the OS hands the same fd number to the next
// accessory and the zombie steals bytes from the new session's stream.
constexpr int kReaderJoinMs = 50;
constexpr int kWriteBudgetMs = 1200;
constexpr int kWritePollMs = 100;
constexpr size_t kMaxQueuedWrites = 32;

std::mutex g_lock;

struct UsbEvent {
    std::string kind;
    std::vector<uint8_t> data;
    bool hasData = false;
};

void CallJs(napi_env env, napi_value jsCallback, void *, void *raw) {
    UsbEvent *event = static_cast<UsbEvent *>(raw);
    if (env == nullptr || jsCallback == nullptr || event == nullptr) {
        delete event;
        return;
    }
    napi_value argv[2];
    napi_create_string_utf8(env, event->kind.c_str(), NAPI_AUTO_LENGTH, &argv[0]);
    if (event->hasData) {
        void *buffer = nullptr;
        if (napi_create_arraybuffer(env, event->data.size(), &buffer, &argv[1]) != napi_ok) {
            napi_get_null(env, &argv[1]);
        } else if (buffer != nullptr && !event->data.empty()) {
            std::memcpy(buffer, event->data.data(), event->data.size());
        }
    } else {
        napi_get_null(env, &argv[1]);
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, jsCallback, 2, argv, nullptr);
    delete event;
}

void Emit(napi_threadsafe_function tsfn, const std::string &kind, std::vector<uint8_t> &&data) {
    if (tsfn == nullptr) {
        return;
    }
    const bool hasData = kind == "data" && !data.empty();
    auto *event = new UsbEvent{kind, std::move(data), hasData};
    if (napi_call_threadsafe_function(tsfn, event, napi_tsfn_nonblocking) != napi_ok) {
        delete event;
    }
}

// The accessory fd blocks in practice (F_SETFL is refused, or the driver ignores
// it): read() and write() can sit in the kernel until the cable is pulled. Both
// directions therefore run on their own thread and are never joined from the JS
// thread — one stuck syscall would freeze the whole UI.
struct ReadState {
    std::atomic<bool> running{true};
    std::atomic<bool> exited{false};
    napi_threadsafe_function tsfn = nullptr;
    int fd = -1;
    std::thread thread;
};

struct WriteState {
    std::mutex lock;
    std::condition_variable cv;
    std::deque<std::vector<uint8_t>> items;
    std::atomic<bool> stopping{false};
    int fd = -1;
    std::thread thread;
};

std::shared_ptr<ReadState> g_reader;   // guarded by g_lock
std::shared_ptr<WriteState> g_writer;  // guarded by g_lock

// Only read when poll says data is queued: F_SETFL can fail on an accessory fd,
// and a bare read() then blocks the caller until the host writes.
void DrainPending(int fd) {
    uint8_t discard[4096];
    for (;;) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int ready = poll(&pfd, 1, 0);
        if (ready <= 0 || !(pfd.revents & POLLIN)) {
            return;
        }
        if (read(fd, discard, sizeof(discard)) <= 0) {
            return;
        }
    }
}

void ReadLoop(std::shared_ptr<ReadState> state) {
    // A closed session can leave host bytes queued on the OUT endpoint. The host
    // writes nothing until it has read our HELLO, so discard them before reading.
    DrainPending(state->fd);
    std::vector<uint8_t> buffer(kReadSize);
    int64_t totalBytes = 0;
    int32_t reads = 0;
    int lastRevents = 0;
    while (state->running.load()) {
        // Always keep a read posted: the driver only pulls the host's OUT
        // transfers up while a read is outstanding, so a poll-gated loop
        // deadlocks (host NAKs forever, poll never turns readable). The cost is
        // that stop cannot interrupt this call — StopLocked detaches instead,
        // and a blocked read stays pinned to the old fd, so it can never steal
        // bytes from the next session's accessory.
        ssize_t count = read(state->fd, buffer.data(), buffer.size());
        if (count <= 0) {
            if (count < 0 && (errno == EINTR || errno == EAGAIN)) {
                continue;
            }
            lastRevents = count == 0 ? -1000 : -errno;
            break;
        }
        totalBytes += count;
        reads += 1;
        if (reads <= 3 || reads % 200 == 0) {
            OH_LOG_INFO(LOG_APP, "MirageNative usb read n=%{public}d bytes=%{public}zd total=%{public}lld",
                reads, count, static_cast<long long>(totalBytes));
        }
        Emit(state->tsfn, "data", std::vector<uint8_t>(buffer.begin(), buffer.begin() + count));
    }
    OH_LOG_INFO(LOG_APP, "MirageNative usb read exit reads=%{public}d total=%{public}lld marker=%{public}d",
        reads, static_cast<long long>(totalBytes), lastRevents);
    Emit(state->tsfn, "closed", {});
    napi_threadsafe_function tsfn = state->tsfn;
    state->tsfn = nullptr;
    if (tsfn != nullptr) {
        napi_release_threadsafe_function(tsfn, napi_tsfn_release);
    }
    state->exited.store(true);
}

// Runs on the writer thread only. poll gates each attempt, and the deadline
// bounds the EAGAIN livelock that happens when poll keeps reporting POLLOUT
// while the endpoint refuses data.
int WriteAll(int fd, const uint8_t *data, size_t length) {
    if (fd < 0) {
        return -1;
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(kWriteBudgetMs);
    size_t offset = 0;
    while (offset < length) {
        if (std::chrono::steady_clock::now() > deadline) {
            return -1;
        }
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLOUT;
        pfd.revents = 0;
        int ready = poll(&pfd, 1, kWritePollMs);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (ready == 0) {
            continue;
        }
        if (!(pfd.revents & POLLOUT)) {
            return -1;
        }
        ssize_t count = write(fd, data + offset, length - offset);
        if (count < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            return -1;
        }
        if (count == 0) {
            return -1;
        }
        offset += static_cast<size_t>(count);
    }
    return static_cast<int>(offset);
}

void WriteLoop(std::shared_ptr<WriteState> state) {
    for (;;) {
        std::vector<uint8_t> item;
        {
            std::unique_lock<std::mutex> waitLock(state->lock);
            state->cv.wait(waitLock, [&state] {
                return state->stopping.load() || !state->items.empty();
            });
            if (state->stopping.load()) {
                return;
            }
            item = std::move(state->items.front());
            state->items.pop_front();
        }
        // A failed write means the session is over; the liveness watchdog on
        // the JS side notices the silence and closes it.
        if (WriteAll(state->fd, item.data(), item.size()) != static_cast<int>(item.size())) {
            state->stopping.store(true);
            state->cv.notify_all();
            return;
        }
    }
}

// Caller must hold g_lock.
void StopLocked() {
    const std::shared_ptr<ReadState> reader = g_reader;
    g_reader = nullptr;
    if (reader != nullptr) {
        OH_LOG_INFO(LOG_APP, "MirageNative usb stop fd=%{public}d", reader->fd);
        reader->running.store(false);
        // The reader must be gone before the caller closes the fd: the OS reuses
        // fd numbers immediately, so a straggler still blocked in read() starts
        // consuming the *next* accessory's stream and corrupts its framing.
        // Bounded, because a read() wedged on a silent endpoint only returns
        // when the cable is pulled; that case still falls back to detaching.
        for (int waited = 0; waited < kReaderJoinMs && !reader->exited.load(); waited += 5) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        if (reader->thread.joinable()) {
            if (reader->exited.load()) {
                reader->thread.join();
            } else {
                reader->thread.detach();
            }
        }
    }
    const std::shared_ptr<WriteState> writer = g_writer;
    g_writer = nullptr;
    if (writer != nullptr) {
        {
            std::lock_guard<std::mutex> writerLock(writer->lock);
            writer->stopping.store(true);
            writer->items.clear();
        }
        writer->cv.notify_all();
        if (writer->thread.joinable()) {
            writer->thread.detach();
        }
    }
}

bool GetBytes(napi_env env, napi_value value, void **data, size_t *length) {
    napi_typedarray_type type;
    napi_value arrayBuffer = nullptr;
    size_t byteOffset = 0;
    if (napi_get_typedarray_info(env, value, &type, length, data, &arrayBuffer, &byteOffset) == napi_ok) {
        return type == napi_uint8_array;
    }
    return napi_get_arraybuffer_info(env, value, data, length) == napi_ok;
}

}  // namespace

napi_value StartUsb(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t fd = -1;
    napi_valuetype type = napi_undefined;
    if (argc < 2 || napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0 ||
        napi_typeof(env, argv[1], &type) != napi_ok || type != napi_function) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    std::lock_guard<std::mutex> guard(g_lock);
    StopLocked();

    napi_threadsafe_function tsfn = nullptr;
    napi_value name;
    napi_create_string_utf8(env, "MirageUsbEvent", NAPI_AUTO_LENGTH, &name);
    napi_status status = napi_create_threadsafe_function(env, argv[1], nullptr, name, 0, 1, nullptr,
        nullptr, nullptr, CallJs, &tsfn);
    if (status != napi_ok || tsfn == nullptr) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    auto reader = std::make_shared<ReadState>();
    reader->fd = fd;
    reader->tsfn = tsfn;
    g_reader = reader;
    reader->thread = std::thread(ReadLoop, reader);
    OH_LOG_INFO(LOG_APP, "MirageNative usb start fd=%{public}d", fd);

    auto writer = std::make_shared<WriteState>();
    writer->fd = fd;
    g_writer = writer;
    writer->thread = std::thread(WriteLoop, writer);

    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

napi_value StopUsb(napi_env env, napi_callback_info) {
    std::lock_guard<std::mutex> guard(g_lock);
    StopLocked();
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value UsbWrite(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    void *data = nullptr;
    size_t length = 0;
    int written = -1;
    if (argc >= 1 && GetBytes(env, argv[0], &data, &length) && data != nullptr) {
        std::lock_guard<std::mutex> guard(g_lock);
        const std::shared_ptr<WriteState> writer = g_writer;
        if (writer != nullptr && !writer->stopping.load()) {
            std::lock_guard<std::mutex> queueLock(writer->lock);
            if (writer->items.size() < kMaxQueuedWrites) {
                const auto *bytes = static_cast<const uint8_t *>(data);
                writer->items.emplace_back(bytes, bytes + length);
                writer->cv.notify_one();
                written = static_cast<int>(length);
            }
        }
    }
    napi_value result;
    napi_create_int32(env, written, &result);
    return result;
}