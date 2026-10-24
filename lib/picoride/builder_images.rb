# frozen_string_literal: true

require_relative "version"

module Picoride
  # ビルド専用Dockerイメージ(docker/esp32/Dockerfile・docker/pico/Dockerfile)の
  # 名前を一か所で決めるモジュール。サーバー(server.rb)・Rakeタスク(Rakefileの
  # docker:build / docker:push)・GitHub Actions(.github/workflows/docker.yml)が
  # すべてここを参照するので、イメージ名がずれない。
  #
  # gemを使う人がイメージを自分でビルドしなくて済むよう、イメージはDocker Hubに
  # 公開して`docker pull`で取ってこられるようにしてある。タグはgemのバージョン
  # (Picoride::VERSION)と同じにする: gemとイメージの組み合わせを固定するため
  # (サーバー側のビルド手順はイメージの中身(pico-sdkのバージョン、zipの有無など)に
  # 依存しているので、latestを追いかけると古いgemが新しいイメージで壊れうる)。
  # pushするときは利便性のためlatestタグも付ける。
  module BuilderImages
    FAMILIES = %w[esp32 pico].freeze

    # Docker Hubの名前空間(ユーザー名/組織名)。フォークして自分の名前空間に
    # pushする場合は環境変数で差し替えられる。
    DEFAULT_NAMESPACE = "youchan"

    module_function

    def namespace
      ENV.fetch("PICORIDE_DOCKER_NAMESPACE", DEFAULT_NAMESPACE)
    end

    # タグなしのリポジトリ名(例: "youchan/picoride-builder-pico")。
    def repository(family)
      check_family!(family)
      "#{namespace}/picoride-builder-#{family}"
    end

    # サーバーが実際に使うイメージ名。環境変数で丸ごと上書きできる
    # (自分でローカルビルドしたイメージを使いたい場合など)。ESP32側は
    # 旧来のPICORUBY_BUILDER_IMAGEも引き続き効くようにしてある。
    def image(family)
      check_family!(family)
      override =
        case family
        when "esp32" then ENV["PICORIDE_ESP32_BUILDER_IMAGE"] || ENV["PICORUBY_BUILDER_IMAGE"]
        when "pico" then ENV["PICORIDE_PICO_BUILDER_IMAGE"]
        end
      override || "#{repository(family)}:#{Picoride::VERSION}"
    end

    # pushするときに付けるタグ一式(バージョン + latest)。
    def publish_tags(family)
      ["#{repository(family)}:#{Picoride::VERSION}", "#{repository(family)}:latest"]
    end

    def dockerfile_dir(family)
      check_family!(family)
      "docker/#{family}"
    end

    def check_family!(family)
      raise ArgumentError, "unknown builder family: #{family.inspect}" unless FAMILIES.include?(family)
    end
  end
end
