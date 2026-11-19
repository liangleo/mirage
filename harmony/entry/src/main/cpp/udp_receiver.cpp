#include "udp_receiver.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstring>
#include <cerrno>

#include "CryptoArchitectureKit/crypto_common.h"
#include "CryptoArchitectureKit/crypto_sym_cipher.h"
#include "CryptoArchitectureKit/crypto_sym_key.h"
#include <hilog/log.h>

namespace {
constexpr size_t kHeaderSize = 16;
constexpr uint16_t kMaxPayload = 1200 + 16;
constexpr uint8_t kFlagSof = 1 << 0;
constexpr uint8_t kFlagEof = 1 << 1;
constexpr uint8_t kFlagKey = 1 << 2;
constexpr uint8_t kFlagNack = 1 << 3;
constexpr uint8_t kFlagHello = 1 << 4;

int64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

uint16_t Read16(const uint8_t *p) {
    return static_cast<uint16_t>((p[0] << 8) | p[1]);
}

uint32_t Read32(const uint8_t *p) {
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

void Write16(uint8_t *p, uint16_t v) {
    p[0] = static_cast<uint8_t>(v >> 8);
    p[1] = static_cast<uint8_t>(v & 0xff);
}

void Write32(uint8_t *p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v >> 24);
    p[1] = static_cast<uint8_t>((v >> 16) & 0xff);
    p[2] = static_cast<uint8_t>((v >> 8) & 0xff);
    p[3] = static_cast<uint8_t>(v & 0xff);
}

} // namespace

GcmDecryptor::~GcmDecryptor() {
    if (ctx_ != nullptr) {
        OH_CryptoSymCipher_Destroy(static_cast<OH_CryptoSymCipher *>(ctx_));
    }
    if (key_ != nullptr) {
        OH_CryptoSymKey_Destroy(static_cast<OH_CryptoSymKey *>(key_));
    }
    if (gen_ != nullptr) {
        OH_CryptoSymKeyGenerator_Destroy(static_cast<OH_CryptoSymKeyGenerator *>(gen_));
    }
}

bool GcmDecryptor::Init(const std::vector<uint8_t> &key) {
    OH_CryptoSymKeyGenerator *gen = nullptr;
    if (OH_CryptoSymKeyGenerator_Create("AES256", &gen) != CRYPTO_SUCCESS) {
        return false;
    }
    Crypto_DataBlob keyData{const_cast<uint8_t *>(key.data()), key.size()};
    OH_CryptoSymKey *keyCtx = nullptr;
    if (OH_CryptoSymKeyGenerator_Convert(gen, &keyData, &keyCtx) != CRYPTO_SUCCESS) {
        OH_CryptoSymKeyGenerator_Destroy(gen);
        return false;
    }
    OH_CryptoSymCipher *ctx = nullptr;
    if (OH_CryptoSymCipher_Create("AES256|GCM", &ctx) != CRYPTO_SUCCESS) {
        OH_CryptoSymKey_Destroy(keyCtx);
        OH_CryptoSymKeyGenerator_Destroy(gen);
        return false;
    }
    gen_ = gen;
    key_ = keyCtx;
    ctx_ = ctx;
    return true;
}

