# 汎用的なツリー表示コンポーネント。「ファイル一覧」に限らず、
# name/path/type/childrenを持つノードの配列であれば何でも描画できるように
# 作ってある(あとで独立したコンポーネント/gemとして切り出すことを想定した設計)。
# ファイルパスの組み立てや読み込み中/空表示のような呼び出し側固有の事情は
# 一切知らない、純粋な表示コンポーネントにしてある。
#
# ノードの形(Hash、シンボルキー):
#   ディレクトリ: { name: "app", path: "app", type: :dir, children: [...] }
#   ファイル    : { name: "app.rb", path: "app/app.rb", type: :file }
# children は同じ形のノードの配列。ソート順など「どの順で並べるか」は
# 呼び出し側がnodesを組み立てる時点で決めておくこと(このコンポーネントは
# 渡された順にそのまま描画するだけ)。
#
# props:
#   nodes:      トップレベルのノード配列(必須)
#   collapsed:  折りたたみ中のディレクトリのpath配列(省略時は全部展開表示)
#   selected:   選択中(強調表示したい)ファイルのpath
#   icon_for:   ノードを受け取り { class:, label: } または nil を返すlambda(省略可、
#               nilを返すか未指定ならアイコンを描画しない)
#   on_select:  ファイルノードがクリックされたときに path を渡して呼ばれるlambda
#   on_toggle:  ディレクトリノードがクリックされたときに path を渡して呼ばれるlambda
#   on_context_menu: ノード(ファイル/ディレクトリどちらも)が右クリックされたときに
#                     (node, event) を渡して呼ばれるlambda(省略可)。どんなメニュー
#                     項目を出すかはこのコンポーネントは一切知らず、呼び出し側が
#                     nodeの中身(type/path)を見て判断する
#
# 折りたたみ状態そのものはこのコンポーネントの中には持たせていない。
# Funicularは呼び出し側(親)が再描画されるたびにこの子コンポーネントを
# 作り直す(initialize_stateを呼び直す)ため、「一度だけ初期化して使い回したい
# 状態」を持たせると壊れる(実際にターミナル機能でこれを踏んだ。詳細は
# editor_app.rbやCLAUDE.md参照)。折りたたみ状態は必ず呼び出し側のstateに
# 持たせ、props経由で渡すこと。
class TreeView < Funicular::Component
  def render
    render_children(props[:nodes] || [], top_level: true)
  end

  private

  def render_children(nodes, top_level: false)
    ul(class: top_level ? 'tree-view' : 'tree-children') do
      nodes.each { |node| render_node(node) }
    end
  end

  def render_node(node)
    if node[:type] == :dir
      render_dir_node(node)
    else
      render_file_node(node)
    end
  end

  def render_dir_node(node)
    path = node[:path]
    collapsed = collapsed?(path)

    li(key: path, class: 'tree-node tree-node-dir') do
      div(class: 'tree-row', onclick: -> { toggle(path) }, oncontextmenu: ->(event) { context_menu(node, event) }) do
        span(class: 'tree-caret') { collapsed ? '▸' : '▾' }
        render_icon(node)
        span(class: 'tree-label') { node[:name] }
      end

      render_children(node[:children] || []) unless collapsed
    end
  end

  def render_file_node(node)
    path = node[:path]
    classes = path == props[:selected] ? 'tree-node tree-node-file active' : 'tree-node tree-node-file'

    li(key: path, class: classes) do
      div(class: 'tree-row', onclick: -> { select_file(path) }, oncontextmenu: ->(event) { context_menu(node, event) }) do
        span(class: 'tree-caret-spacer')
        render_icon(node)
        span(class: 'tree-label') { node[:name] }
      end
    end
  end

  def render_icon(node)
    icon_for = props[:icon_for]
    return unless icon_for

    icon = icon_for.call(node)
    return unless icon

    span(class: "tree-icon #{icon[:class]}") { icon[:label].to_s }
  end

  def collapsed?(path)
    (props[:collapsed] || []).include?(path)
  end

  def toggle(path)
    on_toggle = props[:on_toggle]
    on_toggle.call(path) if on_toggle
  end

  def select_file(path)
    on_select = props[:on_select]
    on_select.call(path) if on_select
  end

  # ブラウザ標準の右クリックメニューは常に抑止し、呼び出し側にnode/eventを渡すだけ。
  def context_menu(node, event)
    event.preventDefault
    on_context_menu = props[:on_context_menu]
    on_context_menu.call(node, event) if on_context_menu
  end
end
