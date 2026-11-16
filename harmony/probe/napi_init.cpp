// Probe: can we hardware-decode H.264 AnnexB in real time via the AVCodec NDK?
// Feeds every NAL of a buffer-mode (NV12) decoder and reports frame count + throughput.
#include <napi/native_api.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_averrors.h>

#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <poll.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <cstdio>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

struct ProbeState {
    OH_AVCodec *codec = nullptr;
    std::vector<std::pair<const uint8_t *, int32_t>> nals;
    std::vector<bool> keyFlags;
    size_t next = 0;
    bool eosSent = false;
    bool done = false;
    int outputFrames = 0;
    int64_t firstPushNs = 0;
    int64_t lastOutputNs = 0;
    std::string error;
    std::mutex lock;
    std::condition_variable cv;
};

int64_t NowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

void OnError(OH_AVCodec *, int32_t code, void *userData) {
    auto *state = static_cast<ProbeState *>(userData);
    std::lock_guard<std::mutex> guard(state->lock);
    state->error = "codec error " + std::to_string(code);
    state->done = true;
    state->cv.notify_all();
}

void OnStreamChanged(OH_AVCodec *, OH_AVFormat *, void *) {}

void OnNeedInput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    auto *state = static_cast<ProbeState *>(userData);
    std::lock_guard<std::mutex> guard(state->lock);
    if (state->done) return;
    if (state->next < state->nals.size()) {
        auto [ptr, len] = state->nals[state->next];
        bool key = state->keyFlags[state->next];
        uint8_t *dst = OH_AVBuffer_GetAddr(buffer);
        int32_t cap = OH_AVBuffer_GetCapacity(buffer);
        OH_AVCodecBufferAttr attr{};
        if (dst == nullptr || cap < len) {
            state->error = "input buffer too small";
            state->done = true;
            state->cv.notify_all();
            return;
        }
        std::memcpy(dst, ptr, len);
        attr.pts = static_cast<int64_t>(state->next) * 33333;
        attr.size = len;
        attr.offset = 0;
        attr.flags = key ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
        if (state->firstPushNs == 0) state->firstPushNs = NowNs();
        state->next++;
        if (OH_VideoDecoder_PushInputBuffer(codec, index) != AV_ERR_OK) {
            state->error = "push input failed";
            state->done = true;
            state->cv.notify_all();
        }
    } else if (!state->eosSent) {
        OH_AVCodecBufferAttr attr{};
        attr.pts = 0;
        attr.size = 0;
        attr.offset = 0;
        attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
        state->eosSent = true;
        OH_VideoDecoder_PushInputBuffer(codec, index);
    }
}

void OnNewOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    auto *state = static_cast<ProbeState *>(userData);
    std::lock_guard<std::mutex> guard(state->lock);
    OH_AVCodecBufferAttr attr{};
    OH_AVBuffer_GetBufferAttr(buffer, &attr);
    OH_VideoDecoder_FreeOutputBuffer(codec, index);
    if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
        state->done = true;
        state->cv.notify_all();
        return;
    }
    state->outputFrames++;
    state->lastOutputNs = NowNs();
}

int SplitAnnexB(const uint8_t *data, size_t size, ProbeState &state) {
    std::vector<size_t> starts;
    size_t i = 0;
    while (i + 3 <= size) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            starts.push_back(i);
            i += 3;
        } else if (i + 4 <= size && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) {
            starts.push_back(i);
            i += 4;
        } else {
            i++;
        }
    }
    if (starts.empty()) return 0;
    for (size_t n = 0; n < starts.size(); n++) {
        size_t begin = starts[n];
        size_t end = n + 1 < starts.size() ? starts[n + 1] : size;
        while (end > begin && data[end - 1] == 0) end--;
        size_t header = (data[begin + 2] == 1) ? 3 : 4;
        if (end <= begin + header) continue;
        int type = data[begin + header] & 0x1F;
        state.nals.emplace_back(data + begin, static_cast<int32_t>(end - begin));
        state.keyFlags.push_back(type == 5);
    }
    return static_cast<int>(state.nals.size());
}

}  // namespace

