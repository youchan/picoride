# ESP32(R2P2-ESP32)用のビルド専用イメージ(移行プラン フェーズ1)。
#
#   公開版: docker pull youchan/picoride-builder-esp32:<picorideのバージョン>(サーバーが自動でpullする)
#   ビルド/公開: rake docker:build[esp32] / rake docker:push[esp32](名前は lib/picoride/builder_images.rb)
#
# Raspberry Pi Pico用は docker/pico/Dockerfile(別イメージ)。picorideサーバーが
# プロジェクト設定のターゲットに応じてどちらのイメージで docker run するかを
# 切り替える(lib/picoride/server.rb の BUILDER_IMAGES 参照)。
#
# 旧来の Dockerfile はESP-IDFに加えてRuby/rbenv・R2P2-ESP32本体・Sinatraアプリまで
# 1つのイメージに焼き込んでいたが、「Sinatraはホストでネイティブに動かし、Dockerは
# idf.py build / rake setup_xxx の実行専用にする」という移行方針(CLAUDE.md参照)に
# 沿って、ここではESP-IDFツールチェインだけを持つ最小限のイメージにしてある。
#
# R2P2-ESP32本体は焼き込まない。プロジェクトごとに独立したビルド状態(sdkconfig・
# build/・managed_components等)を持たせたいため、実行時にホスト側の状態ディレクトリを
# `docker run -v <state_dir>:/R2P2-ESP32` でbind mountして使う想定(R2P2-ESP32の
# git clone・build_config.rbフックのパッチ・idf_component.ymlのバージョン固定は、
# ホスト側のRubyコードがそのstate_dirを初めて使うときに行う。イメージビルド時の
# `RUN`では実行できないため)。
FROM espressif/idf:v5.5.1

SHELL ["/bin/bash", "-c"]

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# R2P2-ESP32のrakelib/setup.rake(`rake setup_xxx`)は内部で`bundle install`を
# 呼び、そこでracc/ffi/io-console/json等ネイティブ拡張を持つgemをビルドしようと
# する。ベースイメージ(espressif/idf)にはコンパイラもRubyのヘッダファイルも
# 無いため、`mkmf.rb can't find header files for ruby`で失敗する(実際に
# `rake setup_esp32`を実行して発覚した)。ビルド専用イメージなので、
# Rubyそのものはベースイメージのシステムruby(apt由来)をそのまま使いつつ、
# 拡張のビルドに必要な最小限だけ追加する。
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ruby-dev \
    libssl-dev \
    libreadline-dev \
    zlib1g-dev \
    libyaml-dev \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# main/CMakeLists.txt の littlefs_create_partition_image(joltwallet/esp_littlefs、
# storageパーティションのイメージ作成に使う)は、ビルド時にvenvを作ってPyPIから
# littlefs-python をインストールする。ビルド実行時にネットワークが不安定だと
# ここでタイムアウトして失敗する(実際に発生した)。R2P2-ESP32側のmain/idf_component.yml
# で joltwallet/littlefs を 1.20.4 に固定する前提(この固定処理自体はR2P2-ESP32を
# プロジェクトごとにcloneするRuby側の処理に移した)で、image-building-requirements.txt
# の中身が littlefs-python==0.15.0 に一意に確定していることを利用し、これを
# イメージビルド時に取得して /opt/pip-wheels に置いておく。PIP_NO_INDEX/PIP_FIND_LINKS
# で「常にこのローカルディレクトリだけを見る」ようコンテナ全体のpipに指示することで、
# ビルド実行時はPyPIへの通信自体(バージョン解決の問い合わせも含めて)を発生させない。
#
# pip3(python3含む)はこのイメージだとentrypoint.sh(コンテナ起動時にのみ実行される)
# 経由でPATHに追加される、export.shが用意するESP-IDF専用のvenvにしか無い。
# `docker build`のRUNはentrypointを経由しない生のシェルなので、同じRUN内で
# 明示的にexport.shをsourceしないとpip3が見つからない(idf.py/rakeの実行時に
# 毎回export.shをsourceしているのと同じ理由)。
RUN . "${IDF_PATH}/export.sh" > /dev/null && pip3 download littlefs-python==0.15.0 -d /opt/pip-wheels

ENV PIP_NO_INDEX=1
ENV PIP_FIND_LINKS=/opt/pip-wheels

# bind mountしたディレクトリ(ホスト側の実UIDのまま見える)に対してgitコマンドを
# 実行すると、コンテナ内のユーザーとの所有者不一致でgitが「dubious ownership」
# エラーを出して拒否する(git 2.35.2以降のCVE-2022-24765対策)。実際に
# `rake setup_xxx`実行時に発生して発覚した。bind mountされたパスは実行のたびに
# 変わりうる(プロジェクトごとの状態ディレクトリ)ので、個別に許可するのではなく
# 全パスを許可しておく(このイメージはビルド専用の使い捨てコンテナ内でしか
# 使わないため、安全性への影響は無視できる)。
RUN git config --system --add safe.directory '*'

# R2P2-ESP32のrakelib/setup.rake(`rake setup_xxx`でmruby/picorubyをビルドする処理)は
# 内部で`bundle install`を呼ぶ。このイメージにはベースイメージ(espressif/idf)が
# 標準で持つRuby(bundlerはデフォルトgemとしてライブラリだけは入っているが、
# `bundle`コマンドの実行ファイルは生成されていない)がある。実際に`rake setup_esp32`
# を実行して`bundle: command not found`(exit 127)になったことで発覚した。
RUN gem install bundler --no-document

# R2P2-ESP32の状態ディレクトリをここへbind mountして使う想定のデフォルトWORKDIR。
WORKDIR /R2P2-ESP32
