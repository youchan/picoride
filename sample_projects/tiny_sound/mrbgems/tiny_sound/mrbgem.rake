MRuby::Gem::Specification.new('picoruby-tiny_sound') do |spec|
  spec.license = 'MIT'
  spec.author  = 'youchan'
  spec.summary = 'Square wave tones and simple melodies on any GPIO pin'

  # The C code calls PicoRuby's portable GPIO and Machine APIs (gpio.h,
  # machine.h); declaring the dependencies puts their headers on the include
  # path. Both gems are part of every R2P2 build.
  spec.add_dependency 'picoruby-gpio'
  spec.add_dependency 'picoruby-machine'
end
