# PicoRuby.wasm 用のビルド専用イメージ。
#
#   公開版: docker pull youchan/picoride-builder-wasm:<picorideのバージョン>(サーバーが自動でpullする)
#   ビルド/公開: rake docker:build[wasm] / rake docker:push[wasm](rakelib/docker.rake)
#
# ESP32用(docker/esp32/Dockerfile)・Pico用(docker/pico/Dockerfile)と同じく、
# ツールチェインだけを持つ使い捨てコンテナ用のイメージ。picorideサーバーが
# プロジェクト設定のターゲットがwasmのときにこのイメージでdocker runする
# (lib/picoride/server.rb の BUILDER_IMAGES参照)。
#
# PicoRuby.wasmもPicoと同じpicoruby本体(picoruby/picoruby)のソースからビルドする。
# ビルド対象のソースはイメージには焼き込まず、プロジェクトごとの状態ディレクトリ
# (<project>/.picoruby-wasm)をホスト側のRubyコードが初回にgit cloneし、
# `docker run -v <state_dir>:/picoruby-wasm` でbind mountして使う
# (lib/picoride/r2p2_state.rb の ensure_wasm_checkout参照)。
# ビルドは `CONFIG=picoruby-wasm rake`(picoruby/build_config/picoruby-wasm.rb、
# picoruby/tasks/picoruby/wasm.rake)。
#
# ベースイメージはEmscripten公式(emscripten/emsdk)ではなく、Ruby公式イメージに
# している。picoruby本体のビルドツール(picoruby-aotがtypedな定義をCへコンパイルする
# `conf.aot`。picoruby-wasm.rbが使う)は`require 'prism'`・RBSパーサーを使うが、
# これらのAPIはRubyのバージョンに強く依存しており、picoruby本体のCI
# (.github/workflows/c-cpp.yml の RUBY_VERSION)が使っているバージョンと
# 大きくズレると壊れる。実際にUbuntu 24.04のaptパッケージ(ruby 3.2.3)で試したところ、
# RBSの内部APIの違いでNoMethodErrorになった(本番投入前に実ビルドで発見できた)。
# picoruby側のRUBY_VERSIONに追従させるため、ARG RUBY_VERSIONで固定する。
ARG RUBY_VERSION=4.0.10
FROM ruby:${RUBY_VERSION}-bookworm

SHELL ["/bin/bash", "-c"]

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

