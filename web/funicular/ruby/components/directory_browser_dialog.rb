# 「プロジェクトを開く」のディレクトリ選択UI。絶対パスを直接テキスト入力させる
# 代わりに、よくあるファイルビューアのようにパンくず("/"区切りのクリック可能な
# セグメント)とサブディレクトリの一覧でファイルシステムを辿れるようにしてある。
#
# EditorAppの「子コンポーネントは親の再描画のたびに作り直される」制約により、
# このコンポーネント自身はinitialize_stateを持たない(表示専用)。現在地・
# 一覧・読み込み中/エラー状態は全部EditorApp側のstate[:project_browser]に
# 持たせ、propsとして受け取るだけにしてある(TreeViewと同じ設計)。新規フォルダ名の
# 入力欄だけはPromptDialogと同じ理由(ポーリング中の親再描画で入力中の文字が
# 消える)でrefベースの非制御コンポーネントにしてある。
#
# props:
#   path:              現在表示しているディレクトリの絶対パス(初回ロード前はnil)
#   parent:            1つ上のディレクトリの絶対パス(これ以上は上がれないならnil)
#   entries:           [{name:, path:}, ...] サブディレクトリの一覧
#   loading:           一覧取得中かどうか
#   error:             ナビゲーション(移動)時のエラーメッセージ(あれば)
#   creating:          「新しいフォルダ」の名前入力欄を表示するかどうか
#   create_error:      フォルダ作成時のエラーメッセージ(あれば)
#   open_error:        「このディレクトリを開く」実行時のエラーメッセージ(あれば)
#   on_navigate:       移動先の絶対パスを渡して呼ばれるlambda(パンくず・一覧項目・上へ)
#   on_open:           「このディレクトリを開く」ボタン
#   on_start_create:   「新しいフォルダ」ボタン(名前入力欄を開く)
#   on_confirm_create: 入力された名前(String)を渡して呼ばれるlambda
#   on_cancel_create:  新規フォルダ名入力のキャンセル
#   on_cancel:         ダイアログ全体のキャンセル(閉じる)
class DirectoryBrowserDialog < Funicular::Component
  def render
    div(class: 'dialog-overlay') do
      div(class: 'dialog directory-browser-dialog') do
        h2 { 'プロジェクトを開く' }
        render_breadcrumb
        div(class: 'directory-browser-toolbar') do
          render_up_button
          render_new_folder_button
        end
        render_navigate_error
        render_entry_list
        render_create_folder_row if props[:creating]
        render_open_error
        div(class: 'dialog-actions') do
          button(class: 'dialog-cancel', onclick: :handle_cancel) { 'キャンセル' }
          render_open_button
        end
      end
    end
  end

  def handle_cancel(event)
    event.preventDefault
    on_cancel = props[:on_cancel]
    on_cancel.call if on_cancel
  end

  def handle_open(event)
    event.preventDefault
    on_open = props[:on_open]
    on_open.call if on_open
  end

  def handle_up(event)
    event.preventDefault
    navigate_to(props[:parent])
  end

  def handle_start_create(event)
    event.preventDefault
    on_start_create = props[:on_start_create]
    on_start_create.call if on_start_create
  end

  def handle_cancel_create(event)
    event.preventDefault
    on_cancel_create = props[:on_cancel_create]
    on_cancel_create.call if on_cancel_create
  end

  def handle_confirm_create(event)
    event.preventDefault
    confirm_create
  end

  # Enterキーでも作成を確定できるようにする(PromptDialogと同じ)。
  def handle_create_keydown(event)
    confirm_create if event[:key].to_s == 'Enter'
  end

  private

  def navigate_to(path)
    return if path.to_s.empty?
    on_navigate = props[:on_navigate]
    on_navigate.call(path) if on_navigate
  end

  def confirm_create
    node = refs[:new_folder_input]
    return unless node

    on_confirm_create = props[:on_confirm_create]
    on_confirm_create.call(node[:value].to_s) if on_confirm_create
  end

  # 例: "/home/youchan/Projects" ->
  #   [{label: '/', path: '/'}, {label: 'home', path: '/home'},
  #    {label: 'youchan', path: '/home/youchan'}, {label: 'Projects', path: '/home/youchan/Projects'}]
  # PicoRuby.wasm上ではFile系メソッドの対応が不確かなため、素の文字列分割で求める
  # (menu_bar.rbのproject_labelと同じ理由)。
  def breadcrumb_segments
    path = props[:path].to_s
    return [] if path.empty?

    parts = path.split('/').reject { |p| p.empty? }
    crumbs = [{ label: '/', path: '/' }]
    acc = ''
    parts.each do |part|
      acc = "#{acc}/#{part}"
      crumbs << { label: part, path: acc }
    end
    crumbs
  end

  def render_breadcrumb
    div(class: 'directory-browser-breadcrumb') do
      breadcrumb_segments.each_with_index do |segment, index|
        span(class: 'breadcrumb-sep') { '/' } if index.positive?
        render_breadcrumb_segment(segment)
      end
    end
  end

  def render_breadcrumb_segment(segment)
    if segment[:path] == props[:path]
      span(class: 'breadcrumb-segment breadcrumb-current') { segment[:label] }
    else
      span(class: 'breadcrumb-segment', onclick: -> { navigate_to(segment[:path]) }) { segment[:label] }
    end
  end

  def render_up_button
    if props[:parent].to_s.empty?
      button(class: 'directory-browser-up', disabled: true) { '↑ 上の階層へ' }
    else
      button(class: 'directory-browser-up', onclick: :handle_up) { '↑ 上の階層へ' }
    end
  end

  def render_new_folder_button
    button(class: 'directory-browser-new-folder', onclick: :handle_start_create) { '新しいフォルダ…' }
  end

  def render_navigate_error
    return if props[:error].to_s.empty?
    div(class: 'prompt-error') { props[:error].to_s }
  end

  def render_entry_list
    div(class: 'directory-browser-list') do
      if props[:loading]
        div(class: 'directory-browser-message') { '読み込み中…' }
      elsif (props[:entries] || []).empty?
        div(class: 'directory-browser-message') { '(サブフォルダがありません)' }
      else
        (props[:entries] || []).each { |entry| render_entry(entry) }
      end
    end
  end

  # entryはJSON(GET /api/browseのentries)をそのまま渡しているため、
  # パース結果がシンボルキーになるとは限らない(文字列キーのHashになりうる)。
  # value_of(menu_bar.rbのproject_label付近と同じ理由)で両対応させる。
  def render_entry(entry)
    path = value_of(entry, 'path')
    div(class: 'directory-browser-item', key: path, onclick: -> { navigate_to(path) }) do
      span(class: 'directory-browser-item-icon') { '📁' }
      span(class: 'directory-browser-item-name') { value_of(entry, 'name') }
    end
  end

  def render_create_folder_row
    div(class: 'directory-browser-create') do
      tag(:input, type: 'text', ref: :new_folder_input, placeholder: '新しいフォルダ名',
                  onkeydown: :handle_create_keydown)
      button(class: 'dialog-confirm', onclick: :handle_confirm_create) { '作成' }
      button(class: 'dialog-cancel', onclick: :handle_cancel_create) { 'キャンセル' }
      render_create_error
    end
  end

  def render_create_error
    return if props[:create_error].to_s.empty?
    div(class: 'prompt-error') { props[:create_error].to_s }
  end

  def render_open_error
    return if props[:open_error].to_s.empty?
    div(class: 'prompt-error') { props[:open_error].to_s }
  end

  def render_open_button
    if props[:path].to_s.empty?
      button(class: 'dialog-confirm', disabled: true) { 'このディレクトリを開く' }
    else
      button(class: 'dialog-confirm', onclick: :handle_open) { 'このディレクトリを開く' }
    end
  end

  def value_of(data, key)
    return nil unless data
    data[key] || data[key.to_sym]
  end
end
