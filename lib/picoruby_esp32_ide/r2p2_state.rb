# プロジェクトごとに独立したR2P2-ESP32のビルド状態(sdkconfig・build/・
# managed_components等)を管理する。
#
# 以前は1つのR2P2-ESP32チェックアウトを全プロジェクトで共有していたが、
# ターゲットやVMが異なるプロジェクトを切り替えるたびに実質フルリビルドに
# なってしまう問題があったため、プロジェクトごとに独立したチェックアウトを
# 持たせる方式に変えた(詳細はCLAUDE.md参照)。
#
# 状態ディレクトリはプロジェクト本体の外(既定 ~/.picoruby-esp32-ide/r2p2-esp32/)に
# 置く。R2P2-ESP32はサイズが大きく、ユーザーのプロジェクト(gitリポジトリかもしれない)
# に混ざるべきではないため。
#
# 以前はDockerfileの`RUN`でイメージビルド時に1回だけ実行していたR2P2-ESP32の
# git clone・build_config.rbフックのパッチ・littlefsバージョン固定を、ここでは
# 「プロジェクトが初めてこの状態ディレクトリを使うとき」に動的に実行する処理として
# 素のRubyで書き直してある。シェルのクォート/エスケープに起因するバグ
# (このセッションで実際に2回踏んだ`\&\&`混入)を構造的に避けられるのが利点。
module PicorubyEsp32Ide
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

    module_function

    # 状態ディレクトリが無ければgit cloneし、必要なパッチを当てる。
    # 既にcloneされているディレクトリに対しては何もしない(パッチも初回のみ)。
    def ensure_checkout(state_dir)
      return if File.directory?(File.join(state_dir, ".git"))

      FileUtils.mkdir_p(File.dirname(state_dir))
      run!("git", "clone", "--depth", "1", R2P2_ESP32_REPO_URL, state_dir)
      run!("git", "-C", state_dir, "submodule", "update", "--init", "--recursive")

      patch_build_config_hooks(state_dir)
      pin_littlefs_version(state_dir)
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
  end
end
