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
#   on_confirm:    入力値(String)を渡して呼ばれるlambda
#   on_cancel:     キャンセル時に呼ばれるlambda
class PromptDialog < Funicular::Component
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
