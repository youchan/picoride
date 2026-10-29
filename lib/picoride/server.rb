# frozen_string_literal: true

require "sinatra/base"
require "json"
require "open3"
require "shellwords"
require "fileutils"
require "uri"
require_relative "background_job"
require_relative "r2p2_state"
require_relative "project_store"
require_relative "version"

module Picoride
  class Server < Sinatra::Base
    # 静的ファイル・ERBテンプレート・Funicular(ブラウザ側Ruby)はgemルートの
    # web/ 配下に置いている(lib/はサーバ側のRubyコード専用、exe/は実行ファイル専用)。
    WEB_ROOT = File.expand_path("../../web", __dir__)

    set :public_folder, File.join(WEB_ROOT, "public")
    set :views, File.join(WEB_ROOT, "views")

    if settings.development?
      set :static_cache_control, [:no_store, :no_cache, :must_revalidate]

      before do
        cache_control :no_store, :no_cache, :must_revalidate
      end
    else
      set :static_cache_control, [:public, max_age: 3600]

      before do
        cache_control :public, max_age: 3600
      end
    end

    # 編集対象のプロジェクト(app/・mrbgems/・build_config.rbを持つディレクトリ)。
    # 固定ディレクトリ・環境変数での既定値は持たず、UI(メニューバーのプロジェクト
    # 切り替えドロップダウン、または「ファイル」>「プロジェクトを開く」)から
    # 都度ユーザーが指定して開く方式にしてある(「よくあるファイルビューアの
    # ような見た目でディレクトリを探せるように」という要望でDirectoryBrowserDialog
    # 経由になっている)。
    #
    # 以前は「プロジェクトを束ねる"ワークスペース"ディレクトリを開き、その配下の
    # 複数プロジェクトから1つを選ぶ」という2階層構成だった(workspace_root +
    # project_root(name)で解決)。しかし「ワークスペース=プロジェクトだった」
    # というフィードバックにより、2階層は不要と判明し1階層に統合した: ここで
    # 開く・切り替えるディレクトリがそのままプロジェクト本体(project_root)になる。
    #
    # project_rootは「現在アクティブな」1つだけを指す。known_projectsは
    # 一度でも開いたプロジェクトの絶対パスを開いた順に積んだ配列で、
    # メニューバーのドロップダウンの選択肢になる(複数プロジェクトを開いておいて
    # ドロップダウンで切り替えたい、という要望)。
    #
    # project_settingsは絶対パス(known_projectsの要素)をキーに、そのプロジェクトの
    # ターゲット・VM・USB Console設定を持つHash(詳細は下の「プロジェクト設定」の
    # 節参照)。
    #
    # これら3つはいずれも`~/.picoride/project.toml`(ProjectStore)に永続化する
    # (一度開いたら覚えておいてほしい、再起動しても開かれた状態で起動してほしい、
    # という要望)。起動時にここで一度読み込んで初期値にし、変更するたびに
    # 書き戻す(ProjectStore.save参照)。
    class << self
      attr_accessor :project_root, :known_projects, :project_settings
    end
    loaded_projects = ProjectStore.load
    self.known_projects = loaded_projects[:paths]
    self.project_root = loaded_projects[:active]
    self.project_settings = loaded_projects[:settings]

    RUBY_ROOT = File.join(WEB_ROOT, "src")

    # プロジェクトごとに独立したR2P2-ESP32のビルド状態(sdkconfig・build/・
    # managed_components等)を置くディレクトリ名。「プロジェクトディレクトリの中に
    # 置きたい、gitには含めたくない、UI上のファイル一覧にも出したくない」という
    # 要望から、プロジェクト直下のドット始まりのディレクトリにしてある。
    # `.`始まりのパスは`Dir.glob("**/*")`が中身ごと辿らない(GET /api/files参照)ので、
    # 特別なフィルタ処理を書かなくてもUI上には出てこない。
    R2P2_STATE_DIRNAME = ".r2p2-esp32"

    # Raspberry Pi Pico用のビルド状態(picoruby本体のチェックアウト。R2P2は
    # picorubyに`picoruby-r2p2` gemとして統合されたため。r2p2_state.rb参照)。
    # ESP32用と同じ理由でプロジェクト直下のドット始まりのディレクトリにしてある。
    PICO_STATE_DIRNAME = ".r2p2-pico"

    # ターゲット(設定ダイアログの「ターゲット」)をファミリーごとに分けたもの。
    # ファミリーによって使うビルド用イメージ・状態ディレクトリ・ビルド手順が切り替わる。
    PLATFORM_FAMILIES = {
      "esp32" => %w[esp32 esp32c3 esp32c6 esp32h2 esp32p4 esp32s3],
      "pico" => %w[pico pico_w pico2 pico2_w]
    }.freeze
    PLATFORM_TARGETS = PLATFORM_FAMILIES.values.flatten.freeze

    # ターゲット未設定のプロジェクトは従来通りESP32として扱う(Pico対応以前に
    # 作られたプロジェクトの挙動を変えないため)。
    DEFAULT_PLATFORM_FAMILY = "esp32"

    # ファミリーごとのビルド専用イメージ(docker/esp32/Dockerfile・docker/pico/Dockerfile)。
    # Docker Hubの `youchan/picoride-builder-{esp32,pico}:<gemのバージョン>`
    # (接頭辞は version.rb の BUILDER_IMAGE_PREFIX)。自分でビルドしたイメージを
    # 使いたい場合は環境変数で丸ごと上書きできる(ESP32側は旧来の
    # PICORUBY_BUILDER_IMAGEも引き続き効く)。手元に無ければビルド開始時に自動で
    # `docker pull`する(builder_image_pull_command)ので、gemを使う人が
    # Dockerfileからイメージをビルドする必要はない。
    #
    # イメージの公開(タグ一覧・push)はgemに含めない rakelib/docker.rake の担当。
    BUILDER_IMAGES = {
      "esp32" => ENV["PICORIDE_ESP32_BUILDER_IMAGE"] || ENV["PICORUBY_BUILDER_IMAGE"] ||
                 "#{BUILDER_IMAGE_PREFIX}-esp32:#{VERSION}",
      "pico" => ENV["PICORIDE_PICO_BUILDER_IMAGE"] || "#{BUILDER_IMAGE_PREFIX}-pico:#{VERSION}"
    }.freeze

    # pullできなかったとき(未公開のバージョン・オフライン等)に案内する、
    # 自分でビルドする場合のDockerfileのディレクトリ。docker/ はgemにも
    # 同梱されるので、gemとしてインストールした場合もこの絶対パスで案内できる。
    BUILDER_DOCKERFILE_DIRS = BUILDER_IMAGES.keys.to_h do |family|
      [family, File.expand_path("../../docker/#{family}", __dir__)]
    end.freeze

    # ビルド専用コンテナの中で、プロジェクト本体・ビルド状態(R2P2-ESP32または
    # picoruby)をそれぞれbind mountする先の固定パス。ホスト側の実パスとコンテナ内
    # パスの対応はこれらの定数を通じて一箇所にまとめておく(builder_docker_command参照)。
    CONTAINER_PROJECT_MOUNT = "/project_src"
    CONTAINER_R2P2_MOUNT = "/R2P2-ESP32"
    CONTAINER_PICORUBY_MOUNT = "/picoruby"
    CONTAINER_STATE_MOUNTS = { "esp32" => CONTAINER_R2P2_MOUNT, "pico" => CONTAINER_PICORUBY_MOUNT }.freeze

    ALLOWED_EXTENSIONS = %w[.rb .c .h .rake].freeze

    # mrbgem名として許可する文字種。ディレクトリ名としてそのまま使うので、
    # パストラバーサルや意図しない特殊文字を避けるため英数字・アンダースコア・
    # ハイフンのみに絞ってある。
    MRBGEM_NAME_PATTERN = /\A[A-Za-z0-9_-]+\z/.freeze

    # 1プロジェクト = app/・mrbgems/・build_config.rbをまとめて持つディレクトリ、
    # という単位にしてある。
    APP_DIRNAME = "app"
    MRBGEMS_DIRNAME = "mrbgems"

    # 「ファイル」メニューからの新規ファイル/新規フォルダ作成は、実機の起動スクリプト
    # である app/ 配下だけに限定する(mrbgems/ 以下は「mrbgemを追加」が専用の雛形を
    # 用意するので対象外)。拡張子もRubyの.rbのみに絞る(app/はR2P2起動時にmain_task.rb
    # がloadするRubyスクリプト置き場であり、.c/.h/.rakeを置く場所ではないため)。
    NEW_FILE_EXTENSION = ".rb"

    # プロジェクト固有のビルド設定。ユーザーが直接編集できる普通のファイルという位置づけ
    # (以前はGemsダイアログが生成する専用ファイルだったが、mrbgemがプロジェクトの中に
    # 物理的に入るようになったことで、追加するmrbgemを選ぶUIは不要になった)。
    BUILD_CONFIG_FILENAME = "build_config.rb"

    # ビルド時にPROJECT_BUILD_CONFIG経由でR2P2-ESP32へ実際に渡すファイル。
    # mrbgems/以下から自動生成した`conf.gem gemdir:`の並びの後ろに、プロジェクトの
    # build_config.rbの内容をそのまま連結したもの(ユーザーが書いたbuild_config.rb自体は
    # 書き換えない)。
    GENERATED_BUILD_CONFIG_FILENAME = ".build_config.generated.rb"

    BUILD_JOB = BackgroundJob.new
    PLATFORM_JOB = BackgroundJob.new

    helpers do
      def project_root
        self.class.project_root
      end

      def known_projects
        self.class.known_projects
      end

      def project_settings
        self.class.project_settings
      end

      # 現在のプロジェクト(project_root)の設定。未保存(そのプロジェクトを
      # 一度も設定したことがない)なら「何も設定されていない」扱い
      # (platform/vmはnil、usb_consoleはfalse)にする。
      def read_project_config
        project_settings[project_root] || { "platform" => nil, "vm" => nil, "usb_console" => false }
      end

      # path traversal (../ などによる範囲外アクセス) を防ぎつつ絶対パスに変換する
      def safe_path(root, rel_path)
        full = File.expand_path(File.join(root, rel_path.to_s))
        root_with_sep = root + File::SEPARATOR
        unless full == root || full.start_with?(root_with_sep)
          raise ArgumentError, "invalid path"
        end
        full
      end

      # プロジェクトのR2P2-ESP32状態ディレクトリの絶対パス。
      def r2p2_state_dir(root)
        File.join(root, R2P2_STATE_DIRNAME)
      end

      # ターゲット名 → ファミリー("esp32"/"pico")。未設定はDEFAULT_PLATFORM_FAMILY。
      def platform_family(platform)
        return DEFAULT_PLATFORM_FAMILY if platform.to_s.empty?

        PLATFORM_FAMILIES.each { |family, targets| return family if targets.include?(platform) }
        DEFAULT_PLATFORM_FAMILY
      end

      # 現在のプロジェクト設定のファミリー。
      def current_platform_family
        platform_family(read_project_config["platform"])
      end

      # ファミリーごとのビルド状態ディレクトリの絶対パス。
      def build_state_dir(root, family)
        File.join(root, family == "pico" ? PICO_STATE_DIRNAME : R2P2_STATE_DIRNAME)
      end

      # .gitignoreを(プロジェクト内に無ければ作成、あれば足りない行だけ追記して)
      # 用意する。R2P2-ESP32の状態やビルド生成物をプロジェクトのgit管理に含めたくない、
      # という要望から、プロジェクトの中に状態を置くようにした以上セットで必要になる。
      # 既存の.gitignoreの中身(ユーザー自身が書いた分)は壊さない。
      def ensure_project_gitignore(root)
        entries = ["#{R2P2_STATE_DIRNAME}/", "#{PICO_STATE_DIRNAME}/", GENERATED_BUILD_CONFIG_FILENAME]
        path = File.join(root, ".gitignore")
        existing = File.file?(path) ? File.read(path) : ""
        existing_lines = existing.lines.map(&:chomp)
        missing = entries.reject { |entry| existing_lines.include?(entry) }
        return if missing.empty?

        File.open(path, "a") do |f|
          f.puts if !existing.empty? && !existing.end_with?("\n")
          missing.each { |entry| f.puts(entry) }
        end
      end

      # 新しく開いた(あるいは初めて開く)プロジェクトに、起動スクリプトの土台
      # (app/app.rb)とビルド設定ファイル(build_config.rb)を空で用意しておく。
      # 以前の「新しいプロジェクト」(ワークスペース配下に名前でサブディレクトリを
      # 作る機能)が担っていた雛形作成を、「プロジェクトを開く」
      # (DirectoryBrowserDialogで任意のディレクトリを指定・新規フォルダ作成して
      # 開く)に統合したもの。
      #
      # **空のディレクトリのときだけ**生成する(rootが完全に空かどうかをDir.empty?で
      # 判定)。最初は「app/app.rb・build_config.rbが無ければ(他に何があっても)
      # 作る」という実装にしていたが、間違って1階層上の(本来のプロジェクトを
      # サブディレクトリとして含む)ディレクトリを開いてしまった場合に、そこへ
      # 無関係な空のapp/・build_config.rbを生成してしまい、ファイルツリーに
      # 「正しいプロジェクトのサブディレクトリ」と「誤って生成された空のapp/」が
      # 並んで表示される、という実際の事故が起きた。ディレクトリに何かしら既存の
      # 中身がある場合は「間違ったディレクトリを開いた可能性がある」とみなして
      # 何もしない(空ディレクトリ=新規作成したばかりで明らかに安全、という
      # ケースだけに絞る)。
      def ensure_project_scaffold(root)
        return unless Dir.empty?(root)

        FileUtils.mkdir_p(File.join(root, APP_DIRNAME))
        File.write(File.join(root, APP_DIRNAME, "app.rb"), "")
        File.write(File.join(root, BUILD_CONFIG_FILENAME), "")
      end

      def json_error(status, message)
        halt status, { error: message }.to_json
      end

      def valid_name?(name)
        name.is_a?(String) && MRBGEM_NAME_PATTERN.match?(name)
      end

      # 新規ファイル/フォルダの作成・削除で使う相対パスのチェック。safe_pathの
      # パストラバーサル対策に加えて、ドット始まりのセグメント(R2P2_STATE_DIRNAME・
      # GENERATED_BUILD_CONFIG_FILENAME等、UI上のファイル一覧に出さない前提の
      # ものと衝突しうる)や空セグメントを拒否する。
      def valid_relative_path?(rel)
        return false if rel.nil? || rel.empty?

        segments = rel.split("/")
        segments.each do |seg|
          return false if seg.empty? || seg == "." || seg == ".." || seg.start_with?(".")
        end
        true
      end

      def under_app_dir?(rel)
        prefix = "#{APP_DIRNAME}/"
        rel.start_with?(prefix) && rel.length > prefix.length
      end

      # 新規ファイル/新規フォルダを作れる場所かどうか。以前はapp/配下限定だったが、
      # 「ツリーのどのフォルダでも作成できるように、ただしmrbgems/直下は不可」
      # という要望で広げた。
      # - プロジェクト直下(app/・mrbgems/・build_config.rbと同じ階層)には作らない
      # - mrbgems/直下には作らない(mrbgemは「mrbgemを追加」で雛形ごと作る)。
      #   mrbgems/<gem>/以下は、そのgemのディレクトリが既に存在する場合だけ許可する
      #   (パスの途中で新しいgemディレクトリが勝手にできてしまわないように)
      def creatable_path?(rel)
        segments = rel.split("/")
        return false if segments.length < 2
        return true unless segments.first == MRBGEMS_DIRNAME

        segments.length >= 3 && File.directory?(File.join(project_root, MRBGEMS_DIRNAME, segments[1]))
      end

      # 新規ファイルに許可する拡張子。app/はR2P2起動時にloadされるRubyスクリプト
      # 置き場なので.rbのみ、それ以外(mrbgemのmrblib/・src/等)は編集できる
      # 拡張子(ALLOWED_EXTENSIONS)すべて。
      def creatable_extension?(rel)
        ext = File.extname(rel)
        under_app_dir?(rel) ? ext == NEW_FILE_EXTENSION : ALLOWED_EXTENSIONS.include?(ext)
      end
    end

    # プロジェクトが開かれていなくても使える/api/*(プロジェクト自体を開くための
    # エンドポイント群)。残りの/api/*はプロジェクト(project_root)が開かれていないと
    # 処理できないので、ここで先に弾いておくことで、各ルートで個別にnilチェックを
    # 書かずに済む。
    PROJECT_EXEMPT_API_PATHS = ["/api/project", "/api/browse"].freeze

    # パターン付きbefore(例: `before %r{...}`)にすると、Sinatraがそのパターンを
    # ルーティングエンジン(Mustermann)でコンパイルしようとする。Mustermannは
    # 独自に文字列全体へのアンカーを付与する実装になっていて、渡した正規表現が
    # (`\A`/`\z`はおろか`^`/`$`でも)既にアンカーを含むと
    # `Mustermann::CompileError`になる(実際に起動して確認した)。パターン無しの
    # `before do ... end`にして、Mustermannを経由しない素のRubyの文字列比較で
    # パスを判定する。
    before do
      next unless request.path_info.start_with?("/api/") &&
                  !PROJECT_EXEMPT_API_PATHS.include?(request.path_info)

      content_type :json
      json_error(400, "project is not open") unless project_root
    end

    get "/" do
      erb :index
    end

    # Funicular アプリの Ruby ソース。
    get %r{/ruby/(.+\.rb)} do |rel|
      full = File.expand_path(File.join(RUBY_ROOT, rel))
      root_with_sep = RUBY_ROOT + File::SEPARATOR

      json_error(400, "invalid path") unless full.start_with?(root_with_sep)
      halt 404 unless File.file?(full)

      content_type "text/plain", charset: "utf-8"
      File.read(full)
    end

    # 現在開いているプロジェクト(絶対パス、未設定ならnull)と、このセッションで
    # 一度でも開いたプロジェクトの一覧(known、メニューバーのドロップダウンの
    # 選択肢)を返す。before フィルタの対象外にしてある唯一の/api/*エンドポイント。
    get "/api/project" do
      content_type :json
      { path: project_root, known: known_projects }.to_json
    end

    # プロジェクトを開く(新規に指定した場合)、または既にknown_projectsに
    # あるものへ切り替える(どちらも同じエンドポイントで、違いは渡されたpathが
    # 既知かどうかだけ)。body(JSON): { path: "/abs/path/to/dir" }。
    # 既存の(あるいはこれから使う)ディレクトリを指定するだけで良く、空の
    # ディレクトリであってもensure_project_scaffoldが起動スクリプトの土台を
    # 用意する。
    post "/api/project" do
      content_type :json

      payload =
        begin
          JSON.parse(request.body.read)
        rescue JSON::ParserError
          json_error(400, "invalid json body")
        end

      path = payload["path"].to_s.strip
      json_error(400, "path is required") if path.empty?

      full = File.expand_path(path)
      json_error(400, "directory does not exist") unless File.directory?(full)

      ensure_project_scaffold(full)

      self.class.project_root = full
      self.class.known_projects << full unless known_projects.include?(full)
      ProjectStore.save(active: project_root, paths: known_projects, settings: project_settings)

      { status: "ok", path: full, known: known_projects }.to_json
    end

    # --- ディレクトリブラウザ(「プロジェクトを開く」のフォルダ選択UI) ---------
    #
    # プロジェクトの絶対パスを一行のテキストで入力させる代わりに、「よくある
    # ファイルビューア」のようにディレクトリを辿って選べるようにするためのAPI。
    # プロジェクト自体をまだ開いていない状態でも使える必要がある(これを使って
    # プロジェクトを開くため)ので、PROJECT_EXEMPT_API_PATHSに/api/browseを
    # 含めてある。GET /api/files等(開いているプロジェクト内の対象拡張子の
    # ファイル一覧)とは別物: ここではファイルシステム上の任意の場所の
    # サブディレクトリだけを列挙する(どのプロジェクトにも属さない)。

    # ドット始まりのディレクトリ(.git・.cache等)は、プロジェクト内のファイル
    # 一覧(GET /api/files等)と同じ理由で一覧から除外し、見た目をすっきりさせる。
    def list_browse_entries(path)
      names = Dir.children(path).select do |name|
        !name.start_with?(".") && File.directory?(File.join(path, name))
      end
      names.sort.map { |name| { name: name, path: File.join(path, name) } }
    end

    # ファイルシステムのルート("/")では".."しても自分自身になるので、
    # その場合はparentをnilにして「これ以上は上がれない」ことを表す。
    def browse_parent(path)
      parent = File.expand_path(File.join(path, ".."))
      parent == path ? nil : parent
    end

    # 指定ディレクトリ(省略時はホームディレクトリ)のサブディレクトリ一覧を返す。
    # 「最初はホームディレクトリが開いている状態で」という要望により、
    # pathが空ならDir.home(Linux上は$HOME)を使う。
    get "/api/browse" do
      content_type :json

      raw = params[:path].to_s.strip
      full = raw.empty? ? Dir.home : File.expand_path(raw)

      json_error(400, "directory does not exist") unless File.directory?(full)

      entries =
        begin
          list_browse_entries(full)
        rescue Errno::EACCES
          json_error(400, "permission denied")
        end

      { path: full, parent: browse_parent(full), entries: entries }.to_json
    end

    # 新しいフォルダを作成する。body(JSON): { path: "親ディレクトリの絶対パス", name: "新しいフォルダ名" }。
    # 「新しいフォルダ」ボタンを押す動機は大抵そこを開きたいからなので、
    # 作成後はそのフォルダ自身をGETと同じ形(path/parent/entries)で返し、
    # フロント側はそのままそこへ移動したものとして扱う。
    post "/api/browse" do
      content_type :json

      payload =
        begin
          JSON.parse(request.body.read)
        rescue JSON::ParserError
          json_error(400, "invalid json body")
        end

      parent_path = payload["path"].to_s.strip
      json_error(400, "path is required") if parent_path.empty?

      full_parent = File.expand_path(parent_path)
      json_error(400, "directory does not exist") unless File.directory?(full_parent)

      name = payload["name"].to_s.strip
      json_error(400, "name is required") if name.empty?
      json_error(400, "invalid name") if name.include?("/") || name == "." || name == ".."

      full = File.join(full_parent, name)
      json_error(409, "already exists") if File.exist?(full)

      begin
        Dir.mkdir(full)
      rescue Errno::EACCES
        json_error(400, "permission denied")
      end

      entries =
        begin
          list_browse_entries(full)
        rescue Errno::EACCES
          []
        end

      { path: full, parent: full_parent, entries: entries }.to_json
    end

    # 編集可能なファイル一覧を返す(現在開いているプロジェクト内)
    get "/api/files" do
      content_type :json

      files = Dir.glob(File.join(project_root, "**", "*")).select do |f|
        File.file?(f) && ALLOWED_EXTENSIONS.include?(File.extname(f))
      end

      relative_paths = files.map { |f| f.sub(project_root + File::SEPARATOR, "") }.sort

      relative_paths.to_json
    end

    # ディレクトリ一覧を返す。GET /api/files はファイルの並びからツリーを
    # 組み立てる都合上、中身が空のディレクトリを表現できない(TreeView側は
    # state[:files]から導出したノードしか描画しないため)。新規フォルダ作成
    # (POST /api/folders)で空のフォルダを作れるようになったことでこれが
    # 表面化するため、ディレクトリ一覧だけは別に取得できるようにしてある。
    # ドット始まりのディレクトリ(.r2p2-esp32等)は GET /api/files と同じ理由
    # (Dir.globの既定動作)で自動的に除外される。
    get "/api/dirs" do
      content_type :json

      dirs = Dir.glob(File.join(project_root, "**", "*")).select { |f| File.directory?(f) }
      relative_paths = dirs.map { |f| f.sub(project_root + File::SEPARATOR, "") }.sort

      relative_paths.to_json
    end

    # 指定ファイルの内容を返す
    get "/api/file" do
      content_type :json

      rel = params[:path]
      json_error(400, "path is required") if rel.nil? || rel.empty?

      full =
        begin
          safe_path(project_root, rel)
        rescue ArgumentError
          json_error(400, "invalid path")
        end

      json_error(404, "file not found") unless File.file?(full)
      json_error(400, "unsupported file type") unless ALLOWED_EXTENSIONS.include?(File.extname(full))

      { path: rel, content: File.read(full) }.to_json
    end

    # ファイル内容を保存する
    post "/api/file" do
      content_type :json

      payload =
        begin
          JSON.parse(request.body.read)
        rescue JSON::ParserError
          json_error(400, "invalid json body")
        end

      rel = payload["path"]
      content = payload["content"]

      json_error(400, "path is required") if rel.nil? || rel.empty?
      json_error(400, "content is required") if content.nil?

      full =
        begin
          safe_path(project_root, rel)
        rescue ArgumentError
          json_error(400, "invalid path")
        end

      # 既存ファイルの上書きのみ許可(新規ファイル作成はサンプルでは対象外)
      json_error(404, "file not found") unless File.file?(full)
      json_error(400, "unsupported file type") unless ALLOWED_EXTENSIONS.include?(File.extname(full))

      File.write(full, content)

      { status: "ok", path: rel, bytes: content.bytesize }.to_json
    end

    # 新規ファイルを作成する(空ファイル)。POST /api/fileは既存ファイルの上書きしか
    # 許可していないので、新規作成はこちらに分けてある。
    post "/api/files" do
      content_type :json

      payload =
        begin
          JSON.parse(request.body.read)
        rescue JSON::ParserError
          json_error(400, "invalid json body")
        end

      rel = payload["path"].to_s
      json_error(400, "path is required") if rel.empty?
      json_error(400, "invalid path") unless valid_relative_path?(rel)
      json_error(400, "cannot create files here") unless creatable_path?(rel)
      unless creatable_extension?(rel)
        allowed = under_app_dir?(rel) ? [NEW_FILE_EXTENSION] : ALLOWED_EXTENSIONS
        json_error(400, "unsupported file type (allowed: #{allowed.join(' ')})")
      end

      full =
        begin
          safe_path(project_root, rel)
        rescue ArgumentError
          json_error(400, "invalid path")
        end

      json_error(409, "file already exists") if File.exist?(full)

      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "")

      { status: "ok", path: rel }.to_json
    end

    # 新規フォルダを作成する(空ディレクトリ)。作れる場所は新規ファイルと同じ(creatable_path?)。
    post "/api/folders" do
      content_type :json

      payload =
        begin
          JSON.parse(request.body.read)
        rescue JSON::ParserError
          json_error(400, "invalid json body")
        end

      rel = payload["path"].to_s
      json_error(400, "path is required") if rel.empty?
      json_error(400, "invalid path") unless valid_relative_path?(rel)
      json_error(400, "cannot create folders here") unless creatable_path?(rel)

      full =
        begin
          safe_path(project_root, rel)
        rescue ArgumentError
          json_error(400, "invalid path")
        end

      json_error(409, "folder already exists") if File.exist?(full)

      FileUtils.mkdir_p(full)

      { status: "ok", path: rel }.to_json
    end

    # ファイルを削除する。ツリーのコンテキストメニュー(「削除」)から呼ばれる。
    # 新規作成とは違いapp/配下に限定しない(mrbgemの.c/.h等、プロジェクト内の
    # ALLOWED_EXTENSIONSファイルであればどこでも削除できる)。
    delete "/api/files" do
      content_type :json

      rel = params[:path].to_s
      json_error(400, "path is required") if rel.empty?

      full =
        begin
          safe_path(project_root, rel)
        rescue ArgumentError
          json_error(400, "invalid path")
        end

      json_error(404, "file not found") unless File.file?(full)
      json_error(400, "unsupported file type") unless ALLOWED_EXTENSIONS.include?(File.extname(full))

      File.delete(full)

      { status: "ok", path: rel }.to_json
    end

    # フォルダを再帰的に削除する。app/自身・mrbgems/自身は構造上必須
    # (app/はR2P2起動スクリプトの置き場所、mrbgems/は「mrbgemを追加」専用の
    # 置き場所)なので削除させない。UIのコンテキストメニューでもこの2つには
    # 「削除」を出していないが、APIを直接叩かれた場合の防御として二重にチェックする。
    delete "/api/folders" do
      content_type :json

      rel = params[:path].to_s
      json_error(400, "path is required") if rel.empty?
      json_error(400, "invalid path") unless valid_relative_path?(rel)
      json_error(400, "cannot delete this folder") if rel == APP_DIRNAME || rel == MRBGEMS_DIRNAME

      full =
        begin
          safe_path(project_root, rel)
        rescue ArgumentError
          json_error(400, "invalid path")
        end

      json_error(404, "folder not found") unless File.directory?(full)

      FileUtils.rm_rf(full)

      { status: "ok", path: rel }.to_json
    end

    # --- プロジェクト設定(ターゲット・VM・USB Console) ----------------------
    #
    # 以前はビルドボタンを押すたびにダイアログでVM/USB Consoleを選ばせ、ターゲット
    # チップはメニューバーの常設セレクトで選ぶ形だったが、「プロジェクトの設定として
    # プロジェクトに含めたい」というフィードバックを受けて、プロジェクトごとに
    # 隠しファイル`.config.yml`へ永続化する方式に変更した。その後「設定はワークスペース
    # (当時はプロジェクトの上位概念だった)毎に持たせてほしい」という要望で
    # `~/.picoride/workspace.toml`へ移し、さらに「ワークスペース=プロジェクトだった」
    # というフィードバックで2階層構成自体を1階層に統合した結果、現在は単純に
    # 「開いているプロジェクトの設定」として`~/.picoride/project.toml`
    # (ProjectStore、project_root/known_projectsと同じファイル)に永続化している。
    # UI側は「設定」ダイアログで編集し、ビルド/プラットフォームセットアップは
    # その時点の設定値をそのまま使って即座に実行するだけになる。

    get "/api/project/config" do
      content_type :json
      read_project_config.to_json
    end

    # body(JSON): { platform:, vm:, usb_console: } — platform/vmはnull(未選択)も許可
    post "/api/project/config" do
      content_type :json

      payload =
        begin
          JSON.parse(request.body.read)
        rescue JSON::ParserError
          json_error(400, "invalid json body")
        end

      platform = payload["platform"]
      json_error(400, "invalid platform") if platform && !PLATFORM_TARGETS.include?(platform)

      vm = payload["vm"]
      json_error(400, "invalid vm") if vm && !BUILD_VM_FLAGS.key?(vm)
      if vm && platform_family(platform) == "pico" && !PICO_BOARD_VMS.fetch(platform).include?(vm)
        json_error(400, "#{platform} では #{vm} を使えません(使えるVM: #{PICO_BOARD_VMS.fetch(platform).join(', ')})")
      end

      config = { "platform" => platform, "vm" => vm, "usb_console" => payload["usb_console"] == true }
      self.class.project_settings = project_settings.merge(project_root => config)
      ProjectStore.save(active: project_root, paths: known_projects, settings: project_settings)

      { status: "ok" }.to_json
    end

    # --- mrbgemのビルド組み込み -------------------------------------------
    #
    # R2P2-ESP32本体のbuild_config(components/picoruby-esp32/build_config/*.rb)は
    # xtensa/riscv・femtoruby/picoruby の組み合わせで4種あり、ツールチェイン設定など
    # 込み入った内容を持つ。これをプロジェクトごとに複製すると本家の変更に追従できなく
    # なるため、複製はせず「本家の設定を評価した最後に、プロジェクト側の追加/除外だけを
    # 差し込む」フックをDockerfileで1行だけ本家4ファイルに追加している(該当箇所は
    # `conf.instance_eval(File.read(ENV['PROJECT_BUILD_CONFIG'])) if ...`)。
    #
    # mrbgems/以下にあるものは全部自動でビルドに含める(選ぶUIは無い)。
    # プロジェクトの中に物理的にmrbgemを置く=そのプロジェクトで使う、という構造そのものが
    # 選択を兼ねているので、ビルドのたびに`generated_build_config_content`で
    # 「その時点でmrbgems/以下にあるgem一覧」から`conf.gem gemdir:`の並びを作り、
    # その後ろにプロジェクトのbuild_config.rb(デフォルトgemを外したい場合はここに
    # `conf.gems.reject!`を書く、普通の編集可能ファイル)をそのまま連結したものを
    # PROJECT_BUILD_CONFIG経由で渡す。gemdir(自作mrbgemの絶対パス)は常にコンテナ内の
    # 絶対パスで書く(相対パス解決の基点があいまいなmruby側の挙動に依存しないため)。

    # mrbgems/直下のディレクトリ名一覧を返す(存在チェック・列挙はホスト側のrootを見る)。
    def project_mrbgem_names(root)
      mrbgems_dir = File.join(root, MRBGEMS_DIRNAME)
      return [] unless Dir.exist?(mrbgems_dir)

      Dir.children(mrbgems_dir).select { |name| File.directory?(File.join(mrbgems_dir, name)) }.sort
    end

    # 「mrbgemを追加」で作るmrbgem.rakeのテンプレート。gem名は作成したmrbgemの名前、
    # licenseはMITを入れ、authorとsummaryはユーザーが書き換えるプレースホルダーにしてある。
    # nameはvalid_name?(英数字・_・-のみ)を通っているのでシングルクォートにそのまま埋め込める。
    MRBGEM_AUTHOR_PLACEHOLDER = "YOUR NAME"
    MRBGEM_SUMMARY_PLACEHOLDER = "TODO: Write a short summary of this mrbgem"

    def mrbgem_rake_content(name)
      <<~RUBY
        MRuby::Gem::Specification.new('#{name}') do |spec|
          spec.license = 'MIT'
          spec.author  = '#{MRBGEM_AUTHOR_PLACEHOLDER}'
          spec.summary = '#{MRBGEM_SUMMARY_PLACEHOLDER}'
        end
      RUBY
    end

    # mrbgems/以下に新しいmrbgemの雛形(mrbgem.rake・mrblib/<name>.rb)を作る。
    # ここに置くだけで次回ビルドから自動的に組み込まれる
    # (generated_build_config_content参照。選ぶUIは無い)。
    post "/api/mrbgems" do
      content_type :json

      payload =
        begin
          JSON.parse(request.body.read)
        rescue JSON::ParserError
          json_error(400, "invalid json body")
        end

      gem_name = payload["name"].to_s
      json_error(400, "invalid mrbgem name") unless valid_name?(gem_name)

      gem_dir = File.join(project_root, MRBGEMS_DIRNAME, gem_name)
      json_error(409, "mrbgem already exists") if File.exist?(gem_dir)

      FileUtils.mkdir_p(File.join(gem_dir, "mrblib"))
      File.write(File.join(gem_dir, "mrbgem.rake"), mrbgem_rake_content(gem_name))
      File.write(File.join(gem_dir, "mrblib", "#{gem_name}.rb"), "")

      { status: "ok", name: gem_name }.to_json
    end

    def generated_build_config_content(root)
      lines = ["# picoride が自動生成する部分(#{MRBGEMS_DIRNAME}/以下のgemを追加する)"]
      project_mrbgem_names(root).each do |name|
        # gemdirはビルドコンテナの中から見たパス(CONTAINER_PROJECT_MOUNT配下)で書く。
        # ホスト側の実パスではない点に注意(builder_docker_commandでproject_srcとしてマウントする)。
        container_path = File.join(CONTAINER_PROJECT_MOUNT, MRBGEMS_DIRNAME, name)
        lines << "conf.gem gemdir: #{container_path.inspect}"
      end

      build_config_path = File.join(root, BUILD_CONFIG_FILENAME)
      if File.file?(build_config_path)
        lines << ""
        lines << "# ここから下は #{BUILD_CONFIG_FILENAME} の内容"
        lines << File.read(build_config_path)
      end

      lines.join("\n") + "\n"
    end

    # ビルド専用コンテナ(ファミリーごとのBUILDER_IMAGES)を使い捨てで起動し、
    # その中でinner_cmdを実行するコマンド文字列を組み立てる。state_dir(プロジェクト
    # ごとのビルド状態。ESP32ならR2P2-ESP32、Picoならpicoruby本体)を
    # CONTAINER_STATE_MOUNTS[family]に、project_root(mrbgems/やapp/を含む
    # プロジェクト本体)をCONTAINER_PROJECT_MOUNTにbind mountする。
    #
    # ESP32では idf.py / rake が ESP-IDF の export.sh を読み込んだシェルでしか
    # 使えないため、コンテナ内で明示的に読み込んでから inner_cmd を実行する
    # (Pico用イメージはPATH・PICO_SDK_PATHがENVで設定済みなので不要)。
    #
    # コンテナは(`--user`を付けず)デフォルトのrootで動かす。rakelib/setup.rakeが
    # 内部で呼ぶ`bundle install`がシステムのgemディレクトリ(/var/lib/gems/...)へ
    # 書き込む必要があり、`--user <非root>`にすると権限エラーで失敗することを
    # 実際に確認したため(root専用のシステムgemパスを使っている以上、非rootでは
    # そもそも動かせない)。その代わり、bind mountしたstate_dir配下がroot所有のまま
    # ホストに残ってプロジェクトディレクトリの持ち主(ホストユーザー)から扱いにくく
    # なる問題を避けるため、コマンド完了後に必ず`chown`でホストユーザーの所有に戻す
    # (`;`でつないでinner_cmdの成否に関わらず実行し、`inner_cmd`自体の終了コードは
    # `$?`で保持して最後に`exit`し直すことで、chown自体の成否でBUILD_JOBの成功/失敗
    # 判定が変わらないようにしている)。
    def builder_docker_command(family, state_dir, project_dir, inner_cmd)
      state_mount = CONTAINER_STATE_MOUNTS.fetch(family)
      chown_target = "#{Process.uid}:#{Process.gid}"
      env_setup = family == "esp32" ? ". \"$IDF_PATH/export.sh\" > /dev/null && " : ""
      full_inner_cmd =
        "#{env_setup}cd #{Shellwords.escape(state_mount)} && " \
        "#{inner_cmd}; " \
        "exit_code=$?; " \
        "chown -R #{chown_target} #{Shellwords.escape(state_mount)}; " \
        "exit $exit_code"

      "#{builder_image_pull_command(family)}" \
        "docker run --rm " \
        "-v #{Shellwords.escape(state_dir)}:#{state_mount} " \
        "-v #{Shellwords.escape(project_dir)}:#{CONTAINER_PROJECT_MOUNT} " \
        "#{Shellwords.escape(BUILDER_IMAGES.fetch(family))} " \
        "bash -c #{Shellwords.escape(full_inner_cmd)}"
    end

    # ファミリーのビルド用イメージがローカルに存在するかどうか。
    def builder_image_available?(family)
      system("docker", "image", "inspect", BUILDER_IMAGES.fetch(family), out: File::NULL, err: File::NULL)
    end

    # イメージが手元に無ければ、docker runの前に`docker pull`するコマンド片を返す
    # (あれば空文字)。以前は「イメージが無ければ500エラーでdocker buildを案内する」
    # だったが、Docker Hubにイメージを公開したことで、初回ビルド時に自動で取ってくる
    # ようにした。pullはBackgroundJobの中で走るので、進捗はビルドログにそのまま出る
    # (数GBあるのでHTTPリクエストの中で同期的にpullするとタイムアウトしてしまう)。
    # pullに失敗したら(未公開のバージョン・オフライン等)、自分でビルドする方法を
    # ログに出して終了する。
    def builder_image_pull_command(family)
      return "" if builder_image_available?(family)

      image = Shellwords.escape(BUILDER_IMAGES.fetch(family))
      found_msg = Shellwords.escape("==> ビルド用イメージ #{BUILDER_IMAGES.fetch(family)} が手元に無いので " \
        "docker pull します(初回のみ。数GBあるので時間がかかります)")
      fail_msg = Shellwords.escape("==> docker pull に失敗しました。ネットワークを確認するか、" \
        "自分でビルドしてください: docker build -t #{BUILDER_IMAGES.fetch(family)} " \
        "#{BUILDER_DOCKERFILE_DIRS.fetch(family)}")
      "echo #{found_msg}; docker pull #{image} || { echo #{fail_msg}; exit 1; }; "
    end

    # R2P2State.ensure_checkout / ensure_pico_checkout は git clone 等に失敗すると
    # 例外を投げる(R2P2State.run! 参照)。Sinatraのリクエストハンドラ内で素通しすると
    # 生の500になってしまうので、json_errorでラップする。
    def ensure_build_checkout!(family, state_dir)
      if family == "pico"
        R2P2State.ensure_pico_checkout(state_dir)
      else
        R2P2State.ensure_checkout(state_dir)
      end
    rescue StandardError => e
      name = family == "pico" ? "picoruby(R2P2)" : "R2P2-ESP32"
      json_error(500, "#{name}のセットアップに失敗しました: #{e.message}")
    end

    # R2P2-ESP32 のビルド状態(実行中/成功/失敗/未実行)とログを返す。
    # UI 側はこれをポーリングして進捗を表示する。
    get "/api/build" do
      content_type :json
      BUILD_JOB.to_response_json(offset: params["offset"], run_id: params["run_id"])
    end

    # idf.py build -DPICORB_VM=xxx に渡すフラグ(R2P2-ESP32/Rakefile の PICORB_VMS と同じ対応)。
    BUILD_VM_FLAGS = { "femtoruby" => "mrubyc", "picoruby" => "mruby" }.freeze

    # Pico各ボードで使えるVM(picoruby/build_config/r2p2-{vm}-{board}.rb が存在する組み合わせ。
    # RP2040(pico/pico_w)はmruby VMのビルド設定が無い)。先頭がVM未指定時の既定値。
    PICO_BOARD_VMS = {
      "pico" => %w[femtoruby],
      "pico_w" => %w[femtoruby],
      "pico2" => %w[femtoruby picoruby],
      "pico2_w" => %w[femtoruby picoruby]
    }.freeze

    # Picoのビルドモード(`rake r2p2:{vm}:{board}:{mode}`のmode)。IDEからは
    # 配布用のprodだけを使う(debugはUART経由のデバッグ出力等、開発者向け)。
    PICO_BUILD_MODE = "prod"

    # 外部USB-UART変換チップを持たないボード向けの設定フラグメント
    # (R2P2-ESP32/sdkconfigs/usb_console、README.md「Hardware-specific Configuration」参照)。
    USB_CONSOLE_SDKCONFIG_DEFAULTS = "sdkconfig.defaults;sdkconfigs/usb_console"

    # 現在の sdkconfig が USB Console設定でビルドされているかどうか。
    # sdkconfigが無い(セットアップ直後、または一度もビルドしていない)場合はfalse扱い。
    def sdkconfig_has_usb_console?(state_dir)
      sdkconfig_path = File.join(state_dir, "sdkconfig")
      return false unless File.file?(sdkconfig_path)

      File.foreach(sdkconfig_path).any? { |line| line.start_with?("CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y") }
    end

    # Picoのボード・VM設定(未指定VMは既定値)を解決する。不正な組み合わせなら400。
    def pico_board_and_vm!(config)
      board = config["platform"]
      vms = PICO_BOARD_VMS.fetch(board)
      vm = config["vm"] || vms.first
      json_error(400, "#{board} では #{vm} を使えません(使えるVM: #{vms.join(', ')})") unless vms.include?(vm)
      [board, vm]
    end

    # mrbgems/以下の現在の一覧とbuild_config.rbから、実際にビルドへ渡す
    # ファイルをビルドのたびに作り直す(generated_build_config_content参照)。
    # 戻り値はPROJECT_BUILD_CONFIGに渡す「コンテナ内から見たパス」の代入文
    # (ホスト側の実パスではない)。
    def prepare_project_build_config(root)
      generated_build_config = File.join(root, GENERATED_BUILD_CONFIG_FILENAME)
      File.write(generated_build_config, generated_build_config_content(root))
      container_build_config = File.join(CONTAINER_PROJECT_MOUNT, GENERATED_BUILD_CONFIG_FILENAME)
      "PROJECT_BUILD_CONFIG=#{Shellwords.escape(container_build_config)}"
    end

    # ビルドをバックグラウンドで開始する。
    # 実行中に重ねて叩かれた場合は 409 を返す(同時に複数走らせない)。
    # ターゲット・VM・USB Consoleはリクエストでは受け取らず、現在のプロジェクトの設定
    # (read_project_config、`~/.picoride/project.toml`から読む)に保存されている
    # 値をそのまま使う。ターゲットのファミリー(ESP32/Pico)によって、使うビルド用
    # イメージ・状態ディレクトリ・ビルド手順が切り替わる。ビルド状態はプロジェクトごとに
    # 独立している(build_state_dir)ので、初回はここでgit clone(R2P2State)が
    # 走り、数分かかることがある。
    post "/api/build" do
      content_type :json

      # BUILD_JOB/PLATFORM_JOBは別々のロックなので、これが無いと「ビルド中に別の
      # リクエストでプラットフォームセットアップ(rake setup_xxxのdeep_clean)を始める」
      # ことを防げず、同じプロジェクトのビルド状態ディレクトリを2つのdocker run
      # コンテナが同時に書き換えてしまう(実際に発生し、ビルド中のファイルが
      # セットアップのdeep_cleanで消えてErrno::ENOENTになった)。
      json_error(409, "platform setup is running") if PLATFORM_JOB.running?

      project_config = read_project_config
      family = platform_family(project_config["platform"])

      root = project_root
      state_dir = build_state_dir(root, family)
      ensure_project_gitignore(root)
      ensure_build_checkout!(family, state_dir)

      inner_cmd =
        if family == "pico"
          pico_build_inner_command(root, project_config)
        else
          esp32_build_inner_command(root, state_dir, project_config)
        end

      started = BUILD_JOB.start(builder_docker_command(family, state_dir, root, inner_cmd))
      json_error(409, "build already running") unless started

      { status: "ok" }.to_json
    end

    # Pico: picorubyの`rake r2p2:{vm}:{board}:prod`(mruby/cのライブラリビルド +
    # pico-sdkのcmakeビルド)を実行する。成果物の.uf2は
    # build/r2p2/{vm}/{board}/prod/ にできる(pico_uf2_path参照)。
    #
    # ESP32と違い、app/以下をファームウェアに焼き込む仕組みは無い(R2P2はPicoの
    # フラッシュをUSBマスストレージとして見せる方式で、ストレージのイメージを
    # ビルド時に作らない)。app/はターミナルタブの「app/ をアップロード」
    # (PicoModem)で書き込む。
    #
    # r2p2のcmakeはmain_task.rbのコンパイルに`<picoruby>/bin/mrbc`を使うが、
    # cloneしたばかりのpicorubyにはこれが無く、r2p2タスク自体も作らない
    # (`/picoruby/bin/mrbc: not found`で失敗することを実際のビルドで確認した)。
    # mrbcはVMに依存しないスタンドアロンのコンパイラなので、無ければ先に
    # build_config/mrbc.rb で1回だけビルドする(bin/mrbcへのシンボリックリンクができる)。
    def pico_build_inner_command(root, project_config)
      board, vm = pico_board_and_vm!(project_config)
      "#{PICO_PREPARE_COMMAND} && " \
        "{ [ -x bin/mrbc ] || MRUBY_CONFIG=build_config/mrbc.rb rake; } && " \
        "#{prepare_project_build_config(root)} rake r2p2:#{vm}:#{board}:#{PICO_BUILD_MODE}"
    end

    # Wi-Fi付きボード(pico_w/pico2_w)のbuild_configが使うpicoruby-socket・
    # picoruby-mbedtlsは、lwIP・mbedTLSをpicoruby側のpico-sdkサブモジュール
    # (mrbgems/picoruby-r2p2/lib/pico-sdk/lib/{lwip,mbedtls})へのシンボリックリンク
    # 経由で参照する。このサブモジュールはcloneしていない(pico-sdkはイメージ側の
    # /opt/pico-sdkを使う。r2p2_state.rb参照)ので、コンテナ内でそのパスを
    # $PICO_SDK_PATHへのシンボリックリンクにしておく(無いと
    # `lwip/opt.h: No such file or directory`で失敗することを実際のビルドで確認した)。
    # リンク先はコンテナ内のパスなので、ホスト側から見るとリンク切れになるが害は無い。
    # `rake ...:clean`もbuild_configを読み込む(picoruby-socketのmrbgem.rakeは
    # リンク切れだと例外を投げる)ので、セットアップでも同じ準備をする。
    PICO_SDK_SUBMODULE_PATH = "mrbgems/picoruby-r2p2/lib/pico-sdk"
    #
    # 「中身があるか」ではなく「シンボリックリンクかどうか」で判定する。picoruby-mbedtlsの
    # mrbgem.rakeは、リンク先が無いと自分でpico-sdkサブモジュールとその中のmbedtls
    # だけをgit submodule update --initしてしまう(lwipは取らない)ので、一度でも
    # その状態になると「ディレクトリはあるがlwipが空」になって中身チェックをすり抜ける
    # (実際に起きた)。
    PICO_PREPARE_COMMAND =
      "{ [ -L #{PICO_SDK_SUBMODULE_PATH} ] || " \
      "{ rm -rf #{PICO_SDK_SUBMODULE_PATH} && ln -s \"$PICO_SDK_PATH\" #{PICO_SDK_SUBMODULE_PATH}; }; }"

    # ESP32: idf.py build。
    def esp32_build_inner_command(root, state_dir, project_config)
      # プロジェクトのapp/以下を実機の起動スクリプトにする(storage/home/を参照する
      # R2P2本来の仕組み。詳細は上のコメント参照)。前回このプロジェクトをビルドした
      # ときの残骸が残らないよう、まずstorage/home/を空にしてからコピーし直す。
      storage_home_dir = File.join(state_dir, "storage", "home")
      FileUtils.mkdir_p(storage_home_dir)
      FileUtils.rm_rf(Dir.glob(File.join(storage_home_dir, "*")))
      project_app_dir = File.join(root, APP_DIRNAME)
      if Dir.exist?(project_app_dir)
        FileUtils.cp_r(Dir.glob(File.join(project_app_dir, "*")), storage_home_dir)
      end

      vm = project_config["vm"]
      usb_console = project_config["usb_console"]

      build_cmd = +"idf.py build"
      build_cmd << " -DPICORB_VM=#{BUILD_VM_FLAGS[vm]}" if vm

      env_assignments = [prepare_project_build_config(root)]

      if usb_console != sdkconfig_has_usb_console?(state_dir)
        # SDKCONFIG_DEFAULTS は sdkconfig ファイルが無いときにしか読まれない仕組みなので、
        # 現在の設定と要求された設定が食い違うときだけ sdkconfig を消してビルドし直す
        # (README.md「If you change SDKCONFIG_DEFAULTS, delete the sdkconfig file and
        # rebuild from scratch」参照。fullclean/deep_cleanでも消えないので明示的に消す)。
        # 値が変わらない限りはこのクリーンビルドを避け、従来通りの差分ビルドのままにする。
        sdkconfig_defaults = usb_console ? USB_CONSOLE_SDKCONFIG_DEFAULTS : "sdkconfig.defaults"
        env_assignments << "SDKCONFIG_DEFAULTS=#{Shellwords.escape(sdkconfig_defaults)}"
        "rm -f sdkconfig && #{env_assignments.join(' ')} #{build_cmd}"
      else
        "#{env_assignments.join(' ')} #{build_cmd}"
      end
    end

    # プラットフォーム(ターゲットチップ)セットアップの実行状態とログを返す。
    get "/api/platform" do
      content_type :json
      PLATFORM_JOB.to_response_json(offset: params["offset"], run_id: params["run_id"])
    end

    # 現在のプロジェクトの設定に設定されているターゲットのセットアップを
    # バックグラウンドで実行する。ターゲット自体はリクエストでは受け取らず、
    # 設定ダイアログで保存された値を使う。
    #
    # - ESP32: `rake setup_#{platform}`。deep_clean + setup(mrubyの再ビルド) +
    #   idf.py set-target という重い処理の直列実行(R2P2-ESP32/rakelib/setup.rake参照)。
    # - Pico: `rake r2p2:{vm}:{board}:clean`。Picoはボード×VMごとにビルド
    #   ディレクトリが分かれていてターゲット切り替えの準備は不要なので、
    #   「そのボードのビルド成果物を消してクリーンな状態からビルドし直せるようにする」
    #   だけ(picorubyのチェックアウト自体はensure_build_checkout!で行われる)。
    post "/api/platform" do
      content_type :json

      project_config = read_project_config
      platform = project_config["platform"]
      json_error(400, "platform is not configured for this project") if platform.to_s.empty?

      # BUILD_JOBとの同時実行を防ぐ理由はPOST /api/build側のコメント参照。
      json_error(409, "build is running") if BUILD_JOB.running?

      family = platform_family(platform)

      root = project_root
      state_dir = build_state_dir(root, family)
      ensure_project_gitignore(root)
      ensure_build_checkout!(family, state_dir)

      inner_cmd =
        if family == "pico"
          board, vm = pico_board_and_vm!(project_config)
          "#{PICO_PREPARE_COMMAND} && rake r2p2:#{vm}:#{board}:clean"
        else
          "rake setup_#{platform}"
        end

      started = PLATFORM_JOB.start(builder_docker_command(family, state_dir, root, inner_cmd))
      json_error(409, "platform setup already running") unless started

      { status: "ok", platform: platform }.to_json
    end

    # デバイスへの書き込み(インストール)は ESP Web Tools
    # (https://esphome.github.io/esp-web-tools/、index.html でCDN読み込み)経由の
    # ブラウザのWeb Serial APIで行う。サーバはビルド成果物からマニフェストと.binを
    # 配信するだけで、実際の書き込み処理はブラウザ側(esp-web-install-button)が担う。
    # ビルド成果物は現在のプロジェクトのR2P2-ESP32状態ディレクトリ(r2p2_state_dir)の下、
    # `build/`にある。

    # idf.py set-target のターゲット名 → ESP Web Tools の chipFamily 名。
    # ESP Web Tools が対応しているチップ一覧(esp-web-tools/src/const.ts の Build#chipFamily)
    # のうち、R2P2-ESP32側がサポートしている(PLATFORM_TARGETSにある)ものだけ載せてある。
    CHIP_FAMILY_MAP = {
      "esp32" => "ESP32",
      "esp32c3" => "ESP32-C3",
      "esp32c6" => "ESP32-C6",
      "esp32h2" => "ESP32-H2",
      "esp32p4" => "ESP32-P4",
      "esp32s3" => "ESP32-S3"
    }.freeze

    def firmware_build_dir(root)
      File.join(r2p2_state_dir(root), "build")
    end

    # --- Raspberry Pi Pico のファームウェア(.uf2) ---------------------------
    #
    # PicoはESP Web Toolsのような「ブラウザから直接書き込む」仕組みを使わず、
    # BOOTSELボタンを押しながら接続すると現れるUSBドライブ(RPI-RP2 / RP2350)へ
    # .uf2をコピーするだけで書き込める。そのためサーバはビルド成果物の.uf2を
    # ダウンロードさせるだけにしてある(UI側はメニューバーの「UF2をダウンロード」)。

    # 現在のプロジェクト設定(ボード・VM)に対応する最新の.uf2の絶対パス(無ければnil)。
    # ファイル名にビルド日付・リビジョンが入る(R2P2-FEMTORUBY-<version>-PICO-<date>-<rev>.uf2)
    # ため過去のビルドの.uf2が残りうるので、更新日時が最も新しいものを選ぶ。
    def pico_uf2_path(root, board, vm)
      dir = File.join(build_state_dir(root, "pico"), "build", "r2p2", vm, board, PICO_BUILD_MODE)
      Dir.glob(File.join(dir, "*.uf2")).max_by { |path| File.mtime(path) }
    end

    get "/api/firmware/uf2" do
      project_config = read_project_config
      json_error(400, "target is not a Raspberry Pi Pico") unless current_platform_family == "pico"

      board, vm = pico_board_and_vm!(project_config)
      path = pico_uf2_path(project_root, board, vm)
      json_error(404, "not built yet") unless path

      send_file path, type: "application/octet-stream", disposition: "attachment", filename: File.basename(path)
    end

    # ESP Web Tools 用のマニフェストを、直近のビルド成果物
    # (build/project_description.json の "target" と build/flash_args)から動的に組み立てる。
    # flash_args は `idf.py build` が生成する、esptool write_flash にそのまま渡せる
    # "<オフセット(16進)> <binへの相対パス>" の行の並び(1行目は --flash_mode 等のオプション行)。
    get "/api/firmware/manifest.json" do
      content_type :json

      json_error(400, "target is not an ESP32") unless current_platform_family == "esp32"

      root = project_root
      build_dir = firmware_build_dir(root)
      desc_path = File.join(build_dir, "project_description.json")
      flash_args_path = File.join(build_dir, "flash_args")
      json_error(404, "not built yet") unless File.file?(desc_path) && File.file?(flash_args_path)

      target = JSON.parse(File.read(desc_path))["target"]
      chip_family = CHIP_FAMILY_MAP[target]
      json_error(500, "unsupported target: #{target}") unless chip_family

      parts = File.readlines(flash_args_path).drop(1).filter_map do |line|
        line = line.strip
        next if line.empty?

        offset_hex, rel_path = line.split(" ", 2)
        # rel_path は "bootloader/bootloader.bin" のようにサブディレクトリを含むことがある。
        # basename に切り詰めると実体(build/bootloader/bootloader.bin)と食い違って
        # 404になるため、相対パスのままURLに使う(下の配信ルート側もそれに合わせてある)。
        { path: "/api/firmware/#{rel_path}", offset: Integer(offset_hex, 16) }
      end

      {
        name: "R2P2-ESP32",
        version: Time.now.strftime("%Y%m%d%H%M%S"),
        builds: [{ chipFamily: chip_family, parts: parts }]
      }.to_json
    end

    # ビルド成果物の .bin ファイルを配信する。flash_args の相対パスをそのまま受け取る
    # (例: "bootloader/bootloader.bin" のようにサブディレクトリを含むことがある)ので、
    # 固定セグメントの :filename ではなくワイルドカードで受ける。
    # manifestのpartsが返すpathはここに合わせてある。
    get "/api/firmware/*" do
      rel_path = params[:splat].first
      json_error(400, "invalid filename") unless rel_path.end_with?(".bin")

      full =
        begin
          safe_path(firmware_build_dir(project_root), rel_path)
        rescue ArgumentError
          json_error(400, "invalid path")
        end

      json_error(404, "file not found") unless File.file?(full)

      content_type "application/octet-stream"
      File.read(full, mode: "rb")
    end
  end
end
