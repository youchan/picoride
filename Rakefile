# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require_relative "lib/picoride/builder_images"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test

# ビルド専用Dockerイメージ(docker/esp32・docker/pico)のビルドとDocker Hubへの公開。
# イメージ名・タグは Picoride::BuilderImages で決まる
# (<namespace>/picoride-builder-<family>:<gemのバージョン>、pushするときは :latest も)。
#
#   rake docker:build          # 両方をローカルにビルド(今のマシンのアーキテクチャのみ)
#   rake docker:build[pico]    # 片方だけ
#   rake docker:push           # linux/amd64・linux/arm64 のマルチアーキでビルドしてpush
#   rake docker:push[esp32]
#
# docker:push の前に `docker login` しておくこと。対象アーキテクチャは
# PLATFORMS 環境変数で変えられる(例: PLATFORMS=linux/amd64 rake docker:push)。
# 別アーキテクチャのビルドにはQEMUが要る(Docker Desktopなら設定不要。Linuxでは
# `docker run --privileged --rm tonistiigi/binfmt --install all` を一度実行する)。
# 通常はタグを打つとGitHub Actions(.github/workflows/docker.yml)が同じことをする。
namespace :docker do
  families = lambda do |args|
    family = args[:family]
    family ? [family] : Picoride::BuilderImages::FAMILIES
  end

  desc "Build builder image(s) locally (family: esp32 or pico; default both)"
  task :build, [:family] do |_t, args|
    families.call(args).each do |family|
      tags = Picoride::BuilderImages.publish_tags(family).flat_map { |tag| ["-t", tag] }
      sh "docker", "build", *tags, Picoride::BuilderImages.dockerfile_dir(family)
    end
  end

  desc "Build multi-arch builder image(s) and push to Docker Hub (family: esp32 or pico; default both)"
  task :push, [:family] do |_t, args|
    platforms = ENV.fetch("PLATFORMS", "linux/amd64,linux/arm64")
    families.call(args).each do |family|
      tags = Picoride::BuilderImages.publish_tags(family).flat_map { |tag| ["-t", tag] }
      sh "docker", "buildx", "build", "--platform", platforms, "--push", *tags,
         Picoride::BuilderImages.dockerfile_dir(family)
    end
  end

  desc "Print the builder image names this version of picoride uses"
  task :images do
    Picoride::BuilderImages::FAMILIES.each do |family|
      puts "#{family}: #{Picoride::BuilderImages.image(family)}"
    end
  end
end
