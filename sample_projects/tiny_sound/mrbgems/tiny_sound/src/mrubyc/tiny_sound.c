/* Binding for FemtoRuby (mruby/c VM). Included from src/tiny_sound.c */

#include <mrubyc.h>

static bool
int_args(mrbc_vm *vm, mrbc_value *v, int argc, int expected)
{
  if (argc != expected) {
    mrbc_raise(vm, MRBC_CLASS(ArgumentError), "wrong number of arguments");
    return false;
  }
  for (int i = 1; i <= expected; i++) {
    if (GET_TT_ARG(i) != MRBC_TT_INTEGER) {
      mrbc_raise(vm, MRBC_CLASS(TypeError), "Integer expected");
      return false;
    }
  }
  if (GET_INT_ARG(1) < 0 || 255 < GET_INT_ARG(1)) {
    mrbc_raise(vm, MRBC_CLASS(ArgumentError), "invalid pin");
    return false;
  }
  return true;
}

/* TinySound#_setup(pin) */
static void
c__setup(mrbc_vm *vm, mrbc_value *v, int argc)
{
  if (!int_args(vm, v, argc, 1)) return;
  Sound_setup_pin((uint8_t)GET_INT_ARG(1));
  SET_NIL_RETURN();
}

/* TinySound#_square(pin, freq_chz, duration_ms) -- freq_chz is in 1/100 Hz */
static void
c__square(mrbc_vm *vm, mrbc_value *v, int argc)
{
  if (!int_args(vm, v, argc, 3)) return;
  mrbc_int_t freq_chz = GET_INT_ARG(2);
  mrbc_int_t duration_ms = GET_INT_ARG(3);
  if (freq_chz < SOUND_MIN_FREQ_CHZ || SOUND_MAX_FREQ_CHZ < freq_chz) {
    mrbc_raise(vm, MRBC_CLASS(ArgumentError), "frequency must be between 20 and 20000 Hz");
    return;
  }
  if (duration_ms < 0 || SOUND_MAX_DURATION_MS < duration_ms) {
    mrbc_raise(vm, MRBC_CLASS(ArgumentError), "duration must be between 0 and 10000 ms");
    return;
  }
  Sound_square_wave((uint8_t)GET_INT_ARG(1), (uint32_t)freq_chz, (uint32_t)duration_ms);
  SET_NIL_RETURN();
}

/* Called by `require 'tiny_sound'` (picoruby-require), before mrblib is loaded */
void
mrbc_tiny_sound_init(mrbc_vm *vm)
{
  mrbc_class *class_TinySound = mrbc_define_class(vm, "TinySound", mrbc_class_object);
  mrbc_define_method(vm, class_TinySound, "_setup", c__setup);
  mrbc_define_method(vm, class_TinySound, "_square", c__square);
}
