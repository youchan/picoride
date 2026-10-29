require 'js'
require 'crc'

# エディタ全体のルートコンポーネント。
#
# 状態(ファイル一覧・編集中のパス・バッファ・保存済み内容)はすべてここが持ち、
# TreeView / Toolbar には props で流すだけの構成にしている。
#
# ■ textarea と Prism ハイライトの扱いについて
#
# textarea は VDOM の制御下に置かず(value を render で出力せず)、
# ファイルを切り替えたときだけ ref 経由で value を差し替える「非制御」にしている。
# 入力のたびに VDOM が value を書き戻すとキャレットが末尾に飛ぶため。
#
# ハイライト層 <code> も同様に、VDOM 上は「子を持たない空要素」として描画し、
# Prism が生成したHTMLを innerHTML に直接流し込む。
# 子を持たない要素は再描画時の差分がゼロなので、innerHTML が消されることはない。
#
# ■ ターミナル(xterm.js + Web Serial)を別コンポーネントに切り出さない理由
#
# 当初は TerminalPanel という別コンポーネントに分けていたが、「ファイルペインと
# ターミナルペインを行き来すると接続が切れる」不具合が発生した。原因はFunicularの
# 子コンポーネント(component(...)で呼び出す側)が、**親が再レンダリングされる
# たびに initialize_state / component_mounted をもう一度呼び直す**という挙動
# だったこと(実際にカウンタを仕込んでブラウザで確認した。EditorAppのような
# Funicular.startに渡すルートコンポーネントだけがマウント1回を保証される)。
# xterm.jsのインスタンスやシリアルポートの接続(@port)のような「1回だけ
# 初期化して使い回したい副作用」を持つ以上、それらは全部ルートコンポーネントである
# このEditorAppの中に置く必要がある。textarea/ハイライト層を子コンポーネントに
# 切り出さず、非制御textarea+refで直接扱っているのと同じ理由・同じ対処。
module PicoRIDE
  class App < Funicular::Component
    # プロジェクト内の特別なディレクトリ名。app.rb側のAPP_DIRNAME/MRBGEMS_DIRNAMEと
    # 対応(サーバとフロントで別プロセス=別Rubyランタイムなので定数は共有できず、
    # 両側に定義してある)。
    APP_DIRNAME = 'app'
    MRBGEMS_DIRNAME = 'mrbgems'

    # 拡張子 → Prism の言語名
    LANGUAGES = { 'rb' => 'ruby', 'c' => 'c', 'h' => 'c' }

    # PicoModemプロトコル定数(picoruby-picomodemのmrblib/picomodem.rbと対応)
    TERM_FILE_WRITE = 0x02
    TERM_CHUNK      = 0x04
    TERM_FILE_ACK   = 0x82
    TERM_CHUNK_ACK  = 0x84
    TERM_DONE_ACK   = 0x8F
    TERM_ERROR      = 0xFE
    TERM_OK         = 0x00

    TERM_CHUNK_SIZE      = 480  # PicoModemの1フレームあたりの最大ペイロード
    TERM_TX_CHUNK_SIZE   = 32   # シリアル書き込み自体を分割するサイズ(USB-CDCの安定性のため)
    TERM_TX_CHUNK_GAP_MS = 20
    TERM_TIMEOUT_MS      = 5000

    def initialize_state
      {
        project: nil, # 開いているプロジェクトの絶対パス。未設定ならnil
        known_projects: [], # このセッションで一度でも開いたプロジェクトの絶対パス配列
        loading_project: true,
        files: [],
        dirs: [], # プロジェクト内の(空フォルダも含む)ディレクトリ一覧。file_tree_nodes参照
        loading_files: false,
        collapsed_dirs: [],
        current_path: nil,
        content: '',
        saved_content: '',
        status: '',
        status_kind: '',
        build_status: 'idle',
        build_log: '',
        build_log_offset: 0, # サーバのログのうち取得済みの長さ(次回GETのoffset)
        build_run_id: '',    # 取得済みログがどのジョブ実行のものか(BackgroundJobのrun_id)
        building: false,
        settings_dialog_open: false,
        project_config: default_project_config,
        file_menu_open: false,
        target_menu_open: false,
        prompt_dialog: nil, # { kind:, title:, label:, placeholder:, confirm_label:, error:, context_dir: } または nil
        # { path:, parent:, entries:, loading:, error:, creating:, create_error:, open_error: } または nil(閉じている)。
        # 「プロジェクトを開く」のディレクトリブラウザ(DirectoryBrowserDialog)の状態。
        project_browser: nil,
        context_menu: nil, # { kind:, path:, x:, y: } または nil。open_tree_context_menu参照
        settings_platform: nil,
        settings_vm: '',
        settings_usb_console: false,
        platform_status: 'idle',
        platform_log: '',
        platform_log_offset: 0,
        platform_run_id: '',
        platform_building: false,
        log_tab: 'build',
        editor_tab: 'code',
        terminal_status: 'disconnected', # 'disconnected' | 'connecting' | 'connected'
        terminal_status_message: '未接続',
        terminal_uploading: false,
        terminal_upload_log: []
      }
    end

    def default_project_config
      { 'platform' => nil, 'vm' => nil, 'usb_console' => false }
    end

    def component_mounted
      load_project
      setup_terminal
      watch_for_terminal_reconnect
    end

    # state が変わるたびに呼ばれる(Funicular::Component#patch から引数なしで呼ばれる)。
    # ハイライトは VDOM の外側(ref + innerHTML)で管理しているので、ここで同期する。
    # 前回描画時との差分は自前で覚えておく必要がある。
    def component_updated
      scroll_log_to_bottom_if_changed

      return if @prev_highlight_content == state[:content] &&
                @prev_highlight_path == state[:current_path]

      @prev_highlight_content = state[:content]
      @prev_highlight_path = state[:current_path]
      refresh_highlight
    end

    def render
      div(class: 'app') do
        # 最上部のメニュー/グローバルステータスバー。プロジェクトの切り替えも
        # ここのドロップダウンに集約している(サイドバーはファイル一覧専用)。
        component(MenuBar,
          project: state[:project],
          known_projects: state[:known_projects],
          project_config: state[:project_config],
          building: state[:building],
          platform_building: state[:platform_building],
          file_menu_open: state[:file_menu_open],
          target_menu_open: state[:target_menu_open],
          on_project_select: ->(path) { open_project(path) },
          on_settings: -> { open_settings_dialog },
          on_setup: -> { start_platform_setup },
          on_build: -> { start_build },
          on_file_menu_toggle: -> { toggle_file_menu },
          on_target_menu_toggle: -> { toggle_target_menu },
          on_open_project: -> { open_project_browser },
          on_add_mrbgem: -> { open_add_mrbgem_dialog },
          on_new_file: -> { open_new_file_dialog },
          on_new_folder: -> { open_new_folder_dialog }
        )

        if state[:prompt_dialog]
          component(PromptDialog,
            title: state[:prompt_dialog][:title],
            label: state[:prompt_dialog][:label],
            placeholder: state[:prompt_dialog][:placeholder],
            confirm_label: state[:prompt_dialog][:confirm_label],
            error: state[:prompt_dialog][:error],
            on_confirm: ->(value) { handle_prompt_confirm(value) },
            on_cancel: -> { patch(prompt_dialog: nil) }
          )
        end

        if state[:project_browser]
          browser = state[:project_browser]
          component(DirectoryBrowserDialog,
            path: browser[:path],
            parent: browser[:parent],
            entries: browser[:entries],
            loading: browser[:loading],
            error: browser[:error],
            creating: browser[:creating],
            create_error: browser[:create_error],
            open_error: browser[:open_error],
            on_navigate: ->(path) { load_browse_dir(path) },
            on_open: -> { open_project(browser[:path]) },
            on_start_create: -> { start_create_folder },
            on_confirm_create: ->(name) { confirm_create_folder(name) },
            on_cancel_create: -> { cancel_create_folder },
            on_cancel: -> { patch(project_browser: nil) }
          )
        end

        if state[:settings_dialog_open]
          component(ProjectSettingsDialog,
            project_path: state[:project],
            platform: state[:settings_platform],
            vm: state[:settings_vm],
            usb_console: state[:settings_usb_console],
            # ターゲットを切り替えて今のVMが選べなくなった(例: pico2でPicoRubyを
            # 選んでからpicoへ変えた)ら、VMをデフォルトに戻す。
            on_platform_change: ->(platform) {
              vm = state[:settings_vm]
              vm = '' unless ProjectSettingsDialog.vm_allowed?(platform, vm)
              patch(settings_platform: platform, settings_vm: vm)
            },
            on_vm_change: ->(vm) { patch(settings_vm: vm) },
            on_usb_console_change: ->(enabled) { patch(settings_usb_console: enabled) },
            on_save: -> { save_project_settings },
            on_cancel: -> { patch(settings_dialog_open: false) }
          )
        end

        render_tree_context_menu if state[:context_menu]

        div(class: 'app-body') do
          div(class: 'sidebar') do
            h1 { 'Project Files' }
            render_file_tree
          end

          div(class: 'editor-area') do
            render_editor_tabs

            # コード編集タブとターミナルタブは常に両方マウントしたままにし、
            # 非表示時は class(hidden)でCSS上隠すだけにしてある。ターミナルタブを
            # 条件付きレンダリングでVDOMから外し入れすると、タブを切り替えるたびに
            # TerminalPanelがunmount/remountされ、シリアル接続やxterm.jsの状態が
            # 消えてしまうため。
            div(class: tab_pane_class('code')) do
              component(Toolbar,
                current_path: state[:current_path],
                dirty: dirty?,
                status: state[:status],
                status_kind: state[:status_kind],
                on_save: -> { save_file }
              )

              component(Editor,
                current_path: state[:current_path],
                content: state[:content]
              )
            end

            div(class: tab_pane_class('terminal')) { render_terminal_panel }

            component(LogPanel,
              active_tab: state[:log_tab],
              build_status: state[:build_status],
              build_log: state[:build_log],
              platform_status: state[:platform_status],
              platform_log: state[:platform_log],
              selected_platform: value_of(state[:project_config], 'platform'),
              on_tab_change: ->(tab) { patch(log_tab: tab) },
              on_build_refresh: -> { refresh_build_status },
              on_platform_refresh: -> { refresh_platform_status }
            )
          end
        end
      end
    end

    # --- イベントハンドラ ------------------------------------------------

    def handle_select_code_tab(event)
      event.preventDefault
      patch(editor_tab: 'code')
    end

    def handle_select_terminal_tab(event)
      event.preventDefault
      patch(editor_tab: 'terminal')
    end

    def handle_terminal_connect(event)
      event.preventDefault
      terminal_connected? ? terminal_disconnect : terminal_connect
    end

    def handle_terminal_upload(event)
      event.preventDefault
      upload_app_directory
    end

    # 行番号カラムを本文のスクロールに追従させる
    def handle_scroll(event)
      scroll = refs[:scroll]
      lines = refs[:lines]
      return unless scroll && lines
      lines[:scrollTop] = scroll[:scrollTop]
    end

    private

    def render_editor_tabs
      div(class: 'editor-tabs') do
        render_editor_tab_button('code', 'エディタ', :handle_select_code_tab)
        render_editor_tab_button('terminal', 'ターミナル', :handle_select_terminal_tab)
      end
    end

    def render_editor_tab_button(key, label, handler)
      classes = key == state[:editor_tab] ? 'editor-tab active' : 'editor-tab'
      button(class: classes, onclick: handler) { label }
    end

    def tab_pane_class(key)
      key == state[:editor_tab] ? 'tab-pane' : 'tab-pane hidden'
    end

    # --- サイドバー(ファイルツリー) ----------------------------------------
    #
    # ツリー表示自体は汎用コンポーネント TreeView (tree_view.rb) に任せてあり、
    # ここでは state[:files](プロジェクト直下からの相対パスのフラットな配列)を
    # TreeView が期待するノード構造(name/path/type/childrenを持つHash)に
    # 組み立てる部分と、どのディレクトリを折りたたむかの状態(collapsed_dirs)
    # だけを持つ。

    def render_file_tree
      if state[:project].nil?
        div(class: 'sidebar-message') { 'プロジェクトが開かれていません。メニューバーの「プロジェクトを開く」から開いてください' }
      elsif state[:loading_files]
        div(class: 'sidebar-message') { '読み込み中…' }
      elsif state[:files].empty? && state[:dirs].empty?
        div(class: 'sidebar-message') { '編集できるファイルがありません' }
      else
        component(TreeView,
          nodes: file_tree_nodes,
          collapsed: state[:collapsed_dirs],
          selected: state[:current_path],
          icon_for: ->(node) { file_tree_icon(node) },
          on_select: ->(path) { open_file(path) },
          on_toggle: ->(path) { toggle_tree_dir(path) },
          on_context_menu: ->(node, event) { open_tree_context_menu(node, event) }
        )
      end
    end

    def toggle_tree_dir(path)
      collapsed = state[:collapsed_dirs]
      if collapsed.include?(path)
        patch(collapsed_dirs: collapsed - [path])
      else
        patch(collapsed_dirs: collapsed + [path])
      end
    end

    # 拡張子で色分けする既存のバッジ表示(style.cssの.file-icon.rb等)をそのまま使う。
    # ディレクトリにはアイコンを付けない(TreeView側のキャレットだけで十分なため)。
    def file_tree_icon(node)
      return nil if node[:type] == :dir

      ext = extension(node[:name])
      { class: ext, label: ext }
    end

    # state[:files] (例: ["app/app.rb", "mrbgems/picoruby_hello_world/mrbgem.rake"]) を
    # "/" 区切りで分解し、ディレクトリはまとめてネストしたノード配列に組み立てる。
    # 各階層でディレクトリを先に、それぞれ名前順に並べる。
    #
    # state[:dirs](GET /api/dirsで取得した、中身が空のものも含む全ディレクトリ)も
    # 合わせて挿入する。state[:files]だけからではファイルを1つも含まない空の
    # フォルダを表現できない(パスの並びにディレクトリ単体のエントリが出てこないため)。
    def file_tree_nodes
      root = {}
      state[:files].each { |path| insert_file_tree_path(root, path.split('/'), '') }
      state[:dirs].each { |path| insert_file_tree_dir_path(root, path.split('/'), '') }
      sorted_file_tree_nodes(root)
    end

    # root は { セグメント名 => { node:, children: {セグメント名 => ...} } } という
    # 中間表現(最終的な配列に組み立てる前の、パス分解の途中経過を持つ入れ物)。
    # prefix は「ここまでのセグメントを"/"で連結したパス」で、再帰のたびに伸びていく。
    def insert_file_tree_path(root, segments, prefix)
      name = segments[0]
      path = prefix.empty? ? name : "#{prefix}/#{name}"
      entry = (root[name] ||= { children: {} })

      if segments.length == 1
        entry[:node] = { name: name, path: path, type: :file }
      else
        entry[:node] ||= { name: name, path: path, type: :dir }
        insert_file_tree_path(entry[:children], segments[1, segments.length - 1], path)
      end
    end

    # insert_file_tree_pathのディレクトリ専用版。末尾のセグメントも:dirとして
    # 挿入する(ファイルの経路の途中に出てくる中間ディレクトリと違い、ここでは
    # そのパスそのものがディレクトリであることが分かっている)。既にファイル経由で
    # 同じパスにノードが作られていれば(`entry[:node] ||=`により)上書きしない。
    def insert_file_tree_dir_path(root, segments, prefix)
      name = segments[0]
      path = prefix.empty? ? name : "#{prefix}/#{name}"
      entry = (root[name] ||= { children: {} })
      entry[:node] ||= { name: name, path: path, type: :dir }

      return if segments.length == 1
      insert_file_tree_dir_path(entry[:children], segments[1, segments.length - 1], path)
    end

    def sorted_file_tree_nodes(root)
      names = root.keys.sort
      dirs = names.select { |name| root[name][:node][:type] == :dir }
      files = names.select { |name| root[name][:node][:type] == :file }

      (dirs + files).map do |name|
        node = root[name][:node]
        if node[:type] == :dir
          { name: node[:name], path: node[:path], type: :dir, children: sorted_file_tree_nodes(root[name][:children]) }
        else
          node
        end
      end
    end

    # --- ターミナル(xterm.js + Web Serial) --------------------------------
    #
    # R2P2-ESP32のUSBシリアルに、ブラウザのWeb Serial API (JS::WebSerial、
    # picoruby-wasm本体が提供する。picoruby.org/terminal と同じ仕組み)経由で
    # 直接つなぎ、xterm.jsでターミナルとして表示する。ビルド/インストールとは違い
    # サーバは一切関与しない(ブラウザ⇔実機のUSBが直結)。
    #
    # 「app/ をアップロード」ボタンは、R2P2のシェル(picoruby-shell)がプロンプトで
    # Ctrl-B(STX, 0x02)を受け取るとPicoModemセッション(picoruby-picomodem。
    # picoruby-shellのデフォルト依存gemなので、R2P2-ESP32の標準ビルドには常に
    # 含まれている。R2P2-ESP32/components/picoruby-esp32/picoruby/mrbgems/
    # picoruby-shell/mrbgem.rake 参照)に入る仕組みを使い、現在のプロジェクトの
    # app/以下をファイルごとに実機の/home/以下へ書き込む。PicoModemは1セッションに
    # つき1ファイルのFILE_WRITEしか処理せずシェルへ戻るため、複数ファイルは
    # 「Ctrl-B送信→ACK待ち→FILE_WRITE」をファイルごとに繰り返す。
    #
    # フレームの組み立て・CRC計算・エラー処理・自動再接続は picoruby/picoruby.github.io
    # の pages/r2p2/terminal.rb (picoruby.org/terminal の実装)にあるPicoModem
    # ホストクライアント/自動再接続をほぼそのまま移植したもの。

    def render_terminal_panel
      div(class: 'terminal-panel') do
        div(class: 'terminal-controls') do
          render_terminal_connect_button
          render_terminal_upload_button
          span(class: "terminal-status #{state[:terminal_status]}") { state[:terminal_status_message] }
        end
        div(class: 'terminal-container', ref: :terminal_container)
        render_terminal_upload_log
      end
    end

    def terminal_connected?
      state[:terminal_status] == 'connected'
    end

    def render_terminal_connect_button
      if state[:terminal_status] == 'connecting'
        button(class: 'terminal-connect', disabled: true) { '接続中…' }
      else
        button(class: 'terminal-connect', onclick: :handle_terminal_connect) { terminal_connected? ? '切断' : 'デバイスに接続' }
      end
    end

    def render_terminal_upload_button
      if terminal_connected? && !state[:terminal_uploading]
        button(class: 'terminal-upload', onclick: :handle_terminal_upload) { 'app/ をアップロード' }
      else
        button(class: 'terminal-upload', disabled: true) { state[:terminal_uploading] ? 'アップロード中…' : 'app/ をアップロード' }
      end
    end

    def render_terminal_upload_log
      return if state[:terminal_upload_log].empty?
      tag(:pre, class: 'terminal-upload-log') { state[:terminal_upload_log].join("\n") }
    end

    # xterm.jsの初期化。EditorApp(ルートコンポーネント)のcomponent_mountedから
    # 一度だけ呼ばれる。まだターミナルタブが非表示(class=hidden、display:none)の
    # 間はコンテナの寸法が0になるが、`terminal.open`自体は非表示要素に対しても
    # 問題なく行える。実際の行数/桁数はタブを表示したときにResizeObserverが
    # コンテナの寸法変化を検知して`fit`し直すので、正しいサイズに追従する。
    def setup_terminal
      container = refs[:terminal_container]
      return unless container

      opts = JS.global.create_object
      opts[:scrollback] = 1000
      opts[:cursorBlink] = true
      opts[:convertEol] = true
      opts[:fontFamily] = '"SF Mono", Menlo, Consolas, "Courier New", monospace'
      opts[:fontSize] = 14
      theme = JS.global.create_object
      theme[:background] = '#1a1a1a'
      opts[:theme] = theme

      xterm = JS.global[:Terminal].new(opts)
      @terminal_fit_addon = JS.global[:FitAddon][:FitAddon].new
      xterm.loadAddon(@terminal_fit_addon)
      xterm.open(container)
      @xterm = xterm
      fit_terminal

      JS.global[:ResizeObserver].new { |_entries| fit_terminal }.observe(container)

      # Escapeキーをブラウザに奪われないようにする(全画面解除等のショートカットと衝突するため)
      xterm.attachCustomKeyEventHandler do |event|
        event.preventDefault if event[:key].to_s == 'Escape'
        true
      end

      # 入力はそのままシリアルへ流す(R2P2のシェルが側でエコーバックする)
      xterm.onData { |data| terminal_send_bytes(data.to_s) }
    end

    def fit_terminal
      @terminal_fit_addon&.fit
    end

    def terminal_connect
      unless JS::WebSerial.supported?
        patch(terminal_status: 'disconnected', terminal_status_message: 'Web Serial APIに対応していないブラウザです(Chrome/Edge推奨)')
        return
      end

      patch(terminal_status: 'connecting', terminal_status_message: '接続中…')

      begin
        JS::WebSerial.connect(baud_rate: 115_200) do |ws|
          @terminal_port = ws
          ws.start_terminal_read(@xterm) if @xterm
          ws.on_disconnect { handle_terminal_port_disconnected }
        end
        # ユーザーが明示的に「切断」するまでは、デバイス側の再起動等で
        # ポートが一旦消えても自動再接続を試みる(watch_for_terminal_reconnect参照)。
        @terminal_auto_reconnect = true
        patch(terminal_status: 'connected', terminal_status_message: '接続済み')
        @xterm&.focus
      rescue => e
        @terminal_port = nil
        patch(terminal_status: 'disconnected', terminal_status_message: "接続エラー: #{e.message}")
      end
    end

    # ユーザーがボタンを押しての明示的な切断。以後は自動再接続もしない。
    def terminal_disconnect
      @terminal_auto_reconnect = false
      port = @terminal_port
      @terminal_port = nil
      patch(terminal_status: 'disconnected', terminal_status_message: '未接続')
      return unless port

      port.close rescue nil
    end

    # ポート側からの切断通知(_set_on_disconnect経由、または後述の
    # navigator.serialのdisconnectイベント)。ユーザーの明示的な切断とは違い
    # @terminal_auto_reconnectはそのままにしておく(自動再接続待ちの状態にする)。
    def handle_terminal_port_disconnected
      return unless @terminal_port

      @terminal_port = nil
      if @terminal_auto_reconnect
        patch(terminal_status: 'connecting', terminal_status_message: 'デバイスが再起動中です…自動的に再接続します')
      else
        patch(terminal_status: 'disconnected', terminal_status_message: 'デバイスが切断されました')
      end
    end

    # デバイスがCPUリセット等で再起動すると、USBの列挙が一瞬切れてから
    # 同じ物理ポートとして再度現れる(Web Serial的には対象ポートの'disconnect'に
    # 続けて、ブラウザ全体に'connect'イベントが飛んでくる)。
    # picoruby.org/terminal (pages/r2p2/terminal.rb)のApp#connect/bind_eventsと
    # 同じ仕組みで、権限を与え済みのポートが再度現れたら(ユーザー操作なしに)
    # 自動で開き直す。
    #
    # JS::WebSerial._watch_connect_events / _take_last_connected_port は
    # npmパッケージのwasmにC拡張として直接コンパイルされているが、mrblib側に
    # 高レベルのラッパーメソッドが無い(webserial.rbのRuby側APIには存在しない)
    # ため、"_"付きのまま直接呼び出している。実際に呼べることは
    # `JS::WebSerial.methods(false)`をブラウザのコンソールに出して確認済み。
    def watch_for_terminal_reconnect
      return unless JS::WebSerial.supported?

      JS::WebSerial._watch_connect_events
      JS.global.addEventListener('serial-port-connect') { attempt_terminal_auto_reconnect }

      # 個別ポートのon_disconnect(_set_on_disconnect)がブラウザ/デバイスの
      # 組み合わせによっては発火しないことがあるための保険。terminal.rbでも
      # navigator.serial自体のdisconnectイベントを別途見ている。
      JS.global[:navigator][:serial].addEventListener('disconnect') { handle_terminal_port_disconnected }
    end

    def attempt_terminal_auto_reconnect
      return unless @terminal_auto_reconnect
      return if @terminal_port

      raw_port = JS::WebSerial._take_last_connected_port
      return unless raw_port

      patch(terminal_status: 'connecting', terminal_status_message: '再接続中…')
      # 再起動直後はまだUSBの列挙が安定していないことがあるため、
      # terminal.rbに倣って少し待ってから開く。
      sleep_ms 1500

      begin
        ws = JS::WebSerial.new(raw_port)
        ws.open(baud_rate: 115_200)
        ws.start_terminal_read(@xterm) if @xterm
        ws.on_disconnect { handle_terminal_port_disconnected }
        @terminal_port = ws
        patch(terminal_status: 'connected', terminal_status_message: '再接続しました')
      rescue => e
        patch(terminal_status: 'disconnected', terminal_status_message: "再接続に失敗しました: #{e.message}")
      end
    end

    def terminal_send_bytes(str)
      @terminal_port&.write(str)
    end

    # --- app/ のアップロード(PicoModemプロトコル) ---------------------------

    def upload_app_directory
      return if state[:terminal_uploading]
      return unless terminal_connected?

      files = terminal_app_files
      if files.empty?
        patch(terminal_upload_log: ['app/ 以下にアップロード可能なファイルがありません'])
        return
      end

      patch(terminal_uploading: true, terminal_upload_log: ["#{files.length}個のファイルをアップロードします…"])
      upload_next_terminal_file(files, 0)
    end

    # state[:files](現在のプロジェクトのALLOWED_EXTENSIONSファイル一覧)から
    # "app/"配下だけを取り出し、[プロジェクト内の相対パス, 実機上のパス]の
    # ペアにする。POST /api/buildがapp/以下をstorage/home/へコピーする
    # (=実機からは/home/以下に見える)のと対応を合わせてある。
    def terminal_app_files
      result = []
      (state[:files] || []).each do |path|
        next unless path.start_with?('app/')
        relative = path.sub('app/', '')
        next if relative.empty?
        result << [path, "/home/#{relative}"]
      end
      result
    end

    # ファイルを1つずつ順番に処理する(継続渡し)。Funicular::HTTPのコールバックが
    # 同期/非同期どちらであっても、必ず1ファイルの転送が完全に終わってから
    # 次のCtrl-B送信に進むようにするため、Enumerable#eachではなくこの形にしてある
    # (PicoModemは1本のシリアル接続を排他的に使うプロトコルなので、複数ファイルの
    # 転送が重なるとフレームが混ざって壊れる)。
    def upload_next_terminal_file(files, index)
      if index >= files.length
        patch(terminal_uploading: false)
        append_terminal_upload_log('アップロードが完了しました')
        return
      end

      relative_path, device_path = files[index]
      upload_one_terminal_file(relative_path, device_path) { upload_next_terminal_file(files, index + 1) }
    end

    def upload_one_terminal_file(relative_path, device_path, &done)
      append_terminal_upload_log("#{relative_path} -> #{device_path} …")

      Funicular::HTTP.get("/api/file?path=#{encode(relative_path)}") do |response|
        unless response.ok
          append_terminal_upload_log('  読み込みに失敗しました')
          done.call
          next
        end

        content = value_of(response.data, 'content').to_s
        begin
          enter_picomodem_mode
          write_picomodem_file(device_path, content)
          append_terminal_upload_log("  完了 (#{content.bytesize} bytes)")
        rescue => e
          append_terminal_upload_log("  失敗: #{e.message}")
        ensure
          exit_picomodem_mode
          done.call
        end
      end
    end

    # --- PicoModemクライアント(ホスト側) -----------------------------------
    # 実装は picoruby.org/terminal (picoruby/picoruby.github.io の
    # pages/r2p2/terminal.rb)のPicoModemクライアント部分に準拠している。

    def enter_picomodem_mode
      raise 'デバイスに接続されていません' unless @terminal_port
      js_port = @terminal_port.instance_variable_get(:@js_port)

      JS::WebSerial.binary_capture_start(js_port)
      @terminal_port.write("\x02")
      @terminal_port.drain.await

      waited = 0
      while waited < TERM_TIMEOUT_MS
        b = JS::WebSerial.binary_capture_read(js_port, 1)
        if b && 0 < b.bytesize
          return if b.getbyte(0) == 0x06
          next
        end
        sleep_ms 10
        waited += 10
      end

      JS::WebSerial.binary_capture_stop(js_port) rescue nil
      raise 'デバイスからの応答がありません(R2P2のプロンプトが表示されているか確認してください)'
    end

    def exit_picomodem_mode
      return unless @terminal_port
      js_port = @terminal_port.instance_variable_get(:@js_port)
      JS::WebSerial.binary_capture_stop(js_port) rescue nil
    end

    def write_picomodem_file(path, content)
      js_port = @terminal_port.instance_variable_get(:@js_port)

      send_picomodem_frame(TERM_FILE_WRITE, [content.bytesize].pack('N') + path)

      frame = recv_picomodem_frame(js_port)
      raise 'タイムアウト(書き込み開始の応答待ち)' unless frame
      raise "デバイスエラー: #{frame[1]}" if frame[0] == TERM_ERROR
      raise "想定外の応答: 0x#{frame[0].to_s(16)}" unless frame[0] == TERM_FILE_ACK

      offset = 0
      while offset < content.bytesize
        remain = content.bytesize - offset
        size = remain < TERM_CHUNK_SIZE ? remain : TERM_CHUNK_SIZE
        chunk = content.byteslice(offset, size)
        send_picomodem_frame(TERM_CHUNK, chunk)

        ack = recv_picomodem_frame(js_port)
        raise "タイムアウト(#{offset}バイト目)" unless ack
        raise "デバイスエラー: #{ack[1]}" if ack[0] == TERM_ERROR
        raise "想定外の応答: 0x#{ack[0].to_s(16)}" unless ack[0] == TERM_CHUNK_ACK

        offset += size
      end

      frame = recv_picomodem_frame(js_port)
      raise 'タイムアウト(完了待ち)' unless frame
      raise "デバイスエラー: #{frame[1]}" if frame[0] == TERM_ERROR
      raise "想定外の応答: 0x#{frame[0].to_s(16)}" unless frame[0] == TERM_DONE_ACK

      payload = frame[1]
      return unless 5 <= payload.bytesize

      status = payload.getbyte(0)
      remote_crc = payload.byteslice(1, 4).unpack('N')[0]
      local_crc = CRC.crc32(content)
      raise 'CRC32が一致しません(転送中にデータが壊れた可能性があります)' unless status == TERM_OK && local_crc == remote_crc
    end

    def send_picomodem_frame(cmd, payload = '')
      body = cmd.chr + payload.to_s
      crc = CRC.crc16(body)
      frame = [0x02, body.bytesize].pack('Cn') + body + [crc].pack('n')
      send_picomodem_bytes(frame)
    end

    def send_picomodem_bytes(data)
      return unless @terminal_port
      off = 0
      while off < data.bytesize
        remain = data.bytesize - off
        size = remain < TERM_TX_CHUNK_SIZE ? remain : TERM_TX_CHUNK_SIZE
        @terminal_port.write(data.byteslice(off, size))
        off += size
        sleep_ms(TERM_TX_CHUNK_GAP_MS) if off < data.bytesize
      end
      @terminal_port.drain.await
    end

    def recv_picomodem_frame(js_port)
      stx = read_picomodem_exact(js_port, 1)
      return nil unless stx
      return nil unless stx.getbyte(0) == 0x02

      len_bytes = read_picomodem_exact(js_port, 2)
      return nil unless len_bytes
      length = len_bytes.unpack('n')[0]

      rest = read_picomodem_exact(js_port, length + 2)
      return nil unless rest
      body = rest.byteslice(0, length)
      expected_crc = rest.byteslice(length, 2).unpack('n')[0]
      return nil unless CRC.crc16(body) == expected_crc

      cmd = body.getbyte(0)
      payload = 1 < length ? body.byteslice(1, length - 1) : ''
      [cmd, payload]
    end

    def read_picomodem_exact(js_port, n)
      buf = ''
      waited = 0
      while buf.bytesize < n
        chunk = JS::WebSerial.binary_capture_read(js_port, n - buf.bytesize)
        if chunk && 0 < chunk.bytesize
          buf << chunk
          waited = 0
        else
          return nil if TERM_TIMEOUT_MS <= waited
          sleep_ms 10
          waited += 10
        end
      end
      buf
    end

    def append_terminal_upload_log(line)
      patch(terminal_upload_log: state[:terminal_upload_log] + [line])
    end

    # --- ファイルメニュー(プロジェクトを開く/mrbgemを追加/新規ファイル/新しいフォルダ) --

    # ファイル/ターゲットの2つのメニューは同時に開かない(片方を開いたらもう片方を閉じる)。
    def toggle_file_menu
      patch(file_menu_open: !state[:file_menu_open], target_menu_open: false)
    end

    def toggle_target_menu
      patch(target_menu_open: !state[:target_menu_open], file_menu_open: false)
    end

    # 「プロジェクトを開く」ダイアログを開く。常にホームディレクトリから始める
    # (「最初はホームディレクトリが開いている状態で」という要望)。pathを渡さずに
    # load_browse_dirを呼ぶと、サーバ側(GET /api/browse)がDir.homeへ解決する。
    def open_project_browser
      patch(file_menu_open: false, context_menu: nil, project_browser: {
        path: nil, parent: nil, entries: [], loading: true, error: nil,
        creating: false, create_error: nil, open_error: nil
      })
      load_browse_dir(nil)
    end

    # ディレクトリブラウザで別の場所へ移動する(パンくず・一覧項目クリック・
    # 「上へ」ボタン、いずれもこれを通る)。失敗しても現在表示中の一覧は保持し
    # (壊れたリンクで迷子にならないように)、エラーメッセージだけ出す。
    def load_browse_dir(path)
      return unless state[:project_browser]

      patch(project_browser: state[:project_browser].merge(loading: true, error: nil))

      query = path.to_s.empty? ? '' : "?path=#{encode(path)}"
      Funicular::HTTP.get("/api/browse#{query}") do |response|
        next unless state[:project_browser]

        if response.ok
          data = response.data || {}
          patch(project_browser: state[:project_browser].merge(
            path: value_of(data, 'path'),
            parent: value_of(data, 'parent'),
            entries: value_of(data, 'entries') || [],
            loading: false,
            error: nil
          ))
        else
          patch(project_browser: state[:project_browser].merge(loading: false, error: response.error_message))
        end
      end
    end

    def start_create_folder
      return unless state[:project_browser]
      patch(project_browser: state[:project_browser].merge(creating: true, create_error: nil))
    end

    def cancel_create_folder
      return unless state[:project_browser]
      patch(project_browser: state[:project_browser].merge(creating: false, create_error: nil))
    end

    def confirm_create_folder(name)
      browser = state[:project_browser]
      return unless browser

      cleaned = name.to_s.strip
      if cleaned.empty?
        patch(project_browser: browser.merge(create_error: '入力してください'))
        return
      end

      Funicular::HTTP.post('/api/browse', { path: browser[:path], name: cleaned }) do |response|
        next unless state[:project_browser]

        if response.ok
          data = response.data || {}
          patch(project_browser: state[:project_browser].merge(
            path: value_of(data, 'path'),
            parent: value_of(data, 'parent'),
            entries: value_of(data, 'entries') || [],
            loading: false,
            error: nil,
            creating: false,
            create_error: nil
          ))
        else
          patch(project_browser: state[:project_browser].merge(create_error: response.error_message))
        end
      end
    end

    def open_add_mrbgem_dialog
      return if state[:project].nil?

      patch(file_menu_open: false, context_menu: nil, prompt_dialog: {
        kind: :add_mrbgem,
        title: 'mrbgemを追加',
        label: 'mrbgem名(英数字・_・-のみ)',
        placeholder: 'picoruby_my_gem',
        confirm_label: '追加',
        error: nil
      })
    end

    # 新規ファイル・新しいフォルダは、実機起動スクリプトの置き場であるapp/配下だけを
    # 対象にしている(app.rb側のunder_app_dir?と対応)。「ファイル」メニューからは
    # app/を省いた相対パス(ネストしたパスも可)を、ツリーのコンテキストメニューからは
    # 右クリックしたディレクトリ内でのファイル名だけを入力させる。どちらもcontext_dir
    # (前者は固定で'app'、後者は右クリックしたディレクトリのpath)を基準にした相対パス
    # という点は同じなので、show_new_file_dialog/show_new_folder_dialogに集約している。
    def open_new_file_dialog
      return if state[:project].nil?
      show_new_file_dialog('app')
    end

    def open_new_folder_dialog
      return if state[:project].nil?
      show_new_folder_dialog('app')
    end

    def show_new_file_dialog(context_dir)
      patch(file_menu_open: false, context_menu: nil, prompt_dialog: {
        kind: :new_file,
        title: '新規ファイル',
        label: context_dir_label(context_dir, '拡張子は.rb'),
        placeholder: context_dir == 'app' ? 'utils/foo.rb' : 'foo.rb',
        confirm_label: '作成',
        error: nil,
        context_dir: context_dir
      })
    end

    def show_new_folder_dialog(context_dir)
      patch(file_menu_open: false, context_menu: nil, prompt_dialog: {
        kind: :new_folder,
        title: '新しいフォルダ',
        label: context_dir_label(context_dir, nil),
        placeholder: 'utils',
        confirm_label: '作成',
        error: nil,
        context_dir: context_dir
      })
    end

    def context_dir_label(context_dir, note)
      base = context_dir == 'app' ? 'app/ からの相対パス' : "#{context_dir}/ 内の名前"
      note ? "#{base}。#{note}" : base
    end

    # PromptDialogの確定ボタン(または入力欄でのEnter)から呼ばれる。
    # kindによってmrbgem追加/新規ファイル作成/新規フォルダ作成のどれを行うか分岐する。
    def handle_prompt_confirm(value)
      dialog = state[:prompt_dialog]
      return unless dialog

      name = value.to_s.strip
      if name.empty?
        patch(prompt_dialog: dialog.merge(error: '入力してください'))
        return
      end

      case dialog[:kind]
      when :add_mrbgem then add_mrbgem(name)
      when :new_file then create_file(to_full_path(dialog[:context_dir], name))
      when :new_folder then create_folder(to_full_path(dialog[:context_dir], name))
      end
    end

    # ダイアログに入力された相対パスの先頭にcontext_dir(基準ディレクトリ)を補う。
    # ユーザーが誤って基準ディレクトリ自体を書いてしまっても二重にはならないようにする。
    #
    # 正規表現(\Aアンカー)は使わない。PicoRuby.wasm上のRegexpはJSのRegExpへ
    # そのまま委譲される作りで、JSは\Aをサポートしないため
    # 「Invalid regular expression」でArgumentErrorになった(実際にブラウザで
    # 踏んで発覚。この例外はコールバック内で発生するため画面上には何も表示されず、
    # ブラウザのコンソールにだけ出る=「ボタンを押しても何も起きない」ように見える、
    # setTimeoutの罠と同じ性質の落とし穴)。
    def to_full_path(context_dir, rel)
      cleaned = rel.to_s
      cleaned = cleaned[1, cleaned.length - 1].to_s while cleaned.start_with?('/')
      prefix = "#{context_dir}/"
      cleaned.start_with?(prefix) ? cleaned : "#{prefix}#{cleaned}"
    end

    def prompt_dialog_error(message)
      dialog = state[:prompt_dialog]
      return unless dialog
      patch(prompt_dialog: dialog.merge(error: (message && !message.empty?) ? message : '失敗しました'))
    end

    # プロジェクトを開く(新規にダイアログから指定した場合も、メニューバーの
    # ドロップダウンでknown_projectsの中から切り替えた場合も、どちらもこれを通る)。
    # 既に開いているプロジェクトを選び直した場合は何もしない。
    #
    # 切り替え前のファイル関連のstateは全部そのプロジェクトに属さないものなので、
    # 作業中の編集状態(textareaの内容含む)をクリアしてから、新しいプロジェクトの
    # ファイル一覧・設定を取り直す。
    def open_project(path)
      if path == state[:project]
        # 既に開いているプロジェクトをブラウザ経由で選び直した場合は、
        # 何もせずダイアログだけ閉じる(ドロップダウン経由なら元々何もしない)。
        patch(project_browser: nil) if state[:project_browser]
        return
      end

      Funicular::HTTP.post('/api/project', { path: path }) do |response|
        if response.ok
          patch(
            project_browser: nil,
            project: value_of(response.data, 'path'),
            known_projects: value_of(response.data, 'known') || [],
            files: [],
            dirs: [],
            loading_files: true,
            collapsed_dirs: [],
            current_path: nil,
            content: '',
            saved_content: '',
            status: '',
            status_kind: '',
            settings_dialog_open: false,
            project_config: default_project_config
          )
          sync_textarea('')
          load_file_list
          load_dir_list
          load_project_config
        elsif state[:project_browser]
          # ダイアログ(DirectoryBrowserDialog)経由ならダイアログ内にエラーを出す。
          patch(project_browser: state[:project_browser].merge(open_error: response.error_message))
        else
          # ドロップダウンでの切り替え(ダイアログを経由しない)はトップレベルの
          # ステータス表示でエラーを伝える。
          patch(status: 'プロジェクトを開けませんでした', status_kind: 'error')
        end
      end
    end

    def add_mrbgem(name)
      Funicular::HTTP.post('/api/mrbgems', { name: name }) do |response|
        if response.ok
          patch(prompt_dialog: nil, status: 'mrbgemを追加しました', status_kind: 'ok')
          load_file_list
        else
          prompt_dialog_error(response.error_message)
        end
      end
    end

    def create_file(path)
      Funicular::HTTP.post('/api/files', { path: path }) do |response|
        if response.ok
          patch(prompt_dialog: nil, status: 'ファイルを作成しました', status_kind: 'ok')
          load_file_list
          load_dir_list # ネストしたパスなら中間フォルダも新しくできているため
          open_file(path)
        else
          prompt_dialog_error(response.error_message)
        end
      end
    end

    def create_folder(path)
      Funicular::HTTP.post('/api/folders', { path: path }) do |response|
        if response.ok
          patch(prompt_dialog: nil, status: 'フォルダを作成しました', status_kind: 'ok')
          load_dir_list
        else
          prompt_dialog_error(response.error_message)
        end
      end
    end

    # --- ツリーのコンテキストメニュー ---------------------------------------
    #
    # TreeView自体はファイル/プロジェクトの概念を知らない汎用コンポーネントなので、
    # 右クリックされたnode(type/path)を受け取ってメニューの中身を決めるのはこちら側の
    # 責務にしてある。出す項目はnodeの種類によって変える:
    #   - ファイル: 削除
    #   - "app" 自身: ファイルを作成/フォルダを作成(削除は出さない。プロジェクトの
    #     実行スクリプト置き場である app/ 自体を消せてしまうと壊れるため)
    #   - "app" 配下のディレクトリ: ファイルを作成/フォルダを作成/削除
    #   - "mrbgems" 自身: mrbgemを追加(専用の雛形を作る、他のディレクトリとは別メニュー)
    #   - それ以外のディレクトリ(mrbgems/<gem>やそのサブディレクトリ等): 削除のみ
    #     (ファイル/フォルダの新規作成はapp/配下限定のため、ここでは作成系を出さない)

    def open_tree_context_menu(node, event)
      kind = context_menu_kind(node)
      return unless kind

      patch(context_menu: {
        kind: kind,
        path: node[:path],
        x: event[:clientX].to_i,
        y: event[:clientY].to_i
      })
    end


    def context_menu_kind(node)
      return :file if node[:type] == :file
      return :mrbgems_dir if node[:path] == MRBGEMS_DIRNAME
      return :app_dir if node[:path] == APP_DIRNAME
      return :app_subdir if node[:path].start_with?("#{APP_DIRNAME}/")

      :other_dir
    end

    def close_tree_context_menu
      patch(context_menu: nil)
    end

    def render_tree_context_menu
      menu = state[:context_menu]
      # 全画面の透明なオーバーレイでメニュー以外へのクリック/右クリックを拾い、
      # 「メニューを出したまま別の操作をされて閉じ忘れる」ことがないようにする。
      div(class: 'context-menu-overlay', onclick: -> { close_tree_context_menu },
          oncontextmenu: ->(event) { event.preventDefault; close_tree_context_menu }) do
        div(class: 'context-menu', style: "left: #{menu[:x]}px; top: #{menu[:y]}px;") do
          render_context_menu_items(menu)
        end
      end
    end

    def render_context_menu_items(menu)
      case menu[:kind]
      when :file
        context_menu_item('削除…') { confirm_delete_file(menu[:path]) }
      when :app_dir
        context_menu_item('ファイルを作成…') { show_new_file_dialog(menu[:path]) }
        context_menu_item('フォルダを作成…') { show_new_folder_dialog(menu[:path]) }
      when :app_subdir
        context_menu_item('ファイルを作成…') { show_new_file_dialog(menu[:path]) }
        context_menu_item('フォルダを作成…') { show_new_folder_dialog(menu[:path]) }
        context_menu_item('削除…') { confirm_delete_folder(menu[:path]) }
      when :mrbgems_dir
        context_menu_item('mrbgemを追加…') { open_add_mrbgem_dialog }
      when :other_dir
        context_menu_item('削除…') { confirm_delete_folder(menu[:path]) }
      end
    end

    # メニュー項目を選んだら、まずメニュー自体を閉じてから実際の処理(ダイアログを
    # 開く/削除するなど)を実行する。
    def context_menu_item(label, &action)
      button(class: 'context-menu-item', onclick: -> { close_tree_context_menu; action.call }) { label }
    end

    # --- 削除 --------------------------------------------------------------

    # window.confirmはブラウザ標準のブロッキングダイアログ。Funicular本体の
    # Funicular.confirmも既定ではこれに委譲する作りになっている
    # (picoruby-funicular/mrblib/funicular.rb 参照。`!!JS.global.confirm(message)`)。
    # 削除は取り消せない操作なので、実行前に必ずここで確認する。
    def confirm_delete_file(path)
      return unless JS.global.confirm("#{path} を削除しますか?この操作は取り消せません。")
      delete_file(path)
    end

    def confirm_delete_folder(path)
      return unless JS.global.confirm("#{path} を中身ごと削除しますか?この操作は取り消せません。")
      delete_folder(path)
    end

    def delete_file(path)
      Funicular::HTTP.delete("/api/files?path=#{encode(path)}") do |response|
        if response.ok
          patch(status: 'ファイルを削除しました', status_kind: 'ok')
          close_open_file if state[:current_path] == path
          load_file_list
          load_dir_list
        else
          message = response.error_message
          patch(status: (message && !message.empty?) ? message : '削除に失敗しました', status_kind: 'error')
        end
      end
    end

    def delete_folder(path)
      Funicular::HTTP.delete("/api/folders?path=#{encode(path)}") do |response|
        if response.ok
          patch(status: 'フォルダを削除しました', status_kind: 'ok')
          close_open_file if current_path_under?(path)
          load_file_list
          load_dir_list
        else
          message = response.error_message
          patch(status: (message && !message.empty?) ? message : '削除に失敗しました', status_kind: 'error')
        end
      end
    end

    # 削除されたファイル(またはその親フォルダごと削除された場合)が現在エディタで
    # 開いたままになっていると、実体の無いファイルを編集し続けてしまうので閉じる。
    def close_open_file
      patch(current_path: nil, content: '', saved_content: '')
      sync_textarea('')
    end

    def current_path_under?(dir_path)
      current = state[:current_path]
      return false unless current
      current == dir_path || current.start_with?("#{dir_path}/")
    end

    # --- サーバとのやりとり ----------------------------------------------

    # 起動時にサーバが(同じプロセスのまま前のブラウザセッションなどで)既に
    # プロジェクトを開いているかどうか・これまでに開いたプロジェクト一覧
    # (known_projects、メニューバーのドロップダウンの選択肢)を確認する。
    # 未設定の間はメニューバーのドロップダウンが「プロジェクトを開く」ボタンとして
    # 表示される(menu_bar.rb参照)ので、ユーザーがそれを押すまで何もしない
    # (自動でダイアログを表示したりはしない)。
    def load_project
      Funicular::HTTP.get('/api/project') do |response|
        path = response.ok ? value_of(response.data, 'path') : nil
        known = response.ok ? (value_of(response.data, 'known') || []) : []
        patch(project: path, known_projects: known, loading_project: false)
        if path
          load_file_list
          load_dir_list
          load_project_config
        end
      end
    end

    # 現在のプロジェクトの設定(ターゲット・VM・USB Console)を取得する。
    # load_project(起動時)・open_project(切り替え時)から呼ばれる。
    def load_project_config
      Funicular::HTTP.get('/api/project/config') do |response|
        next unless response.ok

        data = response.data || {}
        patch(
          project_config: {
            'platform' => value_of(data, 'platform'),
            'vm' => value_of(data, 'vm'),
            'usb_console' => truthy?(value_of(data, 'usb_console'))
          }
        )
      end
    end

    def load_file_list
      Funicular::HTTP.get('/api/files') do |response|
        if response.ok
          patch(files: response.data || [], loading_files: false)
        else
          patch(
            files: [],
            loading_files: false,
            status: 'ファイル一覧の取得に失敗しました',
            status_kind: 'error'
          )
        end
      end
    end

    # 空フォルダもツリーに表示するための、ファイル一覧とは別のディレクトリ一覧取得。
    # file_tree_nodes参照。
    def load_dir_list
      Funicular::HTTP.get('/api/dirs') do |response|
        patch(dirs: response.data || []) if response.ok
      end
    end

    def open_file(path)
      return if path == state[:current_path]

      patch(status: '読み込み中…', status_kind: '')

      Funicular::HTTP.get("/api/file?path=#{encode(path)}") do |response|
        if response.ok
          content = value_of(response.data, 'content').to_s
          patch(
            current_path: path,
            content: content,
            saved_content: content,
            status: '',
            status_kind: ''
          )
          # 非制御の textarea なので、ファイル切り替え時はここで流し込む
          sync_textarea(content)
        else
          patch(status: '読み込みに失敗しました', status_kind: 'error')
        end
      end
    end

    def save_file
      path = state[:current_path]
      return unless path
      return unless dirty?

      # 送信時点の内容を控えておく(レスポンスが返る頃には編集が進んでいる可能性がある)
      sending = state[:content]

      Funicular::HTTP.post('/api/file', { path: path, content: sending }) do |response|
        if response.ok
          patch(saved_content: sending, status: '保存しました', status_kind: 'ok')
        else
          message = response.error_message
          patch(
            status: (message && !message.empty?) ? message : '保存に失敗しました',
            status_kind: 'error'
          )
        end
      end
    end

    def start_build
      return if state[:building]

      # ビルドの状態表示はログパネルのビルドタブにしか無いので、そちらに切り替える。
      patch(log_tab: 'build', building: true, build_status: 'running', build_log: '', build_log_offset: 0)

      Funicular::HTTP.post('/api/build', {}) do |response|
        if response.ok
          schedule_build_poll
        else
          message = response.error_message
          patch(
            building: false,
            build_status: 'failed',
            build_log: (message && !message.empty?) ? message : 'ビルドの開始に失敗しました'
          )
        end
      end
    end

    # ビルド中は一定間隔で自動的にログを取りに行く。完了(running以外)になったら止める。
    #
    # PicoRubyの JS::Object#setTimeout は setTimeout(delay_ms, &block) というシグネチャ
    # (picoruby-wasm の mrblib/js.rb 参照)で、コールバックは第一引数ではなくブロックとして
    # 渡す。JS.global.setTimeout(callback, delay) のように2引数で渡すと
    # 「ArgumentError: wrong number of arguments (given 2, expected 1)」になる。
    def schedule_build_poll
      JS.global.setTimeout(3000) { refresh_build_status }
    end

    # ログは切り詰めずに全量を表示するが、毎回全量を取り直すとPicoRuby.wasmでの
    # JSONパースが重くなる(数秒〜十秒固まる)ので、取得済みの長さ(offset)以降の
    # 差分だけを取って追記する(BackgroundJob#to_response_json参照)。
    # 1レスポンスは最大8,000文字で、続きがあれば(more)すぐ次を取りに行く。
    def refresh_build_status
      query = "?offset=#{state[:build_log_offset]}&run_id=#{state[:build_run_id]}"
      Funicular::HTTP.get("/api/build#{query}") do |response|
        next unless response.ok

        data = response.data || {}
        status = value_of(data, 'status').to_s
        still_running = status == 'running'
        log = merge_job_log(data, state[:build_log], state[:build_log_offset])

        if log
          patch(
            build_status: status,
            build_log: log,
            build_log_offset: value_of(data, 'next_offset').to_s.to_i,
            build_run_id: value_of(data, 'run_id').to_s,
            building: still_running
          )
        else
          patch(build_status: status, building: still_running)
        end

        # running の間だけポーリングを継続する。手動の「ログを更新」クリックと
        # ポーリングのタイマーが両方生きていると呼び出しが二重になりうるが、
        # 重複したレスポンスはmerge_job_logが捨てるので実害はない
        if truthy?(value_of(data, 'more'))
          JS.global.setTimeout(0) { refresh_build_status }
        elsif still_running
          schedule_build_poll
        end
      end
    end

    # GET /api/build・/api/platform のレスポンス(差分)を手元のログに反映した
    # 結果を返す。offsetが0なら(新しいジョブが始まった/初回取得)丸ごと置き換え、
    # 手元の長さと一致すれば追記。どちらでもなければ二重リクエストなどで
    # 既に反映済みの古いレスポンスなので nil(反映しない)を返す。
    def merge_job_log(data, current_log, current_offset)
      chunk = value_of(data, 'log').to_s
      offset = value_of(data, 'offset').to_s.to_i
      return chunk if offset == 0
      return nil unless offset == current_offset

      current_log + chunk
    end

    # 表示中のログ(タブ)の中身が変わったら、ログ表示欄を一番下までスクロールする。
    # .build-log はLogPanel(子コンポーネント)の中にあり、子は親の再描画のたびに
    # 作り直される(CLAUDE.md参照)ので、refではなくDOMを直接引く。
    # DOMへの反映後に実行されるよう setTimeout(0) で遅らせている。
    def scroll_log_to_bottom_if_changed
      log = state[:log_tab] == 'platform' ? state[:platform_log] : state[:build_log]
      key = "#{state[:log_tab]}:#{log.to_s.bytesize}"
      return if @prev_log_scroll_key == key

      @prev_log_scroll_key = key
      JS.global.setTimeout(0) do
        node = JS.global[:document].querySelector('.build-log')
        node[:scrollTop] = node[:scrollHeight].to_i if node
      end
    end

    def start_platform_setup
      return if state[:platform_building]
      return if value_of(state[:project_config], 'platform').to_s.empty?

      # ターゲットメニューから実行するので、メニューを閉じてログパネルを
      # セットアップのタブに切り替え、進捗がすぐ見えるようにする。
      patch(
        target_menu_open: false, log_tab: 'platform',
        platform_building: true, platform_status: 'running', platform_log: '', platform_log_offset: 0
      )

      Funicular::HTTP.post('/api/platform', {}) do |response|
        if response.ok
          schedule_platform_poll
        else
          message = response.error_message
          patch(
            platform_building: false,
            platform_status: 'failed',
            platform_log: (message && !message.empty?) ? message : 'セットアップの開始に失敗しました'
          )
        end
      end
    end

    # 仕組みはビルドのポーリングと同じ(schedule_build_poll参照)。
    def schedule_platform_poll
      JS.global.setTimeout(3000) { refresh_platform_status }
    end

    def refresh_platform_status
      query = "?offset=#{state[:platform_log_offset]}&run_id=#{state[:platform_run_id]}"
      Funicular::HTTP.get("/api/platform#{query}") do |response|
        next unless response.ok

        data = response.data || {}
        status = value_of(data, 'status').to_s
        still_running = status == 'running'
        log = merge_job_log(data, state[:platform_log], state[:platform_log_offset])

        if log
          patch(
            platform_status: status,
            platform_log: log,
            platform_log_offset: value_of(data, 'next_offset').to_s.to_i,
            platform_run_id: value_of(data, 'run_id').to_s,
            platform_building: still_running
          )
        else
          patch(platform_status: status, platform_building: still_running)
        end

        if truthy?(value_of(data, 'more'))
          JS.global.setTimeout(0) { refresh_platform_status }
        elsif still_running
          schedule_platform_poll
        end
      end
    end

    # --- プロジェクト設定ダイアログ -----------------------------------------
    # ターゲット・VM・USB Consoleは`~/.picoride/project.toml`(server.rb /
    # project_store.rb参照)に永続化しているプロジェクト単位の設定。

    # 現在保存されている設定(state[:project_config])を作業用のフィールドへ
    # コピーしてダイアログを開く。キャンセルすれば作業用フィールドは捨てられる。
    def open_settings_dialog
      config = state[:project_config] || {}
      patch(
        target_menu_open: false,
        settings_dialog_open: true,
        settings_platform: value_of(config, 'platform'),
        settings_vm: value_of(config, 'vm').to_s,
        settings_usb_console: truthy?(value_of(config, 'usb_console'))
      )
    end

    def save_project_settings
      platform = state[:settings_platform]
      vm = state[:settings_vm].to_s.empty? ? nil : state[:settings_vm]
      usb_console = state[:settings_usb_console]

      payload = { platform: platform, vm: vm, usb_console: usb_console }
      Funicular::HTTP.post('/api/project/config', payload) do |response|
        if response.ok
          patch(
            settings_dialog_open: false,
            project_config: { 'platform' => platform, 'vm' => vm, 'usb_console' => usb_console },
            status: 'プロジェクト設定を保存しました',
            status_kind: 'ok'
          )
        else
          message = response.error_message
          patch(status: (message && !message.empty?) ? message : '設定の保存に失敗しました', status_kind: 'error')
        end
      end
    end

    # --- 表示まわりのヘルパ ----------------------------------------------

    def dirty?
      !state[:current_path].nil? && state[:content] != state[:saved_content]
    end

    def refresh_highlight
      node = refs[:highlight]
      return unless node
      html = JS.global.funicularHighlight(state[:content], language).to_s
      node[:innerHTML] = html
    end

    def sync_textarea(content)
      node = refs[:editor]
      return unless node
      node[:value] = content
    end

    def insert_indent
      node = refs[:editor]
      return unless node

      value = node[:value].to_s
      from = node[:selectionStart].to_i
      to = node[:selectionEnd].to_i

      node[:value] = value[0, from].to_s + '  ' + value[to, value.length - to].to_s
      node[:selectionStart] = from + 2
      node[:selectionEnd] = from + 2

      patch(content: node[:value].to_s)
    end

    def language
      LANGUAGES[extension(state[:current_path])] || 'ruby'
    end

    def extension(path)
      parts = path.to_s.split('.')
      parts.length > 1 ? parts.last.to_s : ''
    end

    def encode(path)
      JS.global.encodeURIComponent(path).to_s
    end

    # JSONのパース結果がキーを String / Symbol どちらで持つかは環境差があるため両対応にする
    def value_of(data, key)
      return nil unless data
      data[key] || data[key.to_sym]
    end

    def truthy?(js_value)
      js_value.to_s == 'true'
    end
  end
end
