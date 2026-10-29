# 最上部のメニューバー。ビルドの状態表示はログパネルのビルドタブ(log_panel.rb)に一本化した。
#
# 常設ドロップダウンは「プロジェクト」の切り替え用。プロジェクトが1つも
# 開かれていない(props[:known_projects]が空)間は、この場所に実質的に
# 「プロジェクトを開く」ボタンを出す(ドロップダウンの代わりにbuttonを
# 描画するだけで、同じprops[:on_open_project]を使う)。アプリ起動時に自動で
# ダイアログを出したりはしない。ユーザーがこのボタン/ファイルメニューから
# 明示的に開く操作をするまで、プロジェクトは開かれない。
#
# 以前は「複数プロジェクトを束ねるワークスペース」という上位概念があり、
# このドロップダウンはワークスペース選択用、プロジェクトの切り替えは別の
# ダイアログ(OpenProjectDialog)、という2階層構成だった。しかし
# 「ワークスペース=プロジェクトだった」というフィードバックにより2階層は
# 不要と判明し、1階層に統合した。このドロップダウンはそのままプロジェクト
# 選択用になり、OpenProjectDialog・「新しいプロジェクト」メニュー項目(旧・
# ワークスペース配下に名前でサブディレクトリを作る機能)は削除した
# (「新しいプロジェクト」はDirectoryBrowserDialogの「新しいフォルダ」+
# 「このディレクトリを開く」に統合されている)。
#
# ターゲットチップ・VM・USB Consoleはプロジェクトごとの設定
# (`~/.picoride/project.toml`)に持たせてある。
# 左端には「ファイル」メニュー(プロジェクトを開く/mrbgemを追加/新規ファイル/
# 新しいフォルダ)と「ターゲット」メニュー(ターゲット設定/セットアップ)を置いてある。
# 設定とセットアップは以前メニューバー右側の常設ボタンだったが、最初に一度
# 触るだけのものなので「メニューに置きたい」という要望でメニューに移した
# (常設ボタンとして残っているのは頻繁に使う「ビルド開始」「インストール」だけ)。
# メニューの開閉状態はここでは持たず(理由は
# editor_app.rbの「子コンポーネントは親の再描画のたびに作り直される」の節参照)、
# props[:file_menu_open] / props[:target_menu_open]として親(EditorApp)の
# stateをそのまま反映するだけにしてある。
# 他のパネルと同じく表示専用で、実処理(状態管理・API呼び出し)は
# props[:on_project_select] / props[:on_settings] / props[:on_setup] /
# props[:on_build] / props[:on_file_menu_toggle] / props[:on_target_menu_toggle] /
# props[:on_open_project] / props[:on_add_mrbgem] / props[:on_new_file] /
# props[:on_new_folder] 経由で親(EditorApp)に委譲する。
#
# props[:project] は現在開いているプロジェクトの絶対パス(未設定ならnil)。
# props[:known_projects] はこのセッションで一度でも開いたプロジェクトの
# 絶対パスの配列(ドロップダウンの選択肢)。
module PicoRIDE
  class MenuBar < Funicular::Component
    def render
      div(class: 'menu-bar') do
        span(class: 'menu-bar-title') { 'PicoRIDE' }
        render_file_menu
        render_target_menu
        render_project_select
        div(class: 'menu-bar-spacer')
        render_build_button
        render_install_button
      end
    end

    def handle_file_menu_toggle(event)
      event.preventDefault
      on_file_menu_toggle = props[:on_file_menu_toggle]
      on_file_menu_toggle.call if on_file_menu_toggle
    end

    def handle_target_menu_toggle(event)
      event.preventDefault
      on_target_menu_toggle = props[:on_target_menu_toggle]
      on_target_menu_toggle.call if on_target_menu_toggle
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

    # <select> の変更イベント。選ばれたプロジェクトの絶対パスをそのまま渡す。
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
        button(class: 'file-menu-item', onclick: :handle_open_project) { 'プロジェクトを開く…' }
        render_add_mrbgem_menu_item
        render_new_file_menu_item
        render_new_folder_menu_item
      end
    end

    # mrbgem追加・新規ファイル作成はプロジェクトを開いていないと行き先が無いので、
    # 未選択時は押せないようにする(disabled: false を渡す書き方はこのDSLでは
    # 効かないため、分岐で二通りの要素を書き分ける。toolbar.rbのrender_save_button参照)。
    def render_add_mrbgem_menu_item
      if props[:project].to_s.empty?
        button(class: 'file-menu-item', disabled: true) { 'mrbgemを追加…' }
      else
        button(class: 'file-menu-item', onclick: :handle_add_mrbgem) { 'mrbgemを追加…' }
      end
    end

    def render_new_file_menu_item
      if props[:project].to_s.empty?
        button(class: 'file-menu-item', disabled: true) { '新規ファイル…' }
      else
        button(class: 'file-menu-item', onclick: :handle_new_file) { '新規ファイル…' }
      end
    end

    def render_new_folder_menu_item
      if props[:project].to_s.empty?
        button(class: 'file-menu-item', disabled: true) { '新しいフォルダ…' }
      else
        button(class: 'file-menu-item', onclick: :handle_new_folder) { '新しいフォルダ…' }
      end
    end

    # プロジェクトを1つも開いたことが無ければ(known_projectsが空)、<select>の
    # 代わりに「プロジェクトを開く」ボタンを出す(props[:on_open_project]、
    # ファイルメニューの項目と同じコールバック)。1つ以上開いていれば、それらを
    # 選択肢に持つ<select>にする(選ぶとon_project_select経由で即座に切り替わる)。
    def render_project_select
      known = props[:known_projects] || []

      if known.empty?
        button(class: 'menu-project-open', onclick: :handle_open_project) { 'プロジェクトを開く…' }
      else
        tag(:select, class: 'menu-project-select', ref: :project_select, onchange: :handle_project_change,
                     title: props[:project].to_s) { render_project_options(known) }
      end
    end

    def render_project_options(known)
      known.each do |path|
        label = project_label(path)
        if path == props[:project]
          tag(:option, value: path, selected: true) { label }
        else
          tag(:option, value: path) { label }
        end
      end
    end

    # プロジェクト名は既定でディレクトリ名(パスの最後のセグメント)にする。
    # PicoRuby.wasm上ではFile.basenameのようなFile系メソッドの対応が不確かなため
    # (editor_app.rbのextensionヘルパーと同じ理由)、素の文字列分割で求める。
    def project_label(path)
      segments = path.to_s.split('/')
      name = segments.last
      (name.nil? || name.empty?) ? path.to_s : name
    end

    # 「ターゲット」メニュー。見た目・開閉の仕組みは「ファイル」メニューと同じ。
    def render_target_menu
      div(class: 'file-menu') do
        button(class: 'file-menu-toggle', onclick: :handle_target_menu_toggle) { 'ターゲット' }
        render_target_menu_dropdown if props[:target_menu_open]
      end
    end

    def render_target_menu_dropdown
      div(class: 'file-menu-dropdown') do
        render_settings_menu_item
        render_setup_menu_item
      end
    end

    # 設定はプロジェクト単位(project_store.rb参照)なので、プロジェクト未設定の
    # 間は保存先が無く押せない。
    def render_settings_menu_item
      if props[:project].to_s.empty?
        button(class: 'file-menu-item', disabled: true) { 'ターゲット設定…' }
      else
        button(class: 'file-menu-item', onclick: :handle_settings) { 'ターゲット設定…' }
      end
    end

    # ターゲットが未設定なら押せない(ターゲット設定で選んでもらう)。
    def render_setup_menu_item
      platform = value_of(props[:project_config], 'platform')

      if props[:platform_building]
        button(class: 'file-menu-item', disabled: true) { 'セットアップ中…' }
      elsif platform.to_s.empty?
        button(class: 'file-menu-item', disabled: true) { 'セットアップ(ターゲット未設定)' }
      else
        button(class: 'file-menu-item', onclick: :handle_setup) { "#{platform}をセットアップ" }
      end
    end

    def render_build_button
      if props[:building]
        button(class: 'menu-build', disabled: true) { 'ビルド中…' }
      else
        button(class: 'menu-build', onclick: :handle_build) { 'ビルド開始' }
      end
    end

    # ESP32: 実際の書き込み処理はブラウザのWeb Serial API経由でESP Web Tools
    # (esp-web-install-button カスタム要素)が行う。旧 install_panel.rb と同じ使い方。
    # Raspberry Pi Pico: ブラウザから直接書き込む仕組みは使わず、ビルド成果物の
    # .uf2をダウンロードさせる(BOOTSELを押しながら接続して現れるドライブへ
    # ユーザーがコピーする)。<a download>をボタン風に見せている。
    def render_install_button
      if props[:project].to_s.empty?
        button(class: 'menu-install', disabled: true) { 'デバイスにインストール' }
      elsif ProjectSettingsDialog.pico?(value_of(props[:project_config], 'platform'))
        tag(:a, class: 'menu-install menu-download', href: '/api/firmware/uf2', download: '',
                title: 'BOOTSELボタンを押しながらPicoを接続し、現れたドライブへUF2ファイルをコピーしてください') do
          'UF2をダウンロード'
        end
      else
        tag(:'esp-web-install-button', manifest: '/api/firmware/manifest.json') do
          button(slot: 'activate', class: 'menu-install') { 'デバイスにインストール' }
          span(slot: 'unsupported', class: 'menu-bar-hint') { '未対応ブラウザ' }
          span(slot: 'not-allowed', class: 'menu-bar-hint') { 'HTTPS必須' }
        end
      end
    end

    def value_of(data, key)
      return nil unless data
      data[key] || data[key.to_sym]
    end
  end
end
