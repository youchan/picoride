# 「ファイル」メニューの「プロジェクトを開く」から出す、既存プロジェクト
# 一覧から開くプロジェクトを選ぶだけのダイアログ。
#
# プロジェクトの切り替え自体はメニューバー常設のドロップダウン(MenuBar)でも
# できるが、デスクトップアプリの「ファイル > 開く」に相当する入り口として
# 別で用意した。一覧はEditorAppが既に持っているstate[:projects]をそのまま
# propsで受け取るだけで、追加のAPI呼び出しはしない。
#
# props:
#   projects:        プロジェクト名の配列
#   current_project: 現在開いているプロジェクト名(強調表示用)
#   on_select:        クリックされたプロジェクト名を渡して呼ばれるlambda
#   on_cancel:        キャンセル時に呼ばれるlambda
class OpenProjectDialog < Funicular::Component
  def render
    div(class: 'dialog-overlay') do
      div(class: 'dialog open-project-dialog') do
        h2 { 'プロジェクトを開く' }
        render_project_list
        div(class: 'dialog-actions') do
          button(class: 'dialog-cancel', onclick: :handle_cancel) { 'キャンセル' }
        end
      end
    end
  end

  def handle_cancel(event)
    event.preventDefault
    on_cancel = props[:on_cancel]
    on_cancel.call if on_cancel
  end

  private

  def render_project_list
    projects = props[:projects] || []
    if projects.empty?
      div(class: 'open-project-empty') { '開けるプロジェクトがありません' }
    else
      ul(class: 'open-project-list') { projects.each { |name| render_project_item(name) } }
    end
  end

  def render_project_item(name)
    classes = name == props[:current_project] ? 'open-project-item active' : 'open-project-item'
    li(key: name, class: classes, onclick: -> { select_project(name) }) { name }
  end

  def select_project(name)
    on_select = props[:on_select]
    on_select.call(name) if on_select
  end
end
