# 🎃 MONSTER BINGO（GitHub Pages ＋ Supabase 版）

**話しかけるほど、モンスターが集まる。**
サーバー不要。HTML を GitHub Pages に置き、データと処理はすべて Supabase の中で動きます。

```
monster-bingo-pages/
├─ index.html                 参加者用アプリ（1ファイル）
├─ admin.html                 運営用の管理画面
├─ config.js                  Supabase の接続先（ここだけ書き換える）
├─ sw.js                      電波が切れても画面が開くように、アプリの外枠だけを端末に保存（API は保存しない）
├─ manifest.webmanifest, icon.svg   ホーム画面に追加できるように
└─ supabase/monster_bingo.sql テーブル＋ロジック（均等配布・カード・交換・ビンゴ判定・不正検知）＋権限
```
ローカル確認用サーバーとテスト（dev/・tests/）は開発用の zip に入っています。

## 更新するとき（v1 → v2）
`supabase/monster_bingo.sql` を SQL Editor で**もう一度まるごと Run** するだけです。何度流しても同じ結果になり、参加者のデータとログイン状態はそのまま残ります（テストで確認済み）。HTML と sw.js は GitHub に上げ直してください。

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

## LINEから参加する（BUZZ BASE 公式LINE）
参加者は BUZZ BASE 公式LINE（@832dqxif）のトークやリッチメニューから開くだけで参加できます。
- 参加リンク：`https://liff.line.me/2011953081-yO9l9mGo?e=イベントコード`（管理画面のダッシュボード「受付用QR」の下にも表示）
- 初回だけ「LINEの名前を初期値にしたニックネーム」を確認して参加。2回目以降は、別のスマホからでも同じ参加者に戻ります
- LINEの中では、相手のQRは LINE のQRリーダーで読み取ります
- LINEを使わない人は、これまでどおりイベントコード＋ニックネーム、受付カード（QR／番号＋PIN）で参加できます

しくみ：LINE Developers（プロバイダー BUZZ BASE）の LINEログインチャネル「MONSTER BINGO」（チャネルID 2011953081）に LIFF アプリを作成し、公式アカウント BUZZ BASE とリンク。ブラウザが受け取った LINE の IDトークンを Supabase Edge Function `mb-line-login`（`supabase/functions/mb-line-login/index.ts`）が LINE のサーバーで照合し、確かめた LINE の利用者IDでだけ `mb_line_login` を呼びます（この関数はブラウザからは呼べません）。チャネルシークレットは使いません。

## 当日の流れ
| タイミング | やること |
|---|---|
| 前日まで | admin.html でイベント作成（定番24体が自動登録）。RARE/SECRET を追加。設定タブで紙のガイド画像（https の画像URL）を登録 |
| 名簿がある時 | 参加者タブ →「名簿を貼り付けて一括登録」に表計算ソフトから貼り付け →「未入場」で絞り込み →「🖨 受付カードを印刷」（名刺サイズ・A4に10枚・切り取り線つき。**1枚スマホで読めるか試してから**配る） |
| 受付 | 名簿の人：受付カードを手渡し → QRを読むだけで入場。読めない人はアプリの「番号で入る」に 受付番号＋PIN。<br>当日参加の人：ダッシュボードの「受付用QR」を掲示（ニックネームを入れて参加） |
| 開始 | 「▶ イベント開始」 |
| 開催中 | ダッシュボードの「まだ一度も交流していない人」にスタッフが声かけ。スピーチ中などは「⏸ 交換を一時停止」。景品・集合の合図は「📣 全体へのお知らせ」。来なかった人は参加者タブで **欠席**（人数・配布・ランキングから外れ、あとで戻せる） |
| 困った時 | 名前の聞き間違い → 参加者タブの「編集」／名簿の No つきで貼り付け。受付の渡し間違い → 「入場を取り消す」。カードをなくした → 「受付カードを再発行」。スクショ共有の疑い → 「交換用QRを作り直す」 |
| 終了 | 「■ 終了」→「参加者データCSV」（No・所属・入場時刻・欠席つき） |

## しくみ
- 参加者のブラウザが呼べるのは `mb_join` / `mb_state` / `mb_exchange` / `mb_ranking` などの関数だけ。テーブルは RLS 有効＋権限剥奪で直接読めません
- 管理用の関数はログインで得たトークンが必須（7日で失効、ログイン失敗が15分で10回続くとロック）
- 参加者のログイン状態はスマホのブラウザに保存（同じスマホ・同じブラウザで開けば続きから）
- 参加者の画面は「前回から変わっていなければ極小の応答だけ」を返す方式で、問い合わせ間隔も変化が無ければ5秒→最大20秒に広がります（自分のQRを見せている間だけ3秒）。150人・90分の再現で **1台あたり約0.4MB**（旧方式の約1割）
- 電波が切れても画面は開き、その間に読んだQRは電波が戻ったら自動で送ります
- 画面に出す人数は「当日いる人」（入場済み・欠席でない）。登録数とは分けて表示します
- QRの中身は `…/?x=<乱数トークン>`。アプリ内のSCANでも、スマホ標準のカメラで読んでも交換できます

## 公開中の環境
- 参加者用：https://koki2130414.github.io/monster-bingo/
- 管理画面：https://koki2130414.github.io/monster-bingo/admin.html
- Supabase プロジェクト：monster-bingo（組織：にいみ農園）

## 制限・今後
- リアルタイム更新は4〜5秒ごとの取得（Supabase Realtime は今後）
- モンスター画像は https の画像URLを指定（アップロード機能は今後）
- 動的QRは `participant_qr_tokens.expires_at` で拡張可能
