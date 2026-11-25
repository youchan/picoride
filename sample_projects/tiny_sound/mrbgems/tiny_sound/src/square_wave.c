/*
 * Square wave generator (VM independent part of picoruby-tiny_sound).
 *
 * Why this is written in C:
 * A square wave at frequency f means flipping the pin every 1/(2f) seconds:
 * every 1136 us for A4 (440 Hz), every 568 us for A5. Ruby's sleep_ms has a
 * 1 ms (or coarser) resolution and the VM adds its own jitter, so the pitch
 * would be wrong and wobble. Here the pin is toggled on an exact microsecond
 * schedule taken from the hardware clock.
 *
 * Only PicoRuby's own portable C APIs are used (GPIO from picoruby-gpio,
 * Machine from picoruby-machine). Every R2P2 port implements them, so this
 * gem builds as a plain project mrbgem: no ESP-IDF / Pico SDK headers and
 * no patch to R2P2 are needed.
 *
 * The call blocks for the duration of the note; keep notes short (the Ruby
 * side plays a melody note by note and sleeps between them).
 */

#include "../include/tiny_sound.h"
#include "gpio.h"
#include "machine.h"

void
Sound_setup_pin(uint8_t pin)
{
  GPIO_init(pin);
  GPIO_set_dir(pin, OUT);
  GPIO_write(pin, 0);
}

void
Sound_square_wave(uint8_t pin, uint32_t freq_chz, uint32_t duration_ms)
{
  if (freq_chz == 0 || duration_ms == 0) return;

  /* Half period in nanoseconds. freq_chz is in 1/100 Hz so that the Ruby side
     can pass fractional frequencies (e.g. 261.63 Hz for C4) without floats. */
  const uint64_t half_period_ns = 50000000000ULL / freq_chz;

  const uint64_t start_us = Machine_uptime_us();
  const uint64_t end_us = start_us + (uint64_t)duration_ms * 1000;
  /* Toggle times are kept in ns and advanced by an exact half period, so the
     rounding error does not accumulate over a long note. */
  uint64_t next_ns = start_us * 1000 + half_period_ns;
  uint8_t level = 1;

  GPIO_write(pin, level);
  for (;;) {
    uint64_t now_us = Machine_uptime_us();
    if (end_us <= now_us) break;
    if (next_ns <= now_us * 1000) {
      level ^= 1;
      GPIO_write(pin, level);
      next_ns += half_period_ns;
    }
  }
  GPIO_write(pin, 0);
}
