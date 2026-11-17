#include <napi/native_api.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "video_decoder.h"
#include "usb_transport.h"

namespace {

std::mutex g_lock;
std::shared_ptr<VideoDecoder> g_decoder;
napi_threadsafe_function g_tsfn = nullptr;
napi_env g_env = nullptr;

// Create/Stop/Destroy talk to the hardware codec service and can block for as
// long as that service takes; running them on the JS thread froze page
// transitions. Opens and closes run one at a time on this worker so their order
// matches the order the page requested them.
class CodecWorker {
public:
    CodecWorker() : thread_([this] { Run(); }) {
    }

    void Post(std::function<void()> task) {
        {
            std::lock_guard<std::mutex> guard(lock_);
            tasks_.push_back(std::move(task));
        }
        cv_.notify_one();
    }

private:
    void Run() {
        for (;;) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> waitLock(lock_);
                cv_.wait(waitLock, [this] { return !tasks_.empty(); });
                task = std::move(tasks_.front());
                tasks_.pop_front();
            }
            task();
        }
    }

    std::mutex lock_;
    std::condition_variable cv_;
    std::deque<std::function<void()>> tasks_;
    std::thread thread_;
};

CodecWorker &Worker() {
    static CodecWorker *worker = new CodecWorker();
    return *worker;
}

struct EventPayload {
    DecoderEvent event;
};

struct BoolPayload {
    bool value = false;
    napi_threadsafe_function tsfn = nullptr;
};

void CallJs(napi_env env, napi_value jsCallback, void *, void *data) {
    std::unique_ptr<EventPayload> payload(static_cast<EventPayload *>(data));
    if (env == nullptr || jsCallback == nullptr || payload == nullptr) {
        return;
    }
    napi_value event;
    napi_create_object(env, &event);
    napi_value value;
    napi_create_string_utf8(env, payload->event.kind.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, event, "kind", value);
    napi_create_int64(env, payload->event.frameId, &value);
    napi_set_named_property(env, event, "frameId", value);
    napi_create_int32(env, payload->event.bytes, &value);
    napi_set_named_property(env, event, "bytes", value);
    napi_create_int32(env, payload->event.flags, &value);
    napi_set_named_property(env, event, "flags", value);
    napi_create_int64(env, payload->event.captureTsMicros, &value);
    napi_set_named_property(env, event, "captureTsMicros", value);
    napi_create_double(env, payload->event.decodeMs, &value);
    napi_set_named_property(env, event, "decodeMs", value);
    napi_create_string_utf8(env, payload->event.reason.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, event, "reason", value);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, jsCallback, 1, &event, nullptr);
}

void EmitToJs(const DecoderEvent &event) {
    napi_threadsafe_function tsfn = g_tsfn;
    if (tsfn == nullptr) {
        return;
    }
    auto *payload = new EventPayload{event};
    if (napi_call_threadsafe_function(tsfn, payload, napi_tsfn_nonblocking) != napi_ok) {
        delete payload;
    }
}

void CallJsBool(napi_env env, napi_value jsCallback, void *, void *raw) {
    std::unique_ptr<BoolPayload> payload(static_cast<BoolPayload *>(raw));
    if (payload == nullptr) {
        return;
    }
    if (env != nullptr && jsCallback != nullptr) {
        napi_value value;
        napi_get_boolean(env, payload->value, &value);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, jsCallback, 1, &value, nullptr);
    }
    // Released only after delivery: releasing right after the call can drop the
    // queued callback on this runtime.
    if (payload->tsfn != nullptr) {
        napi_release_threadsafe_function(payload->tsfn, napi_tsfn_release);
    }
}

bool GetBytes(napi_env env, napi_value value, void **data, size_t *length) {
    napi_typedarray_type type;
    napi_value arrayBuffer = nullptr;
    size_t byteOffset = 0;
    if (napi_get_typedarray_info(env, value, &type, length, data, &arrayBuffer, &byteOffset) == napi_ok) {
        return true;
    }
    return napi_get_arraybuffer_info(env, value, data, length) == napi_ok;
}

