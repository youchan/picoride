# プロジェクトの引き継ぎコンテキスト

このファイルはClaude Codeがこのリポジトリで作業する際に自動的に読み込む前提のメモです。
プロジェクトルート(`app.rb`と同じ階層)に置いてください。

## プロジェクト概要

Rubyプロジェクトの中で、Ruby(`.rb`)とC(`.c` `.h`)のソースコードをブラウザ上で
編集できるようにする最小構成のサンプルアプリ。

- サーバー: Sinatra (Ruby)。Railsは不要という前提で選定
- フロントエンド: ビルドステップなしのvanilla JS + Prism.js(CDN読み込み)
- 目的はあくまで「サンプル/たたき台」。本番投入前提の機能(認証、複数人編集の競合制御など)は未実装

## 技術選定の経緯(重要)

エディタ部分は当初 CodeMirror 6 → 最終的に「textarea + Prism.jsオーバーレイ」方式に
変更している。この経緯を知らずに再度CodeMirrorへ戻そうとすると同じ問題を踏むので記録しておく。

1. **CodeMirror 6 (esm.sh CDN経由のESM import)**
   `https://esm.sh/codemirror@6` 等から直接importする構成で開始したが、
   `Uncaught SyntaxError: The requested module 'https://esm.sh/codemirror@6' does not
   provide an export named 'basicSetup'` というエラーが発生。esm.sh側での
   パッケージ間バージョン解決のズレが原因。CDN上のESMは複数パッケージ構成のライブラリと
   相性が悪い場合がある、という教訓。

2. **CodeMirror 6 (npm + esbuildでローカルバンドル)**
   1の問題を受けてnpm管理+esbuildバンドルに変更し、正常動作を確認。
   ただしRubyプロジェクトにNode.js/npmのビルド環境を持ち込むことになり、
   「Railsも要らないくらいシンプルにしたい」という当初の方針とはやや矛盾していた。

3. **picoruby.org/terminal の実装調査**
   ユーザーからの質問で https://picoruby.org/terminal (PicoRuby公式のWebターミナル)の
   エディタ実装を調査。ソースは
   https://github.com/picoruby/picoruby.github.io/blob/main/pages/r2p2/terminal.html
   にあり、CodeMirrorやMonacoではなく **`<textarea>` + 行番号レイヤー + ハイライトレイヤーの
   透明重ね合わせ + Prism.js(字句解析) + PicoRuby.wasm(ロジックをRubyで記述)** という
   自作の軽量構成だと判明。ターミナル部分は `@xterm/xterm` (xterm.js) を使用。

4. **現在の実装: textarea + Prism.jsオーバーレイ方式**
   3を参考に、CodeMirrorとnpm/esbuildを完全に廃止し、Prism.js(cdnjs、バージョン固定の
   `<script>`タグ読み込み)による軽量構成に置き換えた。これにより:
   - npm/Node.js環境が不要になり、`bundle install && ruby app.rb` だけで動くように
   - 引き換えに、補完・複数カーソル・折りたたみ等の高度な編集機能は失った
   - シンタックスハイライトのみのシンプルなエディタという位置づけ

5. **キャレット/ハイライトのズレ修正**
   textarea+オーバーレイ方式に切り替えた直後、「表示文字列とキャレット行がズレる」不具合が
   発生。原因は `<textarea>` が内容あふれ時に**要素内部で独自にスクロールする**性質を持つため、
   `position: absolute` で単純に重ねると親のスクロールとtextarea自身のスクロールが
   ズレること。**CSS Grid (`display: grid` + 両要素に `grid-area: 1 / 1`)** で
   重ねる方式に変更し、スクロール可能な要素を親の `.editor-scroll-area` ひとつに
   集約することで解消した。この手法は react-simple-code-editor や CodeJar など
   同種のライブラリでも採用されている標準的な解決策。

## 現在のアーキテクチャ

```
.
├── app.rb                # Sinatraアプリ本体。ファイル一覧/読込/保存のJSON APIのみ
├── Gemfile                # sinatra, puma, rackup
├── views/index.erb        # エディタ画面のHTML。Prism.jsをcdnjs(バージョン固定)から読込
├── public/
│   ├── css/style.css      # textareaオーバーレイ(CSS Grid)・行番号・Prismトークン配色
│   └── js/editor.js       # エディタ本体ロジック。ビルド不要のvanilla JS(IIFE)
└── project/                # 編集対象のサンプルファイル群(.rb / .c / .h)
```

### API (`app.rb`)

- `GET /api/files` — `project/` 以下の `.rb` `.c` `.h` ファイル一覧(相対パス)を返す
- `GET /api/file?path=...` — 指定ファイルの内容を返す
- `POST /api/file` — `{path, content}` を受け取り、既存ファイルを上書き保存する
  (新規作成は不可。`ALLOWED_EXTENSIONS` にないファイルや `project/` 外は拒否)
