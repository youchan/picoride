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

module Picoride
  class Server < Sinatra::Base
    set :public_folder, File.join(__dir__, "public")
    set :views, File.join(__dir__, "views")

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

    FUNICULAR_ROOT = File.expand_path("funicular", __dir__)

    # プロジェクトごとに独立したR2P2-ESP32のビルド状態(sdkconfig・build/・
    # managed_components等)を置くディレクトリ名。「プロジェクトディレクトリの中に
    # 置きたい、gitには含めたくない、UI上のファイル一覧にも出したくない」という
    # 要望から、プロジェクト直下のドット始まりのディレクトリにしてある。
    # `.`始まりのパスは`Dir.glob("**/*")`が中身ごと辿らない(GET /api/files参照)ので、
    # 特別なフィルタ処理を書かなくてもUI上には出てこない。
    R2P2_STATE_DIRNAME = ".r2p2-esp32"

    # idf.py build / rake setup_xxx を実行するビルド専用イメージ(Dockerfile参照)。
    # `docker build -t #{BUILDER_IMAGE} .` で事前にビルドしておく必要がある。
    BUILDER_IMAGE = ENV.fetch("PICORUBY_BUILDER_IMAGE", "picoride-builder")

    # ビルド専用コンテナの中で、プロジェクト本体・R2P2-ESP32の状態をそれぞれ
    # bind mountする先の固定パス。ホスト側の実パスとコンテナ内パスの対応は
    # この2つの定数を通じて一箇所にまとめておく(r2p2_docker_command参照)。
    CONTAINER_PROJECT_MOUNT = "/project_src"
    CONTAINER_R2P2_MOUNT = "/R2P2-ESP32"

    ALLOWED_EXTENSIONS = %w[.rb .c .h .rake].freeze
    PLATFORM_TARGETS = %w[esp32 esp32c3 esp32c6 esp32h2 esp32p4 esp32s3].freeze

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

      # .gitignoreを(プロジェクト内に無ければ作成、あれば足りない行だけ追記して)
      # 用意する。R2P2-ESP32の状態やビルド生成物をプロジェクトのgit管理に含めたくない、
      # という要望から、プロジェクトの中に状態を置くようにした以上セットで必要になる。
      # 既存の.gitignoreの中身(ユーザー自身が書いた分)は壊さない。
      def ensure_project_gitignore(root)
        entries = ["#{R2P2_STATE_DIRNAME}/", GENERATED_BUILD_CONFIG_FILENAME]
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
      # (app/app.rb)とビルド設定ファイル(build_config.rb)が無ければ空で
      # 用意しておく。既存ファイルは上書きしない(非破壊)。以前の「新しい
      # プロジェクト」(ワークスペース配下に名前でサブディレクトリを作る機能)が
      # 担っていた雛形作成を、「プロジェクトを開く」(DirectoryBrowserDialogで
      # 任意のディレクトリを指定・新規フォルダ作成して開く)に統合したもの。
      def ensure_project_scaffold(root)
        app_dir = File.join(root, APP_DIRNAME)
        FileUtils.mkdir_p(app_dir)
        app_file = File.join(app_dir, "app.rb")
        File.write(app_file, "") unless File.exist?(app_file)

        build_config_path = File.join(root, BUILD_CONFIG_FILENAME)
        File.write(build_config_path, "") unless File.exist?(build_config_path)
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

      # 新規ファイル/新規フォルダの作成先を app/ 配下に限定するチェック。
      # "app" 自身(プロジェクト作成時に既に存在する)は対象外で、その下に
      # 最低1階層のセグメントが必要。
      def under_app_dir?(rel)
        prefix = "#{APP_DIRNAME}/"
        rel.start_with?(prefix) && rel.length > prefix.length
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
      full = File.expand_path(File.join(FUNICULAR_ROOT, "ruby", rel))
      root_with_sep = File.join(FUNICULAR_ROOT, "ruby") + File::SEPARATOR

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
      json_error(400, "unsupported file type") unless File.extname(rel) == NEW_FILE_EXTENSION
      json_error(400, "invalid path") unless valid_relative_path?(rel)
      json_error(400, "files can only be created under #{APP_DIRNAME}/") unless under_app_dir?(rel)

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

    # 新規フォルダを作成する(空ディレクトリ)。新規ファイルと同じくapp/配下のみ許可する。
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
      json_error(400, "folders can only be created under #{APP_DIRNAME}/") unless under_app_dir?(rel)

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

    # 最小構成のmrbgem.rake(mrbgemとして成立する最低限の内容)。
    def mrbgem_rake_content(name)
      <<~RUBY
        MRuby::Gem::Specification.new("#{name}") do |spec|
          spec.license = "MIT"
          spec.authors = "#{name}"
          spec.summary = "#{name}"
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
        # ホスト側の実パスではない点に注意(r2p2_docker_commandでproject_srcとしてマウントする)。
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

    # ビルド専用コンテナ(BUILDER_IMAGE)を使い捨てで起動し、その中でinner_cmdを
    # 実行するコマンド文字列を組み立てる。state_dir(プロジェクトごとのR2P2-ESP32状態)を
    # CONTAINER_R2P2_MOUNTに、project_root(mrbgems/やapp/を含むプロジェクト本体)を
    # CONTAINER_PROJECT_MOUNTにbind mountする。
    #
    # idf.py / rake は ESP-IDF の export.sh を読み込んだシェルでしか使えないため、
    # コンテナ内で明示的に読み込んでから inner_cmd を実行する。
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
    def r2p2_docker_command(state_dir, project_dir, inner_cmd)
      chown_target = "#{Process.uid}:#{Process.gid}"
      full_inner_cmd =
        ". \"$IDF_PATH/export.sh\" > /dev/null && cd #{Shellwords.escape(CONTAINER_R2P2_MOUNT)} && " \
        "#{inner_cmd}; " \
        "exit_code=$?; " \
        "chown -R #{chown_target} #{Shellwords.escape(CONTAINER_R2P2_MOUNT)}; " \
        "exit $exit_code"

      "docker run --rm " \
        "-v #{Shellwords.escape(state_dir)}:#{CONTAINER_R2P2_MOUNT} " \
        "-v #{Shellwords.escape(project_dir)}:#{CONTAINER_PROJECT_MOUNT} " \
        "#{Shellwords.escape(BUILDER_IMAGE)} " \
        "bash -c #{Shellwords.escape(full_inner_cmd)}"
    end

    # BUILDER_IMAGEがローカルに存在するかどうか。無いままdocker runすると
    # 分かりにくいエラーになるので、事前にチェックして案内を出せるようにする。
    def builder_image_available?
      system("docker", "image", "inspect", BUILDER_IMAGE, out: File::NULL, err: File::NULL)
    end

    # R2P2State.ensure_checkout は git clone 等に失敗すると例外を投げる
    # (R2P2State.run! 参照)。Sinatraのリクエストハンドラ内で素通しすると生の500に
    # なってしまうので、json_errorでラップする。
    def ensure_r2p2_checkout!(state_dir)
      R2P2State.ensure_checkout(state_dir)
    rescue StandardError => e
      json_error(500, "R2P2-ESP32のセットアップに失敗しました: #{e.message}")
    end

    # R2P2-ESP32 のビルド状態(実行中/成功/失敗/未実行)とログを返す。
    # UI 側はこれをポーリングして進捗を表示する。
    get "/api/build" do
      content_type :json
      BUILD_JOB.to_response_json
    end

    # idf.py build -DPICORB_VM=xxx に渡すフラグ(R2P2-ESP32/Rakefile の PICORB_VMS と同じ対応)。
    BUILD_VM_FLAGS = { "femtoruby" => "mrubyc", "picoruby" => "mruby" }.freeze

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

    # R2P2-ESP32 のビルド(idf.py build)をバックグラウンドで開始する。
    # 実行中に重ねて叩かれた場合は 409 を返す(同時に複数走らせない)。
    # VM・USB Consoleはリクエストでは受け取らず、現在のプロジェクトの設定
    # (read_project_config、`~/.picoride/project.toml`から読む)に保存されている
    # 値をそのまま使う。R2P2-ESP32の状態はプロジェクトごとに独立している
    # (r2p2_state_dir)ので、初回はここでgit clone(R2P2State.ensure_checkout)が
    # 走り、数分かかることがある。
    post "/api/build" do
      content_type :json

      # BUILD_JOB/PLATFORM_JOBは別々のロックなので、これが無いと「ビルド中に別の
      # リクエストでプラットフォームセットアップ(rake setup_xxxのdeep_clean)を始める」
      # ことを防げず、同じプロジェクトのR2P2-ESP32状態ディレクトリを2つのdocker run
      # コンテナが同時に書き換えてしまう(実際に発生し、ビルド中のファイルが
      # セットアップのdeep_cleanで消えてErrno::ENOENTになった)。
      json_error(409, "platform setup is running") if PLATFORM_JOB.running?

      unless builder_image_available?
        json_error(500, "ビルド用イメージ #{BUILDER_IMAGE} が見つかりません。" \
          "docker build -t #{BUILDER_IMAGE} . を実行してください")
      end

      root = project_root
      state_dir = r2p2_state_dir(root)
      ensure_project_gitignore(root)
      ensure_r2p2_checkout!(state_dir)

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

      project_config = read_project_config
      vm = project_config["vm"]
      usb_console = project_config["usb_console"]

      build_cmd = +"idf.py build"
      build_cmd << " -DPICORB_VM=#{BUILD_VM_FLAGS[vm]}" if vm

      # mrbgems/以下の現在の一覧とbuild_config.rbから、実際にR2P2-ESP32へ渡す
      # ファイルをビルドのたびに作り直す(generated_build_config_content参照)。
      # PROJECT_BUILD_CONFIGにはコンテナ内から見たパスを渡す(ホスト側の実パスではない)。
      generated_build_config = File.join(root, GENERATED_BUILD_CONFIG_FILENAME)
      File.write(generated_build_config, generated_build_config_content(root))
      container_build_config = File.join(CONTAINER_PROJECT_MOUNT, GENERATED_BUILD_CONFIG_FILENAME)
      env_assignments = ["PROJECT_BUILD_CONFIG=#{Shellwords.escape(container_build_config)}"]

      if usb_console != sdkconfig_has_usb_console?(state_dir)
        # SDKCONFIG_DEFAULTS は sdkconfig ファイルが無いときにしか読まれない仕組みなので、
        # 現在の設定と要求された設定が食い違うときだけ sdkconfig を消してビルドし直す
        # (README.md「If you change SDKCONFIG_DEFAULTS, delete the sdkconfig file and
        # rebuild from scratch」参照。fullclean/deep_cleanでも消えないので明示的に消す)。
        # 値が変わらない限りはこのクリーンビルドを避け、従来通りの差分ビルドのままにする。
        sdkconfig_defaults = usb_console ? USB_CONSOLE_SDKCONFIG_DEFAULTS : "sdkconfig.defaults"
        env_assignments << "SDKCONFIG_DEFAULTS=#{Shellwords.escape(sdkconfig_defaults)}"
        inner_cmd = "rm -f sdkconfig && #{env_assignments.join(' ')} #{build_cmd}"
      else
        inner_cmd = env_assignments.empty? ? build_cmd : "#{env_assignments.join(' ')} #{build_cmd}"
      end

      started = BUILD_JOB.start(r2p2_docker_command(state_dir, root, inner_cmd))
      json_error(409, "build already running") unless started

      { status: "ok" }.to_json
    end

    # プラットフォーム(ターゲットチップ)セットアップの実行状態とログを返す。
    get "/api/platform" do
      content_type :json
      PLATFORM_JOB.to_response_json
    end

    # 現在のプロジェクトの設定に設定されているターゲットへ向けて
    # `rake setup_#{platform}` をバックグラウンドで実行する。ターゲット自体は
    # リクエストでは受け取らず、設定ダイアログで保存された値を使う。
    # setup_esp32xxx は deep_clean + setup(mrubyの再ビルド) + idf.py set-target という
    # 重い処理の直列実行(R2P2-ESP32/rakelib/setup.rake参照)。
    post "/api/platform" do
      content_type :json

      platform = read_project_config["platform"]
      json_error(400, "platform is not configured for this project") if platform.to_s.empty?

      # BUILD_JOBとの同時実行を防ぐ理由はPOST /api/build側のコメント参照。
      json_error(409, "build is running") if BUILD_JOB.running?

      unless builder_image_available?
        json_error(500, "ビルド用イメージ #{BUILDER_IMAGE} が見つかりません。" \
          "docker build -t #{BUILDER_IMAGE} . を実行してください")
      end

      root = project_root
      state_dir = r2p2_state_dir(root)
      ensure_project_gitignore(root)
      ensure_r2p2_checkout!(state_dir)

      started = PLATFORM_JOB.start(r2p2_docker_command(state_dir, root, "rake setup_#{platform}"))
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

    # ESP Web Tools 用のマニフェストを、直近のビルド成果物
    # (build/project_description.json の "target" と build/flash_args)から動的に組み立てる。
    # flash_args は `idf.py build` が生成する、esptool write_flash にそのまま渡せる
    # "<オフセット(16進)> <binへの相対パス>" の行の並び(1行目は --flash_mode 等のオプション行)。
    get "/api/firmware/manifest.json" do
      content_type :json

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