# - rake: picorubyのビルド。ESP32/Pico用イメージと同じく`bundle exec`を使わない
#   素の`rake`なのでBundler/gemのインストールは不要(Ruby公式イメージ同梱のgemで足りる)
# - git: チェックアウト自体はホスト側(r2p2_state.rb)がbind mount前に行うが、
#   ビルド中にgitを使う処理に備えて入れておく
# - brotli: picoruby-wasmのmrbgem.rakeがビルド後に`brotli -f picoruby.wasm`を
#   実行して圧縮版(.wasm.br)を作る。無いとその行でシェルコマンドが失敗し、
#   .wasm.wasm自体はできているのにビルド全体が失敗扱いになる
#   (Pico用イメージのzipと同種の罠。実際にmrbgem.rakeのsh呼び出しを読んで確認した)
# - python3: emsdkのインストーラ(emsdk)自体がPython製
RUN apt-get update && apt-get install -y --no-install-recommends \
    brotli \
    build-essential \
    ca-certificates \
    file \
    git \
    python3 \
    rake \
    && rm -rf /var/lib/apt/lists/* \
    && gem install rake --no-document

# Emscripten SDK。emscripten/emsdk公式イメージのDockerfile
# (github.com/emscripten-core/emsdk/blob/main/docker/Dockerfile)と同じ手順
# (emsdkリポジトリ自体をclone → `./emsdk install/activate`)。バージョンは
# picoruby本体のCI(.github/workflows/c-cpp.yml、mymindstorm/setup-emsdk)が
# 使っているものに合わせてある。
ARG EMSCRIPTEN_VERSION=7.0.0
ENV EMSDK=/emsdk
RUN git clone https://github.com/emscripten-core/emsdk.git "$EMSDK" \
    && cd "$EMSDK" \
    && ./emsdk install "${EMSCRIPTEN_VERSION}" \
    && ./emsdk activate "${EMSCRIPTEN_VERSION}"

# emsdk_env.shはNode.jsのバージョンディレクトリ名等、インストール結果に依存する
# パスをPATHへ追加する(ビルド時のインストール結果でしか分からない)。固定の
# ENV PATHとして埋め込むのではなく、ビルド実行のたびに明示的にsourceする
# (ESP32用イメージの"$IDF_PATH/export.sh"と同じ方式。builder_docker_command参照)。

# mrbgems/picoruby-mbedtls/mrbgem.rakeは、mrbgems/picoruby-r2p2/lib/pico-sdk/lib/mbedtls
# (gitでシンボリックリンクとして管理されている)の先にmbedtlsのヘッダーが無いと、
# 「Mbed TLS submodule is not initialized」と出してpico-sdk一式 + mbedtls
# サブモジュール(depth指定なしのフルクローンで数百MB)を自動でgit submodule update
# してしまう(picoruby-wasm.rbのgem構成にpicoruby-drbが含まれ、間接的に
# picoruby-mbedtlsを要求するため)。これを実際にビルドして確認した
# (ビルドのたびに数分〜十数分待たされる)。
#
# 最初は「lib/pico-sdk/lib/mbedtlsだけをシンボリックリンクにする」対策を
# 試したが、一度でも自動初期化が走ってpico-sdkが本物のgitサブモジュールとして
# チェックアウトされると、rm -rfで中身を消してもgit側のサブモジュール登録情報は
# 残ったままで、rake実行中の別の処理が「未初期化」と再判定して作ったはずの
# シンボリックリンクを上書きしてしまう不具合が実際に起きた(本番投入前に
# 気づけてよかった類のバグ)。Pico用イメージのPICO_PREPARE_COMMANDと同じく、
# pico-sdkという**ディレクトリ自体**をシンボリックリンクにする対策に直した
# (gitからは「サブモジュールの登録パスがそもそもディレクトリではない」ように
# 見えるため、再チェックアウトが起きない)。wasmビルドにpico-sdk本体
# (ARMツールチェイン設定等)は不要なので、mbedtlsだけを含む最小限の構造
# ($WASM_PICO_SDK_PATH/lib/mbedtls)を用意してある。
ARG MBEDTLS_VERSION=v3.6.2
RUN mkdir -p /opt/wasm-pico-sdk/lib && \
    git clone --depth 1 --branch "${MBEDTLS_VERSION}" \
      https://github.com/Mbed-TLS/mbedtls.git /opt/wasm-pico-sdk/lib/mbedtls
ENV WASM_PICO_SDK_PATH=/opt/wasm-pico-sdk

# picoruby-aot(`conf.aot`、picoruby-wasm.rbが使う)のビルドツールは
# `require 'prism'`する。prismはRuby 3.3以降は標準添付だが、念のため明示的に
# 入れておく(Ruby 4.0系では既に同梱されているはずだが、バージョンが
# 将来変わってもズレないように)。
RUN gem install prism --no-document

# bind mountしたディレクトリ(ホスト側の実UIDのまま見える)に対してgitを実行すると
# 「dubious ownership」で拒否される(ESP32/Pico用イメージと同じ問題)。
RUN git config --system --add safe.directory '*'

# picorubyの状態ディレクトリをここへbind mountして使う想定のデフォルトWORKDIR。
# Pico用(/picoruby)とは別のマウント先にしてある(同じリポジトリでも
# チェックアウト・ビルド成果物はプロジェクトごと・ターゲットファミリーごとに
# 独立させているため)。
WORKDIR /picoruby-wasm
