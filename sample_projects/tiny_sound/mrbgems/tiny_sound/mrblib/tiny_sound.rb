# Square wave sound on a GPIO pin.
#
#   require 'tiny_sound'
#   sound = TinySound.new(4)          # GPIO4 -- piezo buzzer -- 330 ohm -- GND
#   sound.tone(440, 500)          # 440 Hz for 500 ms
#   sound.note("C5", 250)         # note name + octave ("C#5", "Bb4" also work)
#   sound.play("T120 O4 L8 CDEFGAB>C")   # simple MML
#
# The waveform itself is generated in C (src/square_wave.c): flipping a pin
# every few hundred microseconds is far below what Ruby's sleep_ms can time.
# Ruby takes care of the music: note names, octaves, tempo and MML parsing.
class TinySound
  # Frequencies of octave 4 (C4..B4) in 1/100 Hz, equal temperament, A4 = 440 Hz.
  # Other octaves are made by doubling / halving (no Float#** needed).
  OCTAVE4 = [26163, 27718, 29366, 31113, 32963, 34923, 36999, 39200, 41530, 44000, 46616, 49388]

  NOTE_INDEX = {
    "C" => 0, "D" => 2, "E" => 4, "F" => 5, "G" => 7, "A" => 9, "B" => 11,
    "c" => 0, "d" => 2, "e" => 4, "f" => 5, "g" => 7, "a" => 9, "b" => 11
  }
  DIGITS = {
    "0" => 0, "1" => 1, "2" => 2, "3" => 3, "4" => 4,
    "5" => 5, "6" => 6, "7" => 7, "8" => 8, "9" => 9
  }

  # Highest octave that every port can play (B7 is about 3951 Hz)
  MAX_OCTAVE = 7
  # Silence after each note so that repeated notes are heard separately
  GAP_MS = 20

  attr_reader :pin

  def initialize(pin)
    @pin = pin
    _setup(pin)
  end

  # Play a square wave of +frequency+ Hz for +ms+ milliseconds (blocks).
  def tone(frequency, ms)
    _square(@pin, (frequency * 100).to_i, ms.to_i)
    self
  end

  # Silence for +ms+ milliseconds.
  def rest(ms)
    sleep_ms ms.to_i
    self
  end

  # Play a note such as "A4", "C#5", "Bb3" for +ms+ milliseconds.
  def note(name, ms)
    _square(@pin, note_frequency(name), ms.to_i)
    self
  end

  # Frequency of a note name in 1/100 Hz ("A4" -> 44000).
  def note_frequency(name)
    index = NOTE_INDEX[name[0]]
    raise ArgumentError, "unknown note: #{name}" if index.nil?
    pos = 1
    accidental = name[pos]
    if accidental == "#" || accidental == "+"
      index += 1
      pos += 1
    elsif accidental == "b" || accidental == "-"
      index -= 1
      pos += 1
    end
    octave = DIGITS[name[pos]]
    raise ArgumentError, "octave missing: #{name}" if octave.nil?
    frequency_of(index, octave)
  end

  # Play a melody written in a small subset of MML:
  #   C D E F G A B  notes (followed by # + or - for sharp/flat, then an
  #                  optional length like 4 or 8, and . for dotted)
  #   R              rest
  #   O<n>           octave (default 4), < and > go down / up one octave
  #   L<n>           default length (default 4 = quarter note)
  #   T<n>           tempo in quarter notes per minute (default 120)
  # Spaces and | are ignored, so bars can be written as "CDEF | GAB>C".
  def play(mml)
    octave = 4
    length = 4
    tempo = 120
    i = 0
    while i < mml.length
      ch = mml[i]
      i += 1
      up = ch.upcase
      if NOTE_INDEX[ch] || up == "R"
        index = NOTE_INDEX[ch]
        if index
          if mml[i] == "#" || mml[i] == "+"
            index += 1
            i += 1
          elsif mml[i] == "-"
            index -= 1
            i += 1
          end
        end
        n, i = read_number(mml, i)
        dotted = (mml[i] == ".")
        i += 1 if dotted
        ms = 240000 / (tempo * (n || length))
        ms = ms * 3 / 2 if dotted
        if index
          play_note(frequency_of(index, octave), ms)
        else
          rest(ms)
        end
      elsif up == "O"
        n, i = read_number(mml, i)
        octave = n if n
      elsif up == "L"
        n, i = read_number(mml, i)
        length = n if n && 0 < n
      elsif up == "T"
        n, i = read_number(mml, i)
        tempo = n if n && 0 < n
      elsif ch == "<"
        octave -= 1
      elsif ch == ">"
        octave += 1
      end
      # anything else (spaces, |, newlines) is skipped
    end
    self
  end

  private

  # index: semitones from C (may be -1 or 12 after a flat/sharp)
  def frequency_of(index, octave)
    while index < 0
      index += 12
      octave -= 1
    end
    while 11 < index
      index -= 12
      octave += 1
    end
    if octave < 1 || MAX_OCTAVE < octave
      raise ArgumentError, "octave out of range (1..#{MAX_OCTAVE}): #{octave}"
    end
    f = OCTAVE4[index]
    o = octave
    while o < 4
      f = f / 2
      o += 1
    end
    while 4 < o
      f = f * 2
      o -= 1
    end
    f
  end

  def play_note(freq_chz, ms)
    if GAP_MS < ms
      _square(@pin, freq_chz, ms - GAP_MS)
      sleep_ms GAP_MS
    else
      _square(@pin, freq_chz, ms)
    end
  end

  # Reads digits starting at +i+. Returns [number or nil, next index].
  def read_number(str, i)
    n = nil
    while i < str.length
      d = DIGITS[str[i]]
      break if d.nil?
      n = (n || 0) * 10 + d
      i += 1
    end
    [n, i]
  end
end
