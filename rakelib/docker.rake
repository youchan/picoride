# frozen_string_literal: true

# ビルド専用Dockerイメージ(docker/esp32・docker/pico)のビルドとDocker Hubへの公開。
# gemを使う人には不要なメンテナー向けのタスクなので、gemには含めない
# (picoride.gemspec で rakelib/ を除外している。Rakeは rakelib/*.rake を自動で読み込む)。
#
# イメージ名は "#{Picoride::BUILDER_IMAGE_PREFIX}-<family>"(lib/picoride/version.rb)。
# サーバーは :<gemのバージョン> をpullし、公開時は :latest も付ける。
#
#   rake docker:images         # このバージョンのサーバーが使うイメージ名
#   rake docker:build          # 両方をローカルにビルド(今のマシンのアーキテクチャのみ)
#   rake docker:build[pico]    # 片方だけ
#   rake docker:push           # linux/amd64・linux/arm64 でビルドしてpush
#   rake docker:push[esp32]
#   rake docker:tags[pico]     # pushするタグをカンマ区切りで出力(GitHub Actions用)
#
# docker:push の前に `docker login` しておくこと。対象アーキテクチャは PLATFORMS
# 環境変数で変えられる(例: PLATFORMS=linux/amd64 rake docker:push)。別アーキテクチャの
# ビルドにはQEMUが要る(Docker Desktopなら設定不要。Linuxでは
# `docker run --privileged --rm tonistiigi/binfmt --install all` を一度実行する)。
# フォークで自分の名前空間に公開したい場合は IMAGE_PREFIX で接頭辞を差し替える
# (例: IMAGE_PREFIX=someone/picoride-builder。サーバー側は
# PICORIDE_{ESP32,PICO}_BUILDER_IMAGE で使うイメージを指定する)。
# 通常は v* タグをpushすると .github/workflows/docker.yml が同じことをする。
require_relative "../lib/picoride/version"

namespace :docker do
  families = %w[esp32 pico]
  prefix = -> { ENV.fetch("IMAGE_PREFIX", Picoride::BUILDER_IMAGE_PREFIX) }
  repository = ->(family) { "#{prefix.call}-#{family}" }
  publish_tags = ->(family) { [Picoride::VERSION, "latest"].map { |tag| "#{repository.call(family)}:#{tag}" } }
  dockerfile_dir = ->(family) { File.expand_path("../docker/#{family}", __dir__) }

  select_families = lambda do |args|
    family = args[:family]
    next families unless family
    abort "unknown family: #{family} (esp32 or pico)" unless families.include?(family)
    [family]
  end

  desc "Print the builder image names this version of picoride pulls"
  task :images do
    families.each { |family| puts "#{family}: #{repository.call(family)}:#{Picoride::VERSION}" }
  end

  desc "Print the tags docker:push publishes, comma-separated (used by GitHub Actions)"
  task :tags, [:family] do |_t, args|
    select_families.call(args).each { |family| puts publish_tags.call(family).join(",") }
  end

  desc "Build builder image(s) locally (family: esp32 or pico; default both)"
  task :build, [:family] do |_t, args|
    select_families.call(args).each do |family|
      tag_args = publish_tags.call(family).flat_map { |tag| ["-t", tag] }
      sh "docker", "build", *tag_args, dockerfile_dir.call(family)
    end
  end

  desc "Build multi-arch builder image(s) and push to Docker Hub (family: esp32 or pico; default both)"
  task :push, [:family] do |_t, args|
    platforms = ENV.fetch("PLATFORMS", "linux/amd64,linux/arm64")
    select_families.call(args).each do |family|
      tag_args = publish_tags.call(family).flat_map { |tag| ["-t", tag] }
      sh "docker", "buildx", "build", "--platform", platforms, "--push", *tag_args, dockerfile_dir.call(family)
    end
  end
end
