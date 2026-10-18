# picoride のGemsダイアログ機能を試すためのサンプルmrbgem。
# picoruby本体のmrbgem(mrbgems/picoruby-base64等)と同じ構成に揃えてある。
#
# gem名を"picoruby-"で始めておくのが重要: picoruby本体側の
# lib/picoruby/gem.rb (define_gem_init_builder) が「femtoruby(mrubyc)ビルドで、
# かつgem名がpicoruby-で始まる」場合だけ、mrbgem標準のRuby組み込み処理を
# スキップしてpicoruby-require gem独自の初期化(mrbc_xxx_init)に任せる
# という分岐になっているため、この命名規則を外すとfemtoruby側でリンクできない。
MRuby::Gem::Specification.new('picoruby-hello_world') do |spec|
  spec.license = 'MIT'
  spec.author  = 'youchan'
  spec.summary = 'Hello World sample mrbgem for picoride'

  # 素の名前("_hello_world"のように先頭にアンダースコアが付く)ではなく
  # require 'hello_world' で読み込めるようにする
  spec.require_name = 'hello_world'
end
