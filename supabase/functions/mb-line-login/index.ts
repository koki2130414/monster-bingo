/**
 * MONSTER BINGO — LINEログイン（Supabase Edge Function「mb-line-login」）
 *
 * BUZZ BASE 公式LINE のトーク／リッチメニューから LIFF で開いた参加者を、LINE アカウントで参加させる。
 *
 * なぜサーバー側で照合するのか：
 *   ブラウザが「私の LINE ID は U…です」と名乗るだけだと、他人の ID を書けばなりすませてしまう。
 *   そこで LIFF が発行する IDトークンを、LINE のサーバー（/oauth2/v2.1/verify）に照合してから、
 *   確かめ済みの sub（LINE の利用者ID）と表示名だけをデータベース関数 mb_line_login に渡す。
 *   mb_line_login はブラウザ（anon）からは呼べず、この関数（service_role）からだけ呼べる。
 *
 * 秘密情報：チャネルシークレットは不要（IDトークンの照合はチャネルIDだけでできる）。
 *   service_role の鍵は Supabase が環境変数で自動的に渡すもので、ブラウザには出ない。
 *
 * 入力（POST JSON）：{ idToken, code, nickname?, agreed? }
 * 出力：mb_line_login の結果そのまま（{ok:true, sessionToken, eventCode, isNew} など）
 */
const LINE_CHANNEL_ID = Deno.env.get('LINE_CHANNEL_ID') ?? '2011953081';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const CORS = {
  'Access-Control-Allow-Origin': '*', // 認証は LINE の IDトークンで行うので、呼び出し元のドメインは絞らなくてよい
  'Access-Control-Allow-Headers': 'content-type, apikey, authorization, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, code: 'METHOD', message: 'POST で呼んでください' }, 405);

  let input: { idToken?: string; code?: string; nickname?: string | null; agreed?: boolean };
  try { input = await req.json(); } catch { return json({ ok: false, code: 'BAD_JSON', message: '送信内容が読めません' }, 400); }
  const idToken = String(input.idToken ?? '');
  if (!idToken || idToken.length > 4096) return json({ ok: false, code: 'NO_TOKEN', message: 'LINEのログイン情報がありません' }, 400);

  // 1) LINE のサーバーで IDトークンを照合（署名・有効期限・発行先チャネルを LINE 側が確かめる）
  const verify = await fetch('https://api.line.me/oauth2/v2.1/verify', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ id_token: idToken, client_id: LINE_CHANNEL_ID }),
  });
  const claims = await verify.json().catch(() => null);
  if (!verify.ok || !claims?.sub) {
    // 期限切れが多い。画面側はこのコードを見て LINE に再ログインしてもらう
    return json({ ok: false, code: 'LINE_TOKEN_INVALID', message: 'LINEのログインの有効期限が切れました。もう一度開き直してください' }, 401);
  }

  // 2) 確かめ済みの sub と表示名でデータベースに問い合わせ（service_role）
  const rpc = await fetch(`${SUPABASE_URL}/rest/v1/rpc/mb_line_login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    body: JSON.stringify({
      p_code: String(input.code ?? ''),
      p_line_sub: claims.sub,
      p_line_name: String(claims.name ?? ''),
      p_nickname: input.nickname ?? null,
      p_agreed: Boolean(input.agreed),
    }),
  });
  const result = await rpc.json().catch(() => null);
  if (!rpc.ok) return json({ ok: false, code: result?.hint ?? 'DB_ERROR', message: result?.message ?? '参加処理に失敗しました' }, 400);
  return json(result);
});
