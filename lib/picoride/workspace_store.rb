require "fileutils"
require "perfect_toml"

module Picoride
  # ~/.picoride/workspace.toml への永続化。
  #
  # 「ワークスペースを一度開いたら覚えておいてほしい、サーバーを再起動しても
  # 開かれている状態で起動してほしい」という要望を受けて追加した。保存先は
  # プロジェクトディレクトリの外(ホームディレクトリ配下の`.picoride/`。
  # r2p2_state.rbの状態ディレクトリと同じ「プロジェクト本体の外に置く」発想)。
  #
  # その後「設定(ターゲット・VM・USB Console)はプロジェクトではなくワークスペース
  # 単位で持たせてほしい」というフィードバックを受けて、各ワークスペースの設定も
  # 同じファイルに持たせるようにした(`platform`/`vm`/`usb_console`。
  # server.rbのread_workspace_config/workspace_settings参照)。
  #
  # TOMLの読み書きは自前実装せず、PerfectTOML(mame/perfect_toml、単一ファイル・
  # 無依存でTOML v1.0.0に完全準拠するパーサ/ジェネレータ)を使う。ファイルは
  #   active = "最後にアクティブだったワークスペースの絶対パス"
  #
  #   [名前]
  #   path = "絶対パス"
  #   platform = "esp32"       # 未設定なら書かない(TOMLにnullは無いため)
  #   vm = "femtoruby"         # 同上
  #   usb_console = false
  # という形(nameはPerfectTOML.generateがHashのキーから自動でTOMLのテーブル名に
  # 変換してくれる。空白を含む名前なども自動でクォートされる)。
  module WorkspaceStore
    DIR = File.join(Dir.home, ".picoride")
    PATH = File.join(DIR, "workspace.toml")

    module_function

    # 保存されているワークスペース一覧(存在しなくなったディレクトリは除外)、
    # 最後にアクティブだったワークスペースの絶対パス、各ワークスペースの設定を返す。
    # 戻り値: {
    #   active: "絶対パス" または nil,
    #   paths: [絶対パスの配列(出現順)],
    #   settings: { "絶対パス" => {"platform"=>, "vm"=>, "usb_console"=>}, ... }
    # }
    def load
      data =
        begin
          PerfectTOML.load_file(PATH)
        rescue Errno::ENOENT, PerfectTOML::ParseError
          # ファイルが無い(初回起動)、あるいはユーザーが手で編集して壊した
          # 場合でも、ここで落ちずに「何も保存されていない」扱いにする。
          {}
        end

      active = data["active"]
      paths = []
      settings = {}

      data.each do |name, value|
        next if name == "active" || !value.is_a?(Hash)

        path = value["path"]
        next unless path.is_a?(String) && File.directory?(path)

        paths << path
        settings[path] = {
          "platform" => value["platform"],
          "vm" => value["vm"],
          "usb_console" => value["usb_console"] == true
        }
      end

      active = nil unless active.is_a?(String) && paths.include?(active)

      { active: active, paths: paths, settings: settings }
    end

    # 現在の状態をまるごと書き込む(差分更新ではなく毎回全体を作り直す。
    # ワークスペースの開閉・設定変更はそう頻繁な操作ではないので、素朴な
    # 全体書き直しで十分という判断)。
    #
    # settingsはキーワード必須にしてある(デフォルト値を用意して省略を許すと、
    # 「ワークスペースを開くだけ」の呼び出し箇所で既存の設定を空のHashで
    # 上書きしてしまうミスを構造的に防げないため。実際に一度このミスを
    # 作りかけた)。
    def save(active:, paths:, settings:)
      FileUtils.mkdir_p(DIR)

      data = {}
      data["active"] = active if active

      used_names = {}
      paths.each do |path|
        entry = { "path" => path }
        s = settings[path]
        if s
          # TOMLにnullは無いため、未設定(nil)のキーは書かない。
          entry["platform"] = s["platform"] if s["platform"]
          entry["vm"] = s["vm"] if s["vm"]
          entry["usb_console"] = true if s["usb_console"] == true
        end
        data[unique_name(path, used_names)] = entry
      end

      PerfectTOML.save_file(PATH, data)
    end

    # ワークスペース名は既定でディレクトリ名(パスの最後のセグメント)にする
    # (menu_bar.rbのworkspace_labelと同じロジック。フロントとサーバで共有
    # できないので両側に同じものを持たせてある)。
    def display_name(path)
      name = path.to_s.split("/").last
      name.nil? || name.empty? ? path.to_s : name
    end

    # 別のパスのワークスペースが同じディレクトリ名(例: 違う場所にある2つの
    # "projects"ディレクトリ)だった場合に備えて、TOMLのテーブル名として
    # 一意になるよう連番を振る。
    def unique_name(path, used_names)
      base = display_name(path)
      name = base
      counter = 2
      while used_names.key?(name)
        name = "#{base}_#{counter}"
        counter += 1
      end
      used_names[name] = true
      name
    end
  end
end
