# プロジェクトごとの設定(ターゲットチップ・VM・USB Console)を編集するダイアログ。
#
# 以前はターゲットをメニューバー常設のセレクトで、VM/USB Consoleをビルド開始の
# たびに出るダイアログで選ばせていたが、「プロジェクトの設定としてプロジェクトに
# 含めたい」というフィードバックを受けて、プロジェクトごとの隠しファイル
# (`.config.yml`)に永続化する方式に変更した。このダイアログはその値を編集して
# 保存するためだけのもので、保存後は「プラットフォームをセットアップ」
# 「ビルド開始」の各ボタンがこの設定値をそのまま使う(都度選び直す必要はない)。
#
# 他のパネルと同じく表示専用。値の変更/保存/キャンセルは
# props[:on_platform_change] / props[:on_vm_change] / props[:on_usb_console_change] /
# props[:on_save] / props[:on_cancel] 経由で親(EditorApp)に委譲する。
class ProjectSettingsDialog < Funicular::Component
  PLATFORM_OPTIONS = %w[esp32 esp32c3 esp32c6 esp32h2 esp32p4 esp32s3].freeze

  # 空文字は「現在のCMake設定のデフォルトVMのまま」(idf.py buildにVM未指定)を意味する。
  VM_OPTIONS = [
    ['', 'デフォルト'],
    ['femtoruby', 'FemtoRuby (mruby/c)'],
    ['picoruby', 'PicoRuby (mruby)']
  ].freeze

  def render
    div(class: 'dialog-overlay') do
      div(class: 'dialog settings-dialog') do
        h2 { "プロジェクト設定(#{props[:project]})" }
        div(class: 'build-options') do
          render_platform_select
          render_vm_select
          render_usb_console_checkbox
        end
        div(class: 'dialog-actions') do
          button(class: 'dialog-cancel', onclick: :handle_cancel) { 'キャンセル' }
          button(class: 'dialog-confirm', onclick: :handle_save) { '保存' }
        end
      end
    end
  end

  def handle_cancel(event)
    event.preventDefault
    on_cancel = props[:on_cancel]
    on_cancel.call if on_cancel
  end

  def handle_save(event)
    event.preventDefault
    on_save = props[:on_save]
    on_save.call if on_save
  end

  def handle_platform_change(event)
    node = refs[:platform_select]
    return unless node
    value = node[:value].to_s
    on_platform_change = props[:on_platform_change]
    on_platform_change.call(value.empty? ? nil : value) if on_platform_change
  end

  def handle_vm_change(event)
    node = refs[:vm_select]
    return unless node
    on_vm_change = props[:on_vm_change]
    on_vm_change.call(node[:value].to_s) if on_vm_change
  end

  def handle_usb_console_change(event)
    node = refs[:usb_console_checkbox]
    return unless node
    on_usb_console_change = props[:on_usb_console_change]
    on_usb_console_change.call(truthy?(node[:checked])) if on_usb_console_change
  end

  private

  def render_platform_select
    label(class: 'build-option') do
      span { 'ターゲット' }
      tag(:select, ref: :platform_select, onchange: :handle_platform_change) { render_platform_options }
    end
  end

  def render_platform_options
    if props[:platform].to_s.empty?
      tag(:option, value: '', selected: true) { '未選択' }
    else
      tag(:option, value: '') { '未選択' }
    end

    PLATFORM_OPTIONS.each do |name|
      if name == props[:platform]
        tag(:option, value: name, selected: true) { name }
      else
        tag(:option, value: name) { name }
      end
    end
  end

  def render_vm_select
    label(class: 'build-option') do
      span { 'VM' }
      tag(:select, ref: :vm_select, onchange: :handle_vm_change) { render_vm_options }
    end
  end

  def render_vm_options
    VM_OPTIONS.each do |value, label_text|
      if value == props[:vm]
        tag(:option, value: value, selected: true) { label_text }
      else
        tag(:option, value: value) { label_text }
      end
    end
  end

  def render_usb_console_checkbox
    label(class: 'build-option') do
      render_usb_console_input
      span { 'USB Console(外部UART変換チップなしのボード向け)' }
    end
  end

  def render_usb_console_input
    if props[:usb_console]
      tag(:input, type: 'checkbox', ref: :usb_console_checkbox, checked: true, onchange: :handle_usb_console_change)
    else
      tag(:input, type: 'checkbox', ref: :usb_console_checkbox, onchange: :handle_usb_console_change)
    end
  end

  def truthy?(js_value)
    js_value.to_s == 'true'
  end
end
