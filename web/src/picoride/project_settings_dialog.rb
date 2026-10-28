# プロジェクトごとの設定(ターゲットチップ・VM・USB Console)を編集するダイアログ。
#
# 以前はターゲットをメニューバー常設のセレクトで、VM/USB Consoleをビルド開始の
# たびに出るダイアログで選ばせていたが、「プロジェクトの設定としてプロジェクトに
# 含めたい」というフィードバックを受けて永続化する方式に変更した。永続化先は
# プロジェクトごとの隠しファイル(`.config.yml`)→(一時期あった「複数プロジェクトを
# 束ねるワークスペース」という上位概念の下で)`~/.picoride/workspace.toml`、と
# 経緯を経て、現在は`~/.picoride/project.toml`(`project_store.rb`)に落ち着いている。
# このダイアログはその値を編集して保存するためだけのもので、保存後は
# 「プラットフォームをセットアップ」「ビルド開始」の各ボタンがこの設定値を
# そのまま使う(都度選び直す必要はない)。
#
# 他のパネルと同じく表示専用。値の変更/保存/キャンセルは
# props[:on_platform_change] / props[:on_vm_change] / props[:on_usb_console_change] /
# props[:on_save] / props[:on_cancel] 経由で親(EditorApp)に委譲する。
#
# ターゲットはESP32系とRaspberry Pi Pico系の2ファミリーに分かれていて、
# どちらを選んだかでサーバー側のビルド用Dockerイメージ・ビルド手順が切り替わる
# (lib/picoride/server.rb の PLATFORM_FAMILIES / BUILDER_IMAGES)。
# Picoでは「USB Console」はESP32専用の設定なので出さず、VMはボードによって
# 選べるものが違う(RP2040のpico/pico_wはFemtoRubyのみ)。
module PicoRIDE
  class ProjectSettingsDialog < Funicular::Component
    # [optgroupのラベル, [[値, 表示名], ...]] の並び。値はサーバー側の
    # PLATFORM_FAMILIES と一致させる。
    PLATFORM_GROUPS = [
      ['ESP32', [
        ['esp32', 'esp32'],
        ['esp32c3', 'esp32c3'],
        ['esp32c6', 'esp32c6'],
        ['esp32h2', 'esp32h2'],
        ['esp32p4', 'esp32p4'],
        ['esp32s3', 'esp32s3']
      ]],
      ['Raspberry Pi Pico', [
        ['pico', 'Pico (RP2040)'],
        ['pico_w', 'Pico W (RP2040)'],
        ['pico2', 'Pico 2 (RP2350)'],
        ['pico2_w', 'Pico 2 W (RP2350)']
      ]]
    ].freeze

    # 空文字は「デフォルトVM」を意味する(ESP32: idf.py buildにVM未指定、
    # Pico: FemtoRuby)。
    VM_OPTIONS = [
      ['', 'デフォルト'],
      ['femtoruby', 'FemtoRuby (mruby/c)'],
      ['picoruby', 'PicoRuby (mruby)']
    ].freeze

    # Picoの各ボードで選べるVM(サーバー側のPICO_BOARD_VMSと一致させる)。
    PICO_BOARD_VMS = {
      'pico' => ['femtoruby'],
      'pico_w' => ['femtoruby'],
      'pico2' => ['femtoruby', 'picoruby'],
      'pico2_w' => ['femtoruby', 'picoruby']
    }.freeze

    PICO_NOTE = 'ビルドするとUF2ファイルができます。BOOTSELボタンを押しながらPicoをUSB接続し、' +
                '現れたドライブ(RPI-RP2 / RP2350)へコピーすると書き込めます。' +
                'app/ はターミナルタブの「app/ をアップロード」で転送してください。'

    def self.pico?(platform)
      PICO_BOARD_VMS.key?(platform.to_s)
    end

    # そのターゲットで選べるVMかどうか(空文字=デフォルトは常に可)。
    # ターゲットを切り替えたときに、選べなくなったVMをデフォルトに戻すのに使う
    # (EditorAppのon_platform_change)。
    def self.vm_allowed?(platform, vm)
      return true if vm.to_s.empty?
      return true unless pico?(platform)

      PICO_BOARD_VMS[platform.to_s].include?(vm.to_s)
    end

    def render
      div(class: 'dialog-overlay') do
        div(class: 'dialog settings-dialog') do
          h2 { "プロジェクト設定(#{props[:project_path]})" }
          div(class: 'build-options') do
            render_platform_select
            render_vm_select
            if ProjectSettingsDialog.pico?(props[:platform])
              render_pico_note
            else
              render_usb_console_checkbox
            end
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

      PLATFORM_GROUPS.each do |group_label, options|
        tag(:optgroup, label: group_label) do
          options.each do |value, label_text|
            if value == props[:platform]
              tag(:option, value: value, selected: true) { label_text }
            else
              tag(:option, value: value) { label_text }
            end
          end
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
        next unless ProjectSettingsDialog.vm_allowed?(props[:platform], value)

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

    def render_pico_note
      div(class: 'build-option-note') do
        span { PICO_NOTE }
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
end