- `safe_path` ヘルパーでパストラバーサル対策済み
- `GET /api/build` / `POST /api/build` — R2P2-ESP32 のビルド(`idf.py build`)
  - `POST`のbodyで `vm`(`"femtoruby"`|`"picoruby"`、`BUILD_VM_FLAGS`で
    `-DPICORB_VM=mrubyc`|`mruby`に変換)と `usb_console`(true/false)を選べる。
    公式の[R2P2-ESP32-installer](https://github.com/picoruby/R2P2-ESP32-installer)は
    CIで全組み合わせ(VM×usb_console×チップ)を事前ビルドしてGitHub Releaseで配布し、
    ブラウザ側でファイル名をパースして選ばせる方式だが、こちらは「今コンテナ内で
    1本だけビルドする」設計なので、オプションはビルド開始時にリクエストで渡す形にした
  - `usb_console` は `R2P2-ESP32/sdkconfigs/usb_console`
    (`CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y`。外部USB-UART変換チップを持たない
    ボード向け)を `SDKCONFIG_DEFAULTS` にマージする。ESP-IDFは
    `SDKCONFIG_DEFAULTS` を **`sdkconfig` ファイルが存在しないときしか読まない**ため、
    設定を反映させるには `sdkconfig` を消してからビルドし直す必要がある
    (`rake deep_clean`/`idf.py fullclean` でも `sdkconfig` 自体は消えない。
    README.md「If you change SDKCONFIG_DEFAULTS, delete the sdkconfig file and
    rebuild from scratch」参照)
  - **踏んだ罠**: 最初「`usb_console: true`のときだけ`sdkconfig`を消す」という
    実装にしたら、一度trueにした後falseに戻しても`sdkconfig`にUSB Console設定が
    残ったままになるバグを作ってしまった(実機で試すまで気づかなかった類の話ではなく、
    このセッション内でAPIを叩いて`grep CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG sdkconfig`
    で確認して発覚した)。正しくは `sdkconfig_has_usb_console?` ヘルパーで
    **今の`sdkconfig`の実際の中身**を見て、リクエストされた値と食い違うときだけ
    `rm -f sdkconfig && SDKCONFIG_DEFAULTS=... idf.py build` する。一致していれば
    従来通りの高速な差分ビルドのまま(オプション未指定の通常ビルドが遅くならない)
  - VM(`-DPICORB_VM=`)の切り替えは`sdkconfig`と無関係(CMakeのキャッシュ変数)なので
    上記のクリーン処理は不要。ビルドログの早い段階に出る
    `-- PICORB_VM is set to: mrubyc` のような行は、キャッシュがまだ更新される前の
    表示に見えることがあるので、本当に反映されたかは
    `build/CMakeCache.txt` の `PICORB_VM:STRING=...` や、
    `components/picoruby-esp32/picoruby/build/` 配下に
    `esp32-{femtoruby,picoruby}` のディレクトリが増えているかで確認するのが確実
- `GET /api/platform` / `POST /api/platform` — プラットフォーム(ターゲットチップ)
  セットアップ(`rake setup_#{platform}`)。`platform` は
  `PLATFORM_TARGETS`(`esp32` `esp32c3` `esp32c6` `esp32h2` `esp32p4` `esp32s3`。
  `R2P2-ESP32/rakelib/setup.rake` 参照)にあるものだけ許可
  (コマンドインジェクション対策とrakeタスク名の妥当性確認を兼ねる)
  - `setup_esp32xxx` は `deep_clean` + `setup`(mrubyの再ビルド) +
    `idf.py set-target` という重い処理の直列実行なので、実行に数分かかる

この2つはどちらも同じ形の非同期ジョブ(GETでポーリング、POSTで開始、実行中の
POSTは409)なので、共通処理を `BackgroundJob` クラス(`app.rb`)に抽出してある。
`BUILD_JOB` / `PLATFORM_JOB` という2つのインスタンスがそれぞれの状態
(`idle`/`running`/`success`/`failed`、ログ)を持つ。ログは末尾
`BackgroundJob::LOG_TAIL_LIMIT`(8,000文字)のみをレスポンスに含め、
切り詰めた場合は `log_truncated: true` を付ける
(ブラウザ内のPicoRuby.wasmで全量(100KB超になりうる)をJSONパース/描画すると
数秒〜十秒近くかかり、「反応がない」ように見えてしまう問題への対処)。
`idf.py` / `rake` はESP-IDFの `export.sh` を読み込んだシェルでないと使えないため、
両ジョブとも実行コマンドは `r2p2_shell_command` ヘルパーで
`$IDF_PATH/export.sh` を明示的にsourceしてから組み立てている
(Dockerのentrypoint(`R2P2-ESP32/docker/Dockerfile`)は起動時に一度export済みだが、
`docker exec` 等で入った場合はexportされていないことがあり、それに頼らない実装にした)。

UI側(`web/funicular/ruby/components/editor_app.rb`)は実行中、
`JS.global.setTimeout(3000) { refresh_xxx_status }` で3秒おきに自動的にログを
取りに行く(runningでなくなったら止まる)。「ログを更新」ボタンはこれとは別に、
すぐ最新状態を見たいときの手動トリガーとして残してある。
ビルドパネル(`build_panel.rb`)とプラットフォームパネル(`platform_panel.rb`)は
表示ロジックがほぼ同じ(ステータスラベル・ログ切り詰め表示・自動ポーリング)だが、
まだ2つ書いているだけの重複度なので共通化はしていない。3つ目の非同期ジョブUIが
必要になったら抽象化を検討する。

**ここで踏んだ罠**: PicoRuby.wasmの `JS::Object#setTimeout` は Ruby標準の
`Kernel#sleep` 的な感覚で `JS.global.setTimeout(callback_proc, delay_ms)` のように
2引数で呼びたくなるが、実際のシグネチャは `setTimeout(delay_ms, &block)`
(picoruby本体 `mrbgems/picoruby-wasm/mrblib/js.rb` 参照)で、コールバックは
**ブロックとして**渡す必要がある。2引数で呼ぶと
`ArgumentError: wrong number of arguments (given 2, expected 1)` になり、
しかもこの例外はブラウザの `console.error` に `Callback <id>: ArgumentError: ...`
という形で出るだけで、Rubyコード上は握りつぶされて画面には何も出ない
(=「ボタンを押しても何も起きない」ように見える)。正しくは
`JS.global.setTimeout(3000) { ... }` のようにブロックで渡す。
同様のAPIを追加するときは `js.rb` のソース(`gh api
repos/picoruby/picoruby/contents/mrbgems/picoruby-wasm/mrblib/js.rb`)を
先に確認したほうが早い。

### エディタ (`public/js/editor.js` + `views/index.erb` + `style.css`)

- `<textarea id="editor">`: 文字色を透明にしキャレットのみ見せる
- `<pre id="highlight-layer"><code id="highlight-content"></code></pre>`: Prism.jsで
  ハイライトしたHTMLをここに描画。`.editor-scroll-area` 内で `#editor` と
  `grid-area: 1 / 1` により完全に重なる
- `#line-numbers`: 別カラム。`.editor-scroll-area` の `scroll` イベントで
  `scrollTop` を同期
- 拡張子→Prism言語のマッピングは `languageFor()` にハードコード(`rb`→ruby, `c`/`h`→c)
- Tabキーはスペース2つを挿入するだけ(自動インデント等は未実装)
- 保存のたびに `savedContent` と比較して未保存差分の有無を判定し、保存ボタンの
  活性/非活性を制御

## 既知の制約・today's TODO候補

READMEにも記載しているが、Claude Codeで次に着手する際の候補:

- **自動インデント未実装**: 改行時に直前行のインデント幅を引き継ぐ処理がない
  (picoruby側の `auto_indent.rb` が参考になる)
- **大きいファイルでの性能**: 入力のたびに全文を `Prism.highlight()` で再トークナイズしている。
  デバウンス処理を入れるか、変更行のみ再描画する差分更新に変えると改善する
- **新規ファイル作成/削除/リネームAPIがない**: 既存ファイルの上書き保存のみ対応
- **同時編集の競合制御がない**: 複数人が同時に同じファイルを開いた場合、後勝ちで上書きされる
- **対応拡張子が `.rb` `.c` `.h` のみ**: 増やす場合は `app.rb` の `ALLOWED_EXTENSIONS`、
  `views/index.erb` のPrismコンポーネント読み込み、`editor.js` の `languageFor` /
  `iconFor` の3箇所を対応させる必要がある
### 実機への書き込み(インストール)機能

ビルド(`idf.py build`)・プラットフォームセットアップ(`rake setup_xxx`)とは違い、
書き込みだけは**サーバ側で`rake flash`を実行する方式にしなかった**。理由は、
サーバがDockerコンテナ内で動く前提だと、コンテナにUSBシリアルデバイスを渡す
(`docker run --device /dev/ttyUSB0` 等)必要があり、`bin/dev`の変更やホスト環境の
デバイスパス依存が増えて複雑になるため。代わりに公式の
[R2P2-ESP32-installer](https://picoruby.org/R2P2-ESP32-installer/)と同じ、
**ブラウザのWeb Serial API経由([ESP Web Tools](https://esphome.github.io/esp-web-tools/)、
`esp-web-install-button`カスタム要素)でブラウザから直接USBに書き込む方式**を採用した。
これによりサーバは「ビルド成果物を配信するだけ」でよくなり、USBデバイスの取り回しを
気にする必要がなくなる(ただしChrome/Edge/OperaなどWeb Serial API対応ブラウザが必須)。

- `GET /api/firmware/manifest.json` — ESP Web Tools用のマニフェストを、直近のビルド
  成果物(`R2P2-ESP32/build/project_description.json` の `target` と
  `R2P2-ESP32/build/flash_args`)から動的に組み立てて返す。ビルド未実行なら404
  - `flash_args` は `idf.py build` が生成する、esptoolの`write_flash`にそのまま渡せる
    `<オフセット(16進)> <binへの相対パス>` の行の並び(1行目は`--flash_mode`等の
    オプション行なので読み飛ばす)。実際の中身の例:
    ```
    --flash_mode dio --flash_freq 40m --flash_size 4MB
    0x1000 bootloader/bootloader.bin
    0x10000 R2P2-ESP32.bin
    0x8000 partition_table/partition-table.bin
    0x210000 storage.bin
    ```
  - `target`(`esp32`等、`idf.py set-target`の引数と同じ)→ESP Web Toolsの`chipFamily`
    (`ESP32`等)への変換テーブルが `CHIP_FAMILY_MAP`。ESP Web Tools側の対応チップ一覧は
    `gh api repos/esphome/esp-web-tools/contents/src/const.ts` の `Build#chipFamily`
    で確認した(`PLATFORM_TARGETS` にある6種は全部サポートされている)
- `GET /api/firmware/:filename` — 上記マニフェストが指す`.bin`を配信する
  (拡張子とパストラバーサル対策あり)
- UI側(`install_panel.rb`)は状態を持たない。`<esp-web-install-button manifest="...">`
  を配置するだけで、実際の書き込み処理・進捗ダイアログはESP Web Tools側が全部担う。
  ボタンのコールバックは `manifest` を**HTML属性**として読む
  (`button.manifest || button.getAttribute("manifest")`、
  `esp-web-tools/src/connect.ts` 参照)ので、Funicularの`tag`で属性として渡せばよい
  - `index.html` で `<script type="module" src=".../esp-web-tools@10.4.0/dist/web/
    install-button.js">` をCDN読み込み。バージョン固定の方針は他ライブラリと同様
  - 実機なしでも「No port selected」ダイアログ(ESP Web Tools自身が出す、Linuxの
    dialoutグループ設定などのトラブルシューティング付き)が出ることをブラウザで確認済み

## 開発環境まわりの注意点

- Rubyの実行環境がこちらのサンドボックスに無かったため、`app.rb` 等は目視レビューのみで
  実機での起動確認はできていない(ユーザー側の `ruby app.rb` で都度確認してもらっている)
- Prism.jsのCDN URL (`cdnjs.cloudflare.com`) はサンドボックスのネットワーク制限で
  直接疎通確認できなかったため、`npm pack prismjs@1.30.0` でnpmレジストリ経由で
  ファイル名(`prism-core.min.js` 等)の実在のみ検証した
- esm.sh経由のESM CDN importは、今回のようなバージョン解決の不安定さが起きやすいので、
  今後もCDN経由でJSライブラリを追加する場合は、安定版の `<script>` タグ+バージョン固定URLを
  優先する方針でよい

### `bin/dev`は廃止した(`bin/server`に置き換え)

**この節は古い(Dockerオンリー時代の)記述で、現在は成り立たない。** `bin/dev`は
Sinatraアプリ自体をDockerコンテナの中で動かす前提のスクリプトだったが、後述の
「Sinatraのホスト外出し」でSinatra自体はDockerを使わずホストでネイティブに動く
ようになったため、このマウントの工夫は丸ごと不要になり`bin/dev`は削除した。
開発時の起動は`bin/server`(`bundle exec exe/picoride`をラップするだけ)を使う。
過去に踏んだ罠の記録として残しておくと: 当時`app/`を`/root/app`のように1階層
深くマウントしようとして、`PROJECTS_ROOT`が`__dir__`からの相対パス解決だった
ために`../projects`の解決先がズレる問題があった。今は`PROJECTS_ROOT`自体が
環境変数で上書き可能になっているので、同種の問題はもう起きない。

## プロジェクト管理・mrbgemのビルド組み込み方針

複数のプロジェクト(1つのアプリと、それが使う自作mrbgem群)を`projects/`配下で
どう管理し、どうビルドに組み込むかを検討して決めた内容。**この設計は2回作り直して
いる**ので、経緯も含めて残しておく。

### 現在のプロジェクト構造

1プロジェクト = `projects/<project名>/`の中に`app/`・`mrbgems/`・`build_config.rb`を
まとめて持つディレクトリ、という単位にしてある。

```
projects/
  hello_world_project/
    app/                      # ビルド時にR2P2-ESP32のstorage/home/へまるごとコピーされる
      app.rb                  # main_task.rbが起動時に自動loadする(後述)
    mrbgems/                  # ここにあるものは全部自動でビルドに含まれる
      picoruby_hello_world/
        mrbgem.rake
        mrblib/...
        src/...
    build_config.rb           # デフォルトgemを外したい場合などに直接編集する普通のファイル
```

プロジェクトの選択は画面上部のメニューバーのドロップダウン(`MenuBar`の
`render_project_select`)から行う(以前はサイドバーに一覧を出す`ProjectList`
コンポーネントだったが、上部に移した)。マウントは`projects/`を1つだけbind mountする
方針は変わっていない(mrbgemを継続的に追加してもコンテナ再起動が要らないように)。
IDEはgit操作(clone/pull/push/commit)に一切ノータッチで、プロジェクトディレクトリが
独立したgitリポジトリかどうかもIDEは関知しない。

**ここに至るまでの変遷**: 最初は「`projects/`直下の各ディレクトリを1プロジェクトとし、
`mrbgem.rake`の有無で中身を見てapp/mrbgem種別を自動判定する」フラットな構成にして
いた(mrbgemが「あるappプロジェクトの一部」ではなく独立した存在という前提)。
この場合「どのmrbgemをどのappに含めるか」を選ぶ必要が生じ、Gemsダイアログ
(チェックボックスでmrbgemを選ぶUI)とその永続化(`.gems_prefs.json`、
opt-in→opt-out方式への変更を経た)を作り込んだ。しかし実際にサンプルを作ってみると、
「1つのappとそれが使うmrbgemは元々セットで管理したい」という要望が出てきて、
mrbgemをapp側のディレクトリの中に物理的に含める今の構造に変更した。これにより
「mrbgemを選ぶ」という概念自体が不要になり(ディレクトリの中に置く=そのプロジェクトで
使う、という構造そのものが選択を兼ねる)、Gemsダイアログ・`.gems_prefs.json`は
まるごと削除した。`build_config.rb`も「ダイアログが生成する専用ファイル」から
「プロジェクトの中にある普通の編集可能ファイル」に位置づけが変わっている。

### mrbgemのビルドへの組み込み

mrubyのビルド設定(`MRuby::CrossBuild.new do |conf| ... end`、`conf.gem`)は
`conf.gem gemdir: '<path>'`で任意のローカルディレクトリをgemとして追加でき、
`conf.gems.reject! { |g| ... }`で既に登録済みのデフォルトgemを除外できる
(`conf.gems.delete(name)`もあるが、該当gemが無いと`fail`で例外になるため、
存在しない場合に何もしない`reject!`のほうが今回の用途には安全)。

R2P2-ESP32本体の`components/picoruby-esp32/build_config/*.rb`は
xtensa/riscv × femtoruby/picoruby の組み合わせで4種類あり、ツールチェイン設定など
込み入った内容を持つ。これをプロジェクトごとに複製すると本家の変更に追従できなく
なる。かといって「project内のbuild_config.rbをMRUBY_CONFIGとして丸ごと差し替える」
方式も、`components/picoruby-esp32/CMakeLists.txt`が`MRUBY_CONFIG`のパスを
`${IDF_TARGET_ARCH}-esp-${vm}.rb`固定で毎回計算し直す実装になっていて外から
上書きできないため、そのままでは無理だった。

代わりに採用したのが、**本家4ファイルの`do |conf| ... end`ブロック末尾に1行だけ
フックを差し込む**方式(`Dockerfile`の`git submodule update`直後の`RUN`)。

```ruby
conf.instance_eval(File.read(ENV["PROJECT_BUILD_CONFIG"])) if ENV["PROJECT_BUILD_CONFIG"] && File.exist?(ENV["PROJECT_BUILD_CONFIG"])
```

`PROJECT_BUILD_CONFIG`は`idf.py build`を叩くシェルコマンドの環境変数として
`app.rb`(`POST /api/build`)が設定する(`cmake -E env A=1 B=2 rake`のような
形で最終的に`rake`まで渡っても、その前後で明示的に指定していない環境変数は
プロセスの環境変数として素通りするので、CMakeLists.txt自体は無改造で済む)。

このフックが読むファイルは、プロジェクトの`build_config.rb`そのものではなく、
**ビルド開始のたびに`generated_build_config_content`が生成する一時ファイル**
(`projects/<project>/.build_config.generated.rb`)。中身は
「`mrbgems/`以下の現在の一覧から自動生成した`conf.gem gemdir:`の並び」+
「プロジェクトの`build_config.rb`の内容をそのまま連結したもの」:

```ruby
# 自動生成部分
conf.gem gemdir: "/projects/hello_world_project/mrbgems/picoruby_hello_world"

# ここから下はbuild_config.rbの内容(ユーザーが直接編集する)
conf.gems.reject! { |g| g.name == "picoruby-vim" }
```

ユーザーが書いた`build_config.rb`自体は一切書き換えない(生成物は別ファイルにして
連結するだけ)ので、IDEのファイルエディタで見えている内容と実際にビルドされる内容が
食い違わない。gemdir(自作mrbgemの絶対パス)は常にコンテナ内の絶対パスで書く
(相対パス解決の基点があいまいなmruby側の挙動に依存しないため)。

**踏んだ罠**: 上記のDockerfileパッチで、シングルクォート文字列の中で`&&`を
`\&\&`とバックスラッシュエスケープして書いてしまい、`printf`がバックスラッシュを
剥がさずそのまま出力した結果、生成されたRubyコードに`\&\&`という不正なトークンが
混入してSyntaxErrorになった(実際にビルドを試したユーザーからの報告で発覚)。
シングルクォートの中では`&`はそもそもシェルにとって特別な文字ではない
(`&&`はダブルクォート無し/クォート無しの文脈でコマンド連結として解釈されるだけ)ので、
エスケープ自体が不要だった。シェル文字列に埋め込むコードにshell上の特殊文字が
含まれる場合、「クォートの種類によってエスケープが要るかどうかが変わる」ことを
都度確認する(今回のように`ruby -c`や実際のcloneに対してパッチを当てて検証していれば
リリース前に気付けた)。

### プロジェクトのapp/を実機の起動スクリプトにする

プロジェクトの`app/`以下は、ビルド時にR2P2-ESP32実機の起動スクリプトとして実行
されるようにした。これはR2P2-ESP32側の改造は一切不要で、既にある2つの仕組みを
組み合わせただけ:

1. `main/CMakeLists.txt`の`littlefs_create_partition_image(storage ../storage
   FLASH_IN_PROJECT)`が、`R2P2-ESP32/storage/`以下をそのまま`storage`パーティション
   (littlefs)のイメージ(`storage.bin`)にする。つまり`storage/home/app.rb`を置けば
   実機の`/home/app.rb`になる
2. 起動スクリプト`components/picoruby-esp32/mrblib/main_task.rb`が起動のたびに
   `File.exist?("/home/app.rb")`をチェックして自動で`load`する処理を最初から持っている
   (`/home/app.mrb`があればそちらを優先。picoruby-esp32本体の元々の仕様で、
   ユーザーアプリを実行する正式な入り口はここ)

なので`app.rb`(`POST /api/build`)は、ビルド開始直前に指定projectの`app/`以下を
`R2P2-ESP32/storage/home/`へまるごとコピーするだけ(`STORAGE_HOME_DIR`)。
前回別プロジェクトをビルドしたときの残骸が残らないよう、コピー前に`storage/home/`を
空にする。build_config.rbのとき(CMakeLists.txtがパスを決め打ちしていて上書き
できなかった)とは違い、ここはR2P2-ESP32側が最初から「storage/以下の現在の中身を
そのまま焼く」という素直な作りだったので、Dockerfileパッチのような迂回策は不要だった。

## storageパーティション作成に使うlittlefs-pythonをオフライン化する

`main/CMakeLists.txt`の`littlefs_create_partition_image`(依存する
`joltwallet/esp_littlefs`コンポーネント、`main/idf_component.yml`で
`joltwallet/littlefs: "~=1.20.0"`と指定)は、storageパーティションのイメージを
作る際に**初回ビルド時にvenvを作ってPyPIから`littlefs-python`をpip installする**。
これが実際のビルド実行時にネットワークの不調でタイムアウトして失敗する事象が
起きた(`pip._vendor.urllib3.exceptions.ReadTimeoutError`)。

最初は「Dockerイメージビルド時にpipキャッシュへ先に取り込んでおく」対処をしたが、
`"~=1.20.0"`というレンジ指定だと実際に解決されるパッチバージョンが変わりうる
(1.20.0〜1.20.4の間で`image-building-requirements.txt`の中身
= 要求される`littlefs-python`のバージョンが`0.13.3`/`0.15.0`の2パターンあることを
実際に確認した)ため、「たぶん合っているキャッシュ」止まりだった。

そこで一歩進めて、**バージョン解決自体を無くす**方針に変更した:

1. Dockerfileで`main/idf_component.yml`の`joltwallet/littlefs`を`"~=1.20.0"`から
   `"1.20.4"`(Docker build時点で実在を確認できた最新パッチ版。
   https://components.espressif.com/components/joltwallet/littlefs で確認)に
   `sed`で固定する。これで`image-building-requirements.txt`の中身
   (=`littlefs-python==0.15.0`)が一意に確定する
2. そのバージョンのwheelを`pip3 download littlefs-python==0.15.0 -d /opt/pip-wheels`
   でDockerイメージビルド時に取得して焼き込む
3. `ENV PIP_NO_INDEX=1` / `ENV PIP_FIND_LINKS=/opt/pip-wheels`
   をコンテナ全体に設定する。これにより、コンテナ内のどのpip実行も常に
   `/opt/pip-wheels`だけを見るようになり(PyPIへの通信自体が発生しない)、
   ビルド実行時のvenv内pipもこの設定を継承する(`ENV`はコンテナの環境変数として
   永続するため、`docker exec`等で入った場合や、`idf.py build`→ninja→cmakeの
   カスタムコマンド経由で起動される孫プロセスにも問題なく伝わる。
   `PROJECT_BUILD_CONFIG`環境変数と同じ伝播の仕組み)

実際に検証もした: `PIP_NO_INDEX=1 PIP_FIND_LINKS=<ローカルディレクトリ>`かつ
存在しないインデックスURLを指定した状態で`pip install littlefs-python==0.15.0`を
実行し、ローカルのwheelだけから(ネットワーク通信なしで)正常にインストールできる
ことを確認済み。

**トレードオフ**: `PIP_NO_INDEX`/`PIP_FIND_LINKS`はコンテナ全体に効くため、
将来他の目的で何かpipインストールが必要になった場合、事前に`/opt/pip-wheels`へ
用意しない限り失敗するようになる(ESP-IDFの component manager自体はPyPIではなく
ESP Component Registryを見る別の仕組みなので影響を受けない)。今のところこの
コンテナ内でpipを使うのはここだけなので許容している。

## プロジェクト設定(ターゲット・VM・USB Console)

ターゲットチップ(`esp32`等)・VM(femtoruby/picoruby)・USB Consoleは、最初は
メニューバー常設のセレクト(ターゲット)や、ビルド開始のたびに出るダイアログ
(VM/USB Console)で毎回選ばせる作りだったが、「プロジェクトの設定として
プロジェクトに含めたい」というフィードバックを受けて、mrbgemのopt-out方式への
変更や「プロジェクトのapp.rbを起動スクリプトにする」変更と同じ考え方
(プロジェクトディレクトリの中に状態を持たせる)で、プロジェクトごとの隠しファイル
`.config.yml`(`PROJECT_CONFIG_FILENAME`)に永続化する方式に変えた。

- `GET`/`POST /api/projects/:name/config` — 読み書き。`read_project_config`は
  ファイルが無い/壊れている場合「未設定」(platform/vmはnil、usb_consoleはfalse)
  として扱う(`YAML.safe_load`が例外を出す壊れたYAMLでも落ちないようにしてある)
- UI側は`ProjectSettingsDialog`(旧`BuildDialog`を置き換え)でこの3項目をまとめて
  編集・保存する。保存後は「プラットフォームをセットアップ」
  (`POST /api/platform`、bodyは`{project:}`のみ)「ビルド開始」
  (`POST /api/build`、bodyは`{project:}`のみ)の各ボタンが、リクエストの
  パラメータではなくその時点で保存済みの`.config.yml`の値をサーバ側で読んで
  そのまま使う。都度選び直す必要がなくなった
- プロジェクトを切り替えたら`load_project_config`でそのプロジェクトの
  `.config.yml`を読み直す(`select_project`から呼ぶ)。切り替え中に古いレスポンスが
  後から返ってきて新しいプロジェクトの設定を上書きしないよう、レスポンス受信時に
  `state[:current_project]`と一致するかを確認してから反映している

## Sinatraのホスト外出し・Dockerのビルド専用化(大規模アーキテクチャ変更)

これまでは「Sinatraアプリ・R2P2-ESP32・ESP-IDFすべてを1つのDockerイメージに
焼き込み、そのコンテナ内でアプリごと動かす」という構成だった。これを
「**Sinatraはホストでネイティブに動かし、Dockerはビルド専用**」という構成に
変更した。GitHubのdocsで実際に議論して固めた方針で、詳しい経緯・比較検討は
このセッションの会話に残っている。要点だけ書くと:

- 対象ユーザーがRuby開発者である以上「Rubyの実行環境がある」ことはハードルに
  ならない。むしろ「アプリ全体がDocker前提」であることのほうがハードルが高い
- ESP-IDFのビルド環境はセットアップが重く複雑なので、Dockerで隠蔽する価値が高い
  (=ここだけはDockerに残す価値がある)
- 「ビルドキャッシュ・sdkconfig・managed_componentsをプロジェクトごとに持たせたい」
  (ターゲットやVMが違うプロジェクトを切り替えるたびに実質フルリビルドになる問題)
  という要望から、**ビルドのたびに使い捨てコンテナを起動する**設計になった。
  これによりDockerソケット共有(DooD)のような複雑さも不要になった
  (Sinatraがホストの通常プロセスとして`docker run`を呼ぶだけで済むため)

### 新しい構成

- `Dockerfile` — ESP-IDFツールチェインだけを持つビルド専用イメージ(後述)。
  `docker build -t picoride-builder .` で事前にビルドしておく
- `bin/server` — Sinatraをホストでネイティブに起動するスクリプト
  (`bundle exec exe/picoride`のラッパー)。旧`bin/dev`は削除した
- `lib/picoride/r2p2_state.rb` — プロジェクトごとのR2P2-ESP32状態を
  管理するモジュール(詳細後述)
- `PROJECTS_ROOT` / `R2P2_STATE_ROOT` / `PICORUBY_BUILDER_IMAGE`
  (`lib/picoride/server.rb`) —
  いずれも環境変数で上書き可能。特に`PROJECTS_ROOT`が設定可能になったことで、
  当初の目的だった「プロジェクトをホストの好きな場所に置きたい」が実現している

### プロジェクトごとのR2P2-ESP32状態(`lib/picoride/r2p2_state.rb`)

以前は1つのR2P2-ESP32チェックアウトを全プロジェクトで共有していたが、これを
プロジェクトごとに独立させた。状態ディレクトリは`R2P2_STATE_ROOT`
(既定`~/.picoride/r2p2-esp32/`)配下に`<project名>`で1つずつ持つ
(プロジェクト本体の外に置く。R2P2-ESP32はサイズが大きく、ユーザーのプロジェクト
gitリポジトリに混ざるべきではないため)。

以前Dockerfileの`RUN`でイメージビルド時に1回だけ実行していた

- R2P2-ESP32のgit clone
- build_config.rbフックのパッチ(`conf.instance_eval(...)`を4ファイルの`end`直前に挿入)
- `main/idf_component.yml`のjoltwallet/littlefsバージョン固定

は、`R2P2State.ensure_checkout(state_dir)`として**プロジェクトが初めてその
状態ディレクトリを使うとき**に動的に実行する処理になった。パッチ処理は
シェルのワンライナー(`head -n -1` / `printf` / `mv`)から素のRubyコードに
書き直した。理由は、プロジェクトごとに動的に実行する処理としてRubyで書く方が
自然なのに加え、このセッションで2度踏んだシェルエスケープバグ
(`\&\&`が生成コードに混入してSyntaxError)を構造的に避けられるため。

### ビルド/セットアップの実行(`r2p2_docker_command`)

`POST /api/build` / `POST /api/platform`は、ビルド開始直前に
`R2P2State.ensure_checkout`(未チェックアウトならここでgit clone、数分かかる)
してから、`r2p2_docker_command(state_dir, project_root, inner_cmd)`が組み立てる
`docker run --rm -v <state_dir>:/R2P2-ESP32 -v <project_root>:/project_src
<BUILDER_IMAGE> bash -c '...'`を`BackgroundJob`(変更なし)で実行する。

- `BackgroundJob`(`Open3.popen2e`でサブプロセスの標準出力を逐次読む仕組み)は
  **無変更で流用できた**。`docker run`もただのサブプロセスでしかないので、
  リアルタイムのログストリーミングはそのまま動く
- `PROJECT_BUILD_CONFIG`環境変数や、mrbgemの`conf.gem gemdir:`に書くパスは、
  **コンテナ内から見たパス**(`/project_src/...`、`CONTAINER_PROJECT_MOUNT`)に
  変わった。ホスト側の実パスではない点に注意(以前は同じプロセス内で完結していた
  ので気にする必要がなかった)
- `sdkconfig_has_usb_console?`・ファームウェア配信(`GET /api/firmware/*`)・
  `storage/home/`へのapp.rbコピーは、参照するパスを`state_dir`(プロジェクトごと)
  に差し替えるだけで、**ファイルI/Oのロジック自体は変更していない**。R2P2-ESP32の
  状態をホストの実ディレクトリにbind mountする設計(named volumeではなく)に
  したことで、Sinatra(ホスト上で動く)は今まで通り`File.read`/`Dir.glob`で
  直接読める
- ファームウェア配信系(`GET /api/firmware/manifest.json`・`GET /api/firmware/*`)は
  プロジェクトごとにビルド成果物の場所が変わったので、`project`クエリパラメータが
  必須になった(以前は不要だった)。マニフェストの`parts[].path`にも
  `?project=...`を埋め込んで、ESP Web Tools側からのファイル取得時にも
  引き継がれるようにしてある
- `docker run`前に`builder_image_available?`(`docker image inspect`)で
  ビルド用イメージの存在を確認し、無ければビルド方法を案内するエラーを返す

### `Dockerfile`(ビルド専用イメージ)で実際に踏んだ罠

Ruby/rbenv/R2P2-ESP32を全部イメージから追い出して「ESP-IDFツールチェインだけ」
にすれば十分だろうと考えていたが、実際に`rake setup_esp32`を通しで実行してみたら
2つ想定外のエラーが出た(**目視だけでなく実際にビルド→実行して検証したことで
発見できた**、この種のバグは動かしてみないと分からない典型):

1. **`git`の`dubious ownership`エラー**: bind mountしたディレクトリはホスト側の
   実UIDのまま見えるため、コンテナ内のユーザーとの所有者不一致でgit
   2.35.2以降(CVE-2022-24765対策)が操作を拒否する。
   `git config --system --add safe.directory '*'`をイメージビルド時に実行して解決
   (bind mountされるパスは実行のたびに変わるプロジェクトごとの状態ディレクトリ
   なので、個別許可ではなく全許可にした。ビルド専用の使い捨てコンテナでしか
   使わないイメージなので安全性への影響は無視できる)
2. **`bundle: command not found`(exit 127)**: R2P2-ESP32の`rakelib/setup.rake`は
   内部で(mrubyをビルドするために)picorubyサブモジュール内で`bundle install`を
   呼ぶ。ベースイメージ(`espressif/idf`)にはシステムRubyがあり`bundler`ライブラリも
   デフォルトgemとして入っているが、`bundle`コマンドの実行ファイルは生成されて
   いなかった。`gem install bundler --no-document`で解決
3. **ネイティブ拡張のビルド失敗(`mkmf.rb can't find header files for ruby`)**:
   上記の`bundle install`がracc/ffi/io-console/json等ネイティブ拡張を持つgemを
   ビルドしようとするが、ベースイメージにはコンパイラもRubyのヘッダファイルも
   無い。`apt-get install build-essential ruby-dev libssl-dev libreadline-dev
   zlib1g-dev libyaml-dev libffi-dev`で解決(奇しくも、Ruby自体をrbenvで
   ソースからビルドしていた旧Dockerfileでは同じパッケージ群が副次的に必要
   だったため、apt-getのパッケージリスト自体は実質同じものが必要だった)

いずれも`docker build` → 実際に`rake setup_esp32`を`docker run`経由で実行して
初めて見つかったバグ。`ruby -c`のような静的チェックでは検出できない類のもの
なので、Dockerfileを変更したときは必ず実際にビルド〜実行まで通すこと。

## PicoRuby Web Terminal相当の機能(ソースコードペインのタブ切り替え)

ビルド・インストール(ESP Web Tools)とは別に、実機のUSBシリアルに直接つないで
対話するターミナル画面を追加した。エディタ(`editor-area`)を「エディタ」/
「ターミナル」のタブ切り替えにし(`editor_app.rb`の`editor_tab` state、
`.tab-pane` / `.tab-pane.hidden`)、現在のプロジェクトの`app/`以下を実機の
`/home/`以下へ転送する「app/ をアップロード」ボタンも一緒に置いた。

**ターミナル関連の状態・ロジックは全部`editor_app.rb`(ルートコンポーネント)の
中にある。** 当初は`TerminalPanel`という別コンポーネントに分けていたが、後述の
「子コンポーネントは親の再描画のたびに作り直される」問題を踏んで`EditorApp`に
統合した。次にこの機能を触るときも、うっかり別コンポーネントに切り出さないこと。

### 設計方針: サーバは一切関与しない

ビルド/インストールは「サーバでビルド → ブラウザのWeb Serial API(ESP Web Tools)で
書き込み」という2段構えだったが、ターミナルは書き込み後の対話なので
サーバを経由する理由が無い。ブラウザ⇔実機USBを直結する
(picoruby.org/terminal https://picoruby.org/terminal 、実装は
https://github.com/picoruby/picoruby.github.io の pages/r2p2/terminal.rb
と pages/r2p2/terminal.html 参照)のと同じ構成にした。

### `JS::WebSerial`はpicoruby-wasm本体が既に持っている

エディタ画面自体がFunicular(hasumikin作、PicoRuby.wasm上で動くVDOMフレームワーク)
で動いており、Web Serial APIも「アプリ側でJSを書いて橋渡しする」のではなく
picoruby-wasm本体(npm `@picoruby/wasm-wasi`)が`JS::WebSerial`として
既に提供している。このIDEが依存しているバージョン(`@picoruby/wasm-wasi@4.0.2`、
`views/index.erb`でCDN読み込み)に実際に入っているかどうかは、この機能を
実装する時点でのサンドボックスにRubyはあってもブラウザでの実機テストが
できなかったため、`npm pack @picoruby/wasm-wasi@4.0.2`して展開した
`dist/picoruby.wasm`/`dist/picoruby.js`に対して`strings`やNode.jsで文字列検索し、
以下を確認して裏付けを取った:

- `dist/picoruby.js`に`serial_request_port` `serial_port_open` `serial_start_reading`
  `serial_binary_capture_start/read/stop` 等のJS側関数が実装済みで存在する
- `dist/picoruby.wasm`(コンパイル済みバイナリ)の文字列に、picoruby本体の
  `mrbgems/picoruby-wasm/mrblib/webserial.rb`(`JS::WebSerial`のRuby側API。
  `supported?` `connect` `open` `on_receive` `on_disconnect` `write_bytes`
  `opened?`、Cで実装される`_request_port` `_open_port` `_start_reading`
  `_close_port_promise`等)や、`crc16` `crc32`(`require 'crc'`、
  `picoruby-crc`)、`pack`/`unpack`(`Array#pack`/`String#unpack`)、
  `start_terminal_read` `binary_capture_read/start/stop` `drain` `@js_port`
  といった、picoruby.org/terminalのterminal.rbが実際に呼んでいるメソッド名が
  ほぼそのまま埋め込まれている

以上から、このnpmパッケージがFunicular同梱・WebSerial対応の(picoruby.org/terminal
と同系統の)ビルドだと判断し、terminal.rbの実装をほぼそのまま移植する方針にした。
実際に`bin/server`相当(`bundle exec ruby app/app.rb`)を起動し、ブラウザで
「デバイスに接続」を押したところ、`navigator.serial.requestPort()`が実際に
呼ばれ(実機もポート選択もないため`Failed to execute 'requestPort' on 'Serial':
No port selected by the user.`という本物のブラウザ例外が返り、それを
Rubyの`rescue`が捕まえてステータス表示に出す、というエンドツーエンドの配線は
確認できた。ただし実機(ESP32)を使ったPicoModem転送そのものは、この環境に
実機が無いため未検証。実際に試す際は先に実機をUSB接続し、R2P2のプロンプトが
出ている状態で試すこと。

**罠**: `dist/picoruby.wasm`に対する`strings`でのメソッド名検索は、
`serial_binary_capture_start`のような長く固有な名前には有効だが、
`getbyte` `pack` `sub` `each` `ord`のような短くありふれたメソッド名では
**実際には使えるのに見つからない(偽陰性)**ことがある(既にこのアプリで
動いている`.each`ですら`strings`では見つからなかった)。おそらくmrubyの
シンボルテーブルが短い名前を`strings`が拾えない形式で保持しているため。
そのため「`strings`で見つからない」ことは「使えない」ことの証拠にはならない。
`String#getbyte`が実際に使えるかどうかを最終確認したときは、
`EditorApp#component_mounted`に一時的な自己診断コード(各メソッドを
`begin/rescue`で呼んで`JS.global[:console].log`に結果を出すだけのもの)を
仕込み、`bundle exec ruby app/app.rb`を実際に起動してブラウザの
コンソールログで確認した上でコードを削除する、という手順を踏んだ。
この手のAPI有無の確認は静的な文字列探索より、実際に動かして確認するほうが早くて確実。

### デバイス再起動時の自動再接続

「デバイスを再起動すると接続が切れる」というフィードバックを受けて、
picoruby.org/terminalと同じ自動再接続を実装した。ESP32がリセットされると
USBの列挙が一瞬切れて同じ物理ポートとして再度現れる(Web Serial的には
対象ポートの`disconnect`に続けて、ブラウザ全体に`navigator.serial`の
`connect`イベントが飛んでくる)。ユーザーが明示的に「切断」ボタンを押した
のでなければ、ポートが再度現れた時点で確認ダイアログ無しに自動で開き直す
(`EditorApp#watch_for_terminal_reconnect` / `#attempt_terminal_auto_reconnect`)。

これも前節と同じ理由(`strings`は短い名前を拾えないことがある)で、
`JS::WebSerial.methods(false)` / `.instance_methods(false)`を実際に
ブラウザのコンソールへ出して初めて全容が分かった。分かったこと:

- クラスメソッドに`_watch_connect_events` `_take_last_connected_port`という
  低レベルAPIは**存在する**(npmパッケージのwasmにC拡張として直接コンパイル
  済み)。JS側実装(`picoruby.js`)はグローバルに1回だけ`navigator.serial`の
  `connect`イベントを監視し、来たポートを`globalThis.picorubyLastConnectedSerialPort`
  に控えつつ`window`に`serial-port-connect`というCustomEventを飛ばす、という
  作り
- ただしmrblib(`webserial.rb`)側には、これらを使う**高レベルのRubyラッパー
  メソッドが無い**(`on_reconnect`のような便利メソッドは無い)。なので
  `"_"`付きのままRubyから直接呼ぶ(`JS::WebSerial._watch_connect_events`
  という具合)。挙動としては`window.picorubySerialConnectWatcherInstalled`
  というグローバルフラグが立つので、ブラウザのコンソールで
  `window.picorubySerialConnectWatcherInstalled === true`を見れば
  登録できたかどうか確認できる(実機テストできない環境でもこれで配線だけは検証可能)
- 再接続本体は`JS::WebSerial._take_last_connected_port`で控えておいた
  ポートを取り出し、`JS::WebSerial.new(raw_port)`(`request_port`を経由しない
  コンストラクタ呼び出し)→`ws.open(baud_rate: ...)`で開き直す、という
  terminal.rbのApp#bind_events内`serial.addEventListener('connect')`
  ハンドラとほぼ同じ流れ
- 個別ポートの`on_disconnect`(`_set_on_disconnect`経由)が発火しない
  ブラウザ/デバイスの組み合わせに備えて、`navigator.serial`自体の
  `disconnect`イベントも保険で見ている(これもterminal.rbと同じ構成)

`@auto_reconnect`(インスタンス変数、`state`には入れていない)で
「ユーザーが明示的に切断したか」を覚えておき、明示的な切断のときだけ
自動再接続を止める。実機での動作(実際にリセットして再接続まで確認)は
この環境では検証できていないので、次に実機を使うセッションで確認すること。

### 「app/ をアップロード」はPicoModemプロトコル(標準ビルドに元々含まれる)

R2P2のシェル(`picoruby-shell`)はプロンプト待機中にCtrl-B(STX, 0x02)を
受け取ると`PicoModem.session($stdin, $stdout)`(`picoruby-picomodem`)に入り、
1セッションにつき1ファイルのFILE_WRITE/FILE_READ等を処理してシェルへ戻る
(`picoruby-shell/mrblib/shell.rb`、`require "picomodem"`が最初から書いてある)。
`picoruby-picomodem`は`picoruby-shell`の`add_dependency`なので、**mrbgemを
何も追加しなくても、R2P2-ESP32の標準ビルド(4種のbuild_config全部)に
最初から含まれている**(実際に`components/picoruby-esp32/build_config/*.rb`と
`picoruby-shell/mrbgem.rake`を確認して裏付けた)。そのため、実機ファーム側の
変更は一切不要で、ブラウザ側だけでPicoModemクライアントを実装すればよかった。

フレーム構造(STX + 長さ + Cmd + Payload + CRC16)・CRC32によるファイル整合性
検証・チャンク分割送信などのプロトコル詳細は、terminal.rbのPicoModemクライアント
実装をほぼそのまま`editor_app.rb`に移植した。CRC16/CRC32の多項式・初期値も
picoruby本体`picoruby-crc`のC実装(`crc.c`)から拾って一致させてある。

複数ファイルを送る際、PicoModemは1セッション1ファイルなので
「Ctrl-B送信→ACK待ち→FILE_WRITE」をファイルごとに繰り返す必要がある。
`upload_next_terminal_file`は、ファイル内容の取得(`Funicular::HTTP.get`)の
コールバックが同期/非同期どちらで呼ばれるか確証が持てなかったため、
`Enumerable#each`ではなく継続渡し(1ファイル完全に終わってから次を呼ぶ)に
してある。1本のシリアル接続を複数ファイルの転送が同時に取り合うと、
PicoModemのフレームが混ざって壊れるため。

デバイス上のパスは、`POST /api/build`が`app/`以下を`storage/home/`へコピーする
(→実機からは`/home/`以下に見える)のと対応を合わせて、`app/foo.rb` →
`/home/foo.rb`のように変換している。

### xterm.jsは「タブが非表示の間にマウントするとサイズが0になる」問題がある

タブが非表示(`.tab-pane.hidden`、`display: none`)の間にxterm.jsを初期化すると
コンテナの寸法が0になる。ただし`terminal.open(container)`自体は非表示要素に
対しても問題なく実行でき、実際の行数/桁数はコンテナに登録した`ResizeObserver`が
寸法変化(タブ表示時にdisplay:noneが外れて0以外になる)を検知して`fit`し直す
ので、タブを表示した時点で正しいサイズに追従する。実際にブラウザで「ターミナル
タブに切り替えた瞬間に`.xterm-rows`が生成され、寸法も正しく反映される」ことを
確認済み。

### 【重大】子コンポーネントは親が再描画されるたびに作り直される
#
# このセクションはこのIDE特有の、かつ他の機能にも影響しうる重要な制約なので
# 太字にしてある。今後 `component(SomeClass, ...)` で切り出した子コンポーネントに
# 「一度だけ初期化して使い回したい副作用」(外部リソースへの接続、イベント
# リスナー登録、外部ライブラリのインスタンス化など)を持たせるときは、必ず
# このセクションを読み返すこと。

最初`TerminalPanel`という独立コンポーネント(`props`に`project`/`files`/`active`を
渡し、`state`に接続状態を持たせる作り)にしていたところ、
「ファイルペインとターミナルペインを行き来すると接続が切れる。再接続しようとすると
`すでにオープンされている`と言われて失敗する」という不具合が実際のユーザーから
報告された。

原因はFunicularの仕様: **`component(SomeClass, props)`という呼び出しは、呼び出す
親(ここではEditorApp)が再描画されるたびに、その子コンポーネントの
`initialize_state`と`component_mounted`を毎回呼び直す。** ルートコンポーネント
(`Funicular.start(EditorApp, ...)`に渡すもの)だけがマウント1回を保証される。
これは`EditorApp`の`initialize_state`/`component_mounted`に呼び出し回数を数える
一時的なデバッグコードを仕込んで実際にブラウザで確認した(`TerminalPanel`側は
数回のページ操作だけで3回以上呼ばれたのに対し、`EditorApp`側は終始1回だけだった)。

この既存コードベースを見ると、**このIDEの子コンポーネント(`FileList` `Toolbar`
`MenuBar` `ProjectSettingsDialog` `LogPanel`)は元から1つも`initialize_state`を
定義していない**、つまり全部「propsを受け取って描画するだけの表示専用」
コンポーネントだった。これは単なるコーディング規約ではなく、**Funicularのこの
挙動に対する回避策として最初から必須の設計**だったということ。`TerminalPanel`は
この規約を破って唯一`initialize_state`を持つ子コンポーネントにしてしまったために
問題が表面化した。

具体的に起きていたこと: EditorAppは`patch()`のたびに再描画される(タブ切り替え・
ファイルを開く・1文字タイプする、等ほぼ全ての操作で発生)。そのたびに
`TerminalPanel`の`initialize_state`が再実行され、`state[:status]`が初期値
`'disconnected'`に戻る。一方`@port`(生のシリアルポート、実際にはbrowserレベルで
まだopenのまま)はインスタンス変数なので必ずしも即座には失われないが、UI表示上は
「未接続」に見える。ユーザーが「接続」ボタンを押すと`JS::WebSerial.connect`が
また`_request_port`を呼び、同じ物理デバイスを選ぶと(一度も`.close()`されていない
ため)ブラウザ側ではまだopenなSerialPortオブジェクトが返り、`.open()`が
`InvalidStateError`(「すでにオープンされている」)で失敗する。

対処: **状態と副作用(xterm.jsインスタンス、シリアルポート、イベントリスナー)を
`TerminalPanel`から`EditorApp`本体へ丸ごと統合した**(`terminal_panel.rb`は削除、
ロジックは`editor_app.rb`に`terminal_`プレフィックス付きのメソッド/state key
として移動)。これは元々あった「textarea/ハイライト層をコンポーネントに切り出さず
EditorApp直下に置く」設計と全く同じ理由・同じ対処であり、後から振り返れば
必然だった。もし将来また「一度だけ初期化する副作用を持つUI」を追加したくなったら、
別コンポーネントに切り出さずEditorAppに直接書くか、少なくともこの制約を
踏まえた設計にすること。

## サイドバーのファイル一覧をツリー表示にした(TreeView)

「ファイル一覧をツリー表示に、フォルダの開閉もできるように」という要望を受けて、
`FileList`(フラットな一覧、表示専用)を`TreeView`(`web/funicular/ruby/components/
tree_view.rb`)に置き換えた。

### 汎用コンポーネントとして設計した

「あとで独立したコンポーネント/gemとして切り出すことを念頭に」という指定だったので、
`TreeView`は「ファイル」や「プロジェクト」を一切知らない、
`{name:, path:, type: :dir|:file, children: [...]}`という形のノード配列を
描画するだけの汎用コンポーネントにしてある。props(`nodes` `collapsed` `selected`
`icon_for` `on_select` `on_toggle`)経由でしか外の世界とやり取りしない。

前節の「子コンポーネントは親の再描画のたびに作り直される」という制約があるので、
**折りたたみ状態(どのディレクトリが閉じているか)は`TreeView`自身のstateには
一切持たせず、呼び出し側(`EditorApp`の`state[:collapsed_dirs]`)に持たせて
propsで渡す**設計にしてある。`TreeView`は`initialize_state`を定義していない
(=表示専用コンポーネントの規約を守っている)ので、作り直されても実害が無い。

`state[:files]`(プロジェクト直下からの相対パスのフラットな配列。例:
`"mrbgems/picoruby_hello_world/mrbgem.rake"`)をネストしたノード配列に組み立てる
ロジック(`file_tree_nodes` / `insert_file_tree_path` / `sorted_file_tree_nodes`)は
「ファイルパス」というこのアプリ固有の概念を扱うので、`TreeView`側ではなく
`EditorApp`側に置いてある。

### 踏んだ罠: `TreeView#select`がFunicularの`<select>`タグヘルパーと衝突する

ファイルクリック時のハンドラを最初`select(path)`という名前にしたところ、
ブラウザで即座に

```
Funicular::DSLCollisionError: TreeView#select collides with the Funicular DSL
(<select> tag helper). Rename it (e.g. `select_value`), or declare
`allow_dsl_override :select` and use `tag(:select, ...)` to emit the element.
```

というエラーが出て、ツリーが「読み込み中…」のまま固まった(例外がrender中に
発生すると、そのレンダーパス全体が失敗し、直前の(読み込み中の)DOMが
そのまま残ってしまう)。Funicularは`div` `span` `button` `ul` `li`等と同じ感覚で
`select`という**HTMLタグ用のDSLメソッドを標準で生やしている**ため、
コンポーネント側で同名のメソッド(`select`)を定義すると衝突する。エラーメッセージ
自体は非常に分かりやすく、原因の特定に迷うことは無かった。対処は単純に
`select_file`のような衝突しない名前に変える。

**教訓**: Funicularのコンポーネントにメソッドを生やすときは、HTMLタグ名
(`select` `label` `option` `form` `data` 等、意外と一般的な単語がタグ名として
存在する)と衝突しないか一応意識する。衝突した場合はエラーメッセージが
`Funicular::DSLCollisionError`として明示的に教えてくれるので、実際に動かして
みればすぐ分かる(今回もブラウザで動かして1回で発見できた)。

## 「ファイル」メニュー(新規プロジェクト/プロジェクトを開く/mrbgemを追加/新規ファイル/新しいフォルダ)

既知の制約に挙げていた「新規ファイル作成/削除/リネームAPIがない」「プロジェクトの
新規作成ができない」を一部解消する形で、メニューバー左端に「ファイル」ドロップダウンを
追加した(`menu_bar.rb`の`render_file_menu`)。削除/リネームは対象外のまま(スコープ外)。

- `POST /api/projects` — 新規プロジェクト作成。`app/app.rb`(空)と`build_config.rb`
  (空)だけを作る。`mrbgems/`は最初のmrbgem追加まで作らない
  (`project_mrbgem_names`がディレクトリ不在でも空配列を返すため不要)
- `POST /api/projects/:name/mrbgems` — mrbgemの雛形(`mrbgem.rake` +
  `mrblib/<name>.rb`)を作る。ここに置くだけで次回ビルドから自動的に組み込まれる
  仕組み(`generated_build_config_content`)は変更していない
- `POST /api/projects/:name/files` — 空の新規ファイルを作る。既存の`POST /api/file`は
  上書き専用のままにして、新規作成はこちらに分離した
- `POST /api/projects/:name/folders` — 空のフォルダを作る
- プロジェクト名・mrbgem名は`PROJECT_NAME_PATTERN`(英数字・`_`・`-`のみ)で
  バリデーションしている。新規ファイル/フォルダのパスは`safe_path`のパストラバーサル
  対策に加え、`valid_new_file_path?`でドット始まりのセグメント(`.r2p2-esp32`や
  `.config.yml`等、UI上のファイル一覧に出さない前提のものと衝突しうる)を拒否する

**新規ファイル・新しいフォルダは`app/`配下だけに制限してある**(「ファイルの作成は
app以下に制限したい」というフィードバック)。`under_app_dir?`ヘルパーで
`app/`で始まり、かつ`app/`自身ではないことをチェックする。`mrbgems/`側は
「mrbgemを追加」が専用の雛形(`mrbgem.rake` + `mrblib/<name>.rb`)を作るので、
この2つのエンドポイントの対象外のままでよい。新規ファイルの拡張子も
`NEW_FILE_EXTENSION`(`.rb`)固定にした(同フィードバックの「rubyファイルだけに
制限」より。`app/`はR2P2起動時に`main_task.rb`がloadするRubyスクリプト置き場で
あり、mrbgemのような`.c`/`.h`/`.rake`を置く場所ではないため)。UI側のダイアログには
`app/`を省いた相対パス(例: `utils/foo.rb`)を入力させ、送信直前に
`EditorApp#to_app_path`で`app/`を補っている(サーバ側のチェックは飽くまで防御。
「`app/`を書かなくていい」というUXはフロント側の責務)。

**空のフォルダをツリーに表示するために`GET /api/dirs`を追加した。**
既存の`GET /api/files`はファイルパスの一覧しか返さないため、`file_tree_nodes`が
そこから組み立てるツリーは「1つもファイルを含まないディレクトリ」を表現できない
(パスの並びにディレクトリ単体のエントリが出てこないので)。新規フォルダ作成で
このケースが実際に起きるため、ディレクトリ一覧(空のものも含む、`Dir.glob`ベースで
`GET /api/files`と同じくドット始まりは自動的に除外)を別エンドポイントで返し、
フロント側は`state[:dirs]`として保持、`insert_file_tree_dir_path`
(`insert_file_tree_path`のディレクトリ専用版。末尾セグメントも`:dir`として
挿入する点だけが違う)で`state[:files]`由来のツリーにマージしている。
`GET /api/files`のレスポンス形自体(ファイルパスの配列)は変えていない
(ターミナルの「app/ をアップロード」機能がこの配列をそのままファイルとして
読み込みに行くため、ディレクトリを混ぜると壊れる)。

UI側は3つのフォームダイアログ(新規プロジェクト名/mrbgem名/ファイルパス)を
`PromptDialog`という1つの汎用コンポーネントに集約した(タイトル/ラベル/
プレースホルダ/確定ボタンのラベル/エラーメッセージをpropsで差し替えるだけ)。
「プロジェクトを開く」だけは一覧から選ぶ形なので別コンポーネント`OpenProjectDialog`
にしている(EditorAppが既に持っている`state[:projects]`をそのまま渡すだけで、
追加のAPI呼び出しはしない)。

**入力欄はrefで直接DOM値を読む非制御コンポーネントにしてある**(`PromptDialog`)。
ビルドログのポーリング(3秒おき)でEditorAppが再描画される間もダイアログを開いたままに
できる設計上、`value`をpropsから毎回書き戻す制御方式にすると、そのたびに入力中の文字が
消えてしまう。他のフォーム系コンポーネント(`project_settings_dialog.rb`の
`<select>`)と同じ理由・同じ対処。

実装時に上の「`TreeView#select`衝突」と全く同じ罠を`OpenProjectDialog#select`でも
踏んだ(プロジェクトをクリックして選択するメソッドに`select`と名付けてしまった)。
ブラウザのコンソールに`Funicular::DSLCollisionError`が出て発覚、`select_project`に
リネームして解決。**この罠は繰り返し踏みやすいので、Funicularコンポーネントに
クリックハンドラ用メソッドを生やすときは`select`という名前を反射的に避けること。**

## ファイルツリーの右クリックコンテキストメニュー・削除機能

「ファイルツリーにもコンテキストメニューが欲しい」というフィードバックを受けて、
`TreeView`(`tree_view.rb`)の各行に`oncontextmenu`を追加した。`TreeView`自体は
ファイル/プロジェクトの概念を知らない汎用コンポーネントという設計を保つため、
右クリックされた`node`(type/path)とDOMの`event`をそのまま`props[:on_context_menu]`
経由で呼び出し側(`EditorApp`)に渡すだけにしてある。メニューの中身を何にするかの
判断は全部`EditorApp#context_menu_kind`に置いた:

- ファイル: 削除のみ
- `"app"`自身: ファイルを作成/フォルダを作成(削除は出さない。プロジェクトの
  実行スクリプト置き場であるapp/自体が消えると壊れるため)
- `"app"`配下のディレクトリ: ファイルを作成/フォルダを作成/削除
- `"mrbgems"`自身: mrbgemを追加のみ(既存の「ファイル」メニューの項目と同じ
  `open_add_mrbgem_dialog`を呼ぶだけ。専用の雛形を作る仕組みなので他の
  ディレクトリとは別メニューにしてある、という要望通り)
- それ以外のディレクトリ(`mrbgems/<gem>`やそのサブディレクトリ等): 削除のみ
  (ファイル/フォルダの新規作成はapp/配下限定という既存の制約と矛盾しないよう、
  ここでは作成系のメニュー項目を出さない)

**新規ファイル/フォルダ作成ダイアログをcontext_dirで一般化した。** 以前は
「app/ からの相対パス」を常に入力させる作りだったが、コンテキストメニューから
開く場合は右クリックしたディレクトリの中に作るのが自然なので、
`PromptDialog`の`state[:prompt_dialog][:context_dir]`(基準ディレクトリの
プロジェクト内相対パス。「ファイル」メニューからなら常に`'app'`、コンテキスト
メニューからなら右クリックしたディレクトリの`path`)を基準に、入力欄には
「基準ディレクトリの中でのファイル名」だけを入力させ、送信直前に
`EditorApp#to_full_path(context_dir, rel)`で連結する。基準ディレクトリを
ダイアログの入力欄の初期値として埋め込む(prefill)方式は採用していない
——`PromptDialog`は非制御コンポーネントなので、ポーリング等による親の
再描画のたびに初期値を書き戻すと入力中の文字が消える(既存の「入力欄は
refで直接DOM値を読む」節と同じ理由)。代わりにラベル・タイトル側に
基準ディレクトリを文言として表示するだけにして、入力欄自体は常に空から
始まる設計にしてある。

**削除(`DELETE /api/projects/:name/files` / `DELETE /api/projects/:name/folders`)は
作成と違いapp/配下に限定していない**(mrbgemの.c/.hファイルなど、プロジェクト内の
どこにあるファイル/フォルダでも削除自体は妥当なユースケースがあるため)。
その代わり、フォルダ削除は`app`自身・`mrbgems`自身を消せないようサーバ側でも
明示的にガードしている(UIのコンテキストメニューで出さないのに加えて、
APIを直接叩かれた場合の防御を二重にしてある)。削除は取り消せない操作なので、
実行前に`JS.global.confirm(message)`で確認を挟む(Funicular本体の
`Funicular.confirm`も既定でこれに委譲する作りになっている。
`picoruby-funicular/mrblib/funicular.rb`の`!!JS.global.confirm(message)`参照)。
削除対象のファイルがエディタで開いたままだった場合(削除されたフォルダの
配下に開いていたファイルがあった場合も含む)は、実体の無いファイルを
編集し続けないよう`current_path`をクリアする。

**踏んだ罠1**: `context_menu_kind`で`APP_DIRNAME`/`MRBGEMS_DIRNAME`を参照したところ
`NameError: uninitialized constant EditorApp::MRBGEMS_DIRNAME`になった。
これらの定数は`app.rb`(Sinatra、サーバ側のRubyプロセス)にしか定義しておらず、
`editor_app.rb`(ブラウザのPicoRuby.wasm、別プロセス・別Rubyランタイム)から
見えるわけではない、という当たり前の見落とし。フロント側にも同名の定数を
別途定義して解決した(サーバとフロントで定数を共有する仕組みは無いので、
今後も両側に同じ文字列リテラルを持つ設計になる)。

**踏んだ罠2**: 削除確認の`JS.global.confirm(...)`は、このセッションで使っている
ブラウザ自動操作ツール(MCP経由)ではネイティブダイアログが自動的に抑制され、
常に`false`が返ってくる(「ボタンを押しても削除されない」ように見えた)。
実際にはconfirmメッセージの内容自体は正しく渡っており、`curl`で
`DELETE`エンドポイントを直叩きして削除自体が動くことを別途確認した。
実際のブラウザ(自動操作ツール経由でない、人間が操作するブラウザ)では
ネイティブダイアログが普通に表示される。この種の自動操作ツール特有の
制約は、機能自体のバグと混同しないよう注意すること。

**踏んだ罠3**: 上記まではこの自動操作ツールで検証していたが、実際にユーザーが
自分のブラウザで試したところ「ブラウザ標準の右クリックメニューも自前のメニューと
一緒に出てしまう」と報告があった。`tree_view.rb`の各行の`oncontextmenu`(Funicular
DSL経由)でも`event.preventDefault`は呼んでいたが、それだけでは足りなかった
(自動操作ツールでは right_click してもブラウザの標準メニュー自体が画面に
描画されないため、この不具合はこのツールだけでは検出できず、実際に人間が
ブラウザで試して初めて発覚した)。

最初の対処として、`EditorApp#component_mounted`から素のJS
`JS.global[:document].addEventListener('contextmenu') { |event| ... }`
にRubyのブロックを直接渡す形(xterm.jsの`attachCustomKeyEventHandler`と同じ
発想)を試したが、**これでも直らなかった**。`refs[:sidebar]`越しの
`Node#contains`判定や、そもそもRubyブロック自体がPicoRuby.wasmを経由する
呼び出しである以上、`addEventListener`の登録先がJS/Rubyのどちらであっても、
コールバック本体がRuby(wasm)側にある限り、ブラウザ側から見て
「このcontextmenuイベントのデフォルト動作をまだキャンセルできる」同期的な
タイミングに間に合わない可能性がある、ということが実機での再現から
分かった(正確な内部メカニズムは未特定だが、Rubyブロックを経由する時点で
何らかの非同期性が生じると考えるのが一番説明がつく)。

最終的に効いたのは、**PicoRuby/Funicularのブリッジを完全に経由しない、
`views/index.erb`内の素の`<script>`タグ**(`window.funicularHighlight`と同じ、
「確実性が要る部分はプレーンJSに任せる」既存の方針):

```js
document.addEventListener('contextmenu', function (event) {
  if (event.target.closest('.sidebar')) {
    event.preventDefault();
  }
});
```

これなら`preventDefault`の呼び出しがブラウザのイベントディスパッチと完全に
同一のJS実行コンテキスト・同一のコールスタックで完結するため、タイミングの
不確実性が原理的に無くなる。`EditorApp#suppress_sidebar_native_context_menu`
(Rubyブロック版)と`div(class: 'sidebar', ref: :sidebar)`は不要になったので
削除した。実際に`document.querySelector('.tree-row')`へ合成contextmenuイベントを
`dispatchEvent`し、`event.defaultPrevented === true`になることと、
`.sidebar`外(エディタの`<textarea>`)では`false`のままになることを
ブラウザのJS実行で直接検証して確認済み。

**教訓**: `preventDefault`が間に合うかどうかが問題になったら、Funicularの
`onXxx:`経由はもちろん、「素のJS APIにRubyのブロックを直接渡す」形
(xterm.jsの`attachCustomKeyEventHandler`のような、コールバックの型自体は
JSネイティブでもRubyブロックである時点でPicoRuby.wasmを経由する)でも
確実とは限らない。**本当に確実にしたいなら、Rubyを一切経由しない
`<script>`タグの中で完結させること。** また、この種のタイミング不具合は
自動操作ツールのスクリーンショットだけでは気づけない(ネイティブUIの重なりが
写らない)ので、疑わしいときは実際に人間のフィードバックを当てにし、
`dispatchEvent`+`defaultPrevented`のような形でJS実行から直接検証する。

## gemとして配布する構成への変更(classic → modular Sinatra、`app/`廃止)

Sinatraアプリ本体を`gem install`で配布することを前提に、2つの変更をした。

### `lib/picoride/server.rb`: classic Sinatra → modular Sinatra

それまで`server.rb`は`require "sinatra"`(classicスタイル)でトップレベルに
`get`/`post`を書く形だった。classicスタイルは`require`しただけで
`sinatra/main.rb`の`at_exit`フックが仕込まれ、プロセス終了時に**自動で**
HTTPサーバーが起動してしまう。これは単発のスクリプトなら問題ないが、
gemとして配布するライブラリファイルがrequireされただけでサーバーを起動する
副作用を持つのは好ましくない(将来テストやirbから`require`したら勝手にサーバーが
立ってしまう)。

そこで`require "sinatra/base"` + `module Picoride; class Server <
Sinatra::Base; ... end; end`のmodularスタイルに書き換えた。ルート定義
(`get`/`post`/`delete`)・`helpers do...end`・トップレベルの`def`(いずれも元々
Rubyのレキシカルスコープに乗っているだけなので)は、クラス本体の中にそのまま
入れ子にするだけで動く(呼び出され方は変わらない)。`PROJECTS_ROOT`等の定数、
`BackgroundJob.new`・`R2P2State.ensure_checkout`のような他ファイルの定数参照も、
`module Picoride`の中に入ったことでレキシカルスコープ経由で
正しく解決されるようになった(`Picoride::BackgroundJob`等への
明示的な修飾は不要)。

**踏んだ罠**: classicスタイルの`-p`/`-o`/`-e`コマンドラインオプション
(`ruby app.rb -o 0.0.0.0`のような)は、実は`Sinatra::Base`自体の機能ではなく
`sinatra/main.rb`(`require "sinatra"`した時だけ読まれる)がARGVを
`OptionParser`で自前パースしているだけ、という実装になっている
(`gem which sinatra`で実際のgemソースを確認して判明)。`require "sinatra/base"`
に変えるとこの自動パースは丸ごと失われるので、[exe/picoride](exe/picoride)側で
同等の`-p`/`-o`/`-e`を`OptionParser`で自前実装し、
`Picoride::Server.run!(options)`を明示的に呼ぶようにした。

### `app/public/` `app/funicular/` `app/views/` → `lib/picoride/{public,funicular,views}/`

gemの`spec.files`は`git ls-files`から`bin/`等を除いたもの(`picoride.gemspec`
参照)で、実質的に`lib/`配下しか配布対象に入らない。`server.rb`の
`set :public_folder` / `set :views` / `FUNICULAR_ROOT`はいずれも`__dir__`
(= `server.rb`自身のディレクトリ)からの相対パスで組み立てているため、
これらの実体(CSS/JS、Funicularの Rubyコンポーネント、`index.erb`)が
`lib/picoride/`配下に無いと、gem installした環境では存在しない
パスを見てしまい何も配信できなくなる。そのため`git mv`で
`app/`配下から`lib/picoride/`配下へ丸ごと移動した
(`app/`は空になって消滅)。移動後も`index.erb`内のURLはサーバーのルート
(`/css/style.css`・`/ruby/components/*.rb`)への参照であり、物理的な
配置場所には依存しないので書き換え不要だった。

### 続き: `lib/picoride/{public,funicular,views}/` → `web/{public,funicular,views}/`

上の移動で gem には同梱されるようになったが、`lib/` は `$LOAD_PATH` に入る
サーバ側Rubyコードの置き場であり、CSS/JS・ERB・ブラウザ(PicoRuby.wasm)側で
動くFunicularのコードが混ざるのは役割として不自然だったため、gemルート直下の
`web/` に移した(Sidekiqの `web/assets` `web/views` と同じ発想)。

- `exe/` 配下は**不可**: gemspecの`spec.executables = spec.files.grep(%r{\Aexe/})`
  に引っかかり、`style.css`等が実行ファイルとしてbinstub化されてしまう
- `spec.files`は`git ls-files`から`bin/` `test/`等を除いたものなので、
  ルート直下の`web/`は設定変更なしでgemに同梱される
- `server.rb`は`WEB_ROOT = File.expand_path("../../web", __dir__)`を基点に
  `public_folder` / `views` / `FUNICULAR_ROOT`を組み立てる。配信URL
  (`/css/...` `/js/...` `/ruby/...`)は変わらない

### `exe/picoride`: gem実行ファイルとしての注意点

gemの`exe/`に置く実行ファイルは、依存関係やロードパスを**RubyGemsが
自動的に**設定してくれる(bin stub経由で起動されるため)。これを踏まえていない
実装が2つ残っていたので直した:

- `require "bundler/setup"`が書かれていたが、これは`bin/server`のような
  「リポジトリ内で開発用に動かすスクリプト」で使うもの。`gem install`後に
  リポジトリと無関係な場所で`picoride`コマンドだけ叩いた場合、カレント
  ディレクトリにGemfileが無くて`Bundler::GemfileNotFound`になる(最悪、
  別の無関係なGemfileを拾ってしまう)。gem実行ファイルには不要かつ有害。
- `require "picoruby-esp32-ide"`(当時のgem名をハイフンのまま)と書かれていたが、
  `bundle gem`が生成する本体ファイルは常にアンダースコア名
  (当時は`lib/picoruby_esp32_ide.rb`。現在は`picoride`へのリネームにより
  `lib/picoride.rb`)なので、これはそもそも存在しないファイルを`require`
  しようとしていた(`LoadError`)。

**検証方法**: この種の「gemとして配布されたときにちゃんと動くか」は
リポジトリ内で`bundle exec`して動かすだけでは検証できない(Bundlerが
Gemfile経由でロードパスを解決してしまうため、上記のバグがあっても気づけない)。
実際に`gem build`→別のGEM_HOMEに`gem install`→リポジトリの外のディレクトリから
`picoride`コマンドだけを叩く、という「本当にインストールされた状態」を
再現して初めて上記2つのバグが発覚した。gem化に関わる変更をしたときは、
このレベルまで検証するのが確実。

## プロジェクトの置き場所(ワークスペース)をUIから指定する方式に変更

以前は`PROJECTS_ROOT`(`lib/picoride/server.rb`)という固定パスの定数で、
既定値は`__dir__`からの相対パス(`../projects`)、環境変数で上書き可能という
設計だった。これが実際に「プロジェクトディレクトリがない」というエラーの
原因になっていた: gemとして配布する構成への変更(`app/`→`lib/picoride/`への
移動、上の節参照)で`server.rb`自身の`__dir__`が1階層深くなったのに、
相対パスの計算(`File.join(__dir__, "..", "projects")`)はそのままだったため、
実際には存在しない`lib/projects`を指すようになっていた。環境変数で上書きする
運用に頼っている限り、ディレクトリ構成が変わるたびに同種の問題が再発しうる。

そこで、固定パス・環境変数での既定値を完全に無くし、**起動直後は「ワークスペース
未設定」から始まり、ブラウザの「ファイル」>「ワークスペースを開く」から
絶対パスを指定して開く**方式に変更した(「プロジェクトディレクトリではなく
ワークスペースとしてUIから指定したい」という要望)。用語としては、
従来`PROJECTS_ROOT`が指していたディレクトリ(複数のプロジェクトを
サブディレクトリとして持つ場所)がそのまま「ワークスペース」になった。
1プロジェクト = `<workspace>/<name>/`という単位(app/・mrbgems/・
build_config.rb)自体は変更していない。「新しいプロジェクト」「プロジェクトを
開く」は今まで通りワークスペース配下のプロジェクトを対象に動く。

- `Server.workspace_root`(クラスインスタンス変数のアクセサ)がワークスペースの
  絶対パスを保持する。サーバプロセスが生きている間だけ保持され、永続化はしない
  (再起動したら未設定に戻る。複数ワークスペースの履歴・最近開いた一覧も持たない
  —「常に1つだけ、履歴なし」という要望によるシンプルな設計)
- `GET /api/workspace` — 現在のワークスペース(`{path: "..."}`。未設定は`null`)
- `POST /api/workspace` — `{path: "/abs/path"}`で開く。`File.expand_path`で
  正規化する(`~`展開・相対パスの解決も行うが、相対パスはサーバプロセスの
  カレントディレクトリ基準になるため分かりにくい。基本は絶対パスを渡す前提)。
  既存ディレクトリであることだけをチェックし、作成はしない
- `/api/workspace`自身を除く全ての`/api/*`は、ワークスペース未設定だと
  `project_root`が成立せず処理できないため、`before do ... end`
  (パターン無し)で`request.path_info`を見て一括チェックしている。
  **踏んだ罠**: 最初`before %r{\A/api/(?!workspace\z)} do ... end`のように
  パターン付きbeforeにしたところ、実際に起動したら
  `Mustermann::CompileError: regular expression should not contain \A`に
  なった。Sinatraのルート/フィルタにパターンを渡すと内部のMustermannが
  コンパイルする際に独自に文字列全体へのアンカーを付与する実装になっていて、
  渡した正規表現が(`\A`/`\z`はおろか`^`/`$`でも)既にアンカーを含むと
  コンパイルエラーになる(両方試して両方失敗することを実際の起動で確認した)。
  この種のエラーは`ruby -c`の静的チェックでは検出できず、実際に
  `bundle exec exe/picoride`を起動して初めて分かった。対処はパターン無しの
  `before do ... end`にして、Mustermannを経由しない素のRubyの文字列比較
  (`request.path_info.start_with?(...)`)でパスを判定する形に変更した
- フロント側(`editor_app.rb`)は`component_mounted`で`load_project_list`を
  直接呼ばず、まず`load_workspace`(`GET /api/workspace`)を呼ぶ。ワークスペースが
  既に開かれていれば従来通り`load_project_list`、未設定なら
  「ワークスペースを開く」ダイアログ(`PromptDialog`の`kind: :open_workspace`、
  他の用途と同じく使い回し)を自動で表示してユーザーに指定してもらう
  (VSCodeの「フォルダを開く」相当)。サイドバーにも
  `state[:workspace].nil?`のときだけ出す専用メッセージを用意した
- ワークスペースを切り替えたとき(`open_workspace`)は、`select_project`と
  同じ理由で、プロジェクト/ファイル関連のstate(現在選択中のプロジェクト・
  ファイル一覧・編集中の内容など)を全部クリアしてから新しいワークスペースの
  プロジェクト一覧を取り直す
- `MenuBar`に現在のワークスペースの絶対パス表示を追加した。「新しいプロジェクト」
  「プロジェクトを開く」メニュー項目は、ワークスペース未設定の間は押せない
  (mrbgem追加・新規ファイル作成がプロジェクト未選択の間押せないのと同じ
  disabledの書き方)

### 続き: 起動時の自動ダイアログを廃止し、常設ドロップダウンをワークスペース切り替えに転用

上記の初回実装では、(1)起動時にワークスペース未設定なら「ワークスペースを開く」
ダイアログを自動表示し、(2)ワークスペースのパスはメニューバーの専用ラベル
(`.menu-bar-workspace`)で表示するだけ、(3)メニューバー常設の`<select>`は
従来通りプロジェクト切り替え専用、という作りだった。これをフィードバックで
変更した:

- **自動ダイアログは廃止**。「それはやめてほしい」という要望により、
  `component_mounted`→`load_workspace`は`GET /api/workspace`の結果を
  state(`workspace`・`known_workspaces`)に反映するだけになり、未設定でも
  何も自動表示しない。ユーザーがメニューバーのボタン、または「ファイル」>
  「ワークスペースを開く…」を明示的に押すまでワークスペースは開かれない
- **ワークスペースは複数開けて、メニューバー常設の`<select>`で切り替える**
  ように変更(以前の「履歴なし、常に1つだけ」という設計判断を上書きする
  フィードバック)。これに伴い、**この`<select>`はプロジェクト選択ではなく
  ワークスペース選択に転用した**。プロジェクトの切り替えは「ファイル」>
  「プロジェクトを開く…」(`OpenProjectDialog`、変更なし)に一本化している
  - `Server.known_workspaces`(`workspace_root`と同じくクラスインスタンス変数の
    アクセサ、配列)が、このセッションで一度でも開いたワークスペースの絶対パスを
    開いた順に保持する。`POST /api/workspace`は毎回この配列に(無ければ)追加し、
    `GET /api/workspace`は`{path:, known: [...]}`の形で両方返す。`workspace_root`
    同様、サーバプロセスが生きている間だけ保持しディスクには永続化しない
  - フロント側の`<select>`(`menu_bar.rb`の`render_workspace_select`)は、
    `known_workspaces`が空の間は`<select>`の代わりに「ワークスペースを開く…」
    という`<button>`を描画する(同じ`props[:on_open_workspace]`コールバックを
    使い回すだけ)。1つ以上あれば、`known_workspaces`を選択肢に持つ`<select>`になり、
    選ぶと即座に`open_workspace(path)`経由で切り替わる(確認ダイアログは無い。
    値は常に絶対パスなので取り違えようがないため)
  - ワークスペース名は既定で「ディレクトリ名(パスの最後のセグメント)」
    (「ワークスペース名はデフォルトではディレクトリ名でよい」という要望通り)。
    picoruby.wasm上では`File.basename`等`File`系メソッドの対応が不確かなため
    (`editor_app.rb`の`extension`ヘルパーと同じ理由)、`path.split('/').last`の
    ような素の文字列分割で求めている(`menu_bar.rb`の`workspace_label`)
  - `open_workspace(path)`は「ダイアログから新規に開く」「ドロップダウンで
    既知のワークスペースへ切り替える」の両方を1つのメソッドで処理する
    (どちらも`POST /api/workspace`を叩くだけで、サーバ側のロジックは
    「既に知っているパスなら追加しない」で自然に両対応になる)。違いは
    失敗時のエラー表示先だけで、`state[:prompt_dialog]`が開いていれば
    ダイアログ内に、そうでなければ(＝ドロップダウン経由)トップレベルの
    ステータス表示にエラーを出す
  - 既に選択中のワークスペースをドロップダウンで選び直したとき(ブラウザの
    `<select>`はユーザーが同じ値を選んでも`change`イベントを発火させない
    ことが多いが、万一発火しても)`open_workspace`の先頭で
    `return if path == state[:workspace]`としてプロジェクト一覧の不要な
    再取得・編集状態のクリアを避けている

### 続き2: 「ワークスペースを開く」を絶対パスのテキスト入力からディレクトリブラウザに変更

絶対パスを手で一行入力させる方式は、実際に使うと「正確なパスを覚えていないと
開けない」という使いにくさがあった。「よくあるファイルビューアのような見た目で
ディレクトリを探しやすく、最初はホームディレクトリが開いている状態に、
ディレクトリを作成できる機能も」という要望を受けて、専用のディレクトリブラウザ
ダイアログ(`DirectoryBrowserDialog`)に置き換えた。これに伴い、`PromptDialog`の
`kind: :open_workspace`は廃止した(他の`:new_project`等はそのまま)。

- サーバ側に汎用のディレクトリブラウザAPIを追加した。`workspace`や`projects`とは
  別物で、ファイルシステム上の**任意の場所**のサブディレクトリだけを列挙する
  (どのワークスペースにも属さない、という位置づけ)
  - `GET /api/browse?path=...` — 指定ディレクトリのサブディレクトリ一覧
    (`{path:, parent:, entries: [{name:, path:}, ...]}`)。`path`省略時は
    `Dir.home`(「最初はホームディレクトリが開いている状態で」という要望に
    対応)。ドット始まりのディレクトリは`GET /api/files`等と同じ理由で除外する
  - `POST /api/browse` — `{path:, name:}`で新しいフォルダを作成する。
    「新しいフォルダ」を押す動機は大抵そこを開きたいからという想定で、
    作成後は親ではなく**作成したフォルダ自身**をGETと同じ形で返す
    (フロント側はそのままそこへ移動したものとして扱うだけでよい)
  - どちらも`workspace_root`が無くても使える必要がある(これを使って
    ワークスペースを選ぶため)ので、`WORKSPACE_EXEMPT_API_PATHS`に
    `/api/browse`を追加して`before`フィルタの対象外にした
- フロント側(`directory_browser_dialog.rb`)は、他の子コンポーネント
  (`TreeView`・`OpenProjectDialog`等)と同じく`initialize_state`を持たない
  表示専用コンポーネントにしてある。現在地・一覧・読み込み中/エラー状態は
  全部`EditorApp`の`state[:workspace_browser]`(Hashまたはnil)に持たせ、
  propsとして渡すだけ(理由はCLAUDE.md内の「子コンポーネントは親が
  再描画されるたびに作り直される」の節と同じ)。新規フォルダ名の入力欄だけは
  `PromptDialog`と同じ理由でrefベースの非制御コンポーネントにしてある
- パンくず("/" "home" "youchan" "Projects"のようなクリック可能なセグメント)は
  `path.split('/')`から累積パスを組み立てて作る。他の箇所
  (`menu_bar.rb`の`workspace_label`、`editor_app.rb`の`extension`)と同じ理由で
  `File.basename`等`File`系メソッドは使わず素の文字列分割にしてある
- **踏んだ罠**: `GET /api/browse`が返す`entries`(`[{name:, path:}, ...]`の配列)を
  `DirectoryBrowserDialog`側で`entry[:name]` / `entry[:path]`とシンボルキーで
  読んだところ、実際にブラウザで開くとフォルダ一覧はアイコンだけ並んで
  名前が全部空欄になり、クリックしても反応しない(`navigate_to(nil)`になり
  早期returnするため)という不具合になった。原因はJSONをパースした結果が
  文字列キーのHashであること(トップレベルの`path`/`parent`等は元から
  `value_of`経由で読んでいたので気づかなかったが、配列の中身である`entries`の
  各要素までは`value_of`を通していなかった)。`menu_bar.rb`等にある
  `value_of(data, key) { data[key] || data[key.to_sym] }`と同じヘルパーを
  `DirectoryBrowserDialog`にも定義し、`entry[:name]`ではなく
  `value_of(entry, 'name')`のように読むことで解決した。この種のバグは
  `ruby -c`は素通りし、実際にブラウザで開いて初めて発覚する
  (今回も実機代わりにブラウザ自動操作ツールで開いて発見した)。**JSON
  レスポンスの中身をRubyのHashとして読むときは、トップレベルだけでなく
  ネストした配列/Hashの要素も含めて、必ず`value_of`経由で読むこと。**

### 続き3: ワークスペースを`~/.picoride/workspace.toml`に永続化

ここまでの`workspace_root`/`known_workspaces`はサーバプロセスが生きている間
だけのメモリ上の状態で、再起動すると消えていた。「一度開いたら覚えておいて
ほしい、再起動しても開かれた状態で起動してほしい」という要望を受けて、
`~/.picoride/workspace.toml`への永続化(`lib/picoride/workspace_store.rb`、
`Picoride::WorkspaceStore`モジュール)を追加した。保存先をプロジェクト本体の
外(ホームディレクトリ配下)にしたのは`r2p2_state.rb`のR2P2-ESP32状態
ディレクトリと同じ理由(プロジェクトのgitリポジトリに混ざるべきではない)。

ファイル形式(TOML):

```toml
active = "最後にアクティブだったワークスペースの絶対パス"

[ワークスペース名]
path = "絶対パス"
```

- 読み書きには[PerfectTOML](https://github.com/mame/perfect_toml)
  (`gem "perfect_toml"`、`picoride.gemspec`に追加)を使っている。単一ファイル・
  無依存でTOML v1.0.0に完全準拠するパーサ/ジェネレータ。**最初は自前で
  ミニマムなTOMLリーダー/ライターを手書きしていた**(書く分だけ読めれば
  十分という割り切りで、シングルクォート文字列のエスケープまで実際に
  `ruby -e`でラウンドトリップ検証して動くところまで作っていた)が、
  ユーザーから「mame/perfect_tomlを使ってほしい」とフィードバックがあり
  差し替えた。既存の外部ライブラリで十分に要件を満たせる(軽量・無依存で、
  このプロジェクトの「Railsもnpmも持ち込まない」方針と衝突しない)なら、
  自前実装よりそちらを優先するべきだったという教訓
- `WorkspaceStore.load`は`{active:, paths:}`を返す。保存されていても
  **実際に存在しなくなったディレクトリは除外**し、`active`がその除外対象
  だった場合は`nil`にフォールバックする(ディレクトリが削除/移動された後に
  再起動しても、存在しないワークスペースを開こうとして`workspace_root`が
  壊れた状態で起動しないようにするため)
- `WorkspaceStore.save`は毎回まるごと書き直す(差分更新はしない。開閉は
  頻繁な操作ではないので素朴な実装で十分と判断)。ワークスペース名
  (TOMLのテーブル名)は`display_name`(ディレクトリ名。`menu_bar.rb`の
  `workspace_label`と同じロジックをサーバ側にも持たせてある)から決め、
  違う場所にある同名ディレクトリ(例: 複数の`projects`)が衝突しないよう
  `unique_name`で連番サフィックスを振る。クォートや空白を含む名前の扱いは
  PerfectTOML.generateに任せている(自前実装が担っていた部分がまるごと
  不要になった)
- `server.rb`はクラス定義時(`class Server < Sinatra::Base ... end`の
  本体が評価されるとき、Rubyプロセスの起動時に1回)に`WorkspaceStore.load`を
  呼んで`workspace_root`/`known_workspaces`の初期値にする。`POST /api/workspace`
  (ワークスペースを開く/切り替える)のたびに`WorkspaceStore.save`で書き戻す。
  フロント側(`editor_app.rb`)は元々`component_mounted`で`GET /api/workspace`を
  呼んでいて、その結果に応じて動く設計だったので、**フロント側の変更は
  一切不要だった**(サーバが起動時点で既に`workspace_root`を持っていれば、
  フロントから見れば「たまたま誰かが先に開いていた」のと区別が付かない)
- 実際に`bundle exec exe/picoride`を起動→ワークスペースを開く→
  `~/.picoride/workspace.toml`の中身を確認→プロセスを再起動→
  `GET /api/workspace`が最初から開かれた状態を返す→ブラウザで実際にダイアログ
  無しでプロジェクトファイルが表示される、まで一通り確認した

### 続き4: ターゲット・VM・USB Console設定をプロジェクト単位からワークスペース単位に変更

「設定はワークスペース毎に持たせてほしい。workspace.tomlに保存するように
してほしい」という要望を受けて、ターゲットチップ・VM・USB Console
(「設定」ダイアログ、旧`ProjectSettingsDialog`)のスコープをプロジェクトから
ワークスペースへ変更した。以前はプロジェクトごとの隠しファイル`.config.yml`に
保存していたため、1ワークスペース内の複数プロジェクトがそれぞれ別のターゲットを
持てたが、変更後は1ワークスペース=1つの設定を全プロジェクトが共有する形になる。
既存の`.config.yml`を読む処理は削除した(ファイル自体の削除はしない。移行処理は
行わないクリーンな置き換え)。

- `WorkspaceStore`(workspace_root/known_workspacesと同じ`~/.picoride/workspace.toml`)の
  各ワークスペースのテーブルに`platform`/`vm`/`usb_console`を追加した:
  ```toml
  [workspace_name]
  path = "絶対パス"
  platform = "esp32"    # 未設定なら書かない
  vm = "femtoruby"       # 未設定なら書かない
  usb_console = false
  ```
  TOMLにはnull/nilが無いため(`PerfectTOML.generate`に`nil`値を渡すと
  `NoMethodError: undefined method 'to_inline_toml' for nil`で落ちることを
  実際に確認した)、`platform`/`vm`が未設定の間はキー自体を書かない設計にした
  (`usb_console`は常にboolなのでnil問題は起きず、常に書く)
- `WorkspaceStore.save`は`settings:`をデフォルト値無しのキーワード必須引数に
  してある。デフォルト値(例: `{}`)を許すと、「ワークスペースを開いた/
  切り替えただけ」の呼び出し箇所(`POST /api/workspace`)で、既存の設定を
  空のHashで上書きして消してしまうミスを構造的に防げないため
  (実際にこの形で実装しかけて気付いた。`POST /api/workspace`側で
  `settings: workspace_settings`を渡し忘れると、ワークスペースを開くたびに
  他の全ワークスペースの設定が消える、という静かなデータ破壊になるところだった)
- `server.rb`に`Server.workspace_settings`(クラスインスタンス変数、
  `{絶対パス => {"platform"=>, "vm"=>, "usb_console"=>}}`)を追加。
  `workspace_root`/`known_workspaces`と同じく起動時に`WorkspaceStore.load`で
  復元する。`read_workspace_config`ヘルパーが現在のワークスペース
  (`workspace_root`)の設定を返す(未設定なら`{"platform"=>nil,"vm"=>nil,
  "usb_console"=>false}`)
- エンドポイントを`GET/POST /api/projects/:name/config`(プロジェクト名が必須)
  から`GET/POST /api/workspace/config`(現在のワークスペースが暗黙の対象、
  プロジェクト名不要)に置き換えた。`POST /api/build`・`POST /api/platform`も
  `read_project_config(root)`ではなく`read_workspace_config`を見るように変更
  (`root`=プロジェクトの絶対パスは`project_root`で検証済みなので、常に
  `workspace_root`配下にある=属するワークスペースの設定を見るのと整合する)
- フロント側は`ProjectSettingsDialog`を`WorkspaceSettingsDialog`に改名
  (ファイル名・クラス名とも)。ダイアログのタイトルも
  `プロジェクト設定(プロジェクト名)`から`ワークスペース設定(ワークスペースの
  絶対パス)`に変更した。`EditorApp`側は`state[:project_config]`を
  `state[:workspace_config]`に改名し、`select_project`からは設定のリセット/
  再取得を削除(プロジェクトを切り替えても設定は変わらないため)。代わりに
  `load_workspace`(起動時)と`open_workspace`(ワークスペース切り替え時)の
  両方で`load_workspace_config`(`GET /api/workspace/config`)を呼ぶ
- 実際に`bundle exec exe/picoride`を起動→ワークスペースを開く→設定を保存→
  `workspace.toml`の中身を確認→プロセスを再起動→ブラウザで設定が復元されて
  いることを確認→別のプロジェクトに切り替えても設定(セットアップボタンの
  ターゲット表示)が変わらないことを確認、まで一通り検証した

### 続き5: 「ワークスペース」=「プロジェクト」だったので2階層構成を1階層に統合

続き1〜4までの一連の変更は、「プロジェクトを束ねる"ワークスペース"ディレクトリを
UIから開き、その配下の複数プロジェクトから1つを選ぶ」という2階層構成を前提に
進めていた。しかしこれは実際にはユーザーの頭の中にあったモデルと食い違っていて、
「ワークスペース=プロジェクトだった(2階層ではなく1階層でよかった)」という
フィードバックを受け、2階層構成を1階層に統合する大きめのリファクタリングを行った。

**変更の性質**: このフィードバックに従うと「ワークスペース」と(従来の)
「プロジェクト」が同じものを指すことになり、名前が衝突する。衝突の解消方法が
2通り考えられた(1階層に統合する/単に呼び方だけ"プロジェクト"に揃えて2階層構造は
維持する)ため、作業前にユーザーに確認し、「1ディレクトリ=1プロジェクトに統合」を
選んでもらった。大きな構造変更は実装前にユーザーに選択肢を示して確認するのが安全、
という教訓(このセッションで既に複数回、作ってから「勘違いだった」という
やり取りが発生していたこともあり)。

**やったこと**(ほぼ全ファイルに影響する全面的なリネーム+簡略化):

- サーバ側の中心的な状態を`workspace_root`/`known_workspaces`/`workspace_settings`
  から`Server.project_root`(単一のアクティブなプロジェクトの絶対パス)/
  `known_projects`/`project_settings`に改名。`project_root(name)`という
  「ワークスペース配下のサブディレクトリ名を解決する」メソッドは消え、
  `project_root`は常に単一の値を返すアクセサになった
- `GET /api/projects`(サブプロジェクト一覧)・`POST /api/projects`
  (ワークスペース配下に名前でサブディレクトリを作る「新しいプロジェクト」)を
  丸ごと削除した。これに伴い、プロジェクト名を受け取っていた全エンドポイント
  (`GET /api/files`・`GET /api/dirs`・`GET/POST /api/file`・
  `POST/DELETE /api/projects/:name/files`・`POST/DELETE /api/projects/:name/folders`・
  `POST /api/projects/:name/mrbgems`・`POST /api/build`・`POST /api/platform`・
  `GET /api/firmware/*`)から`project`パラメータ/`:name`セグメントを削除し、
  常に`project_root`(現在開いている唯一のプロジェクト)を対象にするよう
  簡略化した(`POST /api/files`・`POST /api/folders`・`POST /api/mrbgems`の
  ようにパスからプロジェクト名セグメントが消えた)
- 「新しいプロジェクト」(名前を入力してワークスペース配下にサブディレクトリを
  作る機能)は、`ensure_project_scaffold`に置き換えた:
  `POST /api/project`(プロジェクトを開く)のたびに、`app/app.rb`・
  `build_config.rb`が無ければ空で作成する(既存ファイルは上書きしない)。
  「新しいプロジェクトを作る」という操作は、実質的に
  DirectoryBrowserDialogで「新しいフォルダ」を作ってそのまま「このディレクトリを
  開く」ことと同じになった(開いた瞬間に雛形が用意される)ので、専用のダイアログ・
  エンドポイントが丸ごと不要になった
- `~/.picoride/workspace.toml`(`WorkspaceStore`)を`~/.picoride/project.toml`
  (`Picoride::ProjectStore`、`lib/picoride/project_store.rb`)に改名した
  (旧workspace.tomlからの自動移行は行わない。クリーンな置き換え)
- フロント側: `WorkspaceSettingsDialog`を`ProjectSettingsDialog`に戻し(名前が
  一周して元に戻った形)、`OpenProjectDialog`(サブプロジェクト一覧から選ぶ
  ダイアログ)は丸ごと削除した。`MenuBar`の常設ドロップダウンは
  「ワークスペース選択」から「プロジェクト選択」に意味が戻り、
  `current_project`という概念(ワークスペース配下で選択中のサブプロジェクト名)は
  消えて、`project`(開いているプロジェクトの絶対パス)1つに統合された。
  `EditorApp`の`select_project`(サブプロジェクト切り替え)・`load_project_list`
  (サブプロジェクト一覧取得)は削除し、`load_workspace`/`open_workspace`は
  それぞれ`load_project`/`open_project`に改名して、ファイル一覧・設定の取得も
  このタイミングで直接行うようにした(以前は「ワークスペースを開く→サブ
  プロジェクト一覧取得→最初の1件を自動選択→ファイル一覧取得」という2段階
  だったのが、「プロジェクトを開く→ファイル一覧取得」の1段階になった)
- `DirectoryBrowserDialog`・`project_label`(旧`workspace_label`)等、
  「ワークスペースを開く」という文言だった箇所は全部「プロジェクトを開く」に
  変更。コンポーネント自体は元々汎用設計だったため、ロジックの変更は不要で
  文言とprops名(`workspace_path`→`project_path`等)の変更だけで済んだ
- 実際に`bundle exec exe/picoride`で検証: `POST /api/project`で初めて開いた
  空ディレクトリに`app/app.rb`・`build_config.rb`が自動生成されること、
  既存プロジェクト(`projects/hello_world_project`)をディレクトリブラウザで
  辿って開けること、ファイル一覧・ファイル保存・新規ファイル・mrbgem追加・
  設定の読み書きが全部`project`パラメータ無しで動くこと、プロセス再起動後に
  `project.toml`から同じプロジェクトが開かれた状態で起動すること、をブラウザと
  curl両方で一通り確認した

### 続き6: ensure_project_scaffoldは「空のディレクトリのときだけ」に限定

`ensure_project_scaffold`(続き5参照)は当初「`app/app.rb`・`build_config.rb`が
無ければ(そのディレクトリに他に何があっても)作る」という実装だった。これが
実際に事故を起こした: ユーザーが本来開くべきプロジェクトディレクトリ
(`.../esp32-project/`)の**1階層上**(実際には`esp32-project/`をサブディレクトリ
として含む、別の`esp32-project`という名前のディレクトリだった)を誤って開いて
しまい、そこに無関係な空の`app/`・`build_config.rb`が生成された。結果、
ファイルツリーに「本来のプロジェクト(サブディレクトリとして)」と「誤って
生成された空のapp/」が並んで表示され、「ファイルツリーがおかしい」という
バグ報告になった。実機のディレクトリ構造を`ls`で確認して原因を特定した
(`project.toml`の`active`から実際に開かれているパスが分かるので、そこから
辿った)。

コード自体にバグがあったわけではなく(ツリー構築ロジックは元々正しい)、
「間違ったディレクトリを開いてしまった」というヒューマンエラーだったが、
自動生成が無条件に効いてしまうことがこの種の事故を助長していた。
「自動生成は空のディレクトリのときだけにしよう」というフィードバックを受け、
`Dir.empty?(root)`で判定し、**ディレクトリに何かしら既存の中身がある場合は
何もしない**(=「間違ったディレクトリを開いた可能性がある」とみなして
無関係なファイルを生成しない)方式に変更した。新規にdirectory browserで
「新しいフォルダ」を作ってすぐ開く(=確実に空)という本来の用途は影響を受けない。

## Raspberry Pi Pico 対応(ビルド用Dockerイメージをターゲットで切り替え)

「ESP32用だけでなくRaspberry Pi Pico用のビルド環境も使えるようにしたい。
Dockerfileを分けてイメージを別にし、picorideサーバーからビルドするときに切り替える。
設定でPicoを選べるようにしたい」という要望で追加した。

### 構成

- `Dockerfile` は `docker/esp32/Dockerfile`(中身は従来のESP-IDF用そのまま)と
  `docker/pico/Dockerfile`(新規)に分けた。イメージ名は
  `picoride-builder-esp32` / `picoride-builder-pico`
  (`PICORIDE_ESP32_BUILDER_IMAGE` / `PICORIDE_PICO_BUILDER_IMAGE`で上書き可。
  ESP32側は旧`PICORUBY_BUILDER_IMAGE`も引き続き効く)。**旧イメージ名
  `picoride-builder`は既定では使われなくなった**ので、ESP32側も作り直しが要る
- 「ターゲット」設定(`platform`)に `pico` / `pico_w` / `pico2` / `pico2_w` を追加。
  `server.rb`の`PLATFORM_FAMILIES`でターゲット→ファミリー(`esp32`/`pico`)を
  引き、`BUILDER_IMAGES`・状態ディレクトリ(`build_state_dir`)・コンテナ内の
  マウント先(`CONTAINER_STATE_MOUNTS`)・ビルド手順を切り替える。
  **ターゲット未設定は従来通りESP32扱い**(`DEFAULT_PLATFORM_FAMILY`)
- `r2p2_docker_command` は `builder_docker_command(family, ...)` に一般化した。
  `export.sh` のsourceはESP32のときだけ

### R2P2(Pico版)は picoruby 本体に統合されている

`picoruby/R2P2` リポジトリはアーカイブ扱いで、現在は picoruby 本体の
`mrbgems/picoruby-r2p2` gem + `tasks/picoruby/r2p2.rake` になっている。
ビルドは picoruby のルートで `rake r2p2:{vm}:{board}:{debug|prod}`
(vm は `femtoruby`(mruby/c)/ `picoruby`(mruby)。RP2040 の pico/pico_w は
femtoruby のみ — `build_config/r2p2-{vm}-{board}.rb` があるものだけタスクが定義される)。
IDEは`prod`だけ使う。成果物は `build/r2p2/{vm}/{board}/prod/R2P2-*.uf2`。

- 状態ディレクトリは `<project>/.r2p2-pico`(picoruby の `--depth 1` clone)。
  `R2P2State.ensure_pico_checkout` がサブモジュールを取得するが、
  `mrbgems/picoruby-r2p2/lib/pico-sdk` と `lib/rp2040js`(エミュレータ)は取らない
- pico-sdk と picotool はイメージ側(`/opt/pico-sdk`、`/usr/local`)に焼き込み。
  pico-sdk 2.x は**SDKと同じバージョンのpicotoolがインストールされていないと、
  cmake構成時にGitHubからpicotoolをcloneしてビルドしようとする**ので、
  イメージで同じタグ(`PICO_SDK_VERSION`)をビルド・installしておく。
  picorubyの`r2p2:check_pico_sdk`は`git describe --tags --exact-match`で
  `PICO_SDK_TAG`(`mrbgems/picoruby-r2p2/r2p2_config.rb`)と一致することを要求する
  (`git clone --depth 1 --branch <tag>`でもタグは取れて一致判定は通る)。
  picoruby側がSDKを上げたら`--build-arg PICO_SDK_VERSION=...`でイメージを作り直す
- 完了マーカー `.picoride-ready` で「clone+サブモジュール+パッチまで済んだか」を
  判定する(ESP32側の「`.git`があれば済」だと、サブモジュール取得で失敗したときに
  二度と再試行されないため)
- mrbgem組み込みのフック(`PROJECT_BUILD_CONFIG`)はESP32と同じものを
  `build_config/r2p2-*.rb` に差し込む(どれも `MRuby::CrossBuild.new(...) do |conf| ... end`)。
  r2p2.rake は内部で `sh "MRUBY_CONFIG=... rake"` を呼ぶが、環境変数はそのまま
  子プロセスへ伝わるので追加の細工は不要
- Bundlerは使わない(r2p2.rakeは素の`rake`を呼ぶだけ)。イメージには apt の
  `ruby` / `rake` だけ入れている

### ESP32との違い(UI)

- Picoには app/ をファームウェアに焼き込む仕組みが無い(R2P2はフラッシュを
  USBマスストレージとして見せる方式で、ストレージのイメージをビルド時に作らない)。
  app/ はターミナルタブの「app/ をアップロード」(PicoModem。Pico版R2P2の
  シェルにも標準で入っている)で送る
- 書き込みはESP Web Toolsではなく `.uf2` のダウンロード(`GET /api/firmware/uf2`、
  メニューバーの「UF2をダウンロード」、`<a download>`をボタン風にしたもの)。
  BOOTSELを押しながら接続して出てくるドライブへユーザーがコピーする
- 「セットアップ」は Pico では `rake r2p2:{vm}:{board}:clean`
  (ボード×VMごとにビルドディレクトリが分かれているのでターゲット切り替えの準備は不要)
- 設定ダイアログ: ターゲットを `<optgroup>` でESP32/Raspberry Pi Picoに分けた。
  Picoを選ぶとUSB Consoleの代わりに書き込み方法の説明を出す。VMはボードで
  選べないもの(pico/pico_wのPicoRuby)を出さず、ターゲット変更で選べなくなったら
  デフォルトに戻す(`ProjectSettingsDialog.vm_allowed?`)。サーバー側も
  `PICO_BOARD_VMS`で同じ検証をする(フロントとサーバで同じ表を二重に持っている)

### 実際にビルドして踏んだ罠(Pico)

`docker build` → picorideサーバー経由の`POST /api/build`で実際にビルドを通して
見つけたもの(どちらも静的チェックでは分からない):

1. **`/picoruby/bin/mrbc: not found`**: r2p2のcmakeは`main_task.rb`のコンパイルに
   `<picoruby>/bin/mrbc`を使うが、cloneしたばかりのpicorubyには無く、
   `rake r2p2:...`自体も作らない(r2p2用のbuild_configが作るのは
   `build/mrbc/default/bin/mrbc`で、`bin/`には置かれない)。mrbcはVM非依存の
   スタンドアロンコンパイラなので、`pico_build_inner_command`で
   `[ -x bin/mrbc ] || MRUBY_CONFIG=build_config/mrbc.rb rake` を先に1回実行する
2. **`zip: No such file or directory`**: r2p2のcmakeはリンク後に`.uf2`を
   `zip`/`gzip`する。`.uf2`自体はできているのにビルド失敗扱いになるので、
   イメージに`zip`を入れた

3. **`lwip/opt.h: No such file or directory`(pico_w / pico2_w のみ)**:
   Wi-Fi付きボードのbuild_configが使う`picoruby-socket`/`picoruby-mbedtls`は、
   lwIP/mbedTLSを`mrbgems/picoruby-r2p2/lib/pico-sdk/lib/...`への**git管理された
   シンボリックリンク**経由で参照する。そのサブモジュールはcloneしていないので、
   ビルド・セットアップの前に`PICO_PREPARE_COMMAND`でそのパスをコンテナ内の
   `$PICO_SDK_PATH`(/opt/pico-sdk)へのリンクに差し替える。`rake ...:clean`も
   build_configを読み、`picoruby-socket`のmrbgem.rakeはリンク切れだと例外を
   投げるので、セットアップ側にも同じ前処理が必要

検証済みの組み合わせ: `pico`(FemtoRuby)と`pico2_w`(PicoRuby)。コンテナは
インターネット接続なしで実行してもビルドが通る(picotool・pico-sdkともイメージ内で
完結している)。UF2のマジックナンバー・プロジェクトの`mrbgems/`以下のgemが
リンクされていることも確認した。

## ビルド用イメージをDocker Hubで配布する

「イメージをDocker Hubにpushしておいて、gemを使う人でも`docker pull`すれば
使えるようにしたい」という要望で追加した。

- イメージ名は`lib/picoride/builder_images.rb`(`Picoride::BuilderImages`)に
  一本化した。`<namespace>/picoride-builder-{esp32,pico}:<Picoride::VERSION>`
  (namespace既定`youchan`、`PICORIDE_DOCKER_NAMESPACE`で変更可)。サーバー・
  Rakefile・GitHub Actionsがすべてここを参照するので、名前がずれない
- **タグはgemのバージョン**にした(latestを追わない)。サーバー側のビルド手順は
  イメージの中身(pico-sdkのバージョン、`zip`の有無、`/opt/pico-sdk`の場所など)に
  依存しているので、古いgemが新しいイメージを掴んで壊れるのを防ぐため。
  pushするときは`:latest`も付ける
- サーバーは、イメージが手元に無ければ`docker run`の前に`docker pull`する
  (`builder_image_pull_command`)。以前は「無ければ500エラーでdocker buildを案内」
  だった。pullは数GBあり、HTTPリクエストの中で同期的にやるとタイムアウトするので、
  BackgroundJobのコマンドの先頭に付けてビルドログにそのまま進捗を出す形にした。
  pullに失敗したら、gem内のDockerfileの絶対パス(`BUILDER_DOCKERFILE_DIRS`)を使った
  `docker build`コマンドをログに出して終了する
- 公開手順: `v*`タグのpushで`.github/workflows/docker.yml`が両イメージを
  linux/amd64・linux/arm64でビルドしてpushする(タグと`Picoride::VERSION`が
  一致しないと失敗させる)。シークレット`DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN`が必要。
  手元からは`rake docker:push`(buildx、マルチアーキ)/`rake docker:build`
  (ローカルのみ)/`rake docker:images`(名前の確認)
- arm64にしたのはApple Silicon Macで使う人のため。`espressif/idf`のv5.x系タグは
  Docker Hub上でamd64/arm64の両方が提供されている(タグページで確認)。
  `ubuntu:24.04`も同様。**ただしarm64でのビルドはこのセッションの環境では
  検証できていない**(Docker HubとQEMUのイメージが取得できなかったため)。
  初回のpush時にActionsのログで両アーキテクチャが通ることを確認すること

検証したこと: イメージが無いときにpullが走り、失敗時に案内が出て終了すること
(この環境ではDocker Hubに繋がらないため失敗側だけ確認)/イメージがあるときは
pullを挟まずにPicoのビルドが最後まで通ること/Rakeタスクが組み立てる
`docker build`・`docker buildx build`のコマンド(`sh`を差し替えて確認)。
