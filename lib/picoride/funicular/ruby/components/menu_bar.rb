# 最上部のメニュー/グローバルステータスバー。
#
# 常設ドロップダウンは「ワークスペース」の切り替え用(以前はここで
# プロジェクトを切り替えていたが、「このドロップダウンはワークスペース選択に
# 使いたい」という要望で用途を変えた)。プロジェクトの切り替えは
# 「ファイル」メニューの「プロジェクトを開く…」(OpenProjectDialog)に一本化してある。
# ワークスペースが1つも開かれていない(props[:known_workspaces]が空)間は、
# この場所に実質的に「ワークスペースを開く」ボタンを出す(ドロップダウンの
# 代わりにbuttonを描画するだけで、同じprops[:on_open_workspace]を使う)。
# アプリ起動時に自動でダイアログを出す仕様は廃止した(「それはやめて」という
# フィードバックにより)。ユーザーがこのボタン/ファイルメニューから明示的に
# 開く操作をするまで、ワークスペースは開かれない。
#
# ターゲットチップ・VM・USB Consoleは以前ここに常設セレクト/ビルド時ダイアログで
# 出していたが、「プロジェクトの設定としてプロジェクトに含めたい」という
# フィードバックを受けてプロジェクトごとの`.config.yml`に持たせる方式に変更した。
# そのため、ここには設定値を編集する「設定」ボタンと、その設定値をそのまま使って
# 実行するだけの「セットアップ」「ビルド開始」ボタンだけが残っている。
# 左端には「ファイル」メニュー(ワークスペースを開く/新しいプロジェクト/
# プロジェクトを開く/mrbgemを追加/新規ファイル/新しいフォルダ)を置いてある。
# 開閉状態はここでは持たず(理由は
# editor_app.rbの「子コンポーネントは親の再描画のたびに作り直される」の節参照)、
# props[:file_menu_open]として親(EditorApp)のstateをそのまま反映するだけにしてある。
# 他のパネルと同じく表示専用で、実処理(状態管理・API呼び出し)は
# props[:on_workspace_select] / props[:on_settings] / props[:on_setup] /
# props[:on_build] / props[:on_file_menu_toggle] / props[:on_open_workspace] /
# props[:on_new_project] / props[:on_open_project] / props[:on_add_mrbgem] /
# props[:on_new_file] / props[:on_new_folder] 経由で親(EditorApp)に委譲する。
#
# props[:workspace] は現在開いているワークスペースの絶対パス(未設定ならnil)。
# props[:known_workspaces] はこのセッションで一度でも開いたワークスペースの
# 絶対パスの配列(ドロップダウンの選択肢。サーバプロセスが生きている間だけ
# 保持され、永続化はしない)。プロジェクト(projects/current_project)はこの
# ワークスペース配下のサブディレクトリという位置づけで、ワークスペース未設定の
# 間は「新しいプロジェクト」「プロジェクトを開く」も押せない。
class MenuBar < Funicular::Component
  STATUS_LABELS = {
    'idle' => 'ビルド未実行',
    'running' => 'ビルド中…',
    'success' => 'ビルド成功',
    'failed' => 'ビルド失敗'
  }.freeze

  def render
    div(class: 'menu-bar') do
      render_file_menu
      span(class: 'menu-bar-title') { 'PicoRuby ESP32 IDE' }
      render_workspace_select
      div(class: 'menu-bar-spacer')
      render_settings_button
      render_setup_button
      render_build_button
      render_status_pill
      render_install_button
    end
  end

  def handle_file_menu_toggle(event)
    event.preventDefault
    on_file_menu_toggle = props[:on_file_menu_toggle]
    on_file_menu_toggle.call if on_file_menu_toggle
  end

  def handle_open_workspace(event)
    event.preventDefault
    on_open_workspace = props[:on_open_workspace]
    on_open_workspace.call if on_open_workspace
  end

  def handle_new_project(event)
    event.preventDefault
    on_new_project = props[:on_new_project]
    on_new_project.call if on_new_project
  end

  def handle_open_project(event)
    event.preventDefault
    on_open_project = props[:on_open_project]
    on_open_project.call if on_open_project
  end

  def handle_add_mrbgem(event)
    event.preventDefault
    on_add_mrbgem = props[:on_add_mrbgem]
    on_add_mrbgem.call if on_add_mrbgem
  end

  def handle_new_file(event)
    event.preventDefault
    on_new_file = props[:on_new_file]
    on_new_file.call if on_new_file
  end

  def handle_new_folder(event)
    event.preventDefault
    on_new_folder = props[:on_new_folder]
    on_new_folder.call if on_new_folder
  end

  # <select> の変更イベント。選ばれたワークスペースの絶対パスをそのまま渡す。
  def handle_workspace_change(event)
    node = refs[:workspace_select]
    return unless node

    value = node[:value].to_s
    return if value.empty?

    on_workspace_select = props[:on_workspace_select]
    on_workspace_select.call(value) if on_workspace_select
  end

  def handle_settings(event)
    event.preventDefault
    on_settings = props[:on_settings]
    on_settings.call if on_settings
  end

  def handle_setup(event)
    event.preventDefault
    on_setup = props[:on_setup]
    on_setup.call if on_setup
  end

  def handle_build(event)
    event.preventDefault
    on_build = props[:on_build]
    on_build.call if on_build
  end

  private

  def render_file_menu
    div(class: 'file-menu') do
      button(class: 'file-menu-toggle', onclick: :handle_file_menu_toggle) { 'ファイル' }
      render_file_menu_dropdown if props[:file_menu_open]
    end
  end

  def render_file_menu_dropdown
    div(class: 'file-menu-dropdown') do
      button(class: 'file-menu-item', onclick: :handle_open_workspace) { 'ワークスペースを開く…' }
      render_new_project_menu_item
      render_open_project_menu_item
      render_add_mrbgem_menu_item
      render_new_file_menu_item
      render_new_folder_menu_item
    end
  end

  # ワークスペース未設定の間は行き先が無い(projectsはワークスペース配下の
  # サブディレクトリ)ので押せないようにする。
  def render_new_project_menu_item
    if props[:workspace].to_s.empty?
      button(class: 'file-menu-item', disabled: true) { '新しいプロジェクト…' }
    else
      button(class: 'file-menu-item', onclick: :handle_new_project) { '新しいプロジェクト…' }
    end
  end

  def render_open_project_menu_item
    if props[:workspace].to_s.empty?
      button(class: 'file-menu-item', disabled: true) { 'プロジェクトを開く…' }
    else
      button(class: 'file-menu-item', onclick: :handle_open_project) { 'プロジェクトを開く…' }
    end
  end

  # mrbgem追加・新規ファイル作成はプロジェクトを選択していないと行き先が無いので、
  # 未選択時は押せないようにする(disabled: false を渡す書き方はこのDSLでは
  # 効かないため、分岐で二通りの要素を書き分ける。toolbar.rbのrender_save_button参照)。
  def render_add_mrbgem_menu_item
    if props[:current_project].to_s.empty?
      button(class: 'file-menu-item', disabled: true) { 'mrbgemを追加…' }
    else
      button(class: 'file-menu-item', onclick: :handle_add_mrbgem) { 'mrbgemを追加…' }
    end
  end

  def render_new_file_menu_item
    if props[:current_project].to_s.empty?
      button(class: 'file-menu-item', disabled: true) { '新規ファイル…' }
    else
      button(class: 'file-menu-item', onclick: :handle_new_file) { '新規ファイル…' }
    end
  end

  def render_new_folder_menu_item
    if props[:current_project].to_s.empty?
      button(class: 'file-menu-item', disabled: true) { '新しいフォルダ…' }
    else
      button(class: 'file-menu-item', onclick: :handle_new_folder) { '新しいフォルダ…' }
    end
  end

  # ワークスペースを1つも開いたことが無ければ(known_workspacesが空)、
  # <select>の代わりに「ワークスペースを開く」ボタンを出す(props[:on_open_workspace]、
  # ファイルメニューの項目と同じコールバック)。1つ以上開いていれば、それらを
  # 選択肢に持つ<select>にする(選ぶとon_workspace_select経由で即座に切り替わる)。
  def render_workspace_select
    known = props[:known_workspaces] || []

    if known.empty?
      button(class: 'menu-workspace-open', onclick: :handle_open_workspace) { 'ワークスペースを開く…' }
    else
      tag(:select, class: 'menu-workspace-select', ref: :workspace_select, onchange: :handle_workspace_change,
                   title: props[:workspace].to_s) { render_workspace_options(known) }
    end
  end

  def render_workspace_options(known)
    known.each do |path|
      label = workspace_label(path)
      if path == props[:workspace]
        tag(:option, value: path, selected: true) { label }
      else
        tag(:option, value: path) { label }
      end
    end
  end

  # ワークスペース名は既定でディレクトリ名(パスの最後のセグメント)にする。
  # PicoRuby.wasm上ではFile.basenameのようなFile系メソッドの対応が不確かなため
  # (editor_app.rbのextensionヘルパーと同じ理由)、素の文字列分割で求める。
  def workspace_label(path)
    segments = path.to_s.split('/')
    name = segments.last
    (name.nil? || name.empty?) ? path.to_s : name
  end

  # 設定はワークスペース単位(workspace_store.rb参照)なので、ワークスペース
  # 未設定の間は保存先が無く押せない。
  def render_settings_button
    if props[:workspace].to_s.empty?
      button(class: 'menu-settings', disabled: true) { '設定' }
    else
      button(class: 'menu-settings', onclick: :handle_settings) { '設定' }
    end
  end

  # ターゲットが未設定なら押せない(設定ダイアログで選んでもらう)。
  def render_setup_button
    platform = value_of(props[:workspace_config], 'platform')

    if props[:platform_building]
      button(class: 'menu-setup', disabled: true) { 'セットアップ中…' }
    elsif platform.to_s.empty?
      button(class: 'menu-setup', disabled: true) { 'ターゲット未設定' }
    else
      button(class: 'menu-setup', onclick: :handle_setup) { "#{platform}をセットアップ" }
    end
  end

  def render_build_button
    if props[:building]
      button(class: 'menu-build', disabled: true) { 'ビルド中…' }
    else
      button(class: 'menu-build', onclick: :handle_build) { 'ビルド開始' }
    end
  end

  def render_status_pill
    span(class: "menu-bar-status #{props[:build_status]}") { status_label }
  end

  # 実際の書き込み処理はブラウザのWeb Serial API経由でESP Web Tools
  # (esp-web-install-button カスタム要素)が行う。旧 install_panel.rb と同じ使い方。
  # ビルド成果物がプロジェクトごとに分かれた(r2p2_state_dir参照)ので、
  # マニフェストURLにも現在のプロジェクトをクエリパラメータとして含める。
  def render_install_button
    current_project = props[:current_project]
    if current_project.to_s.empty?
      button(class: 'menu-install', disabled: true) { 'デバイスにインストール' }
    else
      manifest_path = "/api/firmware/manifest.json?project=#{encode(current_project)}"
      tag(:'esp-web-install-button', manifest: manifest_path) do
        button(slot: 'activate', class: 'menu-install') { 'デバイスにインストール' }
        span(slot: 'unsupported', class: 'menu-bar-hint') { '未対応ブラウザ' }
        span(slot: 'not-allowed', class: 'menu-bar-hint') { 'HTTPS必須' }
      end
    end
  end

  def status_label
    STATUS_LABELS[props[:build_status]] || props[:build_status].to_s
  end

  def value_of(data, key)
    return nil unless data
    data[key] || data[key.to_sym]
  end

  def encode(str)
    JS.global.encodeURIComponent(str).to_s
  end
end
