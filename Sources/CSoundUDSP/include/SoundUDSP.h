#ifndef SOUNDU_DSP_H
#define SOUNDU_DSP_H

#include <stdint.h>
#include <CoreAudio/CoreAudioTypes.h>

/// Linear gain ramp. Real-time safe: no allocation, locks or calls out.
typedef struct {
    float current;
    float step;
} SURamp;

/// Sets the ramp to `initial`; a full 0 -> 1.0 sweep takes 10 ms at `sampleRate`.
void su_ramp_init(SURamp *r, float initial, double sampleRate);

/// Moves `current` toward `target` by at most `step` and returns the new value.
float su_ramp_next(SURamp *r, float target);

/// Applies the ramped gain per frame to an interleaved stereo buffer.
/// When `current == target == 1.0f` the samples are left untouched.
void su_ramp_apply_stereo(SURamp *r, float target, float *interleaved, uint32_t frames);

/// Peak limiter for stereo. Instant attack, 50 ms release, ceiling 0.995.
typedef struct {
    float envelope;
    float releaseCoef;
} SULimiter;

void su_limiter_init(SULimiter *l, double sampleRate);

/// Limits an interleaved stereo buffer in place; guarantees |out| <= 0.995.
void su_limiter_process_stereo(SULimiter *l, float *interleaved, uint32_t frames);

#define SU_MAX_SLOTS 32
#define SU_MAX_FRAMES 4096

/// One routed app. Atomic fields may be touched from any thread; the rest
/// belongs to the render thread once `active` is set.
typedef struct {
    _Atomic float targetGain;
    _Atomic int muted;
    _Atomic int active;
    _Atomic float peak;
    SURamp ramp;
    SULimiter limiter;
    uint32_t inputBuffer;
} SUSlot;

typedef struct {
    SUSlot slots[SU_MAX_SLOTS];
    float scratch[SU_MAX_FRAMES * 2];
    float mix[SU_MAX_FRAMES * 2];
    double sampleRate;
} SUMixState;

/// Clears all slots (inactive) and remembers the sample rate. Non-RT.
void su_mix_init(SUMixState *m, double sampleRate);

/// Binds `slot` to input buffer `inputBufferIndex`, resets its ramp to `gain`
/// and its limiter, then sets `active = 1`. Non-RT.
void su_slot_configure(SUMixState *m, uint32_t slot, uint32_t inputBufferIndex, float gain, int muted);

/// Updates target gain (clamped to 0...2) and mute. Any thread; atomics only.
void su_slot_set(SUMixState *m, uint32_t slot, float gain, int muted);

void su_slot_deactivate(SUMixState *m, uint32_t slot);

/// Returns the largest |sample| since the last call and resets it to 0.
float su_slot_take_peak(SUMixState *m, uint32_t slot);

/// IOProc body. Each tap input buffer is interleaved stereo float32. Mixes
/// active slots and writes L/R to output channels 0/1 (interleaved or
/// non-interleaved), zeroes all other channels, hard-clamps to +/-1.0.
void su_render(SUMixState *m, const AudioBufferList *in, AudioBufferList *out, uint32_t frames);

#endif
