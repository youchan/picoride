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
  # TOMLの読み書きは自前実装せず、PerfectTOML(mame/perfect_toml、単一ファイル・
  # 無依存でTOML v1.0.0に完全準拠するパーサ/ジェネレータ)を使う。ファイルは
  #   active = "最後にアクティブだったワークスペースの絶対パス"
  #
  #   [名前]
  #   path = "絶対パス"
  # という形(nameはPerfectTOML.generateがHashのキーから自動でTOMLのテーブル名に
  # 変換してくれる。空白を含む名前なども自動でクォートされる)。
  module WorkspaceStore
    DIR = File.join(Dir.home, ".picoride")
    PATH = File.join(DIR, "workspace.toml")

    module_function

    # 保存されているワークスペース一覧(存在しなくなったディレクトリは除外)と、
    # 最後にアクティブだったワークスペースの絶対パスを返す。
    # 戻り値: { active: "絶対パス" または nil, paths: [絶対パスの配列(出現順)] }
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
      paths = data.filter_map do |name, value|
        next if name == "active" || !value.is_a?(Hash)
        value["path"]
      end

      paths.select! { |path| path.is_a?(String) && File.directory?(path) }
      active = nil unless active.is_a?(String) && paths.include?(active)

      { active: active, paths: paths }
    end

    # 現在の状態をまるごと書き込む(差分更新ではなく毎回全体を作り直す。
    # ワークスペースの開閉はそう頻繁な操作ではないので、素朴な全体書き直しで
    # 十分という判断)。
    def save(active:, paths:)
      FileUtils.mkdir_p(DIR)

      data = {}
      data["active"] = active if active

      used_names = {}
      paths.each do |path|
        data[unique_name(path, used_names)] = { "path" => path }
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