bool GcmDecryptor::Open(const uint8_t *nonce, size_t nonceLen, const uint8_t *aad, size_t aadLen,
                        const uint8_t *cipher, size_t cipherLen, const uint8_t *tag, size_t tagLen,
                        std::vector<uint8_t> &out) {
    auto ctx = static_cast<OH_CryptoSymCipher *>(ctx_);
    auto keyCtx = static_cast<OH_CryptoSymKey *>(key_);
    OH_CryptoSymCipherParams *params = nullptr;
    if (OH_CryptoSymCipherParams_Create(&params) != CRYPTO_SUCCESS) {
        return false;
    }
    Crypto_DataBlob iv{const_cast<uint8_t *>(nonce), nonceLen};
    Crypto_DataBlob aadBlob{const_cast<uint8_t *>(aad), aadLen};
    Crypto_DataBlob tagBlob{const_cast<uint8_t *>(tag), tagLen};
    bool ok = OH_CryptoSymCipherParams_SetParam(params, CRYPTO_IV_DATABLOB, &iv) == CRYPTO_SUCCESS &&
              OH_CryptoSymCipherParams_SetParam(params, CRYPTO_AAD_DATABLOB, &aadBlob) == CRYPTO_SUCCESS &&
              OH_CryptoSymCipherParams_SetParam(params, CRYPTO_TAG_DATABLOB, &tagBlob) == CRYPTO_SUCCESS;
    if (ok) {
        ok = OH_CryptoSymCipher_Init(ctx, CRYPTO_DECRYPT_MODE, keyCtx, params) == CRYPTO_SUCCESS;
    }
    if (ok) {
        Crypto_DataBlob in{const_cast<uint8_t *>(cipher), cipherLen};
        Crypto_DataBlob plain{nullptr, 0};
        ok = OH_CryptoSymCipher_Update(ctx, &in, &plain) == CRYPTO_SUCCESS;
        if (ok) {
            Crypto_DataBlob finalOut{nullptr, 0};
            ok = OH_CryptoSymCipher_Final(ctx, nullptr, &finalOut) == CRYPTO_SUCCESS;
            if (ok) {
                if (plain.data != nullptr) {
                    out.assign(plain.data, plain.data + plain.len);
                }
                if (finalOut.data != nullptr) {
                    out.insert(out.end(), finalOut.data, finalOut.data + finalOut.len);
                }
            }
            if (finalOut.data != nullptr) {
                OH_Crypto_FreeDataBlob(&finalOut);
            }
        }
        if (plain.data != nullptr) {
            OH_Crypto_FreeDataBlob(&plain);
        }
    }
    OH_CryptoSymCipherParams_Destroy(params);
    return ok;
}

UdpReceiver::~UdpReceiver() {
    Stop();
}

bool UdpReceiver::Start(const std::string &host, uint16_t port, const std::vector<uint8_t> &key,
                        const std::vector<uint8_t> &noncePrefix, FrameSink onFrame,
                        EventSink onEvent) {
    Stop();
    if (key.size() != 32 || noncePrefix.size() != 4) {
        return false;
    }
    fd_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) {
        return false;
    }
    // 11Mbps 以上的突发会把默认 200KB 收包缓冲打满，丢片后只能靠 NACK 补
    int rcvbuf = 4 * 1024 * 1024;
    setsockopt(fd_, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    peer_ = sockaddr_in{};
    peer_.sin_family = AF_INET;
    peer_.sin_port = htons(port);
    if (inet_pton(AF_INET, host.c_str(), &peer_.sin_addr) != 1) {
        close(fd_);
        fd_ = -1;
        return false;
    }
    crypto_ = std::make_unique<GcmDecryptor>();
    if (!crypto_->Init(key)) {
        close(fd_);
        fd_ = -1;
        return false;
    }
    key_ = key;
    noncePrefix_ = noncePrefix;
    onFrame_ = std::move(onFrame);
    onEvent_ = std::move(onEvent);
    connected_ = false;
    sawVideo_ = false;
    loggedFirstPacket_ = false;
    nextSeq_ = 1;
    helloTries_ = 0;
    lastHelloMs_ = 0;
    lastPacketMs_ = 0;
    startMs_ = NowMs();
    lastDelivered_ = 0;
    pending_.clear();
    running_ = true;
    thread_ = std::thread(&UdpReceiver::Loop, this);
    return true;
}

void UdpReceiver::Stop() {
    running_ = false;
    if (thread_.joinable()) {
        thread_.join();
    }
    if (fd_ >= 0) {
        close(fd_);
        fd_ = -1;
    }
}

bool UdpReceiver::SendHello() {
    uint8_t datagram[kHeaderSize] = {0};
    Write32(datagram, nextSeq_++);
    Write32(datagram + 4, 0);
    Write16(datagram + 8, 0);
    Write16(datagram + 10, 1);
    datagram[12] = kFlagHello;
    Write16(datagram + 14, 0);
    const ssize_t sent = sendto(fd_, datagram, sizeof(datagram), 0,
                                reinterpret_cast<sockaddr *>(&peer_), sizeof(peer_));
    if (sent != static_cast<ssize_t>(sizeof(datagram))) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0x0200, "MirageUdp", "hello send failed errno=%{public}d", errno);
        return false;
    }
    return true;
}