static napi_value ProbeDecode(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value result;
    napi_create_object(env, &result);
    auto setBool = [&](const char *name, bool value) {
        napi_value v;
        napi_get_boolean(env, value, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setNum = [&](const char *name, double value) {
        napi_value v;
        napi_create_double(env, value, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setStr = [&](const char *name, const std::string &value) {
        napi_value v;
        napi_create_string_utf8(env, value.c_str(), value.size(), &v);
        napi_set_named_property(env, result, name, v);
    };
    auto fail = [&](const std::string &message) {
        setBool("ok", false);
        setStr("error", message);
        return result;
    };

    void *data = nullptr;
    size_t length = 0;
    napi_typedarray_type type;
    napi_value arrayBuffer = nullptr;
    size_t byteOffset = 0;
    if (napi_get_typedarray_info(env, argv[0], &type, &length, &data, &arrayBuffer, &byteOffset) != napi_ok) {
        if (napi_get_arraybuffer_info(env, argv[0], &data, &length) != napi_ok) {
            return fail("argv[0] is not a buffer");
        }
    }
    int32_t width = 1280;
    int32_t height = 720;
    napi_get_value_int32(env, argv[1], &width);
    napi_get_value_int32(env, argv[2], &height);
    if (data == nullptr || length == 0) return fail("empty input");

    ProbeState state;
    if (SplitAnnexB(static_cast<const uint8_t *>(data), length, state) == 0) {
        return fail("no AnnexB NAL units found");
    }
    int nalCount = static_cast<int>(state.nals.size());

    state.codec = OH_VideoDecoder_CreateByMime("video/avc");
    if (state.codec == nullptr) return fail("CreateByMime(video/avc) failed");

    OH_AVCodecCallback callback{OnError, OnStreamChanged, OnNeedInput, OnNewOutput};
    if (OH_VideoDecoder_RegisterCallback(state.codec, callback, &state) != AV_ERR_OK) {
        OH_VideoDecoder_Destroy(state.codec);
        return fail("RegisterCallback failed");
    }

    OH_AVFormat *format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVErrCode configure = OH_VideoDecoder_Configure(state.codec, format);
    OH_AVFormat_Destroy(format);
    if (configure != AV_ERR_OK) {
        OH_VideoDecoder_Destroy(state.codec);
        return fail("Configure failed " + std::to_string(configure));
    }

    OH_AVErrCode start = OH_VideoDecoder_Start(state.codec);
    if (start != AV_ERR_OK) {
        OH_VideoDecoder_Destroy(state.codec);
        return fail("Start failed " + std::to_string(start));
    }

    {
        std::unique_lock<std::mutex> guard(state.lock);
        state.cv.wait_for(guard, std::chrono::seconds(3), [&state] { return state.done; });
    }

    int64_t elapsedNs = state.lastOutputNs > state.firstPushNs ? state.lastOutputNs - state.firstPushNs : 0;
    int frames = state.outputFrames;
    OH_VideoDecoder_Stop(state.codec);
    OH_VideoDecoder_Destroy(state.codec);

    setBool("ok", state.error.empty() && frames > 0);
    setNum("frames", frames);
    setNum("nals", nalCount);
    setNum("totalMs", static_cast<double>(elapsedNs) / 1e6);
    setNum("fps", elapsedNs > 0 ? static_cast<double>(frames) / (static_cast<double>(elapsedNs) / 1e9) : 0);
    setStr("error", state.error);
    return result;
}

static bool GetBufferData(napi_env env, napi_value value, void **data, size_t *length) {
    napi_typedarray_type type;
    napi_value arrayBuffer = nullptr;
    size_t byteOffset = 0;
    if (napi_get_typedarray_info(env, value, &type, length, data, &arrayBuffer, &byteOffset) == napi_ok) {
        return true;
    }
    return napi_get_arraybuffer_info(env, value, data, length) == napi_ok;
}

static napi_value FdWrite(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t fd = -1;
    napi_get_value_int32(env, argv[0], &fd);
    void *data = nullptr;
    size_t length = 0;
    napi_value result;
    napi_create_object(env, &result);
    ssize_t written = -1;
    int err = EINVAL;
    if (fd > 0 && GetBufferData(env, argv[1], &data, &length) && data != nullptr) {
        written = write(fd, data, length);
        err = written < 0 ? errno : 0;
    }
    napi_value n, e;
    napi_create_int32(env, static_cast<int32_t>(written), &n);
    napi_create_int32(env, err, &e);
    napi_set_named_property(env, result, "n", n);
    napi_set_named_property(env, result, "err", e);
    return result;
}

static napi_value FdRead(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t fd = -1;
    int32_t maxLen = 65536;
    int32_t timeoutMs = 3000;
    napi_get_value_int32(env, argv[0], &fd);
    napi_get_value_int32(env, argv[1], &maxLen);
    napi_get_value_int32(env, argv[2], &timeoutMs);

    napi_value result;
    napi_create_object(env, &result);
    auto setNum = [&](const char *name, int32_t value) {
        napi_value v;
        napi_create_int32(env, value, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setBool = [&](const char *name, bool value) {
        napi_value v;
        napi_get_boolean(env, value, &v);
        napi_set_named_property(env, result, name, v);
    };

    if (fd <= 0 || maxLen <= 0) {
        setBool("ok", false);
        setNum("n", 0);
        setNum("err", EINVAL);
        return result;
    }

    struct pollfd pfd = {fd, POLLIN, 0};
    int ready = poll(&pfd, 1, timeoutMs);
    int pollErrno = errno;
    if (ready <= 0) {
        setBool("ok", false);
        setNum("n", 0);
        setNum("err", ready == 0 ? -2 : pollErrno);
        setNum("ready", ready);
        setNum("avail", -1);
        setNum("stage", ready == 0 ? 1 : 2);
        return result;
    }

    int avail = -1;
    int ioctlErrno = 0;
    if (ioctl(fd, FIONREAD, &avail) != 0) {
        avail = -1;
        ioctlErrno = errno;
    }

    std::vector<uint8_t> buffer(static_cast<size_t>(maxLen));
    ssize_t n = read(fd, buffer.data(), buffer.size());
    int readErrno = n < 0 ? errno : 0;
    if (n < 0) {
        setBool("ok", false);
        setNum("n", 0);
        setNum("err", readErrno);
        setNum("ready", ready);
        setNum("avail", avail);
        setNum("ioctlErr", ioctlErrno);
        setNum("stage", 3);
        return result;
    }
    void *out = nullptr;
    napi_value arrayBuffer;
    napi_create_arraybuffer(env, static_cast<size_t>(n), &out, &arrayBuffer);
    if (n > 0 && out != nullptr) std::memcpy(out, buffer.data(), static_cast<size_t>(n));
    napi_set_named_property(env, result, "bytes", arrayBuffer);
    setBool("ok", true);
    setNum("n", static_cast<int32_t>(n));
    setNum("err", 0);
    setNum("ready", ready);
    setNum("avail", avail);
    setNum("stage", 0);
    return result;
}

static napi_value FdInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t fd = -1;
    napi_get_value_int32(env, argv[0], &fd);

    napi_value result;
    napi_create_object(env, &result);
    auto setNum = [&](const char *name, double value) {
        napi_value v;
        napi_create_double(env, value, &v);
        napi_set_named_property(env, result, name, v);
    };
    auto setStr = [&](const char *name, const std::string &value) {
        napi_value v;
        napi_create_string_utf8(env, value.c_str(), value.size(), &v);
        napi_set_named_property(env, result, name, v);
    };

    char path[64];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    char target[256] = {0};
    ssize_t len = readlink(path, target, sizeof(target) - 1);
    setStr("target", len > 0 ? std::string(target, static_cast<size_t>(len)) : std::string("?"));

    struct stat st {};
    if (fstat(fd, &st) == 0) {
        setNum("mode", st.st_mode);
        setNum("isSocket", S_ISSOCK(st.st_mode) ? 1 : 0);
        setNum("isChar", S_ISCHR(st.st_mode) ? 1 : 0);
        setNum("isFifo", S_ISFIFO(st.st_mode) ? 1 : 0);
        setNum("size", static_cast<double>(st.st_size));
    } else {
        setNum("mode", -errno);
    }

    int soType = -1;
    socklen_t soLen = sizeof(soType);
    setNum("soType", getsockopt(fd, SOL_SOCKET, SO_TYPE, &soType, &soLen) == 0 ? soType : -errno);
    int flags = fcntl(fd, F_GETFL, 0);
    setNum("flags", flags < 0 ? -errno : flags);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"probeDecode", nullptr, ProbeDecode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"fdWrite", nullptr, FdWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"fdRead", nullptr, FdRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"fdInfo", nullptr, FdInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module probeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "mirage_probe",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterProbeModule(void) {
    napi_module_register(&probeModule);
}