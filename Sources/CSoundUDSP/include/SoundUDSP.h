#ifndef SOUNDU_DSP_H
#define SOUNDU_DSP_H

#include <stdint.h>

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

#endif
