// Software video decode for streams the phone's own decoders cannot do (e.g. HEVC Main 10).
// FFmpeg's libavcodec only decodes; demuxing, timing, seeking and audio stay in our engine.
// Frames are converted (YUV 4:2:0 8/10-bit -> RGBA, with HDR -> SDR tone mapping) straight into
// the output Surface.
#include <jni.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libavutil/pixfmt.h>
}

#define LOG_TAG "swdecode"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

struct Sw {
    AVCodecContext* ctx = nullptr;
    AVPacket* pkt = nullptr;
    AVFrame* frame = nullptr;
    bool have = false;
    ANativeWindow* win = nullptr;
    int winW = 0, winH = 0;
    int threads = 4;
    uint8_t lut[1024];
    int lutTrc = -1;
};

struct Conv {
    int yoff, ky, kr, kgu, kgv, kbu;
};

Conv makeConv(bool bt2020, bool full) {
    const double kr = bt2020 ? 1.4746 : 1.5748;
    const double kgu = bt2020 ? 0.16455 : 0.1873;
    const double kgv = bt2020 ? 0.57135 : 0.4681;
    const double kbu = bt2020 ? 1.8814 : 1.8556;
    // Work on a 0..1023 scale. Limited range: Y 64..940, C 64..960 (+-448 around 512).
    const double ys = full ? 1.0 : 1023.0 / 876.0;
    const double cs = full ? 1.0 : 1023.0 / 896.0;
    Conv c;
    c.yoff = full ? 0 : 64;
    c.ky = (int)std::lround(ys * 65536.0);
    c.kr = (int)std::lround(kr * cs * 65536.0);
    c.kgu = (int)std::lround(kgu * cs * 65536.0);
    c.kgv = (int)std::lround(kgv * cs * 65536.0);
    c.kbu = (int)std::lround(kbu * cs * 65536.0);
    return c;
}

// Encoded value (0..1023) -> 8-bit SDR output value.
//  HLG is designed to look right on SDR screens, so it passes through.
//  PQ (HDR10) is tone-mapped: nits -> extended Reinhard around 203 nit reference white -> sRGB.
void buildLut(Sw* s, int trc) {
    for (int i = 0; i < 1024; i++) {
        double v = i / 1023.0;
        double out = v;
        if (trc == AVCOL_TRC_SMPTE2084) {
            const double m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
            double p = std::pow(v, 1.0 / m2);
            double num = std::max(p - c1, 0.0);
            double den = c2 - c3 * p;
            double nits = std::pow(num / den, 1.0 / m1) * 10000.0;
            double x = nits / 203.0;
            double w = 1000.0 / 203.0;
            double t = x * (1.0 + x / (w * w)) / (1.0 + x);
            t = std::min(std::max(t, 0.0), 1.0);
            out = t <= 0.0031308 ? 12.92 * t : 1.055 * std::pow(t, 1.0 / 2.4) - 0.055;
        }
        s->lut[i] = (uint8_t)std::lround(std::min(1.0, std::max(0.0, out)) * 255.0);
    }
    s->lutTrc = trc;
}

inline int clamp10(int v) { return v < 0 ? 0 : (v > 1023 ? 1023 : v); }

void convertRows(const AVFrame* f, uint8_t* dst, int dstStride, int y0, int y1, const Conv& c,
                 const uint8_t* lut, bool hi) {
    const int w = f->width;
    for (int y = y0; y < y1; y++) {
        const uint8_t* yp = f->data[0] + (size_t)y * f->linesize[0];
        const uint8_t* cbp = f->data[1] + (size_t)(y >> 1) * f->linesize[1];
        const uint8_t* crp = f->data[2] + (size_t)(y >> 1) * f->linesize[2];
        uint8_t* o = dst + (size_t)y * dstStride;
        for (int x = 0; x < w; x++) {
            int Y, Cb, Cr;
            if (hi) {
                Y = ((const uint16_t*)yp)[x];
                Cb = ((const uint16_t*)cbp)[x >> 1];
                Cr = ((const uint16_t*)crp)[x >> 1];
            } else {
                Y = yp[x] << 2;
                Cb = cbp[x >> 1] << 2;
                Cr = crp[x >> 1] << 2;
            }
            int yv = ((Y - c.yoff) * c.ky) >> 16;
            int u = Cb - 512, v = Cr - 512;
            int r = clamp10(yv + ((v * c.kr) >> 16));
            int g = clamp10(yv - ((u * c.kgu + v * c.kgv) >> 16));
            int b = clamp10(yv + ((u * c.kbu) >> 16));
            o[0] = lut[r];
            o[1] = lut[g];
            o[2] = lut[b];
            o[3] = 255;
            o += 4;
        }
    }
}

