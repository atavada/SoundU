#include "SoundUDSP.h"
#include <math.h>

#define SU_LIMITER_CEILING 0.995f
#define SU_LIMITER_RELEASE_SECONDS 0.050

void su_limiter_init(SULimiter *l, double sampleRate) {
    l->envelope = 0.0f;
    l->releaseCoef = (float)exp(-1.0 / (SU_LIMITER_RELEASE_SECONDS * sampleRate));
}

void su_limiter_process_stereo(SULimiter *l, float *interleaved, uint32_t frames) {
    float env = l->envelope;
    const float coef = l->releaseCoef;
    for (uint32_t i = 0; i < frames; i++) {
        float left = interleaved[2 * i];
        float right = interleaved[2 * i + 1];
        float level = fmaxf(fabsf(left), fabsf(right));
        // Instant attack: the envelope never sits below the current frame's peak.
        env = level > env ? level : level + coef * (env - level);
        if (env > SU_LIMITER_CEILING) {
            float gain = SU_LIMITER_CEILING / env;
            // Clamp guards against rounding pushing a sample one ulp over the ceiling.
            interleaved[2 * i] = fminf(fmaxf(left * gain, -SU_LIMITER_CEILING), SU_LIMITER_CEILING);
            interleaved[2 * i + 1] = fminf(fmaxf(right * gain, -SU_LIMITER_CEILING), SU_LIMITER_CEILING);
        }
    }
    l->envelope = env;
}
