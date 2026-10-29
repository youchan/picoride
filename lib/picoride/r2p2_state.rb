# プロジェクトごとに独立したR2P2-ESP32のビルド状態(sdkconfig・build/・
# managed_components等)を管理する。
#
# 以前は1つのR2P2-ESP32チェックアウトを全プロジェクトで共有していたが、
# ターゲットやVMが異なるプロジェクトを切り替えるたびに実質フルリビルドに
# なってしまう問題があったため、プロジェクトごとに独立したチェックアウトを
# 持たせる方式に変えた(詳細はCLAUDE.md参照)。
#
# 状態ディレクトリはプロジェクト本体の外(既定 ~/.picoride/r2p2-esp32/)に
# 置く。R2P2-ESP32はサイズが大きく、ユーザーのプロジェクト(gitリポジトリかもしれない)
# に混ざるべきではないため。
#
# 以前はDockerfileの`RUN`でイメージビルド時に1回だけ実行していたR2P2-ESP32の
# git clone・build_config.rbフックのパッチ・littlefsバージョン固定を、ここでは
# 「プロジェクトが初めてこの状態ディレクトリを使うとき」に動的に実行する処理として
# 素のRubyで書き直してある。シェルのクォート/エスケープに起因するバグ
# (このセッションで実際に2回踏んだ`\&\&`混入)を構造的に避けられるのが利点。
require "fileutils"
require "open3"

