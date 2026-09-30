/**
 * MONSTER BINGO の Service Worker（参加者画面だけが登録する。管理画面は登録しない）
 *
 * やること：アプリの外枠（index.html・config.js・アイコン・QRライブラリ）を端末に保存して、
 *           会場で電波が切れても画面そのものは開けるようにする。
 * やらないこと：Supabase への問い合わせ（状態・交換・ランキング）は一切保存しない。
 *           保存すると、古い状態が表示される・他人の端末に情報が残る・ログイン情報がキャッシュに残る、という事故になる。
 *           別ドメインへのリクエストは、下の CDN 2つ以外すべて素通し（respondWith しない）。
 *
 * 更新：HTML は「まずネット、ダメなら保存分」。直した版がすぐ届くように。
 *       ライブラリ・アイコンは「保存分を先に出し、裏で更新」。毎回取りに行かないように。
 *       外枠を変えたら VERSION を上げる（古い保存分を消すため）。
 */
const VERSION = 'mb-shell-v2';
const SHELL = ['./', './index.html', './config.js', './icon.svg', './manifest.webmanifest'];
const CDN = [
  'https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.min.js',
  'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.min.js',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(VERSION)
      .then((cache) => Promise.all([...SHELL, ...CDN].map((url) => cache.add(url).catch(() => {}))))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith('mb-shell-') && k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return; // 交換・状態取得（POST）は必ず素通し
  const url = new URL(request.url);
  const sameOrigin = url.origin === self.location.origin;
  if (!sameOrigin && !CDN.includes(url.href)) return; // Supabase・フォントなどは触らない
  if (sameOrigin && url.pathname.endsWith('/admin.html')) return; // 管理画面は保存しない

  if (request.mode === 'navigate' || (sameOrigin && url.pathname.endsWith('.html'))) {
    // ?x=… ?s=… ?e=… 付きで開かれても、保存してある index.html を出せるよう、検索部分は無視して引く
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response.ok) caches.open(VERSION).then((cache) => cache.put('./index.html', response.clone()));
          return response;
        })
        .catch(() => caches.match('./index.html')),
    );
    return;
  }

  event.respondWith(
    caches.match(request, { ignoreSearch: sameOrigin }).then((cached) => {
      const network = fetch(request)
        .then((response) => {
          if (response.ok) caches.open(VERSION).then((cache) => cache.put(request, response.clone()));
          return response;
        })
        .catch(() => cached);
      return cached || network;
    }),
  );
});
