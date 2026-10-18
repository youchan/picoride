# エディタ上部のツールバー(ファイル名 / 保存ボタン / ステータス表示)。
#
# こちらも表示専用。保存の実処理は親が持ち、props[:on_save] 経由で呼び出す。
class Toolbar < Funicular::Component
  def render
    div(class: 'toolbar') do
      span(class: 'current-file') { props[:current_path] || 'ファイルを選択してください' }
      render_save_button
      span(class: "status #{props[:status_kind]}") { props[:status].to_s }
    end
  end

  def handle_save(event)
    event.preventDefault
    on_save = props[:on_save]
    on_save.call if on_save
  end

  private

  # disabled は「属性を付けない/付ける」で切り替える。
  # false を渡す書き方に依存しないよう、分岐で二通りの要素を書き分けている。
  def render_save_button
    if props[:dirty]
      button(class: 'save', onclick: :handle_save) { '保存 (Ctrl+S)' }
    else
      button(class: 'save', disabled: true) { '保存 (Ctrl+S)' }
    end
  end
end
