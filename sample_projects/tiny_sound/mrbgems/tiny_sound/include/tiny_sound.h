#ifndef SOUND_DEFINED_H_
#define SOUND_DEFINED_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Range accepted by Sound_square_wave() (frequencies are in 1/100 Hz) */
#define SOUND_MIN_FREQ_CHZ   (20 * 100)      /*    20 Hz */
#define SOUND_MAX_FREQ_CHZ   (20000 * 100)   /* 20000 Hz */
#define SOUND_MAX_DURATION_MS 10000

void Sound_setup_pin(uint8_t pin);
void Sound_square_wave(uint8_t pin, uint32_t freq_chz, uint32_t duration_ms);

#ifdef __cplusplus
}
#endif

#endif /* SOUND_DEFINED_H_ */