napi_value OnEvent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_valuetype type = napi_undefined;
    if (argc < 1 || napi_typeof(env, argv[0], &type) != napi_ok || type != napi_function) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    napi_value name;
    napi_create_string_utf8(env, "MirageNativeEvent", NAPI_AUTO_LENGTH, &name);
    if (g_tsfn != nullptr) {
        napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
        g_tsfn = nullptr;
    }
    napi_create_threadsafe_function(env, argv[0], nullptr, name, 0, 1, nullptr, nullptr, nullptr, CallJs,
        &g_tsfn);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value OpenDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t width = 0;
    int32_t height = 0;
    int32_t fps = 60;
    napi_get_value_int32(env, argv[0], &width);
    napi_get_value_int32(env, argv[1], &height);
    napi_get_value_int32(env, argv[2], &fps);

    char surfaceText[32] = {0};
    size_t surfaceLen = 0;
    napi_get_value_string_utf8(env, argv[3], surfaceText, sizeof(surfaceText), &surfaceLen);
    uint64_t surfaceId = 0;
    try {
        surfaceId = std::stoull(surfaceText);
    } catch (...) {
        surfaceId = 0;
    }

    napi_threadsafe_function callback = nullptr;
    napi_valuetype type = napi_undefined;
    if (argc >= 5 && napi_typeof(env, argv[4], &type) == napi_ok && type == napi_function) {
        napi_value name;
        napi_create_string_utf8(env, "MirageDecoderOpen", NAPI_AUTO_LENGTH, &name);
        if (napi_create_threadsafe_function(env, argv[4], nullptr, name, 0, 1, nullptr, nullptr, nullptr,
            CallJsBool, &callback) != napi_ok) {
            callback = nullptr;
        }
    }

    Worker().Post([width, height, fps, surfaceId, callback] {
        std::shared_ptr<VideoDecoder> previous;
        {
            std::lock_guard<std::mutex> guard(g_lock);
            previous = g_decoder;
            g_decoder = nullptr;
        }
        if (previous != nullptr) {
            previous->Close();
        }
        auto decoder = std::make_shared<VideoDecoder>();
        bool ok = decoder->Open(width, height, fps, surfaceId, EmitToJs);
        {
            std::lock_guard<std::mutex> guard(g_lock);
            g_decoder = ok ? decoder : nullptr;
        }
        if (callback != nullptr) {
            auto *payload = new BoolPayload{ok, callback};
            if (napi_call_threadsafe_function(callback, payload, napi_tsfn_nonblocking) != napi_ok) {
                delete payload;
                napi_release_threadsafe_function(callback, napi_tsfn_release);
            }
        }
    });

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value SubmitVideo(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    void *data = nullptr;
    size_t length = 0;
    if (!GetBytes(env, argv[0], &data, &length) || data == nullptr) {
        napi_value error;
        napi_create_int32(env, -1, &error);
        return error;
    }
    int32_t flags = 0;
    int64_t frameId = 0;
    int64_t captureTs = 0;
    napi_get_value_int32(env, argv[1], &flags);
    napi_get_value_int64(env, argv[2], &frameId);
    napi_get_value_int64(env, argv[3], &captureTs);

    std::vector<uint8_t> copy(static_cast<uint8_t *>(data), static_cast<uint8_t *>(data) + length);
    std::shared_ptr<VideoDecoder> decoder;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        decoder = g_decoder;
    }
    int32_t rc = decoder != nullptr ? decoder->Submit(std::move(copy), flags, frameId, captureTs) : -1;
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

napi_value CloseDecoder(napi_env env, napi_callback_info) {
    std::shared_ptr<VideoDecoder> decoder;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        decoder = std::move(g_decoder);
        g_decoder = nullptr;
    }
    if (decoder != nullptr) {
        // The page has already destroyed (or is about to destroy) its XComponent
        // surface. Stop submitting frames and rendering into it right now; only
        // the slow Stop/Destroy is deferred to the worker.
        decoder->Suspend();
        Worker().Post([decoder] { decoder->Close(); });
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value Init(napi_env env, napi_value exports) {
    g_env = env;
    napi_property_descriptor desc[] = {
        {"openDecoder", nullptr, OpenDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"submitVideo", nullptr, SubmitVideo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeDecoder", nullptr, CloseDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onEvent", nullptr, OnEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startUsb", nullptr, StartUsb, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopUsb", nullptr, StopUsb, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"usbWrite", nullptr, UsbWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace

static napi_module mirageModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "mirage",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterMirageModule(void) {
    napi_module_register(&mirageModule);
}