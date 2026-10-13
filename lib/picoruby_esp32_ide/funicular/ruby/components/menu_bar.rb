# 最上部のメニュー/グローバルステータスバー。
#
# プロジェクトの切り替えもここのドロップダウンで行う(以前はサイドバーのProjectList
# だったが、「上部のドロップダウンから選べるようにしたい」という要望で移動した)。
# ターゲットチップ・VM・USB Consoleは以前ここに常設セレクト/ビルド時ダイアログで
# 出していたが、「プロジェクトの設定としてプロジェクトに含めたい」という
# フィードバックを受けてプロジェクトごとの`.config.yml`に持たせる方式に変更した。
# そのため、ここには設定値を編集する「設定」ボタンと、その設定値をそのまま使って
# 実行するだけの「セットアップ」「ビルド開始」ボタンだけが残っている。
# 左端には「ファイル」メニュー(新しいプロジェクト/プロジェクトを開く/mrbgemを
# 追加/新規ファイル/新しいフォルダ)を置いてある。開閉状態はここでは持たず(理由は
# editor_app.rbの「子コンポーネントは親の再描画のたびに作り直される」の節参照)、
# props[:file_menu_open]として親(EditorApp)のstateをそのまま反映するだけにしてある。
# 他のパネルと同じく表示専用で、実処理(状態管理・API呼び出し)は
# props[:on_project_select] / props[:on_settings] / props[:on_setup] /
# props[:on_build] / props[:on_file_menu_toggle] / props[:on_new_project] /
# props[:on_open_project] / props[:on_add_mrbgem] / props[:on_new_file] /
# props[:on_new_folder] 経由で親(EditorApp)に委譲する。
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
      render_project_select
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

  # <select> の変更イベント。プレースホルダ("プロジェクト未選択")が選ばれた場合は無視する。
  def handle_project_change(event)
    node = refs[:project_select]
    return unless node

    value = node[:value].to_s
    return if value.empty?

    on_project_select = props[:on_project_select]
    on_project_select.call(value) if on_project_select
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
      button(class: 'file-menu-item', onclick: :handle_new_project) { '新しいプロジェクト…' }
      button(class: 'file-menu-item', onclick: :handle_open_project) { 'プロジェクトを開く…' }
      render_add_mrbgem_menu_item
      render_new_file_menu_item
      render_new_folder_menu_item
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

  def render_project_select
    projects = props[:projects] || []

    if props[:loading_projects] || projects.empty?
      tag(:select, disabled: true) { tag(:option, value: '') { 'プロジェクト未選択' } }
    else
      tag(:select, ref: :project_select, onchange: :handle_project_change) { render_project_options(projects) }
    end
  end

  def render_project_options(projects)
    projects.each do |name|
      if name == props[:current_project]
        tag(:option, value: name, selected: true) { name }
      else
        tag(:option, value: name) { name }
      end
    end
  end

  def render_settings_button
    button(class: 'menu-settings', onclick: :handle_settings) { '設定' }
  end

  # ターゲットが未設定なら押せない(設定ダイアログで選んでもらう)。
  def render_setup_button
    platform = value_of(props[:project_config], 'platform')

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
