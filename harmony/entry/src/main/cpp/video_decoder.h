#ifndef MIRAGE_VIDEO_DECODER_H
#define MIRAGE_VIDEO_DECODER_H

#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <native_window/external_window.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

struct DecoderEvent {
    std::string kind;
    int64_t frameId = 0;
    int32_t bytes = 0;
    int32_t flags = 0;
    int64_t captureTsMicros = 0;
    double decodeMs = 0;
    std::string reason;
};

class VideoDecoder {
public:
    using Emitter = std::function<void(const DecoderEvent &)>;

    VideoDecoder() = default;
    ~VideoDecoder();

    bool Open(int32_t width, int32_t height, int32_t fps, uint64_t surfaceId, Emitter emit);
    int32_t Submit(std::vector<uint8_t> &&data, int32_t flags, int64_t frameId, int64_t captureTsMicros);
    void Close();
    // Called when the page asks to tear down, before the codec worker gets to
    // Stop/Destroy: stops consuming frames and stops rendering into a surface
    // that ArkUI may already be tearing down.
    void Suspend();

private:
    struct Frame {
        std::vector<uint8_t> data;
        int32_t flags = 0;
        int64_t frameId = 0;
        int64_t captureTsMicros = 0;
        int64_t submitNs = 0;
    };
    struct PendingInput {
        uint32_t index = 0;
        OH_AVBuffer *buffer = nullptr;
    };
    struct OutputMeta {
        int64_t frameId = 0;
        int32_t bytes = 0;
        int32_t flags = 0;
        int64_t captureTsMicros = 0;
        int64_t submitNs = 0;
    };

    static void OnError(OH_AVCodec *codec, int32_t code, void *userData);
    static void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData);
    static void OnNeedInput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);
    static void OnNewOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);

    void HandleInput(uint32_t index, OH_AVBuffer *buffer);
    bool PushFrame(uint32_t index, OH_AVBuffer *buffer, Frame &frame);
    void Pump();
    void Emit(const DecoderEvent &event);
    void ReleaseWindow();

    OH_AVCodec *codec_ = nullptr;
    OHNativeWindow *window_ = nullptr;
    uint64_t surfaceId_ = 0;
    int32_t width_ = 0;
    int32_t height_ = 0;
    int32_t fps_ = 60;
    Emitter emit_;

    std::atomic<bool> open_{false};
    // Tells the output callback the surface is still valid. Kept separate from
    // codecLock_ on purpose: Close holds that lock across Stop/Destroy, which
    // wait for in-flight callbacks, so a callback taking it would deadlock.
    std::atomic<bool> windowReady_{false};
    // Serializes calls into the codec from non-callback threads: Pump (JS) and
    // Close/Open (codec worker).
    std::mutex codecLock_;
    std::mutex lock_;
    std::deque<Frame> queue_;
    std::deque<PendingInput> pending_;
    std::deque<OutputMeta> outputMeta_;
    bool error_ = false;
    // Progress counters for diagnosing "frames arrive but nothing renders":
    // in_ counts buffers handed to the codec, out_ counts buffers it returned.
    std::atomic<int32_t> inCount_{0};
    std::atomic<int32_t> outCount_{0};
    // submit_ counts frames accepted from JS, need_ counts input requests from
    // the codec: submit without need means the codec stopped asking.
    std::atomic<int32_t> submitCount_{0};
    std::atomic<int32_t> needCount_{0};
};

#endif  // MIRAGE_VIDEO_DECODER_H