module Picoride
  module R2P2State
    R2P2_ESP32_REPO_URL = "https://github.com/picoruby/R2P2-ESP32.git"

    # components/picoruby-esp32/build_config/*.rb の `do |conf| ... end` ブロック末尾に
    # 差し込むフック。PROJECT_BUILD_CONFIG環境変数(未設定なら何もしない)が指す
    # Rubyファイルをconfのコンテキストで評価するだけで、本家の内容には一切手を
    # 加えない(詳細はapp.rbの generated_build_config_content 参照)。
    BUILD_CONFIG_HOOK_LINE =
      'conf.instance_eval(File.read(ENV["PROJECT_BUILD_CONFIG"]), ENV["PROJECT_BUILD_CONFIG"]) ' \
      'if ENV["PROJECT_BUILD_CONFIG"] && File.exist?(ENV["PROJECT_BUILD_CONFIG"])'

    # main/idf_component.yml は joltwallet/littlefs を "~=1.20.0"(レンジ指定)で
    # 依存させているため、実際に解決されるパッチバージョンが変わりうる
    # (1.20.0〜1.20.4の間でimage-building-requirements.txtの中身、つまり
    # littlefs-pythonのバージョンが変わることを確認済み)。バージョン解決そのものを
    # 不要にするため、実在を確認できた最新パッチ版に固定する
    # (Dockerfile側でこのバージョンのlittlefs-pythonをオフラインインストールできる
    # よう準備してあるので、揃える必要がある)。
    LITTLEFS_VERSION_FROM = 'joltwallet/littlefs: "~=1.20.0"'
    LITTLEFS_VERSION_TO = 'joltwallet/littlefs: "1.20.4"'

    # cloneとサブモジュール取得・パッチがすべて終わったことを示す目印(ESP32/Pico共通)。
    # 以前ESP32側は「.gitがあれば完了扱い」にしていたが、clone直後(サブモジュール
    # 取得中)にリクエストが中断されたり、取得中に別のリクエスト(ビルド/セットアップの
    # 再クリック)が来たりすると、サブモジュールが揃っておらずパッチも当たっていない
    # 状態のまま「完了」とみなされ、`rake`が`LoadError: cannot load such file --
    # mruby/core_ext`で失敗し続けた(mrubyはpicorubyのネストしたサブモジュール)。
    READY_MARKER = ".picoride-ready"

    # cloneは数分かかり、その間HTTPリクエスト(POST /api/build・/api/platform)を
    # 同期的に待たせている。同じ状態ディレクトリに対して2つ目のリクエストが来た場合は
    # 途中状態を使わせず、取得中である旨のエラーにする。
    CHECKOUT_LOCK = Mutex.new

    module_function

    # 状態ディレクトリが未完成ならgit clone/サブモジュール取得をし、必要なパッチを当てる。
    # 途中で失敗・中断していた場合も、次回呼び出し時に続きから再試行する
    # (cloneは.gitがあれば飛ばし、サブモジュール取得・パッチはどれも冪等)。
    def ensure_checkout(state_dir)
      return if File.file?(File.join(state_dir, READY_MARKER))

      with_checkout_lock do
        next if File.file?(File.join(state_dir, READY_MARKER))

        unless File.directory?(File.join(state_dir, ".git"))
          FileUtils.mkdir_p(File.dirname(state_dir))
          run!("git", "clone", "--depth", "1", R2P2_ESP32_REPO_URL, state_dir)
        end
        run!("git", "-C", state_dir, "submodule", "update", "--init", "--recursive")

        patch_build_config_hooks(state_dir)
        pin_littlefs_version(state_dir)
        File.write(File.join(state_dir, READY_MARKER), "")
      end
    end

    def with_checkout_lock
      raise "別のリクエストでソースを取得中です。完了してからもう一度実行してください" unless CHECKOUT_LOCK.try_lock

      begin
        yield
      ensure
        CHECKOUT_LOCK.unlock
      end
    end

    def patch_build_config_hooks(state_dir)
      glob = File.join(state_dir, "components", "picoruby-esp32", "build_config", "*.rb")
      Dir.glob(glob).each { |path| patch_build_config_hook(path) }
    end

    def patch_build_config_hook(path)
      content = File.read(path)
      return if content.include?("PROJECT_BUILD_CONFIG") # 冪等性: 既にパッチ済みなら何もしない

      stripped = content.rstrip
      raise "unexpected build_config format (no trailing 'end'): #{path}" unless stripped.end_with?("end")

      body = stripped[0..-4].rstrip # 末尾の "end" を取り除く
      File.write(path, "#{body}\n\n  #{BUILD_CONFIG_HOOK_LINE}\nend\n")
    end

    def pin_littlefs_version(state_dir)
      path = File.join(state_dir, "main", "idf_component.yml")
      content = File.read(path)
      patched = content.sub(LITTLEFS_VERSION_FROM, LITTLEFS_VERSION_TO)
      File.write(path, patched) if patched != content
    end

    def run!(*cmd)
      system(*cmd, exception: true)
    end

    # --- Raspberry Pi Pico(R2P2)用 -----------------------------------------
    #
    # R2P2(Raspberry Pi Pico版)は以前は独立リポジトリ(picoruby/R2P2)だったが、
    # picoruby本体に`picoruby-r2p2` gemとして統合された(旧リポジトリはアーカイブ扱い)。
    # そのため状態ディレクトリにはpicoruby本体をcloneし、ビルドはpicorubyの
    # `rake r2p2:{vm}:{board}:{mode}`(tasks/picoruby/r2p2.rake)で行う。
    #
    # pico-sdkはイメージ側(docker/pico/Dockerfile、/opt/pico-sdk)に焼き込んである
    # (picotoolのバージョンをSDKと揃える必要があり、両方イメージで固定したほうが
    # 確実なため)。picoruby側のサブモジュールのpico-sdk(と、エミュレータ用で
    # ビルドには不要なrp2040js)はcloneしない。
    PICORUBY_REPO_URL = "https://github.com/picoruby/picoruby.git"
    PICO_SKIPPED_SUBMODULES = %w[
      mrbgems/picoruby-r2p2/lib/pico-sdk
      mrbgems/picoruby-r2p2/lib/rp2040js
    ].freeze

    # 完了判定はESP32側と同じREADY_MARKERで行う。
    def ensure_pico_checkout(state_dir)
      return if File.file?(File.join(state_dir, READY_MARKER))

      with_checkout_lock do
        next if File.file?(File.join(state_dir, READY_MARKER))

        unless File.directory?(File.join(state_dir, ".git"))
          FileUtils.mkdir_p(File.dirname(state_dir))
          run!("git", "clone", "--depth", "1", PICORUBY_REPO_URL, state_dir)
        end

        submodules = pico_submodule_paths(state_dir) - PICO_SKIPPED_SUBMODULES
        run!("git", "-C", state_dir, "submodule", "update", "--init", "--recursive", "--", *submodules)

        patch_pico_build_config_hooks(state_dir)
        File.write(File.join(state_dir, READY_MARKER), "")
      end
    end

    def pico_submodule_paths(state_dir)
      out, status = Open3.capture2(
        "git", "-C", state_dir, "config", "-f", ".gitmodules", "--get-regexp", '\.path$'
      )
      raise "failed to read .gitmodules in #{state_dir}" unless status.success?

      out.lines.map { |line| line.split(" ", 2)[1].to_s.strip }.reject(&:empty?)
    end

    # picoruby/build_config/r2p2-{vm}-{board}.rb も R2P2-ESP32 と同じく
    # `MRuby::CrossBuild.new(...) do |conf| ... end` の形なので、同じフックを差し込む。
    def patch_pico_build_config_hooks(state_dir)
      Dir.glob(File.join(state_dir, "build_config", "r2p2-*.rb")).each { |path| patch_build_config_hook(path) }
    end
  end
end
