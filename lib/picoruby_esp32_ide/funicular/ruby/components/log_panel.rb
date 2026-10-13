# ビルドログとプラットフォームセットアップログをまとめたタブ切り替えパネル。
#
# 以前は BuildPanel / PlatformPanel という別々のパネルを常時両方表示していたが、
# 同時に見る場面は少なく画面を圧迫するだけだったので、タブで切り替える1つの
# パネルに統合した。どちらのタブを表示中かは親(EditorApp)のstate(log_tab)に
# 持たせてあるので、タブを切り替えてもポーリングによるログ更新自体は
# バックグラウンドで両方継続する。
#
# 他のパネルと同じく表示専用。タブ切り替え/ログ更新は
# props[:on_tab_change] / props[:on_build_refresh] / props[:on_platform_refresh]
# 経由で親(EditorApp)に委譲する。
class LogPanel < Funicular::Component
  BUILD_STATUS_LABELS = {
    'idle' => 'ビルド未実行',
    'running' => 'ビルド中…',
    'success' => 'ビルド成功',
    'failed' => 'ビルド失敗'
  }.freeze

  PLATFORM_STATUS_LABELS = {
    'idle' => '未実行',
    'running' => 'セットアップ中…',
    'success' => 'セットアップ完了',
    'failed' => 'セットアップ失敗'
  }.freeze

  def render
    div(class: 'log-panel') do
      div(class: 'log-panel-header') do
        render_tab_button('build', 'R2P2-ESP32 Build', :handle_select_build_tab)
        render_tab_button('platform', 'Platform Setup', :handle_select_platform_tab)
        div(class: 'log-panel-spacer')
        span(class: 'platform-target') { props[:selected_platform] || '未選択' } unless build_tab?
        render_refresh_button
        span(class: "build-status #{status}") { status_label }
      end
      tag(:pre, class: 'build-log') { log_text }
    end
  end

  def handle_select_build_tab(event)
    event.preventDefault
    select_tab('build')
  end

  def handle_select_platform_tab(event)
    event.preventDefault
    select_tab('platform')
  end

  def handle_refresh(event)
    event.preventDefault
    on_refresh = build_tab? ? props[:on_build_refresh] : props[:on_platform_refresh]
    on_refresh.call if on_refresh
  end

  private

  def select_tab(tab)
    on_tab_change = props[:on_tab_change]
    on_tab_change.call(tab) if on_tab_change
  end

  def render_tab_button(key, label_text, handler)
    classes = key == active_tab ? 'log-panel-tab active' : 'log-panel-tab'
    button(class: classes, onclick: handler) { label_text }
  end

  def render_refresh_button
    button(class: 'build-refresh', onclick: :handle_refresh) { 'ログを更新' }
  end

  def active_tab
    props[:active_tab] == 'platform' ? 'platform' : 'build'
  end

  def build_tab?
    active_tab == 'build'
  end

  def status
    build_tab? ? props[:build_status] : props[:platform_status]
  end

  def status_label
    if build_tab?
      BUILD_STATUS_LABELS[props[:build_status]] || props[:build_status].to_s
    else
      PLATFORM_STATUS_LABELS[props[:platform_status]] || props[:platform_status].to_s
    end
  end

  def log_text
    if build_tab?
      log = props[:build_log].to_s
      props[:build_log_truncated] ? "…(冒頭は省略)\n#{log}" : log
    else
      log = props[:platform_log].to_s
      props[:platform_log_truncated] ? "…(冒頭は省略)\n#{log}" : log
    end
  end
end
