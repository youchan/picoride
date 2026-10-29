# コードエディタ(textarea + Prism ハイライト層 + 行番号)。
#
# App から `component(Editor, preserve: true, ...)` で呼び出す前提の子コンポーネント。
#
# ■ preserve: true が必須な理由
#
# Funicular は、子コンポーネントの props が前回と == でなければインスタンスを
# 作り直す。on_change などのラムダは描画のたびに新しい Proc になるので、
# preserve 無しだと App の patch のたびに Editor が作り直される。
# このコンポーネントは「最後に textarea へ流し込んだのはどのリビジョンか」
# 「最後にハイライトした内容は何か」をインスタンス変数で覚えているので、
# 作り直されるとそれが消え、毎回 textarea を書き戻してキャレットが末尾に飛ぶ。
# preserve: true ならインスタンスが保たれる(詳細は CLAUDE.md の「【重大】子コンポーネントは
# propsが変わると作り直される」の節)。
#
# ■ textarea とハイライト層は ref でこのコンポーネント自身が触る
#
# ref は「その要素を描画したコンポーネント」の refs にしか登録されないので、
# textarea・ハイライト層を直接いじる処理(内容の流し込み・ハイライト・Tab インデント)は
# 全部ここに置く。App とは props とコールバックだけでやり取りする。
#
# textarea は VDOM の制御下に置かず(value を render で出力せず)、ファイルを
# 切り替えたときだけ ref 経由で value を差し替える「非制御」にしている。
# 入力のたびに VDOM が value を書き戻すとキャレットが末尾に飛ぶため。
# ハイライト層 <code> も VDOM 上は子を持たない空要素として描画し、Prism が
# 生成した HTML を innerHTML に直接流し込む(子が無いので差分で消されない)。
#
# props:
#   path:      開いているファイルのプロジェクト内パス(nil なら未選択)
#   content:   App が持っている現在の内容(state[:content])
#   revision:  App がファイルを開く/閉じるたびに増やす番号。これが変わったときだけ
#              textarea に content を流し込む(入力中の内容は書き戻さない)
#   on_change: 入力で内容が変わったときに新しい内容(String)を渡して呼ぶ
#   on_save:   Ctrl+S / Cmd+S で呼ぶ
module PicoRIDE
  class Editor < Funicular::Component
    # 拡張子 → Prism の言語名(未知の拡張子は ruby 扱い。.rake も Ruby)
    LANGUAGES = { 'rb' => 'ruby', 'rake' => 'ruby', 'c' => 'c', 'h' => 'c' }

    def component_mounted
      sync_with_props
    end

    # preserve: true の子は、データの props が変わると差分を DOM に反映した後に
    # これが呼ばれる(Funicular の Patcher の :update_and_rebind)。
    def component_updated
      sync_with_props
    end

    def render
      div(class: 'editor-wrapper') do
        # 行番号は innerHTML を使わず、そのまま VDOM で描画する
        div(class: 'line-numbers', ref: :lines) do
          (1..line_count).each do |n|
            div { n.to_s }
          end
        end

        # スクロールする要素をこのコンテナ一箇所に集約し、
        # ハイライト層と textarea は CSS Grid で同じセルに重ねる(style.css 参照)
        div(class: 'editor-scroll-area', ref: :scroll, onscroll: :handle_scroll) do
          tag(:pre, class: 'highlight-layer') do
            tag(:code, ref: :highlight)
          end
          render_textarea
        end
      end
    end

    def handle_input(event)
      node = refs[:editor]
      return unless node
      notify_change(node[:value].to_s)
    end

    def handle_keydown(event)
      key = event[:key].to_s

      # Ctrl+S / Cmd+S で保存
      if key == 's' && (truthy?(event[:ctrlKey]) || truthy?(event[:metaKey]))
        event.preventDefault
        on_save = props[:on_save]
        on_save.call if on_save
        return
      end

      # Tab はフォーカス移動ではなくスペース2つの挿入にする
      if key == 'Tab'
        event.preventDefault
        insert_indent
      end
    end

    # 行番号カラムを本文のスクロールに追従させる
    def handle_scroll(event)
      scroll = refs[:scroll]
      lines = refs[:lines]
      return unless scroll && lines
      lines[:scrollTop] = scroll[:scrollTop]
    end

    private

    def render_textarea
      if props[:path]
        tag(:textarea,
          id: 'editor',
          ref: :editor,
          spellcheck: 'false',
          oninput: :handle_input,
          onkeydown: :handle_keydown
        )
      else
        tag(:textarea,
          id: 'editor',
          ref: :editor,
          spellcheck: 'false',
          disabled: true,
          placeholder: '左のファイル一覧から編集するファイルを選んでください'
        )
      end
    end

    # ファイルが切り替わった(revision が変わった)ときだけ textarea に内容を流し込み、
    # 内容かパスが前回のハイライト時から変わっていればハイライトし直す。
    def sync_with_props
      if @synced_revision != props[:revision]
        @synced_revision = props[:revision]
        node = refs[:editor]
        node[:value] = props[:content].to_s if node
      end

      content = props[:content].to_s
      path = props[:path]
      return if @highlighted_content == content && @highlighted_path == path

      @highlighted_content = content
      @highlighted_path = path
      refresh_highlight(content)
    end

    def refresh_highlight(content)
      node = refs[:highlight]
      return unless node
      node[:innerHTML] = JS.global.funicularHighlight(content, language).to_s
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

      notify_change(node[:value].to_s)
    end

    def notify_change(value)
      on_change = props[:on_change]
      on_change.call(value) if on_change
    end

    def line_count
      count = 1
      props[:content].to_s.each_char { |ch| count += 1 if ch == "\n" }
      count
    end

    def language
      LANGUAGES[extension(props[:path])] || 'ruby'
    end

    # File.extname は PicoRuby.wasm での対応が不確かなので素の文字列分割で求める
    def extension(path)
      parts = path.to_s.split('.')
      parts.length > 1 ? parts.last.to_s : ''
    end

    def truthy?(js_value)
      js_value.to_s == 'true'
    end
  end
end