Sw* S(jlong h) { return reinterpret_cast<Sw*>(h); }

void freeAll(Sw* s) {
    if (!s) return;
    if (s->win) ANativeWindow_release(s->win);
    if (s->frame) av_frame_free(&s->frame);
    if (s->pkt) av_packet_free(&s->pkt);
    if (s->ctx) avcodec_free_context(&s->ctx);
    delete s;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL Java_com_example_hdr_1player_SwNative_nCreate(JNIEnv* env, jclass, jbyteArray csd, jint threads) {
    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    if (!codec) { LOGE("no hevc decoder"); return 0; }
    Sw* s = new Sw();
    s->threads = std::max(1, std::min((int)threads, 8));
    s->ctx = avcodec_alloc_context3(codec);
    jsize n = csd ? env->GetArrayLength(csd) : 0;
    if (n > 0) {
        s->ctx->extradata = (uint8_t*)av_mallocz(n + AV_INPUT_BUFFER_PADDING_SIZE);
        env->GetByteArrayRegion(csd, 0, n, (jbyte*)s->ctx->extradata);
        s->ctx->extradata_size = n;
    }
    s->ctx->thread_count = s->threads;
    s->ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    s->ctx->flags2 |= AV_CODEC_FLAG2_FAST;
    s->ctx->pkt_timebase = AVRational{1, 1000000};
    if (avcodec_open2(s->ctx, codec, nullptr) < 0) { LOGE("avcodec_open2 failed"); freeAll(s); return 0; }
    s->pkt = av_packet_alloc();
    s->frame = av_frame_alloc();
    return (jlong)s;
}

JNIEXPORT void JNICALL Java_com_example_hdr_1player_SwNative_nSetSurface(JNIEnv* env, jclass, jlong h, jobject surface) {
    Sw* s = S(h);
    if (!s) return;
    if (s->win) { ANativeWindow_release(s->win); s->win = nullptr; }
    s->win = ANativeWindow_fromSurface(env, surface);
    s->winW = s->winH = 0;
}

JNIEXPORT jint JNICALL Java_com_example_hdr_1player_SwNative_nSend(JNIEnv* env, jclass, jlong h, jobject buf, jint size, jlong ptsUs) {
    Sw* s = S(h);
    uint8_t* p = (uint8_t*)env->GetDirectBufferAddress(buf);
    if (!s || !p) return -1000;
    s->pkt->data = p;
    s->pkt->size = size;
    s->pkt->pts = ptsUs;
    s->pkt->dts = ptsUs;
    int r = avcodec_send_packet(s->ctx, s->pkt);  // copies the data (no refcounted buffer)
    s->pkt->data = nullptr;
    s->pkt->size = 0;
    return r;
}

JNIEXPORT jint JNICALL Java_com_example_hdr_1player_SwNative_nSendEos(JNIEnv*, jclass, jlong h) {
    Sw* s = S(h);
    return s ? avcodec_send_packet(s->ctx, nullptr) : -1;
}

// Returns the pts (us) of the next decoded frame, or Long.MIN_VALUE (need input),
// +1 (end of stream), +2 (error).
JNIEXPORT jlong JNICALL Java_com_example_hdr_1player_SwNative_nReceive(JNIEnv*, jclass, jlong h) {
    Sw* s = S(h);
    if (!s) return INT64_MIN + 2;
    if (!s->have) {
        int r = avcodec_receive_frame(s->ctx, s->frame);
        if (r == 0) s->have = true;
        else if (r == AVERROR(EAGAIN)) return INT64_MIN;
        else if (r == AVERROR_EOF) return INT64_MIN + 1;
        else return INT64_MIN + 2;
    }
    int64_t pts = s->frame->pts;
    if (pts == AV_NOPTS_VALUE) pts = s->frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) pts = 0;
    return pts;
}

