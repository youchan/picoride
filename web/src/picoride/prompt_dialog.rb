# 1行のテキスト入力を伴う汎用的な確認ダイアログ。
#
# 「新しいプロジェクト」「mrbgemを追加」「新規ファイル」はどれも
# 名前(パス)を1つ入力させて確定/キャンセルさせるだけなので、用途ごとに
# 別コンポーネントを作らずタイトル/ラベル/プレースホルダ/確定ボタンの
# ラベルをpropsで差し替えて使い回す。
#
# 入力欄はref経由でDOM値を直接読む非制御コンポーネントにしてある。
# ビルドログのポーリング等、ダイアログを開いたまま親(EditorApp)が
# 再描画される場面があるため、value を props 経由で毎回書き戻す制御方式にすると
# その再描画のたびに入力中の文字が消えてしまう(他のフォーム系コンポーネントと
# 同じ理由。project_settings_dialog.rb / editor_app.rb 参照)。
#
# props:
#   title:         ダイアログの見出し
#   label:         入力欄のラベル
#   placeholder:   入力欄のプレースホルダ
#   confirm_label: 確定ボタンのラベル(省略時 'OK')
#   error:         エラーメッセージ(あれば表示)
#   initial_value: 入力欄の初期値(省略可。「名前を変更」で現在の名前を入れておく用途)
#   select_length: 初期値の先頭から何文字を選択状態にするか(省略時は全体。
#                  ファイル名の変更で拡張子を除いた部分だけを選択するのに使う)
#   on_confirm:    入力値(String)を渡して呼ばれるlambda
#   on_cancel:     キャンセル時に呼ばれるlambda
#
# 初期値(initial_value)はcomponent_mountedで1回だけDOMに書き込む。呼び出し側
# (App)はpreserve: trueで描画しているので、ダイアログを開いている間に親が
# 再描画されても作り直されず、入力中の文字が初期値で上書きされることはない
# (CLAUDE.md「【重大】子コンポーネントはpropsが変わると作り直される」の節参照)。
module PicoRIDE
  class PromptDialog < Funicular::Component
    def component_mounted
      node = refs[:value_input]
      return unless node

      initial = props[:initial_value].to_s
      node[:value] = initial unless initial.empty?
      node.focus
      return if initial.empty?

      length = props[:select_length]
      length = initial.length if length.nil? || length.to_i <= 0 || length.to_i > initial.length
      node[:selectionStart] = 0
      node[:selectionEnd] = length.to_i
    end

    def render
      div(class: 'dialog-overlay') do
        div(class: 'dialog prompt-dialog') do
          h2 { props[:title].to_s }
          label(class: 'prompt-field') do
            span { props[:label].to_s }
            tag(:input, type: 'text', ref: :value_input, placeholder: props[:placeholder].to_s, onkeydown: :handle_keydown)
          end
          render_error
          div(class: 'dialog-actions') do
            button(class: 'dialog-cancel', onclick: :handle_cancel) { 'キャンセル' }
            button(class: 'dialog-confirm', onclick: :handle_confirm) { confirm_label }
          end
        end
      end
    end

    def handle_cancel(event)
      event.preventDefault
      on_cancel = props[:on_cancel]
      on_cancel.call if on_cancel
    end

    def handle_confirm(event)
      event.preventDefault
      confirm
    end

    # Enterキーでも確定できるようにする(<form>で囲んでいないのでブラウザ標準の
    # submit挙動とは衝突しない)。
    def handle_keydown(event)
      confirm if event[:key].to_s == 'Enter'
    end

    private

    def confirm
      node = refs[:value_input]
      return unless node

      on_confirm = props[:on_confirm]
      on_confirm.call(node[:value].to_s) if on_confirm
    end

    def confirm_label
      label = props[:confirm_label].to_s
      label.empty? ? 'OK' : label
    end

    def render_error
      return if props[:error].to_s.empty?
      div(class: 'prompt-error') { props[:error].to_s }
    end
  end
end
