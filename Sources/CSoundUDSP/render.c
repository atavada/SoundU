#include "SoundUDSP.h"
#include <Accelerate/Accelerate.h>
#include <stdatomic.h>
#include <string.h>

static float clamp_gain(float gain) {
    if (!(gain >= 0.0f)) return 0.0f; // also catches NaN
    return gain > 2.0f ? 2.0f : gain;
}

void su_mix_init(SUMixState *m, double sampleRate) {
    memset(m, 0, sizeof(*m));
    m->sampleRate = sampleRate;
    for (uint32_t i = 0; i < SU_MAX_SLOTS; i++) {
        SUSlot *s = &m->slots[i];
        atomic_init(&s->targetGain, 1.0f);
        atomic_init(&s->muted, 0);
        atomic_init(&s->active, 0);
        atomic_init(&s->peak, 0.0f);
        su_ramp_init(&s->ramp, 1.0f, sampleRate);
        su_limiter_init(&s->limiter, sampleRate);
    }
}

void su_slot_configure(SUMixState *m, uint32_t slot, uint32_t inputBufferIndex, float gain, int muted) {
    if (slot >= SU_MAX_SLOTS) return;
    SUSlot *s = &m->slots[slot];
    gain = clamp_gain(gain);
    s->inputBuffer = inputBufferIndex;
    su_ramp_init(&s->ramp, muted ? 0.0f : gain, m->sampleRate);
    su_limiter_init(&s->limiter, m->sampleRate);
    atomic_store(&s->targetGain, gain);
    atomic_store(&s->muted, muted ? 1 : 0);
    atomic_store(&s->peak, 0.0f);
    atomic_store(&s->active, 1); // publishes the plain fields above to the render thread
}

void su_slot_set(SUMixState *m, uint32_t slot, float gain, int muted) {
    if (slot >= SU_MAX_SLOTS) return;
    atomic_store(&m->slots[slot].targetGain, clamp_gain(gain));
    atomic_store(&m->slots[slot].muted, muted ? 1 : 0);
}

void su_slot_deactivate(SUMixState *m, uint32_t slot) {
    if (slot >= SU_MAX_SLOTS) return;
    atomic_store(&m->slots[slot].active, 0);
}

float su_slot_take_peak(SUMixState *m, uint32_t slot) {
    if (slot >= SU_MAX_SLOTS) return 0.0f;
    return atomic_exchange(&m->slots[slot].peak, 0.0f);
}

static void record_peak(SUSlot *s, float value) {
    float seen = atomic_load_explicit(&s->peak, memory_order_relaxed);
    while (value > seen &&
           !atomic_compare_exchange_weak_explicit(&s->peak, &seen, value,
                                                  memory_order_relaxed, memory_order_relaxed)) {
    }
}

/// Copies `frames` stereo frames starting at `offset` from the slot's tap buffer;
/// anything missing (short or absent buffer) becomes silence.
static void read_input(const AudioBufferList *in, uint32_t index, uint32_t offset,
                       uint32_t frames, float *dst) {
    uint32_t copied = 0;
    if (in && index < in->mNumberBuffers) {
        const AudioBuffer *b = &in->mBuffers[index];
        uint32_t available = b->mData ? b->mDataByteSize / (uint32_t)(2 * sizeof(float)) : 0;
        if (available > offset) {
            copied = available - offset < frames ? available - offset : frames;
            memcpy(dst, (const float *)b->mData + 2 * offset, copied * 2 * sizeof(float));
        }
    }
    if (copied < frames) {
        memset(dst + 2 * copied, 0, (frames - copied) * 2 * sizeof(float));
    }
}

static void mix_slots(SUMixState *m, const AudioBufferList *in, uint32_t offset, uint32_t frames) {
    const vDSP_Length samples = (vDSP_Length)frames * 2;
    vDSP_vclr(m->mix, 1, samples);
    for (uint32_t i = 0; i < SU_MAX_SLOTS; i++) {
        SUSlot *s = &m->slots[i];
        if (!atomic_load_explicit(&s->active, memory_order_acquire)) continue;

        read_input(in, s->inputBuffer, offset, frames, m->scratch);
        if (atomic_load_explicit(&s->muted, memory_order_relaxed)) {
            s->ramp.current = 0.0f; // unmute fades back in
            s->limiter.envelope = 0.0f;
            continue;
        }

        float target = atomic_load_explicit(&s->targetGain, memory_order_relaxed);
        float startGain = s->ramp.current;
        if (startGain == target && target != 1.0f) {
            vDSP_vsmul(m->scratch, 1, &target, m->scratch, 1, samples);
        } else {
            su_ramp_apply_stereo(&s->ramp, target, m->scratch, frames); // no-op at unity
        }

        if (startGain > 1.0f || s->ramp.current > 1.0f) {
            su_limiter_process_stereo(&s->limiter, m->scratch, frames);
        } else {
            s->limiter.envelope = 0.0f;
        }

        float peak = 0.0f;
        vDSP_maxmgv(m->scratch, 1, &peak, samples);
        record_peak(s, peak);
        vDSP_vadd(m->scratch, 1, m->mix, 1, m->mix, 1, samples);
    }
    const float lo = -1.0f, hi = 1.0f;
    vDSP_vclip(m->mix, 1, &lo, &hi, m->mix, 1, samples);
}

/// Writes mix L/R to global output channels 0/1 and zeroes every other channel,
/// for any mix of interleaved and non-interleaved buffers.
static void write_output(const float *mix, AudioBufferList *out, uint32_t offset, uint32_t frames) {
    uint32_t firstChannel = 0;
    for (uint32_t b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer *buf = &out->mBuffers[b];
        uint32_t channels = buf->mNumberChannels;
        if (buf->mData && channels > 0) {
            uint32_t capacity = buf->mDataByteSize / (uint32_t)(channels * sizeof(float));
            uint32_t end = offset + frames < capacity ? offset + frames : capacity;
            float *data = buf->mData;
            for (uint32_t f = offset; f < end; f++) {
                const float *src = mix + 2 * (f - offset);
                for (uint32_t c = 0; c < channels; c++) {
                    uint32_t channel = firstChannel + c;
                    data[f * channels + c] = channel < 2 ? src[channel] : 0.0f;
                }
            }
        }
        firstChannel += channels;
    }
}

void su_render(SUMixState *m, const AudioBufferList *in, AudioBufferList *out, uint32_t frames) {
    for (uint32_t offset = 0; offset < frames; offset += SU_MAX_FRAMES) {
        uint32_t chunk = frames - offset < SU_MAX_FRAMES ? frames - offset : SU_MAX_FRAMES;
        mix_slots(m, in, offset, chunk);
        write_output(m->mix, out, offset, chunk);
    }
}
