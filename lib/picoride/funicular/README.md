# app/funicular

PicoRuby.wasm + [Funicular](https://github.com/picoruby/funicular)(hasumikin作)で書いた
エディタのフロントエンド。**JavaScriptを書かずに、ブラウザ側のロジックを全部Rubyで書く**構成。

バックエンド(Sinatra)と編集対象ファイル、CSSは `../` (= `app/`)のものをそのまま使う。
このディレクトリにはフロントエンドのRubyコードとHTMLだけを置く。

## 構成

```
app/funicular/
├── index.html                     # PicoRuby.wasm と Prism.js の読み込み + マウント先
└── ruby/
    ├── main.rb                    # Funicular.start(EditorApp, container: 'app')
    └── components/
        ├── tree_view.rb           # 汎用ツリー表示(表示専用。ファイル一覧に限らない)
        ├── toolbar.rb             # ファイル名・保存ボタン・ステータス(表示専用)
        └── editor_app.rb          # ルート。状態・サーバ通信・ターミナルはすべてここ
```

(この一覧はサンプルの主要ファイルのみ。実際には `menu_bar.rb` `log_panel.rb`
`project_settings_dialog.rb` 等もある。最新の一覧は `views/index.erb` の
`<script type="text/ruby">` タグの並びを見るのが確実)

`index.html` の `<script type="text/ruby" src="...">` は**書いた順に実行される**ので、
子コンポーネント → ルート → `main.rb` の順に並べること。

## 起動

```console
$ bundle install
$ ruby app/app.rb
```

- `/` … Funicular版エディタ
- `/legacy` … 旧エディタ(素のJavaScript + Prism.js版)。比較用に残してある

`app/app.rb` 側に、`/ruby/**/*.rb` を `app/funicular/ruby/` から配信するルートを足してある。

## 設計メモ

### コンポーネント分割

状態(ファイル一覧・編集中パス・バッファ・保存済み内容・ターミナル接続状態)は
`EditorApp` が一手に持ち、`TreeView` と `Toolbar` は props を受け取って描画するだけの
表示専用にしている。子から親へは props で渡した lambda (`on_select` / `on_save`) を
呼び返す。

**注意**: 子コンポーネント(`component(SomeClass, ...)`)は、呼び出す親が
再描画されるたびに `initialize_state` からもう一度作り直される(ルートコンポーネント
だけがマウント1回を保証される)。そのため「一度だけ初期化して使い回したい副作用」
(外部ライブラリのインスタンス化、接続、イベントリスナー登録など)を持つロジックは
子コンポーネントに切り出さず、`EditorApp` 側に書くこと。実際にターミナル機能
(xterm.js + Web Serial)をこのルールに反して別コンポーネントに切り出した結果、
「タブを行き来すると接続が切れる」不具合を起こした(詳細は `CLAUDE.md` 参照)。

Funicularのライフサイクルは `initialize_state` → `render` → `component_mounted` →
(state更新のたび `render` / `component_updated`) → `component_unmounted`。

### textarea は「非制御」にしている

`render` で `value:` を出力していない。VDOMが入力のたびに value を書き戻すと
キャレットが末尾に飛ぶため。ファイルを切り替えたときだけ
`refs[:editor][:value] = content` で流し込んでいる。

### ハイライト層は ref + innerHTML

Prismが返すのはHTML文字列なので、VDOMでは表現できない。
ハイライト用の `<code>` は**子を持たない空要素**としてVDOMに描画し、
`refs[:highlight][:innerHTML]` に直接書き込む。
子を持たない要素は再描画時の差分がゼロなので、書き込んだHTMLが消されることはない。

同期のタイミングは `component_updated` で、
`content` か `current_path` が変わったときだけ再ハイライトする
(`Funicular::Component#patch` は `component_updated` を引数なしで呼ぶ仕様なので、
前回描画時の値は `@prev_highlight_content` / `@prev_highlight_path` に自前で持っている)。

Prism固有の作法(文法オブジェクトの取り出し、末尾改行の補正)は `index.html` の
`window.funicularHighlight(code, lang)` に閉じ込めてあり、Ruby側は
`JS.global.funicularHighlight(...)` を呼ぶだけ。

### 行番号はVDOMで描画

行番号は単なるテキストなので innerHTML を使わず、`div { n.to_s }` の素直な
VDOM描画にしている。スクロール追従は `onscroll:` ハンドラで
`refs[:lines][:scrollTop]` を同期。

### スクロールのズレ対策

`.editor-scroll-area` に `display: grid` を指定し、ハイライト層と textarea を
`grid-area: 1 / 1` で重ねる方式(`app/public/css/style.css`)。
これは旧エディタから引き継いだCSSで、textareaが要素内部で独自スクロールして
キャレットとハイライトがズレる問題への対処。

## 動作確認済み

ブラウザで一覧表示・ファイル選択・シンタックスハイライト・保存を確認済み。
実装時に不明だった点は以下の通りだった:

- `component_updated` は `Funicular::Component#patch` から**引数なし**で呼ばれる
  (`component_updated(prev_state)` ではなく `component_updated`)。差分検知は
  インスタンス変数で自前管理する必要がある

## 既知の制約(旧エディタから引き継ぎ)

- 自動インデント未実装(Tabはスペース2つを挿入するだけ)
- 新規作成/削除/リネームAPIなし。既存ファイルの上書き保存のみ
- 同時編集の競合制御なし(後勝ち)
- 対応拡張子は `.rb` `.c` `.h`。増やす場合は `app/app.rb` の `ALLOWED_EXTENSIONS`、
  `index.html` のPrismコンポーネント読み込み、`editor_app.rb` の `LANGUAGES` の3箇所
