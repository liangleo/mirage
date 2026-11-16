#include "video_decoder.h"

#include <chrono>
#include <cstring>
#include <hilog/log.h>

namespace {
constexpr int32_t kMaxQueuedFrames = 4;
constexpr const char *kLogTag = "MirageNative";

int64_t NowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
}  // namespace

VideoDecoder::~VideoDecoder() {
    Close();
}

bool VideoDecoder::Open(int32_t width, int32_t height, int32_t fps, uint64_t surfaceId, Emitter emit) {
    Close();
    emit_ = std::move(emit);
    width_ = width;
    height_ = height;
    fps_ = fps > 0 ? fps : 60;
    surfaceId_ = surfaceId;
    error_ = false;

    if (surfaceId == 0) {
        Emit(DecoderEvent{.kind = "decoderError", .reason = "surface 不可用"});
        return false;
    }
    int32_t ret = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window_);
    if (ret != 0 || window_ == nullptr) {
        window_ = nullptr;
        OH_LOG_ERROR(LOG_APP, "MirageNative create window failed %{public}d", ret);
        Emit(DecoderEvent{.kind = "decoderError", .reason = "创建原生窗口失败 " + std::to_string(ret)});
        return false;
    }
    codec_ = OH_VideoDecoder_CreateByMime("video/avc");
    if (codec_ == nullptr) {
        ReleaseWindow();
        Emit(DecoderEvent{.kind = "decoderError", .reason = "创建解码器失败"});
        return false;
    }

    OH_AVCodecCallback callback{OnError, OnStreamChanged, OnNeedInput, OnNewOutput};
    if (OH_VideoDecoder_RegisterCallback(codec_, callback, this) != AV_ERR_OK) {
        Close();
        Emit(DecoderEvent{.kind = "decoderError", .reason = "注册回调失败"});
        return false;
    }

    OH_AVFormat *format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width_);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height_);
    OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, static_cast<double>(fps_));
    OH_AVErrCode configure = OH_VideoDecoder_Configure(codec_, format);
    OH_AVFormat_Destroy(format);
    if (configure != AV_ERR_OK) {
        Close();
        Emit(DecoderEvent{.kind = "decoderError", .reason = "配置解码器失败 " + std::to_string(configure)});
        return false;
    }
    OH_AVErrCode surface = OH_VideoDecoder_SetSurface(codec_, window_);
    if (surface != AV_ERR_OK) {
        Close();
        Emit(DecoderEvent{.kind = "decoderError", .reason = "绑定 surface 失败 " + std::to_string(surface)});
        return false;
    }
    if (OH_VideoDecoder_Prepare(codec_) != AV_ERR_OK) {
        Close();
        Emit(DecoderEvent{.kind = "decoderError", .reason = "准备解码器失败"});
        return false;
    }
    OH_AVErrCode start = OH_VideoDecoder_Start(codec_);
    if (start != AV_ERR_OK) {
        Close();
        Emit(DecoderEvent{.kind = "decoderError", .reason = "启动解码器失败 " + std::to_string(start)});
        return false;
    }
    OH_LOG_INFO(LOG_APP, "MirageNative decoder opened %{public}dx%{public}d surface=%{public}llu",
        width_, height_, static_cast<unsigned long long>(surfaceId));
    return true;
}

bool VideoDecoder::SetSurface(uint64_t surfaceId) {
    if (surfaceId == 0) {
        return false;
    }
    if (surfaceId == surfaceId_) {
        return codec_ != nullptr;
    }
    const auto emit = emit_;
    const int32_t width = width_;
    const int32_t height = height_;
    const int32_t fps = fps_;
    Close();
    return Open(width, height, fps, surfaceId, emit);
}

int32_t VideoDecoder::Submit(std::vector<uint8_t> &&data, int32_t flags, int64_t frameId,
    int64_t captureTsMicros) {
    if (codec_ == nullptr) {
        return -1;
    }
    bool dropped = false;
    {
        std::lock_guard<std::mutex> guard(lock_);
        if (queue_.size() >= static_cast<size_t>(kMaxQueuedFrames)) {
            queue_.pop_front();
            dropped = true;
        }
        queue_.push_back(Frame{.data = std::move(data), .flags = flags, .frameId = frameId,
            .captureTsMicros = captureTsMicros, .submitNs = NowNs()});
    }
    if (dropped) {
        Emit(DecoderEvent{.kind = "dropped", .frameId = frameId, .bytes = 0});
    }
    Pump();
    return dropped ? 1 : 0;
}

void VideoDecoder::Close() {
    if (codec_ != nullptr) {
        OH_VideoDecoder_Stop(codec_);
        OH_VideoDecoder_Destroy(codec_);
        codec_ = nullptr;
    }
    ReleaseWindow();
    {
        std::lock_guard<std::mutex> guard(lock_);
        queue_.clear();
        pending_.clear();
        outputMeta_.clear();
    }
    surfaceId_ = 0;
}