bool UdpReceiver::SendNack(uint32_t frameId, const PendingFrame &pending) {
    if (pending.fragCount == 0) {
        return false;
    }
    std::vector<uint8_t> bitmap((pending.fragCount + 7) / 8, 0);
    for (uint16_t i = 0; i < pending.fragCount; i++) {
        if (!pending.got[i]) {
            bitmap[i / 8] = static_cast<uint8_t>(bitmap[i / 8] | (1u << (i % 8)));
        }
    }
    std::vector<uint8_t> datagram(kHeaderSize + bitmap.size());
    Write32(datagram.data(), nextSeq_++);
    Write32(datagram.data() + 4, frameId);
    Write16(datagram.data() + 8, 0);
    Write16(datagram.data() + 10, static_cast<uint16_t>(bitmap.size()));
    datagram[12] = kFlagNack;
    datagram[13] = 0;
    Write16(datagram.data() + 14, static_cast<uint16_t>(bitmap.size()));
    std::memcpy(datagram.data() + kHeaderSize, bitmap.data(), bitmap.size());
    const ssize_t sent = sendto(fd_, datagram.data(), datagram.size(), 0,
                                reinterpret_cast<sockaddr *>(&peer_), sizeof(peer_));
    return sent == static_cast<ssize_t>(datagram.size());
}

void UdpReceiver::HandleDatagram(const uint8_t *data, size_t length) {
    if (length < kHeaderSize) {
        return;
    }
    const uint32_t seq = Read32(data);
    const uint32_t frameId = Read32(data + 4);
    const uint16_t fragIndex = Read16(data + 8);
    const uint16_t fragCount = Read16(data + 10);
    const uint8_t flags = data[12];
    const uint16_t payloadLength = Read16(data + 14);
    if (payloadLength > kMaxPayload || length != kHeaderSize + payloadLength) {
        return;
    }
    if ((flags & kFlagHello) != 0) {
        if (!connected_) {
            connected_ = true;
            onEvent_("udpReady", "");
        }
        return;
    }
    if ((flags & kFlagNack) != 0 || fragCount == 0 || fragIndex >= fragCount || payloadLength < 16) {
        return;
    }

    const uint8_t *payload = data + kHeaderSize;
    const size_t cipherLen = payloadLength - 16;
    const uint8_t *tag = payload + cipherLen;
    uint8_t nonce[12] = {0};
    std::memcpy(nonce, noncePrefix_.data(), 4);
    for (int i = 0; i < 8; i++) {
        nonce[4 + i] = static_cast<uint8_t>((static_cast<uint64_t>(seq) >> (56 - i * 8)) & 0xff);
    }
    std::vector<uint8_t> plain;
    if (!crypto_->Open(nonce, sizeof(nonce), data, kHeaderSize, payload, cipherLen, tag, 16, plain)) {
        decryptFail_++;
        return;
    }

    if (!connected_) {
        connected_ = true;
        onEvent_("udpReady", "");
    }
    sawVideo_ = true;

    if (frameId <= lastDelivered_) {
        return;
    }
    auto it = pending_.find(frameId);
    if (it == pending_.end()) {
        PendingFrame fresh;
        fresh.fragCount = fragCount;
        fresh.frags.resize(fragCount);
        fresh.got.assign(fragCount, false);
        fresh.firstSeenMs = NowMs();
        it = pending_.emplace(frameId, std::move(fresh)).first;
    }
    PendingFrame &pending = it->second;
    if (pending.fragCount != fragCount) {
        return;
    }
    if (fragIndex == 0) {
        pending.keyFrame = (flags & kFlagKey) != 0;
    }
    if ((flags & kFlagEof) != 0) {
        pending.eof = true;
    }
    if (!pending.got[fragIndex]) {
        pending.got[fragIndex] = true;
        pending.frags[fragIndex] = std::move(plain);
        pending.received++;
    }
}

