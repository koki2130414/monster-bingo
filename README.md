# 🎃 MONSTER BINGO（GitHub Pages ＋ Supabase 版）

**話しかけるほど、モンスターが集まる。**
サーバー不要。HTML を GitHub Pages に置き、データと処理はすべて Supabase の中で動きます。

```
monster-bingo-pages/
├─ index.html                 参加者用アプリ（1ファイル）
├─ admin.html                 運営用の管理画面
├─ config.js                  Supabase の接続先（ここだけ書き換える）
├─ manifest.webmanifest, icon.svg   ホーム画面に追加できるように
└─ supabase/monster_bingo.sql テーブル＋ロジック（均等配布・カード・交換・ビンゴ判定・不正検知）＋権限
```
ローカル確認用サーバーと150人シミュレーション・画面の通しテスト（dev/・tests/）は、開発用の zip（monster-bingo-pages.zip）に入っています。

## セットアップ（初回だけ・約15分）

### 1. Supabase
1. https://supabase.com で **New project**（無料プランで可）。リージョンは Tokyo を推奨
2. 左メニュー **SQL Editor** → New query → `supabase/monster_bingo.sql` の中身を全部貼って **Run**
3. 続けて、管理者を作る1行を実行（メールとパスワードは自分のものに）
   ```sql
   select mb_create_admin('you@example.com', '10文字以上のパスワード');
   ```
4. **Project Settings → API** で次の2つをコピー
   - Project URL（`https://xxxx.supabase.co`）
   - `anon` `public` キー（または Publishable key）

> 既存のプロジェクトに入れても、このSQLが触るのは MONSTER BINGO のテーブルと `mb_` で始まる関数だけです。

### 2. config.js
```js
window.MONSTER_BINGO_CONFIG = {
  supabaseUrl: 'https://xxxx.supabase.co',
  supabaseAnonKey: 'eyJ...（anon キー）',
};
```
anon キーはページに載せて問題ない公開用のキーです（テーブルは読めず、関数しか呼べません）。

### 3. GitHub Pages
1. GitHub で新しいリポジトリ（例：`monster-bingo`）を作り、このフォルダの中身を push（`node_modules` は不要）
2. リポジトリの **Settings → Pages** → Branch: `main` / `/(root)` → Save
3. 数分後に `https://<ユーザー名>.github.io/monster-bingo/` で公開されます
   - 参加者用：`…/monster-bingo/?e=イベントコード`
   - 管理画面：`…/monster-bingo/admin.html`

## 当日の流れ
| タイミング | やること |
|---|---|
| 前日まで | admin.html でイベント作成（定番24体が自動登録）。RARE/SECRET を追加し、参加者タブでスタッフ・ゲストを追加して付与 → 表示されたQRを本人のスマホで読んでもらう |
| 受付 | ダッシュボードの「受付用QR」を印刷・掲示（開始前でも参加できます。交換は開始後） |
| 開始 | 「▶ イベント開始」 |
| 開催中 | 「まだ一度も交流していない人」「交流が少ない人」にスタッフが声かけ。不正ログに「QRスクショ共有の疑い」が出たら参加者タブで **QR再発行** |
| 終了 | 「■ 終了」→「参加者データCSV」 |

## しくみ
- 参加者のブラウザが呼べるのは `mb_join` / `mb_state` / `mb_exchange` / `mb_ranking` などの関数だけ。テーブルは RLS 有効＋権限剥奪で直接読めません
- 管理用の関数はログインで得たトークンが必須（7日で失効、ログイン失敗が15分で10回続くとロック）
- 参加者のログイン状態はスマホのブラウザに保存（同じスマホ・同じブラウザで開けば続きから）
- 相手の画面は4秒ごとに自動更新され、読まれた側にも GET 演出が出ます
- QRの中身は `…/?x=<乱数トークン>`。アプリ内のSCANでも、スマホ標準のカメラで読んでも交換できます

## 公開中の環境
- 参加者用：https://koki2130414.github.io/monster-bingo/
- 管理画面：https://koki2130414.github.io/monster-bingo/admin.html
- Supabase プロジェクト：monster-bingo（組織：にいみ農園）

## 制限・今後
- リアルタイム更新は4〜5秒ごとの取得（Supabase Realtime は今後）
- モンスター画像は https の画像URLを指定（アップロード機能は今後）
- 動的QRは `participant_qr_tokens.expires_at` で拡張可能
