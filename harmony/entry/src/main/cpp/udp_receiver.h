#ifndef MIRAGE_UDP_RECEIVER_H
#define MIRAGE_UDP_RECEIVER_H

#include <atomic>
#include <memory>
#include <netinet/in.h>
#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <thread>
#include <vector>

// AES-256-GCM 解密，参数与 Mac 端 UdpCrypto.swift 对齐：
// nonce = noncePrefix(4) + seq(u64 BE)，AAD = 16 字节头，密文尾部 16B 为 tag。
class GcmDecryptor {
public:
    ~GcmDecryptor();

    bool Init(const std::vector<uint8_t> &key);

    bool Open(const uint8_t *nonce, size_t nonceLen, const uint8_t *aad, size_t aadLen,
              const uint8_t *cipher, size_t cipherLen, const uint8_t *tag, size_t tagLen,
              std::vector<uint8_t> &out);

private:
    void *gen_ = nullptr;
    void *key_ = nullptr;
    void *ctx_ = nullptr;
};

// UDP 视频接收：负责 HELLO 握手、AES-256-GCM 解密、按帧重组和 NACK 重传，
// 只把「完整帧 / 就绪 / 失败」交给上层。
class UdpReceiver {
public:
    struct Frame {
        uint32_t frameId = 0;
        bool keyFrame = false;
        uint64_t captureTsMicros = 0;
        std::vector<uint8_t> data;
    };
    using FrameSink = std::function<void(Frame &&)>;
    using EventSink = std::function<void(const std::string &kind, const std::string &reason)>;

    UdpReceiver() = default;
    ~UdpReceiver();

    bool Start(const std::string &host, uint16_t port, const std::vector<uint8_t> &key,
               const std::vector<uint8_t> &noncePrefix, FrameSink onFrame, EventSink onEvent);
    void Stop();

private:
    struct PendingFrame {
        uint16_t fragCount = 0;
        bool keyFrame = false;
        uint64_t captureTsMicros = 0;
        std::vector<std::vector<uint8_t>> frags;
        std::vector<bool> got;
        uint16_t received = 0;
        bool eof = false;
        int64_t firstSeenMs = 0;
        int nacks = 0;
    };

    void Loop();
    bool SendHello();
    bool SendNack(uint32_t frameId, const PendingFrame &pending);
    void HandleDatagram(const uint8_t *data, size_t length);
    void DeliverReadyFrames();
    void TickPending(int64_t nowMs);

    int fd_ = -1;
    struct sockaddr_in peer_ {};
    std::vector<uint8_t> key_;
    std::vector<uint8_t> noncePrefix_;
    FrameSink onFrame_;
    EventSink onEvent_;
    std::thread thread_;
    std::unique_ptr<GcmDecryptor> crypto_;
    std::atomic<bool> running_{false};
    bool connected_ = false;
    bool sawVideo_ = false;
    bool loggedFirstPacket_ = false;
    bool needKeyframe_ = false;
    uint32_t nextSeq_ = 1;
    int helloTries_ = 0;
    int64_t lastHelloMs_ = 0;
    int64_t lastPacketMs_ = 0;
    int64_t startMs_ = 0;
    uint32_t lastDelivered_ = 0;
    std::map<uint32_t, PendingFrame> pending_;
    int64_t lastStatsMs_ = 0;
    int datagrams_ = 0;
    int frames_ = 0;
    int nacks_ = 0;
    int decryptFail_ = 0;
};

#endif // MIRAGE_UDP_RECEIVER_H