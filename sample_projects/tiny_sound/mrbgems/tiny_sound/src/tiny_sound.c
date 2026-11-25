/*
 * Ruby bindings of picoruby-tiny_sound.
 *
 * Like the gems bundled with PicoRuby, the binding is written once per VM and
 * the right one is picked at compile time: src/mruby/ for PicoRuby (mruby VM)
 * and src/mrubyc/ for FemtoRuby (mruby/c VM). Only the files directly under
 * src/ are compiled, so they are included from here.
 * The tone generation itself is VM independent (square_wave.c).
 */

#include "../include/tiny_sound.h"

#if defined(PICORB_VM_MRUBY)

#include "mruby/tiny_sound.c"

#elif defined(PICORB_VM_MRUBYC)

#include "mrubyc/tiny_sound.c"

#endif
