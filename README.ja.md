# idle-dim-display

[English](README.md) | 日本語 | [中文](README.zh.md)

Windows用の省電力**タスクトレイ常駐ツール**: キーボード・マウスの無操作時にモニターのバックライトをDDC/CIで暗くし、**入力から1秒以内**に復帰します。デスクトップPC(AC電源)向け — Windows標準の「暗転表示」はバッテリー駆動時しか効かないため、モニターを直接制御します。

## 動作仕様

| 項目 | 既定値 |
|---|---|
| 暗転までの無操作時間 | 3分 |
| 暗転時の輝度 | 30% |
| チェック間隔 | 1秒(復帰レイテンシ≤1秒。DDC通信は暗転時のみ) |
| 復帰条件 | 入力検知(アイドル10秒未満) |
| 復帰後の再暗転保護 | 30秒 |

- **タスクトレイ常駐**(円形アイコン: 監視中=黄 / 暗転中=橙半月 / 一時停止=灰)。アイコンが隠れている場合はタスクバー右下の `▲` からドラッグで常に表示できる。
- **アイコンのダブルクリック**(または右クリック→設定を開く)で設定ダイアログ:
  - 無操作時間/暗転時の輝度/チェック間隔を数値指定 → 「保存して適用」で即反映・JSON永続化
  - **現在の輝度スライダー**はドラッグするたびDDC/CIで即時適用(モニターのOSD相当)。スライダー変更は復帰点としても記録されるため、次の暗転サイクルの復帰値が正しくなる
  - **Language グループ**: 日本語 / English / 中文 — ダイアログ・トレイメニュー・ツールチップが即座に切替、保存で永続化
- トレイメニュー: 設定を開く / 今すぐ暗転テスト / 100%に戻す / 一時停止 / 終了
- 復帰時は**暗転直前の輝度**に戻す(手動変更を尊重)
- DDC/CI非応答モニターでは何もしない(安全)
- 単一インスタンスガード(プロセス列挙+自己PID除外)
- **自動復旧**: `idle-dim-wrapper.ps1`(ログオンタスク起動)が異常終了時(終了コード≠0)にトレイを自動再起動。ハンドルされていない例外は黙って死なず `~/bin/idle-dim.log`(`UI-EXCEPTION:` / `DOMAIN-EXCEPTION:` 行)に記録。`idle-dim.ps1 stop` は `idle-dim.stop` フラグファイルを作成してwrapperを停止させたままにする。

## ファイル構成

| ファイル | 役割 |
|---|---|
| `idle-dim-tray.ps1` | **本体**: トレイ常駐+設定GUI+DDC制御(UTF-8 **BOM必須** — BOM無しだとPS 5.1がANSI解釈して構文エラー) |
| `idle-dim-wrapper.ps1` | キープアライブラッパー: クラッシュ時に自動再起動。`idle-dim.stop` を尊重 |
| `idle-dim.ps1` | CLI操作: start / stop / status |
| `idle-dim-config.json` | 設定(`~/bin/`に配置、GUIから保存される) |
| `ddc-probe.ps1` | DDC/CI対応・現在輝度の確認 |
| `ddc-test.ps1` | 暗転→復帰の1回テスト |
| `ddc-restore.ps1` | 輝度を100%へ強制復帰 |
| `restart-idle-dim.ps1` | 全プロセスkill→輝度復帰→タスクから再起動 |
| `register-idle-dim-task.ps1` | ログオン起動タスク `IdleDimWatcher` の登録 |
| `launch-idle-dim-tray.vbs` | ウィンドウ非表示ランチャー(トレイ用) |
| `launch-idle-dim.vbs` | (旧CLIウォッチャー用ランチャー、参考として残置) |
| `install.ps1` | ワンコマンド導入(コピー→確認→登録→起動) |

## インストール(他PC・再セットアップ用)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

内容: `~/bin`へコピー → DDC/CI確認 → ログオンタスク登録 → トレイ起動。

## 操作

```powershell
# GUI: タスクトレイのアイコンをダブルクリック → 設定ダイアログ
# CLI:
powershell $env:USERPROFILE\bin\idle-dim.ps1 status   # 状態+設定+ログ末尾
powershell $env:USERPROFILE\bin\idle-dim.ps1 stop     # 停止+輝度100%復帰
powershell $env:USERPROFILE\bin\idle-dim.ps1 start    # 再開
powershell $env:USERPROFILE\bin\restart-idle-dim.ps1  # 全再起動
```

## 設定

GUIからの変更が基本(「保存して適用」で即反映)。直接編集する場合は `~/bin/idle-dim-config.json`:

```json
{ "IdleMinutes": 3, "DimLevel": 30, "PollSec": 1, "Language": "ja" }
```

変更後 `restart-idle-dim.ps1` を実行。

## 運用メモ(ハマりどころ)

- **`schtasks /end` では子の powershell が殺されない** — タスクのwscriptは即終了しpowershellが生存。停止・再起動は必ず `restart-idle-dim.ps1`(プロセス列挙+kill)を使う。
- **`.ps1` の日本語・中国語文字列は UTF-8 BOM 必須** — BOM無しはPS 5.1がANSI(Shift-JIS)解釈して意味不明なトークンエラーになる。
- **`New-Object 型名(a, b + c)` は3引数になる** — カンマは `+` より強く結合するため `(12, $y + 3)` は `(12, $y, 3)` になり、ダイアログ表示時にコンストラクタが例外を投げる。`(12, ($y + 3))` と括弧で明示。
- **`Add-Type` は C# の警告もエラー扱い** — 未使用のC#フィールドでもビルド失敗。
- **イベントハンドラのscriptblockから関数ローカル変数は見えない** — かといって `.GetNewClosure()` は解決策にならない: `$script:` 名がクロージャモジュールに再束縛され全てnullになる(`Set-Content` で「引数が null...」)。ダイアログのコントロールは `$script:` 変数に置き、ハンドラはクロージャにしない。
- **Mutexによる単一インスタンスガードは `New-Object` + `[ref]` では信頼できない** — プロセス列挙+`$PID`除外方式を使う。
- **コマンドラインでプロセスを検索すると自己マッチ** — 検索側自身のコマンドラインにもスクリプト名が含まれるため、必ず `$_.ProcessId -ne $PID` を入れる。
- **git-bashからインラインPowerShellは `$_` が破壊される** — `.ps1` ファイルに書くこと。
- ログ: `~/bin/idle-dim.log` — 全状態遷移がタイムスタンプ付きで1行ずつ記録される。ヘッドレス常駐の検証はこれが唯一の実用的な手段。