void UdpReceiver::DeliverReadyFrames() {
    while (true) {
        // 严格按 frameID 顺序交付：跳过缺片的旧帧会让解码器永远拿不到 IDR。
        uint32_t smallest = 0;
        bool found = false;
        for (const auto &entry : pending_) {
            if (entry.first <= lastDelivered_) {
                continue;
            }
            if (!found || entry.first < smallest) {
                smallest = entry.first;
                found = true;
            }
        }
        if (!found) {
            break;
        }
        PendingFrame &pending = pending_[smallest];
        if (pending.received < pending.fragCount) {
            // 还在等 NACK 补齐；超过 200ms 仍缺片就放弃这帧并请求新的关键帧。
            if (NowMs() - pending.firstSeenMs < 200) {
                break;
            }
            lastDelivered_ = smallest;
            pending_.erase(smallest);
            needKeyframe_ = true;
            continue;
        }
        uint32_t bestId = smallest;
        Frame frame;
        frame.frameId = bestId;
        frame.keyFrame = pending.keyFrame;
        size_t total = 0;
        for (const auto &frag : pending.frags) {
            total += frag.size();
        }
        frame.data.reserve(total);
        for (auto &frag : pending.frags) {
            frame.data.insert(frame.data.end(), frag.begin(), frag.end());
        }
        lastDelivered_ = bestId;
        pending_.erase(bestId);
        frames_++;
        onFrame_(std::move(frame));
    }
    for (auto it = pending_.begin(); it != pending_.end();) {
        if (it->first <= lastDelivered_) {
            it = pending_.erase(it);
        } else {
            ++it;
        }
    }
}

void UdpReceiver::TickPending(int64_t nowMs) {
    bool hasNewer = false;
    uint32_t newest = 0;
    for (const auto &entry : pending_) {
        if (entry.first > newest) {
            newest = entry.first;
        }
    }
    hasNewer = newest > 0;
    for (auto &entry : pending_) {
        PendingFrame &pending = entry.second;
        if (pending.received >= pending.fragCount || pending.nacks >= 2) {
            continue;
        }
        const bool gap = pending.eof || (hasNewer && entry.first < newest);
        if (!gap || nowMs - pending.firstSeenMs < 6) {
            continue;
        }
        if (SendNack(entry.first, pending)) {
            pending.nacks++;
            nacks_++;
        }
    }
}

void UdpReceiver::Loop() {
    uint8_t buffer[2048];
    while (running_) {
        const int64_t now = NowMs();
        // 看到第一个视频数据报之前一直重发 HELLO：TLS 重连会复位服务端的
        // udpPeerReady，只发一次 hello 会让两边互相等，直到超时回退。
        if (!sawVideo_) {
            if (helloTries_ < 20 && now - lastHelloMs_ >= 500) {
                SendHello();
                lastHelloMs_ = now;
                helloTries_++;
            }
            if (now - startMs_ >= 30000) {
                onEvent_("udpFailed", "no udp video");
                break;
            }
        } else if (now - lastPacketMs_ >= 10000) {
            onEvent_("udpFailed", "udp timeout");
            break;
        }

        pollfd pfd{fd_, POLLIN, 0};
        const int ready = poll(&pfd, 1, 20);
        if (ready > 0 && (pfd.revents & POLLIN) != 0) {
            sockaddr_in from{};
            socklen_t fromLen = sizeof(from);
            const ssize_t count = recvfrom(fd_, buffer, sizeof(buffer), 0,
                                           reinterpret_cast<sockaddr *>(&from), &fromLen);
            if (count > 0) {
                lastPacketMs_ = NowMs();
                datagrams_++;
                if (!loggedFirstPacket_) {
                    loggedFirstPacket_ = true;
                    char ip[32] = {0};
                    inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
                    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0200, "MirageUdp",
                        "first datagram from %{public}s:%{public}d", ip, ntohs(from.sin_port));
                }
                HandleDatagram(buffer, static_cast<size_t>(count));
            }
        }
        TickPending(NowMs());
        DeliverReadyFrames();
        if (needKeyframe_) {
            needKeyframe_ = false;
            onEvent_("udpKeyframe", "");
        }
        if (now - lastStatsMs_ >= 2000) {
            lastStatsMs_ = now;
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0200, "MirageUdp",
                "datagrams=%{public}d frames=%{public}d nacks=%{public}d decryptFail=%{public}d pending=%{public}d",
                datagrams_, frames_, nacks_, decryptFail_, static_cast<int>(pending_.size()));
            datagrams_ = 0;
            frames_ = 0;
            nacks_ = 0;
            decryptFail_ = 0;
        }
    }
    running_ = false;
}