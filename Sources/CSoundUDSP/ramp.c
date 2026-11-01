#include "SoundUDSP.h"

void su_ramp_init(SURamp *r, float initial, double sampleRate) {
    r->current = initial;
    r->step = (float)(1.0 / (0.010 * sampleRate));
}

float su_ramp_next(SURamp *r, float target) {
    float diff = target - r->current;
    if (diff > r->step) {
        r->current += r->step;
    } else if (diff < -r->step) {
        r->current -= r->step;
    } else {
        r->current = target;
    }
    return r->current;
}

void su_ramp_apply_stereo(SURamp *r, float target, float *interleaved, uint32_t frames) {
    if (r->current == 1.0f && target == 1.0f) {
        return;
    }
    for (uint32_t i = 0; i < frames; i++) {
        float gain = su_ramp_next(r, target);
        interleaved[2 * i] *= gain;
        interleaved[2 * i + 1] *= gain;
    }
}
