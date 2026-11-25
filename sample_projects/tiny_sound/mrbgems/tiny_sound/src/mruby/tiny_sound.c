/* Binding for PicoRuby (mruby VM). Included from src/tiny_sound.c */

#include <mruby.h>
#include <mruby/presym.h>

static void
check_pin(mrb_state *mrb, mrb_int pin)
{
  if (pin < 0 || 255 < pin) {
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "invalid pin: %i", pin);
  }
}

/* TinySound#_setup(pin) */
static mrb_value
mrb_sound__setup(mrb_state *mrb, mrb_value self)
{
  mrb_int pin;
  mrb_get_args(mrb, "i", &pin);
  check_pin(mrb, pin);
  Sound_setup_pin((uint8_t)pin);
  return mrb_nil_value();
}

/* TinySound#_square(pin, freq_chz, duration_ms) -- freq_chz is in 1/100 Hz */
static mrb_value
mrb_sound__square(mrb_state *mrb, mrb_value self)
{
  mrb_int pin, freq_chz, duration_ms;
  mrb_get_args(mrb, "iii", &pin, &freq_chz, &duration_ms);
  check_pin(mrb, pin);
  if (freq_chz < SOUND_MIN_FREQ_CHZ || SOUND_MAX_FREQ_CHZ < freq_chz) {
    mrb_raise(mrb, E_ARGUMENT_ERROR, "frequency must be between 20 and 20000 Hz");
  }
  if (duration_ms < 0 || SOUND_MAX_DURATION_MS < duration_ms) {
    mrb_raise(mrb, E_ARGUMENT_ERROR, "duration must be between 0 and 10000 ms");
  }
  Sound_square_wave((uint8_t)pin, (uint32_t)freq_chz, (uint32_t)duration_ms);
  return mrb_nil_value();
}

void
mrb_picoruby_tiny_sound_gem_init(mrb_state *mrb)
{
  struct RClass *class_TinySound = mrb_define_class_id(mrb, MRB_SYM(TinySound), mrb->object_class);
  mrb_define_method_id(mrb, class_TinySound, MRB_SYM(_setup), mrb_sound__setup, MRB_ARGS_REQ(1));
  mrb_define_method_id(mrb, class_TinySound, MRB_SYM(_square), mrb_sound__square, MRB_ARGS_REQ(3));
}

void
mrb_picoruby_tiny_sound_gem_final(mrb_state *mrb)
{
}
