# tiny_sound — picoride のサンプルプロジェクト

GPIO につないだ圧電スピーカー（パッシブブザー）から、矩形波で音階を鳴らすサンプルです。
音を作る部分を C で書いた mrbgem（`mrbgems/tiny_sound`）をプロジェクトに入れてあり、
R2P2 にパッチを当てずにビルドできます。

## 配線

```
GPIO4 ── 圧電スピーカー（パッシブブザー）── 330Ω ── GND
```

ピンは `home/play.rb` の `TinySound.new(4)` で変えられます。

## 対応

- ESP32 / Raspberry Pi Pico のどちらでも、PicoRuby・FemtoRuby のどちらの VM でも動きます
- 音域は 20Hz〜約4kHz（オクターブ 1〜7）

## 使い方

```ruby
require 'tiny_sound'
sound = TinySound.new(4)
sound.tone(440, 500)        # 440Hz を 500ms
sound.note("C#5", 250)      # 音名 + オクターブ（# + で半音上げ、b - で半音下げ）
sound.rest(200)             # 休符
sound.play("T120 O4 L8 CDEFGAB>C")   # 簡単な MML
```

MML で使えるもの: `C D E F G A B`（音符。直後に `#` `+` `-` で半音、数字で長さ、`.` で付点）、
`R`（休符）、`O`（オクターブ）、`<` `>`（オクターブを下げる/上げる）、`L`（既定の長さ）、
`T`（テンポ）。空白と `|` は無視されます。

## しくみ

- **C（`src/square_wave.c`）**: ピンの High/Low を、ハードウェアのクロックを見ながら
  マイクロ秒単位の正確なタイミングで切り替えて矩形波を作ります。A5（880Hz）なら 568µs ごとに
  切り替える必要があり、Ruby の `sleep_ms`（1ms 単位、VM の揺らぎもある）では作れないので C で書いています
- C から使うのは PicoRuby 自身の移植用 API（`gpio.h` の `GPIO_write`、`machine.h` の
  `Machine_uptime_us`）だけです。どのボード向けの R2P2 にも実装があるので、ESP-IDF や Pico SDK の
  ヘッダは使わず、プロジェクトの mrbgem のままビルドできます
- **Ruby（`mrblib/tiny_sound.rb`）**: 音名から周波数への変換、テンポ、MML の解釈
- VM ごとの結び付け（バインディング）は `src/mruby/`（PicoRuby）と `src/mrubyc/`（FemtoRuby）に分けてあり、
  `src/tiny_sound.c` がビルド時にどちらかを読み込みます（PicoRuby 同梱の gem と同じ構成）
- gem の名前は `picoruby-tiny_sound` です（`require 'tiny_sound'`）。FemtoRuby では `picoruby-` で始まる名前の gem だけが
  `require` で C の初期化が呼ばれる仕組みなので、フォルダ名（`tiny_sound`）とは別にこの名前にしています

## 注意

- 音を鳴らしている間（`tone` / `note` / `play` の各音）は、その処理が終わるまで Ruby の他の処理は止まります
- ESP32 で 5 秒以上連続して鳴らすと、タスクウォッチドッグの警告がシリアルに出ることがあります
  （警告だけで止まりはしません）。長い音は分けて鳴らしてください
