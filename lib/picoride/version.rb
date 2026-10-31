# frozen_string_literal: true

module Picoride
  VERSION = "0.1.2"

  # ビルド専用Dockerイメージ(docker/esp32・docker/pico)のDocker Hub上の名前の接頭辞。
  # 実際のイメージ名は "#{BUILDER_IMAGE_PREFIX}-<esp32|pico>:#{VERSION}"。
  # タグをgemのバージョンに揃えて、gemとイメージの組み合わせを固定している
  # (サーバーのビルド手順はイメージの中身に依存するので、latestを追うと古いgemが
  # 新しいイメージで壊れうる)。
  #
  # VERSIONと同じく「このリリースが何か」を表す値なのでここに置いている。
  # サーバー(server.rb)と、gemには含めない公開用のRakeタスク(rakelib/docker.rake。
  # GitHub Actionsもこれを使う)の両方がここを参照する。
  BUILDER_IMAGE_PREFIX = "youchan/picoride-builder"
end
