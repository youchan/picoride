# Raspberry Pi Pico(R2P2)用のビルド専用イメージ。
#
#   公開版: docker pull youchan/picoride-builder-pico:<picorideのバージョン>(サーバーが自動でpullする)
#   ビルド/公開: rake docker:build[pico] / rake docker:push[pico](rakelib/docker.rake)
#
# ESP32用(docker/esp32/Dockerfile)と同じく、ツールチェインだけを持つ使い捨て
# コンテナ用のイメージ。picorideサーバーがプロジェクト設定のターゲットが
# pico / pico_w / pico2 / pico2_w のときにこのイメージで docker run する
# (lib/picoride/server.rb の BUILDER_IMAGES 参照)。
#
# R2P2(Pico版)は picoruby 本体に `picoruby-r2p2` gem として統合されているので、
# ビルド対象のソースは picoruby のチェックアウト。これはイメージには焼き込まず、
# プロジェクトごとの状態ディレクトリ(<project>/.r2p2-pico)をホスト側のRubyコードが
# 初回に git clone し、`docker run -v <state_dir>:/picoruby` でbind mountして使う
# (lib/picoride/r2p2_state.rb の ensure_pico_checkout 参照)。ビルドは
# `rake r2p2:{vm}:{board}:prod`(picoruby/tasks/picoruby/r2p2.rake)。
FROM ubuntu:24.04

SHELL ["/bin/bash", "-c"]

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

# - gcc-arm-none-eabi 一式: libmruby.a と R2P2 本体のクロスコンパイル
# - build-essential: mrbc(ホスト向け)や pioasm・picotool のビルド
# - cmake(>= 3.22)/ python3: pico-sdk のビルドシステム
# - ruby / rake: picoruby のビルド(rake)。r2p2 のビルドは `bundle exec` を使わない
#   素の `rake` なので Bundler / gem のインストールは不要
# - zip: r2p2 の cmake がリンク後に成果物(.uf2 等)を zip にまとめる。無いと
#   .uf2 自体はできているのにビルドが失敗扱いになる(実際のビルドで確認)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    gcc-arm-none-eabi \
    git \
    libnewlib-arm-none-eabi \
    libstdc++-arm-none-eabi-newlib \
    python3 \
    rake \
    ruby \
    zip \
    && rm -rf /var/lib/apt/lists/*

# pico-sdk はイメージに焼き込む。picoruby の rake タスク(r2p2:check_pico_sdk)は
# PICO_SDK_PATH の pico-sdk が `git describe --tags --exact-match` で
# picoruby 側の PICO_SDK_TAG(mrbgems/picoruby-r2p2/r2p2_config.rb)と一致することを
# 要求する。picoruby 側が SDK のバージョンを上げたらビルドがその旨のエラーで
# 止まるので、そのときは --build-arg PICO_SDK_VERSION=<新しいタグ> でイメージを
# 作り直す。
ARG PICO_SDK_VERSION=2.3.0
RUN git clone --depth 1 --branch "${PICO_SDK_VERSION}" \
      --recurse-submodules --shallow-submodules \
      https://github.com/raspberrypi/pico-sdk.git /opt/pico-sdk
ENV PICO_SDK_PATH=/opt/pico-sdk

# picotool(.elf → .uf2 変換に使う)。pico-sdk 2.x は SDK と同じバージョンの
# picotool がインストールされていないと、cmake の構成時に GitHub から picotool を
# 取ってきてビルドしようとする(ビルドのたびにネットワークが必要になる)。
# それを避けるため、同じバージョンをイメージビルド時に /usr/local へ入れておく
# (find_package(picotool) が /usr/local/lib/cmake/picotool を見つける)。
# USB 経由でボードを操作する機能は使わないので libusb 無しでビルドする。
RUN git clone --depth 1 --branch "${PICO_SDK_VERSION}" \
      https://github.com/raspberrypi/picotool.git /tmp/picotool \
    && cmake -S /tmp/picotool -B /tmp/picotool/build \
      -DPICO_SDK_PATH=/opt/pico-sdk -DPICOTOOL_NO_LIBUSB=1 -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /tmp/picotool/build -j"$(nproc)" \
    && cmake --install /tmp/picotool/build \
    && rm -rf /tmp/picotool

# bind mount したディレクトリ(ホスト側の実UIDのまま見える)に対して git を
# 実行すると「dubious ownership」で拒否される(ESP32 用イメージと同じ問題。
# r2p2 の cmake は `git rev-parse` でリビジョンをファイル名に埋め込む)。
RUN git config --system --add safe.directory '*'

# picoruby の状態ディレクトリをここへ bind mount して使う想定のデフォルト WORKDIR。
WORKDIR /picoruby