JNIEXPORT jint JNICALL Java_com_example_hdr_1player_SwNative_nPresent(JNIEnv*, jclass, jlong h) {
    Sw* s = S(h);
    if (!s || !s->have || !s->win) return -1;
    AVFrame* f = s->frame;
    const bool hi = f->format == AV_PIX_FMT_YUV420P10LE;
    if (!hi && f->format != AV_PIX_FMT_YUV420P) {
        av_frame_unref(f); s->have = false;
        return -2;  // unsupported pixel format
    }
    if (s->winW != f->width || s->winH != f->height) {
        ANativeWindow_setBuffersGeometry(s->win, f->width, f->height, WINDOW_FORMAT_RGBA_8888);
        s->winW = f->width; s->winH = f->height;
    }
    if (s->lutTrc != (int)f->color_trc) buildLut(s, (int)f->color_trc);
    const bool bt2020 = f->colorspace == AVCOL_SPC_BT2020_NCL || f->colorspace == AVCOL_SPC_BT2020_CL ||
                        f->color_primaries == AVCOL_PRI_BT2020;
    Conv c = makeConv(bt2020, f->color_range == AVCOL_RANGE_JPEG);

    ANativeWindow_Buffer b;
    if (ANativeWindow_lock(s->win, &b, nullptr) != 0) {
        av_frame_unref(f); s->have = false;
        return -3;
    }
    const int h2 = std::min(f->height, b.height);
    const int stride = b.stride * 4;
    const int n = std::max(1, std::min(s->threads, h2 / 64));
    std::vector<std::thread> pool;
    for (int i = 1; i < n; i++) {
        int y0 = h2 * i / n, y1 = h2 * (i + 1) / n;
        pool.emplace_back(convertRows, f, (uint8_t*)b.bits, stride, y0, y1, c, s->lut, hi);
    }
    convertRows(f, (uint8_t*)b.bits, stride, 0, h2 / n, c, s->lut, hi);
    for (auto& t : pool) t.join();
    ANativeWindow_unlockAndPost(s->win);
    av_frame_unref(f);
    s->have = false;
    return 0;
}

JNIEXPORT void JNICALL Java_com_example_hdr_1player_SwNative_nDrop(JNIEnv*, jclass, jlong h) {
    Sw* s = S(h);
    if (!s) return;
    av_frame_unref(s->frame);
    s->have = false;
}

JNIEXPORT void JNICALL Java_com_example_hdr_1player_SwNative_nFlush(JNIEnv*, jclass, jlong h) {
    Sw* s = S(h);
    if (!s) return;
    avcodec_flush_buffers(s->ctx);
    av_frame_unref(s->frame);
    s->have = false;
}

// 0 = decode everything, 1 = skip non-reference frames, 2 = key frames only
JNIEXPORT void JNICALL Java_com_example_hdr_1player_SwNative_nSetSkip(JNIEnv*, jclass, jlong h, jint mode) {
    Sw* s = S(h);
    if (!s) return;
    s->ctx->skip_frame = mode == 1 ? AVDISCARD_NONREF : (mode == 2 ? AVDISCARD_NONKEY : AVDISCARD_DEFAULT);
}

JNIEXPORT void JNICALL Java_com_example_hdr_1player_SwNative_nRelease(JNIEnv*, jclass, jlong h) {
    freeAll(S(h));
}

}  // extern "C"