void VideoDecoder::ReleaseWindow() {
    if (window_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(window_);
        window_ = nullptr;
    }
}

void VideoDecoder::OnError(OH_AVCodec *, int32_t code, void *userData) {
    auto *self = static_cast<VideoDecoder *>(userData);
    if (self == nullptr) {
        return;
    }
    {
        std::lock_guard<std::mutex> guard(self->lock_);
        self->error_ = true;
    }
    self->Emit(DecoderEvent{.kind = "decoderError", .reason = "解码错误 " + std::to_string(code)});
}

void VideoDecoder::OnStreamChanged(OH_AVCodec *, OH_AVFormat *, void *) {
}

void VideoDecoder::OnNeedInput(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    auto *self = static_cast<VideoDecoder *>(userData);
    if (self == nullptr) {
        return;
    }
    self->HandleInput(index, buffer);
}

void VideoDecoder::HandleInput(uint32_t index, OH_AVBuffer *buffer) {
    Frame frame;
    {
        std::lock_guard<std::mutex> guard(lock_);
        if (error_ || codec_ == nullptr) {
            return;
        }
        if (queue_.empty()) {
            pending_.push_back(PendingInput{.index = index, .buffer = buffer});
            return;
        }
        frame = std::move(queue_.front());
        queue_.pop_front();
    }
    PushFrame(index, buffer, frame);
}

bool VideoDecoder::PushFrame(uint32_t index, OH_AVBuffer *buffer, Frame &frame) {
    uint8_t *dst = OH_AVBuffer_GetAddr(buffer);
    int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
    if (dst == nullptr || capacity < static_cast<int32_t>(frame.data.size())) {
        Emit(DecoderEvent{.kind = "decoderError", .reason = "输入缓冲不足"});
        return false;
    }
    std::memcpy(dst, frame.data.data(), frame.data.size());
    OH_AVCodecBufferAttr attr{};
    attr.pts = frame.captureTsMicros;
    attr.size = static_cast<int32_t>(frame.data.size());
    attr.offset = 0;
    attr.flags = (frame.flags & 1) != 0 ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
    OH_AVBuffer_SetBufferAttr(buffer, &attr);
    {
        std::lock_guard<std::mutex> guard(lock_);
        outputMeta_.push_back(OutputMeta{.frameId = frame.frameId,
            .bytes = static_cast<int32_t>(frame.data.size()), .flags = frame.flags,
            .captureTsMicros = frame.captureTsMicros, .submitNs = frame.submitNs});
        while (outputMeta_.size() > 16) {
            outputMeta_.pop_front();
        }
    }
    if (OH_VideoDecoder_PushInputBuffer(codec_, index) != AV_ERR_OK) {
        Emit(DecoderEvent{.kind = "decoderError", .reason = "提交输入帧失败"});
        return false;
    }
    return true;
}

void VideoDecoder::Pump() {
    while (true) {
        PendingInput pending;
        Frame frame;
        {
            std::lock_guard<std::mutex> guard(lock_);
            if (pending_.empty() || queue_.empty() || codec_ == nullptr) {
                return;
            }
            pending = pending_.front();
            pending_.pop_front();
            frame = std::move(queue_.front());
            queue_.pop_front();
        }
        if (!PushFrame(pending.index, pending.buffer, frame)) {
            return;
        }
    }
}

void VideoDecoder::OnNewOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    auto *self = static_cast<VideoDecoder *>(userData);
    if (self == nullptr) {
        return;
    }
    OH_AVCodecBufferAttr attr{};
    OH_AVBuffer_GetBufferAttr(buffer, &attr);
    if (self->window_ != nullptr) {
        OH_VideoDecoder_RenderOutputBuffer(codec, index);
    } else {
        OH_VideoDecoder_FreeOutputBuffer(codec, index);
    }
    if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
        return;
    }
    OutputMeta meta;
    {
        std::lock_guard<std::mutex> guard(self->lock_);
        if (self->outputMeta_.empty()) {
            meta.frameId = 0;
            meta.bytes = attr.size;
            meta.flags = 0;
            meta.captureTsMicros = attr.pts;
            meta.submitNs = NowNs();
        } else {
            meta = self->outputMeta_.front();
            self->outputMeta_.pop_front();
        }
    }
    DecoderEvent event;
    event.kind = "frame";
    event.frameId = meta.frameId;
    event.bytes = meta.bytes;
    event.flags = meta.flags;
    event.captureTsMicros = meta.captureTsMicros;
    event.decodeMs = static_cast<double>(NowNs() - meta.submitNs) / 1e6;
    self->Emit(event);
}

void VideoDecoder::Emit(const DecoderEvent &event) {
    if (emit_) {
        emit_(event);
    }
}