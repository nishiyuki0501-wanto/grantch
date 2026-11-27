# Grantch

日本語 | [English](README.en.md)

Grantch は、AI コーディングエージェントの承認を macOS のノッチで行うアプリです。Claude Code と Codex CLI の `PermissionRequest`、Antigravity CLI の `PreToolUse` を、自分だけが使える Unix ソケット経由でノッチのパネルに表示し、そこで許可・拒否します。通信はすべてこの Mac の中で完結します。

画面は macOS の言語設定に合わせて日本語または英語で表示されます。macOS 15 以降が必要です。リポジトリ名、コマンド名、内部の識別子には、プロジェクト名の `grantch` を使っています。

## インストール

1. [Releases](https://github.com/nishiyuki0501-wanto/grantch/releases) から `Grantch-<バージョン>-macos-universal.dmg` をダウンロードして開き、Grantch を「アプリケーション」フォルダへドラッグします。同じ内容の zip もあります。
2. Grantch を開きます。ノッチに常駐し、Dock には表示されません。
3. CLI のフックをインストールします。

   ```sh
   /Applications/Grantch.app/Contents/MacOS/grantch-config install
   ```

   一度でも起動したことのある CLI（`~/.claude`、`~/.codex`、`~/.gemini` がある CLI）だけを設定します。あとから CLI を追加したときは、もう一度実行してください。

4. 起動中の Claude Code・Codex CLI・Antigravity CLI を再起動します。Codex は次回起動時に、追加したフックの確認と信頼を求めます。
5. 再起動後も動くように、**システム設定 →「一般」→「ログイン項目」** に追加します。アプリが自分で追加することはありません。アプリが動いていない間は、Claude Code と Codex はそれぞれの通常の確認画面になり、Antigravity の要求は拒否されます。

更新するときは、ノッチを右クリック →「Grantch を終了」で終了し、アプリを置き換えて開きます。その後、もう一度 install を実行して、コピー済みのブリッジをアプリと同じ版にそろえ、CLI を再起動してください。

守れる範囲と守れない範囲は [SECURITY.md](SECURITY.md) にまとめています。必ず読んでください。

## できること

- ノッチ位置に表示されるネイティブの SwiftUI/AppKit パネル。操作スペースを切り替えても、フルスクリーンでも表示されます
- ノッチより少し広い範囲にマウスを乗せると広がり、クリックで開いたまま固定できます。反応するのはメニューバーの高さまでなので、その下にあるアプリ（ブラウザのタブなど）のクリックは妨げません
- 表示はディスプレイごとに変わります。ノッチのある Mac ではその機種のノッチの大きさに合わせ、ノッチのない Mac や外部ディスプレイでは、画面上端の小さなタブと切り欠きのないパネルになります
- 危険度ごとに色が変わる、オリジナルのボクセル風デザイン
- Claude Code と Codex CLI の `PermissionRequest` に対応
- Antigravity CLI（`agy`）のコマンド実行とファイル変更の承認。`--dangerously-skip-permissions` で起動すると、このアプリだけが確認窓口になります
- ターミナルでの回答、ツールの完了、セッション終了、接続の切断、親プロセスの終了を検知して、表示を自動で片付けます
- 承認待ちを最大3件まで並べて表示します（どの CLI か、プロジェクト、コマンド、危険度）
  - シェル系のツールは、実行するコマンドそのものを表示します。サンドボックスの無効化、権限の昇格、作業ディレクトリの指定があれば、目印を付けます
  - ファイル・Web・検索などの既知のツールは、ツール名と対象を表示します
  - MCP ツールを含むそれ以外のツールは、入力の全体を表示します
  - エージェントが書いた説明文は、実際の入力の代わりには使いません。ホバー時に「エージェントの説明」と明記して表示するだけです
- 改行、制御文字、表示の向きを変える文字、目に見えない文字、通常と異なる空白は、目に見える記号で表示します。長く続く空白は数で表示するので、コマンドの一部を隠すことはできません
- 承認要求が表示された直後と、行が繰り上がった直後の 0.5 秒間はボタンが反応しません。別の場所を狙ったクリックで許可されることを防ぎます
- 「許可」「拒否」「停止」（拒否して作業も中断。Claude Code のみ）、「セッション中」（Claude Code がルールを提案したとき）。「セッション中」のボタンには、許可されるルール（例: `Bash(git:*)`）がそのまま表示されます
- 席を外すときの自動承認（15分・1時間・3時間）。パネルまたは右クリックメニューから、すべての CLI に対して使えます
- 危険度の判定はこの Mac の中で行います。対象は、破壊的なシェル操作、Git、データベース、認証情報、デプロイ、ネットワーク、シェルへの流し込みやダウンロードしての実行、エージェント・フック・SSH・Git フック・シェル起動ファイルの変更です。ラベルにマウスを乗せると理由が出ます
- 5分で期限切れになり、要求は CLI に返されます。決定は最初の1回だけが有効です
- ソケットを開けなかったときは、待機中に見えないよう赤い `ERROR` 表示を出します
- アプリが使えない、またはブリッジが入力を受け付けないときは安全側に倒します。Claude Code と Codex はそれぞれの通常の確認画面に戻り、Antigravity は拒否されます（`--dangerously-skip-permissions` のもとでは、ほかに確認する手段がないため）
- ソケットは `~/Library/Application Support/Grantch/run/grantch.sock` です。ディレクトリの権限は `0700`、ソケットの権限は `0600` です

未対応のもの: Cursor、承認内容の保存、フックをインストールする画面、Touch ID、ターミナルの前面表示、ログイン時の自動起動。

## 自動承認

ノッチを固定表示にする（または右クリックする）と「自動承認」を選べます。時間を選ぶと、期限まですべての要求に「今回のみ許可」で答えます。3つの CLI すべてが対象なので、各 CLI を確認なしで動かしているのと同じ状態になります。危険度が「高リスク」「危険」の要求も、ほかと同じように許可されます。

自動承認中は、ノッチに赤い `AUTO` 表示が出て、残り時間と件数が分かります。パネルからは「+15分」と「オフ」を選べます。パネルには許可した内容の一覧が表示されます。この一覧は自動承認が終わった後も残り、次の自動承認を始めるか「消去」を押すまで読み返せます。件数はすべて数え、内容は直近30件を保持し、最新4件を表示します。

自動承認の状態はメモリにだけ持ちます。アプリを終了・再起動すると必ず通常の確認状態に戻り、一覧も消えます。

## ソースからビルド

```sh
swift build
swift run Grantch
```

`swift run` では日本語で表示されます。英語の翻訳と、言語に合わせたアプリ名は、`scripts/package.sh` でアプリにまとめるときに追加されます。

ビルドしたブリッジは `.build/debug/grantch-hook` です。次のコマンドで、フックの設定を安全に追加できます。

```sh
swift run grantch-config install .build/debug/grantch-hook
```

インストーラは、ディレクトリがある CLI についてだけ、`~/.claude/settings.json`、`~/.codex/hooks.json`、`~/.gemini/config/hooks.json` に設定を追加します。Claude と Codex には、承認と完了・セッション終了のフックを入れます。Antigravity には `grantch-approval` という名前の PreToolUse フックを入れます。

- ほかのフックは上書きしません
- シンボリックリンクになっている設定ファイルは、リンク先に書き込みます
- ファイルの権限はそのまま保ちます
- 既存のファイルを変更する前に、1回の実行につき1回、タイムスタンプ付きのバックアップを設定ファイルの隣に作ります。バックアップは自分だけが読める `0600` です
- 設定ファイルは、キーを並べ替えた整形済みの JSON で書き直されます
- メッセージは macOS の言語設定に合わせて表示されます。`GRANTCH_LANG=ja` または `GRANTCH_LANG=en` で切り替えられます

インストール後は CLI を再起動してください。Codex は新しく追加されたローカルのフックを検証するので、次回の通常起動時に求められたら確認して信頼してください。

追加した設定だけを取り除くには、次を実行します。

```sh
swift run grantch-config uninstall
```

## ブリッジの手動確認

アプリを起動した状態で、次を実行します。

```sh
echo '{"session_id":"demo","cwd":"/tmp/grantch-demo","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test"}}' | .build/debug/grantch-hook
```

パネルで操作を選ぶと、CLI 向けの応答が表示されます。アプリを止めた状態では、同じコマンドが `{}` を出力し、通常の確認画面に戻ることを確認できます。Antigravity 用のブリッジは別で、アプリを止めた状態では明示的な拒否を出力します。

```sh
echo '{"conversationId":"demo","workspacePaths":["/tmp/grantch-demo"],"stepIdx":1,"toolCall":{"name":"run_command","args":{"CommandLine":"npm test","Cwd":"/tmp/grantch-demo"}}}' | .build/debug/grantch-hook --source antigravity
```

## テスト

```sh
swift test
swift build -c release
python3 Tests/Integration/config_test.py
python3 Tests/Integration/localization_test.py
```

インストーラのテストは、分離したホームディレクトリ（`GRANTCH_CONFIG_HOME`）で動くので、実際の設定には触れません。翻訳のテストは、画面のすべての日本語に、書式指定の合った英語訳があることを確認します。

フックの仕様は、公式の [Claude Code Hooks リファレンス](https://code.claude.com/docs/en/hooks#permissionrequest-decision-control)、[Codex の設定スキーマ](https://github.com/openai/codex/blob/main/codex-rs/core/config.schema.json)、Antigravity の [Hooks ドキュメント](https://www.agy.dev/docs/hooks/) にあります。

## Antigravity とターミナルとの連携

Antigravity には承認専用のイベントがなく、同期的な `PreToolUse` だけがあります。そのため、このアプリは `run_command`、`write_to_file`、`replace_file_content`、`multi_replace_file_content`、`ask_permission`、MCP ツール（`call_mcp_tool`。パネルには `mcp サーバー/ツール 引数` と表示）を確認対象にしています。Antigravity が自動で許可する操作も含みます。一方、`view_file`、`read_url_content`、`manage_task`、サブエージェントなどは確認しません。また、Antigravity で既に開いている確認ダイアログを表示することもできません。

フックで通すことと、権限を与えることは別です。`agy 1.2.5` では、`decision: allow` を返すとフックは通過しますが、その後 Antigravity は自身の権限ルール（`~/.gemini/antigravity-cli/settings.json` の `permissions.allow` と会話ごとの許可）を評価し、ターミナルで `Run this command?` と確認して止まります。フックの応答でこれを解消する方法はありません。`permissionOverrides` は確認対象の文字列を置き換えるだけで、許可はしません。`["command(echo)"]` を返しても、確認の文言が変わるだけです。

このアプリを確認窓口にするには、Antigravity を `agy --dangerously-skip-permissions` で起動します。このオプションでもフックは実行され、その判断が優先されるので、拒否すれば処理は止まります。ターミナルでの確認がなくなるため、Antigravity については安全側に倒し、期限切れ・取り消し・判断できなかった要求には `decision: deny` を返します。Antigravity は空の `{}` も拒否として扱うので、`{}` は使いません。

共有の `~/.gemini/config/hooks.json` は Antigravity の他の画面からも読み込まれるので、判断できないときは拒否するという動作がそちらにも適用されます。

Claude のターミナルでのフック判断と、対応するツールの実行結果が出ると、承認待ちから消えます。Claude と Codex の完了イベントとセッションのライフサイクルイベントも、片付けのきっかけになります。完了の通知が承認として扱われることはありません。照合には、セッション・ターン・ツール呼び出しの ID を、ある場合は使います。コマンドの一致だけで照合するのは、候補が1件しかないときに限ります。フックとの接続が切れたとき、親プロセスが終了したとき、期限が切れたときも、古い要求は消えます。CLI がフックを動かしたまま判断のイベントを出さない場合は、ターミナルで回答した瞬間ではなく、ツールの結果や完了が届いた時点で片付きます。

## デバッグログ

要求が表示されないときは、まず CLI がフックを呼んだかどうかを確認します。

```sh
touch ~/Library/Application\ Support/Grantch/debug-hook-log
```

この操作の後は、ブリッジが呼ばれるたびに `~/Library/Application Support/Grantch/log/hook.log` に記録されます。ログにはコマンドの内容やファイルのパスが含まれるので、確認が終わったらフラグのファイルとログを削除してください。

## アンインストール

```sh
/Applications/Grantch.app/Contents/MacOS/grantch-config uninstall
```

このコマンドが取り除くのは、追加したフックとコピーしたブリッジだけです。その後、ノッチを右クリック →「Grantch を終了」で終了します。アプリを「アプリケーション」フォルダから削除し、ログイン項目からも外してください。必要なら `~/Library/Application Support/Grantch` も削除します。

インストーラが作ったバックアップは、各設定ファイルの隣に `*.grantch-backup-*` という名前で残っています。Codex は信頼したフックを順番も含めて識別するので、`~/.codex/hooks.json` でこのアプリの後に追加したフックは、もう一度信頼が必要になることがあります。

## リリース手順

リリースはこの Mac でビルドし、Developer ID で署名して公証を受け、DMG と zip を付けた GitHub リリースの下書きとしてアップロードします。最初に一度だけ、公証用の認証情報をキーチェーンに保存します。

```sh
xcrun notarytool store-credentials grantch-notary --apple-id <Apple ID> --team-id <Team ID>
```

リリースのたびに、[CHANGELOG.md](CHANGELOG.md) と [CHANGELOG.en.md](CHANGELOG.en.md) の両方に `## [x.y.z] - YYYY-MM-DD` の項目を追加し、`main` を push してから次を実行します。

```sh
SIGN_IDENTITY="Developer ID Application: <名前> (<Team ID>)" NOTARY_PROFILE=grantch-notary scripts/release.sh x.y.z
```

このスクリプトは次の順に処理します。未コミットの変更がある、または push していない状態では実行を止めます。

1. テストを実行する
2. Intel と Apple シリコンの両対応版をビルドし、デバッグ情報を取り除く
3. アプリと DMG に署名し、公証を受け、結果を添付する
4. 両方のファイルと SHA-256 を付けて、リリースの下書きを作る

下書きを GitHub で公開すると `vx.y.z` タグが作られます。`scripts/package.sh x.y.z` だけを実行すると、手元での確認用に、簡易署名のアプリ・DMG・zip を作ります。

## ライセンス

[MIT](LICENSE)
