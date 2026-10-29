module PicoRIDE
  class Editor < Funicular::Component
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

    def render_textarea
      if props[:current_path]
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

    def line_count
      count = 1
      props[:content].each_char { |ch| count += 1 if ch == "\n" }
      count
    end

    def handle_input(event)
      node = refs[:editor]
      return unless node
      patch(content: node[:value].to_s)
    end

    def handle_keydown(event)
      key = event[:key].to_s

      # Ctrl+S / Cmd+S で保存
      if key == 's' && (truthy?(event[:ctrlKey]) || truthy?(event[:metaKey]))
        event.preventDefault
        save_file
        return
      end

      # Tab はフォーカス移動ではなくスペース2つの挿入にする
      if key == 'Tab'
        event.preventDefault
        insert_indent
      end
    end
  end
end
