-- =====================================================================
-- MONSTER BINGO — Supabase 用 SQL（これ1本で完結）v2
--   Supabase → SQL Editor に全文を貼って Run。何度実行しても安全です（v1 の上に流しても、データとログインは残ります）。
--   v2：欠席・入場記録・受付番号＋PIN・名簿の一括登録・受付カード・全体へのお知らせ・交換の一時停止・差分応答
--   最後に、管理者を作る1行（ファイル末尾のコメント）を実行してください。
--
-- 設計：
--   ・ブラウザ（GitHub Pages の HTML）は anon キーで「mb_ で始まる関数」を呼ぶことしかできない
--   ・テーブルは anon / authenticated から一切読めない・書けない（RLS 有効＋権限剥奪）
--   ・均等配布／カード生成／交換／ビンゴ判定／不正検知はすべてこの関数の中で行う
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- テーブル
create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  status text not null default 'draft' check (status in ('draft','active','ended')),
  free_cell_enabled boolean not null default true,
  exchange_mode text not null default 'both' check (exchange_mode in ('both','scanner_only')),
  name_display_mode text not null default 'nickname' check (name_display_mode in ('full_name','nickname','hidden')),
  ranking_enabled boolean not null default true,
  ranking_metric text not null default 'species' check (ranking_metric in ('encounters','species','bingo','completion')),
  exchange_cooldown_seconds integer not null default 3 check (exchange_cooldown_seconds between 0 and 60),
  max_participants integer not null default 500 check (max_participants between 1 and 5000),
  created_at timestamptz not null default now()
);

create table if not exists monsters (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  name text not null,
  emoji text not null default '👻',
  image_url text,
  color text not null default '#ff7a1a',
  rarity text not null default 'normal' check (rarity in ('normal','rare','secret')),
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists monsters_event_idx on monsters(event_id);

create table if not exists participants (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  nickname text not null,
  full_name text,
  role text not null default 'guest' check (role in ('guest','staff','organizer','sponsor','vip')),
  monster_id uuid references monsters(id),
  session_token_hash text not null unique,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz,
  deleted_at timestamptz
);
create index if not exists participants_event_idx on participants(event_id);

create table if not exists participant_qr_tokens (
  token text primary key,
  participant_id uuid not null references participants(id) on delete cascade,
  event_id uuid not null references events(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz,          -- 将来の動的QR用（null = 固定QR）
  revoked_at timestamptz
);
create index if not exists qr_tokens_participant_idx on participant_qr_tokens(participant_id);

create table if not exists bingo_cards (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  participant_id uuid not null unique references participants(id) on delete cascade,
  size integer not null default 5,
  layout_hash text not null,
  bingo_lines integer not null default 0,
  first_bingo_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (event_id, layout_hash)
);

create table if not exists bingo_cells (
  card_id uuid not null references bingo_cards(id) on delete cascade,
  position integer not null,
  monster_id uuid references monsters(id),
  is_free boolean not null default false,
  opened_at timestamptz,
  opened_by_participant_id uuid references participants(id) on delete set null,
  primary key (card_id, position)
);
create index if not exists bingo_cells_monster_idx on bingo_cells(card_id, monster_id);

create table if not exists encounters (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  scanner_participant_id uuid not null references participants(id) on delete cascade,
  target_participant_id uuid not null references participants(id) on delete cascade,
  exchange_mode text not null,
  scanner_received_monster_id uuid references monsters(id),
  target_received_monster_id uuid references monsters(id),
  created_at timestamptz not null default now()
);
create index if not exists encounters_event_time_idx on encounters(event_id, created_at desc);
create index if not exists encounters_scanner_idx on encounters(scanner_participant_id, created_at desc);
create index if not exists encounters_target_idx on encounters(target_participant_id, created_at desc);

create table if not exists monster_collections (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  participant_id uuid not null references participants(id) on delete cascade,
  monster_id uuid not null references monsters(id),
  source_participant_id uuid not null references participants(id) on delete cascade,
  encounter_id uuid references encounters(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (participant_id, source_participant_id)          -- 同じ相手からの獲得は1回まで
);
create index if not exists collections_participant_idx on monster_collections(participant_id, created_at desc);

create table if not exists fraud_logs (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  participant_id uuid references participants(id) on delete cascade,
  kind text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists fraud_logs_event_idx on fraud_logs(event_id, created_at desc);

create table if not exists admins (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  password_hash text not null,
  created_at timestamptz not null default now()
);

create table if not exists admin_sessions (
  token_hash text primary key,
  admin_id uuid not null references admins(id) on delete cascade,
  expires_at timestamptz not null
);

create table if not exists admin_login_failures (
  email text not null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- v2 で追加した列・表（既存DBにも後から足せるよう add column if not exists）
-- 交換の一時停止はイベントの状態（準備中/開催中/終了）とは別に持つ。
--   当日「スピーチ中だけ止めたい」と言われた時に、状態を戻さずに止められるように。
alter table events add column if not exists exchange_paused boolean not null default false;
-- 紙で配ったガイドと同じ画像をアプリにも出す（説明の食い違いで「どっちが正しいの」と聞かれないように）
alter table events add column if not exists guide_image_url text;
-- 参加者の画面が「全部取り直すべきか」を判断する材料。設定・モンスターを変えたら必ず更新する
alter table events add column if not exists updated_at timestamptz not null default now();

-- 受付番号。QRが読めない時に「番号＋PIN」で入るため、名簿との突き合わせのために使う
alter table participants add column if not exists entry_no integer;
alter table participants add column if not exists affiliation text;
-- 初めてアプリを開いた時刻（受付で「誰がQRを読めたか」を見るため）
alter table participants add column if not exists checked_in_at timestamptz;
-- 欠席。行は消さない（押し間違いを戻せるように）。欠席の人は人数・配布・交換・ランキングから外れる
alter table participants add column if not exists absent_at timestamptz;
-- 印刷カードに載せる4桁PIN（ハッシュで保存。平文はカードにしか無い）
alter table participants add column if not exists pin_hash text;

with m as (select event_id, coalesce(max(entry_no), 0) as mx from participants group by event_id),
     x as (select p.id, m.mx + row_number() over (partition by p.event_id order by p.created_at) as n
           from participants p join m on m.event_id = p.event_id where p.entry_no is null)
update participants p set entry_no = x.n from x where p.id = x.id;
update participants set checked_in_at = last_seen_at where checked_in_at is null and last_seen_at is not null;
create unique index if not exists participants_entry_no_idx on participants(event_id, entry_no);

-- LINEログイン（BUZZ BASE 公式LINE の LIFF から参加）。LINE の利用者ID（sub）でその人を見分ける。
--   1つのイベントで同じLINEアカウントは1人分だけ（機種変更・再インストールしても同じ参加者に戻れるように）
alter table participants add column if not exists line_user_id text;
create unique index if not exists participants_line_idx on participants(event_id, line_user_id)
  where line_user_id is not null and deleted_at is null;

-- 使うモンスターの制限（当日の人数に合わせる）。
--   来場者がモンスターの種類より少ないと、カードに載っているのに誰も持っていないモンスターが出て、そのマスは永遠に開かない。
--   monster_pool_size が入っている間は、配布もカードも in_pool のモンスターだけで行う（null = 制限なし＝全種類）
alter table events add column if not exists monster_pool_size integer check (monster_pool_size is null or monster_pool_size >= 1);
alter table monsters add column if not exists in_pool boolean not null default true;

-- 全体へのお知らせ。参加者の画面へは直近5件しか返さない（増え続けて毎回の応答が重くならないように）
create table if not exists announcements (
  id bigint generated always as identity primary key,
  event_id uuid not null references events(id) on delete cascade,
  message text not null,
  created_at timestamptz not null default now()
);
create index if not exists announcements_event_idx on announcements(event_id, id desc);

-- PIN の総当たり対策。4桁は1万通りしかないので、番号ごと・イベント全体の両方で失敗回数を数える
create table if not exists pin_login_failures (
  event_id uuid not null,
  entry_no integer,
  created_at timestamptz not null default now()
);
create index if not exists pin_failures_idx on pin_login_failures(event_id, created_at desc);

do $$
declare t text;
begin
  foreach t in array array['events','monsters','participants','participant_qr_tokens','bingo_cards','bingo_cells',
                           'encounters','monster_collections','fraud_logs','admins','admin_sessions','admin_login_failures',
                           'announcements','pin_login_failures'] loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- 引数や戻り値の形を変えた関数は、古い形を消してから作り直す
--   （PostgreSQL は同名で引数違いの関数を別物として残す。残ると PostgREST がどちらを呼ぶか迷う）
drop function if exists mb__join(uuid, text, text, text);
drop function if exists mb__participant_stats(uuid);
drop function if exists mb_state(text);
drop function if exists mb_admin_add_participant(text, uuid, text, text, uuid);
drop function if exists mb_admin_issue_logins(text, uuid, uuid[]);

-- ---------------------------------------------------------------- 内部ヘルパー（ブラウザからは呼べない）

create or replace function mb__hash(p_text text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(digest(coalesce(p_text, ''), 'sha256'), 'hex')
$$;

create or replace function mb__token(p_bytes int) returns text
language sql volatile set search_path = public, extensions as $$
  select rtrim(translate(encode(gen_random_bytes(p_bytes), 'base64'), E'+/\n', '-_'), '=')
$$;

create or replace function mb__fail(p_code text, p_message text) returns void
language plpgsql set search_path = public, extensions as $$
begin
  raise exception using message = p_message, hint = p_code;
end $$;

create or replace function mb__display_name(p_mode text, p_nickname text, p_full_name text) returns text
language sql immutable set search_path = public, extensions as $$
  select case p_mode when 'hidden' then null
                     when 'full_name' then coalesce(nullif(trim(p_full_name), ''), p_nickname)
                     else p_nickname end
$$;

create or replace function mb__monster_json(m monsters) returns jsonb
language sql stable set search_path = public, extensions as $$
  select case when m.id is null then null else jsonb_build_object(
    'id', m.id, 'name', m.name, 'emoji', m.emoji, 'imageUrl', m.image_url, 'color', m.color, 'rarity', m.rarity) end
$$;

create or replace function mb__participant_by_session(p_session text) returns participants
language sql stable set search_path = public, extensions as $$
  select p.* from participants p where p.session_token_hash = mb__hash(p_session) and p.deleted_at is null
$$;

create or replace function mb__require_admin(p_admin_token text) returns uuid
language plpgsql set search_path = public, extensions as $$
declare v_admin uuid;
begin
  select admin_id into v_admin from admin_sessions where token_hash = mb__hash(p_admin_token) and expires_at > now();
  if v_admin is null then perform mb__fail('ADMIN_REQUIRED', '管理者ログインが必要です'); end if;
  return v_admin;
end $$;

-- 縦5・横5・斜め2 のうち、全マス OPEN のライン数
create or replace function mb__lines(p_card uuid) returns int
language sql stable set search_path = public, extensions as $$
  with c as (select position, opened_at is not null as is_open from bingo_cells where card_id = p_card),
  l as (
    select 'r' || (position / 5) as k, is_open from c
    union all select 'c' || (position % 5), is_open from c
    union all select 'd1', is_open from c where position in (0, 6, 12, 18, 24)
    union all select 'd2', is_open from c where position in (4, 8, 12, 16, 20)
  )
  select count(*)::int from (select k from l group by k having count(*) = 5 and bool_and(is_open)) done
$$;

-- カードに載せる（＝今回のゲームで使う）モンスター。SECRET は載せない。
--   使うモンスターを制限している間（events.monster_pool_size が入っている間）は in_pool のものだけ
create or replace function mb__card_monster_ids(p_event uuid) returns setof uuid
language sql stable set search_path = public, extensions as $$
  select m.id from monsters m join events e on e.id = m.event_id
  where m.event_id = p_event and m.is_active and m.rarity <> 'secret'
    and (e.monster_pool_size is null or m.in_pool)
$$;

-- 均等ランダム配布：担当人数が最も少ない NORMAL モンスターから1体をランダムに（使うモンスターを制限中はその中から）
--   欠席の人は数えない。数えると、欠席者が多いモンスターが「足りている」扱いになり会場で偏る
create or replace function mb__pick_monster(p_event uuid) returns uuid
language sql volatile set search_path = public, extensions as $$
  select m.id from monsters m
  left join participants p on p.monster_id = m.id and p.deleted_at is null and p.absent_at is null
  where m.event_id = p_event and m.rarity = 'normal' and m.id in (select mb__card_monster_ids(p_event))
  group by m.id
  order by count(p.id), random()
  limit 1
$$;

-- 参加者ごとにランダム配置のカードを作る（同じ配置はイベント内で作らない）
create or replace function mb__create_card(p_event events, p_participant uuid) returns void
language plpgsql set search_path = public, extensions as $$
declare
  v_ids uuid[];
  v_layout uuid[];
  v_needed int := case when p_event.free_cell_enabled then 24 else 25 end;
  v_hash text;
  v_card uuid;
begin
  select array_agg(id) into v_ids from mb__card_monster_ids(p_event.id) id;
  if v_ids is null then perform mb__fail('NO_MONSTERS', 'カードに載せるモンスターが登録されていません'); end if;
  -- 自分のモンスターは自分のカードに載せない（自分とは交換できないので、他に持っている人がいないとそのマスは開かない）
  if array_length(v_ids, 1) > 1 then
    v_ids := array_remove(v_ids, (select monster_id from participants where id = p_participant));
  end if;
  for attempt in 1..50 loop
    select array_agg(x) into v_layout from (select x from unnest(v_ids) x order by random() limit v_needed) s;
    while array_length(v_layout, 1) < v_needed loop       -- 種類が足りなければ重複で埋める
      v_layout := v_layout || v_ids[1 + floor(random() * array_length(v_ids, 1))::int];
    end loop;
    select array_agg(x order by random()) into v_layout from unnest(v_layout) x;
    if p_event.free_cell_enabled then
      v_layout := v_layout[1:12] || array[null::uuid] || v_layout[13:24];
    end if;
    v_hash := md5(array_to_string(v_layout, '|', 'FREE'));
    -- 使うモンスターが少なすぎて違う配置が作れない時（例：2種類で自分のを除くと1種類）は、同じ配置でも作る
    if attempt = 50 then v_hash := md5(v_hash || p_participant::text); end if;
    if not exists (select 1 from bingo_cards where event_id = p_event.id and layout_hash = v_hash) then
      insert into bingo_cards (event_id, participant_id, size, layout_hash) values (p_event.id, p_participant, 5, v_hash)
      returning id into v_card;
      insert into bingo_cells (card_id, position, monster_id, is_free, opened_at)
      select v_card, (ord - 1)::int, m, m is null, case when m is null then now() end
      from unnest(v_layout) with ordinality as t(m, ord);
      return;
    end if;
  end loop;
  perform mb__fail('CARD_GENERATION_FAILED', 'カードを作れませんでした。もう一度お試しください');
end $$;

create or replace function mb__issue_qr(p_event uuid, p_participant uuid) returns text
language plpgsql set search_path = public, extensions as $$
declare v_token text := mb__token(18);
begin
  insert into participant_qr_tokens (token, participant_id, event_id) values (v_token, p_participant, p_event);
  return v_token;
end $$;

-- 参加処理本体（一般参加と運営による追加で共通）
--   p_checked_in：本人がスマホで参加した時は true（その場にいる）。運営が名簿から登録した時は false（まだ来ていない）
create or replace function mb__join(p_event_id uuid, p_nickname text, p_full_name text, p_role text,
                                    p_affiliation text default null, p_checked_in boolean default true)
returns jsonb
language plpgsql set search_path = public, extensions as $$
declare
  ev events;
  v_nickname text := left(trim(coalesce(p_nickname, '')), 20);
  v_session text := mb__token(32);
  v_monster uuid;
  v_participant uuid;
  v_count int;
  v_no int;
begin
  if v_nickname = '' then perform mb__fail('NICKNAME_REQUIRED', 'ニックネームを入力してください'); end if;
  select * into ev from events where id = p_event_id for update;   -- 同時参加でも集計と受付番号がずれないようロック
  if ev.id is null then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;
  if ev.status = 'ended' then perform mb__fail('EVENT_ENDED', 'このイベントは終了しました'); end if;
  -- 番号は削除済みの人も含めた最大＋1。再利用すると、印刷済みカードの番号が別人を指してしまう
  select count(*) filter (where deleted_at is null), coalesce(max(entry_no), 0) + 1 into v_count, v_no
  from participants where event_id = ev.id;
  if v_count >= ev.max_participants then perform mb__fail('EVENT_FULL', '参加人数の上限に達しました。運営スタッフに声をかけてください'); end if;

  v_monster := mb__pick_monster(ev.id);
  if v_monster is null then perform mb__fail('NO_MONSTERS', '配布できるモンスターが登録されていません'); end if;

  insert into participants (event_id, nickname, full_name, role, monster_id, session_token_hash, entry_no, affiliation, checked_in_at)
  values (ev.id, v_nickname, nullif(left(trim(coalesce(p_full_name, '')), 40), ''), coalesce(p_role, 'guest'), v_monster, mb__hash(v_session),
          v_no, nullif(left(trim(coalesce(p_affiliation, '')), 40), ''), case when p_checked_in then now() end)
  returning id into v_participant;
  perform mb__issue_qr(ev.id, v_participant);
  perform mb__create_card(ev, v_participant);
  return jsonb_build_object('sessionToken', v_session, 'eventCode', ev.code, 'participantId', v_participant);
end $$;

-- 獲得を記録し、該当マスを OPEN にして、ライン数を更新
create or replace function mb__grant(p_event uuid, p_receiver uuid, p_source uuid, p_monster uuid, p_encounter uuid)
returns jsonb
language plpgsql set search_path = public, extensions as $$
declare
  v_card_id uuid;
  v_before int;
  v_after int;
  v_opened int[];
  v_done boolean;
begin
  if p_monster is null then return null; end if;
  insert into monster_collections (event_id, participant_id, monster_id, source_participant_id, encounter_id)
  values (p_event, p_receiver, p_monster, p_source, p_encounter)
  on conflict (participant_id, source_participant_id) do nothing;
  if not found then return null; end if;

  select id, bingo_lines into v_card_id, v_before from bingo_cards where participant_id = p_receiver;
  if v_card_id is null then
    return jsonb_build_object('openedPositions', '[]'::jsonb, 'bingoLinesBefore', 0, 'bingoLinesAfter', 0, 'cardCompleted', false);
  end if;
  with opened as (
    update bingo_cells set opened_at = now(), opened_by_participant_id = p_source
    where card_id = v_card_id and monster_id = p_monster and opened_at is null
    returning position
  )
  select coalesce(array_agg(position order by position), '{}') into v_opened from opened;
  v_after := mb__lines(v_card_id);
  select bool_and(opened_at is not null) into v_done from bingo_cells where card_id = v_card_id;
  update bingo_cards set bingo_lines = v_after,
    first_bingo_at = coalesce(first_bingo_at, case when v_after > 0 then now() end),
    completed_at = coalesce(completed_at, case when v_done then now() end)
  where id = v_card_id;
  return jsonb_build_object('openedPositions', to_jsonb(v_opened), 'bingoLinesBefore', v_before,
                            'bingoLinesAfter', v_after, 'cardCompleted', v_done);
end $$;

create or replace function mb__fraud(p_event uuid, p_participant uuid, p_kind text, p_detail jsonb, p_once_per_minute boolean default false)
returns void language plpgsql set search_path = public, extensions as $$
begin
  if p_once_per_minute and exists (
    select 1 from fraud_logs where participant_id = p_participant and kind = p_kind and created_at > now() - interval '60 seconds'
  ) then return; end if;
  insert into fraud_logs (event_id, participant_id, kind, detail) values (p_event, p_participant, p_kind, coalesce(p_detail, '{}'));
end $$;

-- 参加者ごとの集計（ランキング・管理画面・CSV で共通の定義）
create or replace function mb__participant_stats(p_event uuid)
--   欠席の人も行としては返す（管理画面で戻せるように）。数える側で absent_at is null を付けること
returns table (id uuid, nickname text, full_name text, role text, monster_id uuid, created_at timestamptz,
               last_seen_at timestamptz, encounter_people int, species_found int, bingo_lines int, opened_cells int,
               first_bingo_at timestamptz, completed_at timestamptz,
               entry_no int, affiliation text, checked_in_at timestamptz, absent_at timestamptz, via_line boolean)
language sql stable set search_path = public, extensions as $$
  with pairs as (
    select scanner_participant_id as pid, target_participant_id as other from encounters where event_id = p_event
    union
    select target_participant_id, scanner_participant_id from encounters where event_id = p_event
  ),
  people as (select pid, count(*)::int as n from pairs group by pid),
  species as (
    select c.participant_id as pid, count(distinct c.monster_id)::int as n
    from monster_collections c join monsters m on m.id = c.monster_id
    where c.event_id = p_event and m.rarity <> 'secret' and m.is_active group by c.participant_id
  ),
  opened as (
    select b.participant_id as pid, count(*) filter (where c.opened_at is not null)::int as n
    from bingo_cards b join bingo_cells c on c.card_id = b.id where b.event_id = p_event group by b.participant_id
  )
  select p.id, p.nickname, p.full_name, p.role, p.monster_id, p.created_at, p.last_seen_at,
         coalesce(people.n, 0), coalesce(species.n, 0), coalesce(b.bingo_lines, 0), coalesce(opened.n, 0),
         b.first_bingo_at, b.completed_at, p.entry_no, p.affiliation, p.checked_in_at, p.absent_at, p.line_user_id is not null
  from participants p
  left join people on people.pid = p.id
  left join species on species.pid = p.id
  left join opened on opened.pid = p.id
  left join bingo_cards b on b.participant_id = p.id
  where p.event_id = p_event and p.deleted_at is null
  order by p.entry_no, p.created_at
$$;

-- =====================================================================
-- 参加者用の公開関数（anon キーで呼べる）
-- =====================================================================

create or replace function mb_event_public(p_code text, p_session text default null) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare ev events; me participants;
begin
  select * into ev from events where lower(code) = lower(trim(p_code));
  if ev.id is null then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;
  me := mb__participant_by_session(p_session);
  return jsonb_build_object('code', ev.code, 'name', ev.name, 'status', ev.status,
    'askFullName', ev.name_display_mode = 'full_name', 'alreadyJoined', me.event_id is not distinct from ev.id and me.id is not null);
end $$;

create or replace function mb_join(p_code text, p_nickname text, p_full_name text default null, p_agreed boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_event uuid;
begin
  if not coalesce(p_agreed, false) then perform mb__fail('TERMS_REQUIRED', '利用規約とプライバシーへの同意が必要です'); end if;
  select id into v_event from events where lower(code) = lower(trim(p_code));
  if v_event is null then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;
  return mb__join(v_event, p_nickname, p_full_name, 'guest') - 'participantId';
end $$;

-- 参加者の画面の状態。p_version に前回の version を渡すと、何も変わっていなければ {unchanged:true} だけを返す。
--   会場では全員が同じ Wi-Fi に数秒おきに問い合わせる。1回の応答の重さが人数分そのまま効くので、
--   「変わっていないなら本文を運ばない」のが通信量を減らす一番の手（HTTP の ETag/304 と同じ考え方）。
--   version には、この人の画面に出るものを変えうる値をすべて入れる。入れ忘れると「変わったのに画面が古いまま」になる。
create or replace function mb_state(p_session text, p_version text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  me participants;
  ev events;
  v_card uuid;
  v_token text;
  v_version text;
  v_announcements jsonb;
  v_monsters jsonb;
  v_cells jsonb;
  v_collection jsonb;
  v_recent jsonb;
  v_people int;
  v_species_total int;
  v_species_found int;
  v_opened int;
  v_total int;
  v_lines int;
  v_secret_left int;
begin
  me := mb__participant_by_session(p_session);
  if me.id is null then perform mb__fail('NOT_JOINED', 'まだイベントに参加していません'); end if;
  -- 欠席の人は NOT_JOINED と区別する。NOT_JOINED だと端末がログイン情報を捨ててしまい、
  -- 運営が「欠席」を取り消しても本人が戻れなくなる
  if me.absent_at is not null then perform mb__fail('ABSENT', 'いまは参加が止まっています。受付か運営スタッフに声をかけてください'); end if;
  select * into ev from events where id = me.event_id;
  if me.checked_in_at is null then
    update participants set checked_in_at = now(), last_seen_at = now() where id = me.id;
  elsif me.last_seen_at is null or me.last_seen_at < now() - interval '30 seconds' then
    -- 最終アクセスは30秒単位で十分。毎回書くと、ポーリングのたびに全員分の書き込みが走る
    update participants set last_seen_at = now() where id = me.id;
  end if;

  select token into v_token from participant_qr_tokens
  where participant_id = me.id and revoked_at is null and (expires_at is null or expires_at > now())
  order by created_at desc limit 1;
  if v_token is null then v_token := mb__issue_qr(ev.id, me.id); end if;

  select id into v_card from bingo_cards where participant_id = me.id;

  v_version := md5(concat_ws('|', ev.status, ev.updated_at, ev.exchange_paused, me.nickname, me.role, me.monster_id, v_token, v_card,
    (select count(*) || ':' || coalesce(max(created_at)::text, '') from monster_collections where participant_id = me.id),
    (select count(*) from encounters where scanner_participant_id = me.id),
    (select count(*) from encounters where target_participant_id = me.id),
    (select max(id) from announcements where event_id = ev.id),
    (select count(*) from announcements where event_id = ev.id)));
  if p_version is not null and p_version = v_version then
    return jsonb_build_object('unchanged', true, 'version', v_version);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'message', a.message, 'createdAt', a.created_at) order by a.id desc), '[]'::jsonb)
  into v_announcements
  from (select * from announcements where event_id = ev.id order by id desc limit 5) a;
  -- モンスターの中身（名前・絵文字・色…）は下の monsters に1回だけ入れ、マス・図鑑・獲得履歴からは id で指す。
  --   同じモンスターの情報を何十回も繰り返すと、全量の応答が倍以上に膨らむため
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'position', c.position,
      'monsterId', c.monster_id,
      'isFree', c.is_free,
      'isOpen', c.opened_at is not null,
      'openedByName', case when o.id is null then null else mb__display_name(ev.name_display_mode, o.nickname, o.full_name) end
    )) order by c.position), '[]'::jsonb),
    count(*) filter (where c.opened_at is not null), count(*)
  into v_cells, v_opened, v_total
  from bingo_cells c left join participants o on o.id = c.opened_by_participant_id
  where c.card_id = v_card;
  v_lines := coalesce(mb__lines(v_card), 0);

  with got as (select monster_id, count(*)::int as times from monster_collections where participant_id = me.id group by monster_id)
  select coalesce(jsonb_agg(jsonb_build_object('monsterId', m.id, 'found', got.monster_id is not null,
           'timesReceived', coalesce(got.times, 0)) order by m.rarity = 'secret', m.sort_order, m.created_at), '[]'::jsonb),
         count(*) filter (where m.id in (select mb__card_monster_ids(ev.id))),
         count(*) filter (where m.id in (select mb__card_monster_ids(ev.id)) and got.monster_id is not null)
  into v_collection, v_species_total, v_species_found
  from monsters m left join got on got.monster_id = m.id
  -- 図鑑：今回使うモンスター＋（使わないものでも）もらったことがあるもの
  where m.event_id = ev.id and (m.id in (select mb__card_monster_ids(ev.id)) or got.monster_id is not null);

  select count(*) into v_secret_left from monsters m
  where m.event_id = ev.id and m.is_active and m.rarity = 'secret'
    and not exists (select 1 from monster_collections c where c.participant_id = me.id and c.monster_id = m.id);

  select coalesce(jsonb_agg(x.item order by x.created_at desc), '[]'::jsonb) into v_recent from (
    -- 画面に出すのは直近5件。多めに12件返すのは、次の問い合わせまでに複数GETしても演出を取りこぼさないため
    select jsonb_build_object('id', c.id, 'monsterId', c.monster_id,
             'sourceName', mb__display_name(ev.name_display_mode, s.nickname, s.full_name), 'createdAt', c.created_at) as item,
           c.created_at
    from monster_collections c join participants s on s.id = c.source_participant_id
    where c.participant_id = me.id order by c.created_at desc limit 12
  ) x;

  -- 未発見の SECRET は送らない（応答を覗けば正体が分かってしまう）。数だけ undiscoveredSecretCount で返す
  select coalesce(jsonb_object_agg(m.id, mb__monster_json(m) - 'id'), '{}'::jsonb) into v_monsters
  from monsters m
  where m.event_id = ev.id
    and (m.rarity <> 'secret' or m.id = me.monster_id
         or exists (select 1 from monster_collections c where c.participant_id = me.id and c.monster_id = m.id));

  select count(distinct case when scanner_participant_id = me.id then target_participant_id else scanner_participant_id end)::int
  into v_people from encounters where scanner_participant_id = me.id or target_participant_id = me.id;

  return jsonb_build_object(
    'version', v_version,
    'event', jsonb_build_object('code', ev.code, 'name', ev.name, 'status', ev.status, 'freeCellEnabled', ev.free_cell_enabled,
       'exchangeMode', ev.exchange_mode, 'nameDisplayMode', ev.name_display_mode, 'rankingEnabled', ev.ranking_enabled,
       'rankingMetric', ev.ranking_metric, 'exchangePaused', ev.exchange_paused, 'guideImageUrl', ev.guide_image_url),
    'announcements', v_announcements,
    'me', jsonb_build_object('nickname', me.nickname, 'role', me.role, 'entryNo', me.entry_no),
    'myMonster', (select mb__monster_json(m) from monsters m where m.id = me.monster_id),
    'qrToken', v_token,
    'card', jsonb_build_object('size', 5, 'cells', v_cells),
    'stats', jsonb_build_object('speciesFound', v_species_found, 'speciesTotal', v_species_total,
       'completionRate', case when v_species_total > 0 then round(v_species_found * 100.0 / v_species_total)::int else 0 end,
       'bingoLines', v_lines, 'encounterPeople', v_people, 'openedCells', v_opened, 'totalCells', v_total,
       'cardCompleted', v_total > 0 and v_opened = v_total),
    'collection', v_collection,
    'undiscoveredSecretCount', v_secret_left,
    'recentAcquisitions', v_recent,
    'monsters', v_monsters);
end $$;

-- QR 交換。失敗しても不正ログを残すため、例外ではなく {ok:false} を返してコミットする
create or replace function mb_exchange(p_session text, p_scanned text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  me participants;
  ev events;
  target participants;
  v_token text;
  v_scanned text := left(trim(coalesce(p_scanned, '')), 500);
  v_encounter uuid;
  v_gain jsonb;
  v_partner jsonb;
  v_name text;
  v_count int;
begin
  me := mb__participant_by_session(p_session);
  if me.id is null then
    return jsonb_build_object('ok', false, 'code', 'NOT_JOINED', 'message', 'まだイベントに参加していません');
  end if;
  if me.absent_at is not null then
    return jsonb_build_object('ok', false, 'code', 'ABSENT', 'message', 'いまは参加が止まっています。受付か運営スタッフに声をかけてください');
  end if;
  select * into ev from events where id = me.event_id for update;
  if ev.status <> 'active' then
    return jsonb_build_object('ok', false, 'code', 'EVENT_NOT_ACTIVE', 'message', 'いまは交換できません（イベント開始前か終了後です）');
  end if;
  if ev.exchange_paused then
    return jsonb_build_object('ok', false, 'code', 'EXCHANGE_PAUSED', 'message', 'いまは交換をお休みしています。再開のアナウンスを待ってね');
  end if;
  if ev.exchange_cooldown_seconds > 0 and exists (
    select 1 from encounters where scanner_participant_id = me.id
      and created_at > now() - make_interval(secs => ev.exchange_cooldown_seconds)
  ) then
    return jsonb_build_object('ok', false, 'code', 'TOO_FAST', 'message', 'ちょっと待ってね。少し時間をあけてから読み込もう');
  end if;

  -- QR の中身は …?x=<token> / …/x/<token> / トークン単体 のどれでも受け付ける
  v_token := coalesce(substring(v_scanned from '[?&]x=([A-Za-z0-9_-]{10,64})'),
                      substring(v_scanned from '/x/([A-Za-z0-9_-]{10,64})'),
                      substring(v_scanned from '^([A-Za-z0-9_-]{10,64})$'));
  select p.* into target from participant_qr_tokens t join participants p on p.id = t.participant_id
  where t.token = v_token and t.event_id = ev.id and t.revoked_at is null
    and (t.expires_at is null or t.expires_at > now()) and p.deleted_at is null;
  if target.id is null then
    perform mb__fraud(ev.id, me.id, 'INVALID_TOKEN', jsonb_build_object('scannedPrefix', left(v_scanned, 40)));
    return jsonb_build_object('ok', false, 'code', 'INVALID_QR', 'message', 'このQRコードは使えません。相手の MONSTER BINGO の画面を読み取ってね');
  end if;
  if target.id = me.id then
    perform mb__fraud(ev.id, me.id, 'SELF_SCAN', '{}');
    return jsonb_build_object('ok', false, 'code', 'SELF_SCAN', 'message', '自分のQRコードは読み込めません');
  end if;
  -- 欠席扱いの人のQR。本人の落ち度ではない（受付の操作ミスもありうる）ので不正ログには残さない
  if target.absent_at is not null then
    return jsonb_build_object('ok', false, 'code', 'TARGET_ABSENT', 'message', 'この人はいま参加が止まっています。運営スタッフに声をかけてください');
  end if;
  if exists (select 1 from monster_collections where participant_id = me.id and source_participant_id = target.id) then
    v_name := mb__display_name(ev.name_display_mode, target.nickname, target.full_name);
    return jsonb_build_object('ok', false, 'code', 'ALREADY_EXCHANGED',
      'message', coalesce(v_name || 'さんとは', 'この人とは') || '交換済み！別の人に話しかけてみよう');
  end if;
  if target.monster_id is null then
    return jsonb_build_object('ok', false, 'code', 'INVALID_QR', 'message', '相手にモンスターがいないようです。運営スタッフに声をかけてください');
  end if;

  insert into encounters (event_id, scanner_participant_id, target_participant_id, exchange_mode, scanner_received_monster_id)
  values (ev.id, me.id, target.id, ev.exchange_mode, target.monster_id) returning id into v_encounter;
  v_gain := mb__grant(ev.id, me.id, target.id, target.monster_id, v_encounter);
  if ev.exchange_mode = 'both' then
    v_partner := mb__grant(ev.id, target.id, me.id, me.monster_id, v_encounter);
    if v_partner is not null then
      update encounters set target_received_monster_id = me.monster_id where id = v_encounter;
    end if;
  end if;

  -- 不正の疑い：1分に10人超をスキャン／同じ人が5分で12人超にスキャンされた（QRスクショ共有）
  select count(*) into v_count from encounters where scanner_participant_id = me.id and created_at > now() - interval '60 seconds';
  if v_count > 10 then perform mb__fraud(ev.id, me.id, 'RAPID_SCANS', jsonb_build_object('scansInLastMinute', v_count), true); end if;
  select count(distinct scanner_participant_id) into v_count from encounters
  where target_participant_id = target.id and created_at > now() - interval '5 minutes';
  if v_count > 12 then perform mb__fraud(ev.id, target.id, 'QR_SHARED_SUSPECT', jsonb_build_object('scannedByInFiveMinutes', v_count), true); end if;

  return jsonb_build_object('ok', true,
    'received', jsonb_build_object(
      'monster', (select mb__monster_json(m) from monsters m where m.id = target.monster_id),
      'sourceName', mb__display_name(ev.name_display_mode, target.nickname, target.full_name)) || v_gain,
    'partnerAlsoReceived', v_partner is not null);
end $$;

create or replace function mb_ranking(p_code text, p_session text default null) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare ev events; me participants; v_total int; v_entries jsonb; v_me jsonb;
begin
  select * into ev from events where lower(code) = lower(trim(p_code));
  if ev.id is null then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;
  if not ev.ranking_enabled then
    return jsonb_build_object('enabled', false, 'metric', ev.ranking_metric, 'entries', '[]'::jsonb, 'myEntry', null);
  end if;
  me := mb__participant_by_session(p_session);
  select count(*) into v_total from mb__card_monster_ids(ev.id);
  with s as (
    select st.*, case ev.ranking_metric
      when 'encounters' then st.encounter_people
      when 'bingo' then st.bingo_lines
      when 'completion' then case when v_total > 0 then least(100, round(st.species_found * 100.0 / v_total))::int else 0 end
      else st.species_found end as value
    from mb__participant_stats(ev.id) st where st.role = 'guest' and st.absent_at is null
  ), r as (
    select rank() over (order by value desc) as rank, value, species_found,
      case when ev.name_display_mode = 'hidden' then left(nickname, 1) || '***'
           else mb__display_name(ev.name_display_mode, nickname, full_name) end as name,
      id = me.id as is_me
    from s
  )
  select (select coalesce(jsonb_agg(jsonb_build_object('rank', rank, 'name', name, 'value', value, 'isMe', coalesce(is_me, false))
                  order by rank, species_found desc), '[]'::jsonb) from (select * from r order by rank, species_found desc limit 30) top),
         (select jsonb_build_object('rank', rank, 'name', name, 'value', value, 'isMe', true) from r where is_me)
  into v_entries, v_me;
  return jsonb_build_object('enabled', true, 'metric', ev.ranking_metric, 'entries', v_entries, 'myEntry', v_me);
end $$;

-- 受付カードのQRが読めない時の入口：受付番号＋4桁PIN
--   4桁は1万通りしかない。番号ごとに15分で5回、イベント全体で15分に50回失敗したら止める。
--   全体の上限が無いと、PIN を固定して番号を総当たりする攻撃で、1人くらいは当たってしまう
create or replace function mb_login_pin(p_code text, p_entry_no int, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ev events; p participants; v_session text; v_fails int;
begin
  select * into ev from events where lower(code) = lower(trim(coalesce(p_code, '')));
  if ev.id is null then return jsonb_build_object('ok', false, 'message', 'イベントコードが見つかりません'); end if;
  if (select count(*) from pin_login_failures where event_id = ev.id and created_at > now() - interval '15 minutes') >= 50 then
    return jsonb_build_object('ok', false, 'message', 'いまは番号での入場を止めています。受付で声をかけてください');
  end if;
  if (select count(*) from pin_login_failures where event_id = ev.id and entry_no = p_entry_no and created_at > now() - interval '15 minutes') >= 5 then
    return jsonb_build_object('ok', false, 'message', '入力ミスが続いたため、この番号は15分間ログインできません。受付で声をかけてください');
  end if;
  select * into p from participants where event_id = ev.id and entry_no = p_entry_no and deleted_at is null;
  if p.id is null or p.pin_hash is null or p.pin_hash <> mb__hash(p.id::text || ':' || trim(coalesce(p_pin, ''))) then
    insert into pin_login_failures (event_id, entry_no) values (ev.id, p_entry_no);
    select count(*) into v_fails from pin_login_failures where event_id = ev.id and entry_no = p_entry_no and created_at > now() - interval '15 minutes';
    if v_fails = 5 and p.id is not null then perform mb__fraud(ev.id, p.id, 'PIN_LOCKED', jsonb_build_object('entryNo', p_entry_no)); end if;
    perform pg_sleep(0.3);
    return jsonb_build_object('ok', false, 'message', '番号かPINが違います');
  end if;
  if p.absent_at is not null then
    return jsonb_build_object('ok', false, 'message', 'いまは参加が止まっています。受付で声をかけてください');
  end if;
  -- ログイン情報を作り直す（前の端末とカードのQRは使えなくなる。1人1台が前提なので問題ない）
  v_session := mb__token(32);
  update participants set session_token_hash = mb__hash(v_session) where id = p.id;
  return jsonb_build_object('ok', true, 'sessionToken', v_session, 'eventCode', ev.code);
end $$;

-- LINEログイン。ブラウザからは呼べない（service_role 専用）。
--   呼ぶのは Supabase Edge Function「mb-line-login」だけで、そこで LINE の IDトークンを LINE のサーバーに照合してから
--   確かめ済みの sub（LINE の利用者ID）と表示名を渡す。ブラウザが sub を名乗れると、他人になりすませてしまうため。
--   戻り値：{ok:true, sessionToken, eventCode, isNew} ／ 初回でニックネーム未確定なら {ok:false, code:'NEED_PROFILE', suggestedName}
create or replace function mb_line_login(p_code text, p_line_sub text, p_line_name text, p_nickname text default null, p_agreed boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ev events; p participants; v_session text; v_joined jsonb;
begin
  if coalesce(p_line_sub, '') !~ '^U[0-9a-f]{32}$' then perform mb__fail('BAD_LINE_USER', 'LINEの利用者IDが正しくありません'); end if;
  select * into ev from events where lower(code) = lower(trim(coalesce(p_code, '')));
  if ev.id is null then return jsonb_build_object('ok', false, 'code', 'EVENT_NOT_FOUND', 'message', 'イベントが見つかりません'); end if;
  select * into p from participants where event_id = ev.id and line_user_id = p_line_sub and deleted_at is null;
  if p.id is not null then
    if p.absent_at is not null then
      return jsonb_build_object('ok', false, 'code', 'ABSENT', 'message', 'いまは参加が止まっています。受付か運営スタッフに声をかけてください');
    end if;
    -- 2回目以降：ログイン情報を作り直して返す（前の端末はログアウト。1人1台の前提）
    v_session := mb__token(32);
    update participants set session_token_hash = mb__hash(v_session), checked_in_at = coalesce(checked_in_at, now()) where id = p.id;
    return jsonb_build_object('ok', true, 'sessionToken', v_session, 'eventCode', ev.code, 'isNew', false);
  end if;
  if ev.status = 'ended' then return jsonb_build_object('ok', false, 'code', 'EVENT_ENDED', 'message', 'このイベントは終了しました'); end if;
  -- 初回：ニックネームの確認画面を出してもらう（LINE名を初期値に）
  if nullif(trim(coalesce(p_nickname, '')), '') is null then
    return jsonb_build_object('ok', false, 'code', 'NEED_PROFILE', 'eventName', ev.name, 'suggestedName', left(trim(coalesce(p_line_name, '')), 20));
  end if;
  if not coalesce(p_agreed, false) then perform mb__fail('TERMS_REQUIRED', '利用規約とプライバシーへの同意が必要です'); end if;
  v_joined := mb__join(ev.id, p_nickname, null, 'guest', null, true);
  update participants set line_user_id = p_line_sub where id = (v_joined->>'participantId')::uuid;
  return jsonb_build_object('ok', true, 'sessionToken', v_joined->>'sessionToken', 'eventCode', ev.code, 'isNew', true);
end $$;

-- =====================================================================
-- 管理者用の公開関数（ログインで得たトークン必須）
-- =====================================================================

create or replace function mb_admin_login(p_email text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_email text := lower(trim(coalesce(p_email, ''))); v_admin admins; v_token text;
begin
  if (select count(*) from admin_login_failures where email = v_email and created_at > now() - interval '15 minutes') >= 10 then
    return jsonb_build_object('ok', false, 'message', 'ログイン失敗が続いたため15分間ロックしています');
  end if;
  select * into v_admin from admins where email = v_email;
  if v_admin.id is null or crypt(coalesce(p_password, ''), v_admin.password_hash) <> v_admin.password_hash then
    insert into admin_login_failures (email) values (v_email);
    perform pg_sleep(0.4);
    return jsonb_build_object('ok', false, 'message', 'メールアドレスかパスワードが違います');
  end if;
  delete from admin_sessions where expires_at < now();
  v_token := mb__token(32);
  insert into admin_sessions (token_hash, admin_id, expires_at) values (mb__hash(v_token), v_admin.id, now() + interval '7 days');
  return jsonb_build_object('ok', true, 'token', v_token);
end $$;

create or replace function mb_admin_logout(p_admin_token text) returns jsonb
language sql security definer set search_path = public, extensions as $$
  delete from admin_sessions where token_hash = mb__hash(p_admin_token);
  select jsonb_build_object('ok', true);
$$;

create or replace function mb_admin_events(p_admin_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform mb__require_admin(p_admin_token);
  return (select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object('participant_count',
      (select count(*) from participants p where p.event_id = e.id and p.deleted_at is null and p.absent_at is null)) order by e.created_at desc), '[]'::jsonb)
    from events e);
end $$;

create or replace function mb_admin_create_event(p_admin_token text, p_name text, p_code text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_code text := upper(trim(coalesce(p_code, ''))); ev events;
begin
  perform mb__require_admin(p_admin_token);
  if trim(coalesce(p_name, '')) = '' then perform mb__fail('NAME_REQUIRED', 'イベント名を入力してください'); end if;
  if v_code = '' then
    loop
      v_code := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') from generate_series(1, 6));
      exit when not exists (select 1 from events where lower(code) = lower(v_code));
    end loop;
  elsif v_code !~ '^[A-Z0-9-]{3,20}$' then
    perform mb__fail('INVALID_CODE', 'イベントコードは英数字とハイフン3〜20文字にしてください');
  elsif exists (select 1 from events where lower(code) = lower(v_code)) then
    perform mb__fail('CODE_TAKEN', 'そのイベントコードは使われています');
  end if;
  insert into events (name, code) values (trim(p_name), v_code) returning * into ev;
  insert into monsters (event_id, name, emoji, color, sort_order)
  select ev.id, d.name, d.emoji, d.color, d.ord - 1 from (values
    ('ゴースト','👻','#8b7cf6',1),('ヴァンパイア','🧛‍♀️','#e5484d',2),('ドラキュラ','🧛‍♂️','#b4235a',3),('ゾンビ','🧟','#3fa56b',4),
    ('ミイラ','🤕','#c9a36b',5),('魔女','🧙‍♀️','#8b4dff',6),('フランケン','🧌','#4c9a5e',7),('狼男','🐺','#6b7a99',8),
    ('パンプキン','🎃','#ff7a1a',9),('死神','☠️','#4a4560',10),('悪魔','😈','#c2255c',11),('黒猫','🐈‍⬛','#3b3552',12),
    ('スケルトン','💀','#9aa0b5',13),('一つ目','👁️','#2f9e9e',14),('コウモリ','🦇','#5b3fa8',15),('クモ','🕷️','#555066',16),
    ('エイリアン','👽','#57b84a',17),('天狗','👺','#d9480f',18),('鬼','👹','#c92a2a',19),('ピエロ','🤡','#e8590c',20),
    ('ドラゴン','🐉','#2b8a3e',21),('フクロウ','🦉','#a0703c',22),('呪いのロウソク','🕯️','#f59f00',23),('毒リンゴ','🍎','#a61e4d',24)
  ) as d(name, emoji, color, ord);
  return to_jsonb(ev);
end $$;

create or replace function mb_admin_dashboard(p_admin_token text, p_event_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ev events; v_result jsonb;
begin
  perform mb__require_admin(p_admin_token);
  select * into ev from events where id = p_event_id;
  if ev.id is null then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;
  -- 人数は「当日いる人」（入場済み・欠席でない）で数え、登録数とは分けて返す。
  --   登録数を「参加者」と出すと、実際に交換できる人数と食い違い「誰か隠れているのでは」と受け取られる
  with st as (select * from mb__participant_stats(ev.id)),
       here as (select * from st where absent_at is null and checked_in_at is not null)
  select jsonb_build_object(
    'event', to_jsonb(ev),
    'speciesTotal', (select count(*) from mb__card_monster_ids(ev.id)),
    'pool', mb__pool_status(ev.id),
    'totals', jsonb_build_object(
      'participants', (select count(*) from here),
      'registered', (select count(*) from st),
      'absent', (select count(*) from st where absent_at is not null),
      'waiting', (select count(*) from st where absent_at is null and checked_in_at is null),
      'encounters', (select count(*) from encounters where event_id = ev.id),
      'averageEncounterPeople', coalesce((select round(avg(encounter_people)::numeric, 1) from here), 0),
      'bingoAchievers', (select count(*) from here where bingo_lines > 0),
      'cardCompleters', (select count(*) from here where completed_at is not null),
      'fraudLogs', (select count(*) from fraud_logs where event_id = ev.id)),
    'monsters', (select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('assigned_count',
        (select count(*) from participants p where p.monster_id = m.id and p.deleted_at is null and p.absent_at is null)) order by m.sort_order, m.created_at), '[]'::jsonb)
      from monsters m where m.event_id = ev.id),
    'notYetInteracted', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nickname', nickname, 'entryNo', entry_no, 'role', role,
        'encounterPeople', encounter_people, 'joinedAt', checked_in_at) order by checked_in_at), '[]'::jsonb) from here where encounter_people = 0),
    'fewInteractions', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nickname', nickname, 'entryNo', entry_no, 'role', role,
        'encounterPeople', encounter_people, 'joinedAt', checked_in_at) order by encounter_people, checked_in_at), '[]'::jsonb)
      from here where encounter_people between 1 and 2 and checked_in_at < now() - interval '10 minutes'),
    'announcements', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'message', a.message, 'createdAt', a.created_at) order by a.id desc), '[]'::jsonb)
      from (select * from announcements where event_id = ev.id order by id desc limit 5) a)
  ) into v_result;
  return v_result;
end $$;

create or replace function mb_admin_update_event(p_admin_token text, p_event_id uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ev events; v_guide text := nullif(trim(coalesce(p_patch->>'guide_image_url', '')), '');
begin
  perform mb__require_admin(p_admin_token);
  if v_guide is not null and v_guide !~ '^https://' then perform mb__fail('INVALID_IMAGE_URL', 'ガイド画像のURLは https:// で始まるURLにしてください'); end if;
  update events set
    updated_at = now(),
    exchange_paused = coalesce((p_patch->>'exchange_paused')::boolean, exchange_paused),
    guide_image_url = case when p_patch ? 'guide_image_url' then v_guide else guide_image_url end,
    name = coalesce(nullif(trim(p_patch->>'name'), ''), name),
    status = coalesce(p_patch->>'status', status),
    free_cell_enabled = coalesce((p_patch->>'free_cell_enabled')::boolean, free_cell_enabled),
    exchange_mode = coalesce(p_patch->>'exchange_mode', exchange_mode),
    name_display_mode = coalesce(p_patch->>'name_display_mode', name_display_mode),
    ranking_enabled = coalesce((p_patch->>'ranking_enabled')::boolean, ranking_enabled),
    ranking_metric = coalesce(p_patch->>'ranking_metric', ranking_metric),
    exchange_cooldown_seconds = coalesce((p_patch->>'exchange_cooldown_seconds')::int, exchange_cooldown_seconds),
    max_participants = coalesce((p_patch->>'max_participants')::int, max_participants)
  where id = p_event_id returning * into ev;
  if ev.id is null then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;
  return to_jsonb(ev);
end $$;

create or replace function mb_admin_save_monster(p_admin_token text, p_event_id uuid, p_monster_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m monsters; v_image text := nullif(trim(p_data->>'image_url'), '');
begin
  perform mb__require_admin(p_admin_token);
  if v_image is not null and v_image !~ '^https://' then perform mb__fail('INVALID_IMAGE_URL', '画像URLは https:// で始まるURLにしてください'); end if;
  if (p_data ? 'color') and (p_data->>'color') !~ '^#[0-9a-fA-F]{6}$' then perform mb__fail('INVALID_COLOR', '色は #RRGGBB で指定してください'); end if;
  if p_monster_id is null then
    if trim(coalesce(p_data->>'name', '')) = '' then perform mb__fail('NAME_REQUIRED', 'モンスター名を入力してください'); end if;
    -- 使うモンスターを制限している最中に足したモンスターは、制限をかけ直すまで使わない（勝手にカードへ混ざらないように）
    insert into monsters (event_id, name, emoji, image_url, color, rarity, sort_order, in_pool)
    values (p_event_id, trim(p_data->>'name'), coalesce(nullif(trim(p_data->>'emoji'), ''), '👻'), v_image,
            coalesce(p_data->>'color', '#ff7a1a'), coalesce(p_data->>'rarity', 'normal'),
            (select coalesce(max(sort_order), -1) + 1 from monsters where event_id = p_event_id),
            (select monster_pool_size is null from events where id = p_event_id))
    returning * into m;
  else
    update monsters set
      name = coalesce(nullif(trim(p_data->>'name'), ''), name),
      emoji = coalesce(nullif(trim(p_data->>'emoji'), ''), emoji),
      image_url = case when p_data ? 'image_url' then v_image else image_url end,
      color = coalesce(p_data->>'color', color),
      rarity = coalesce(p_data->>'rarity', rarity),
      is_active = coalesce((p_data->>'is_active')::boolean, is_active)
    where id = p_monster_id and event_id = p_event_id returning * into m;
  end if;
  -- 名前や絵文字の変更を参加者の画面に届けるため（差分応答の version が変わるように）
  update events set updated_at = now() where id = p_event_id;
  return to_jsonb(m);
end $$;

-- 使われていれば無効化のみ（履歴を壊さない）、未使用なら削除
create or replace function mb_admin_delete_monster(p_admin_token text, p_event_id uuid, p_monster_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform mb__require_admin(p_admin_token);
  update events set updated_at = now() where id = p_event_id;
  if exists (select 1 from participants where monster_id = p_monster_id)
     or exists (select 1 from bingo_cells where monster_id = p_monster_id)
     or exists (select 1 from monster_collections where monster_id = p_monster_id) then
    update monsters set is_active = false where id = p_monster_id and event_id = p_event_id;
    return jsonb_build_object('result', 'deactivated');
  end if;
  delete from monsters where id = p_monster_id and event_id = p_event_id;
  return jsonb_build_object('result', 'deleted');
end $$;

create or replace function mb_admin_participants(p_admin_token text, p_event_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform mb__require_admin(p_admin_token);
  return (select coalesce(jsonb_agg(to_jsonb(st) || jsonb_build_object(
      'monster_name', m.name, 'monster_emoji', m.emoji, 'monster_rarity', m.rarity) order by st.entry_no), '[]'::jsonb)
    from mb__participant_stats(p_event_id) st left join monsters m on m.id = st.monster_id);
end $$;

-- 運営が1人追加する。まだ来ていない扱い（入場はその人が初めてアプリを開いた時刻）
create or replace function mb_admin_add_participant(p_admin_token text, p_event_id uuid, p_nickname text, p_role text default 'staff',
                                                    p_monster_id uuid default null, p_affiliation text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_joined jsonb;
begin
  perform mb__require_admin(p_admin_token);
  v_joined := mb__join(p_event_id, p_nickname, null, coalesce(p_role, 'staff'), p_affiliation, false);
  if p_monster_id is not null then
    if not exists (select 1 from monsters where id = p_monster_id and event_id = p_event_id) then
      perform mb__fail('INVALID_MONSTER', 'モンスターが見つかりません');
    end if;
    update participants set monster_id = p_monster_id where id = (v_joined->>'participantId')::uuid;
  end if;
  return v_joined;
end $$;

create or replace function mb_admin_update_participant(p_admin_token text, p_event_id uuid, p_participant_id uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform mb__require_admin(p_admin_token);
  if (p_patch ? 'monster_id') and nullif(p_patch->>'monster_id', '') is not null
     and not exists (select 1 from monsters where id = (p_patch->>'monster_id')::uuid and event_id = p_event_id) then
    perform mb__fail('INVALID_MONSTER', 'モンスターが見つかりません');
  end if;
  update participants set
    nickname = coalesce(nullif(left(trim(p_patch->>'nickname'), 20), ''), nickname),
    full_name = case when p_patch ? 'full_name' then nullif(left(trim(p_patch->>'full_name'), 40), '') else full_name end,
    affiliation = case when p_patch ? 'affiliation' then nullif(left(trim(p_patch->>'affiliation'), 40), '') else affiliation end,
    role = coalesce(p_patch->>'role', role),
    monster_id = case when p_patch ? 'monster_id' then nullif(p_patch->>'monster_id', '')::uuid else monster_id end,
    -- 欠席は時刻で持つ。false で戻せる（行は消さない）
    absent_at = case when p_patch ? 'absent' then case when (p_patch->>'absent')::boolean then coalesce(absent_at, now()) end else absent_at end,
    -- 入場の取り消し（受付のやり直し）。本人が次にアプリを開くと、また入場済みになる
    checked_in_at = case when (p_patch->>'checked_in') = 'false' then null else checked_in_at end
  where id = p_participant_id and event_id = p_event_id;
  if not found then perform mb__fail('PARTICIPANT_NOT_FOUND', '参加者が見つかりません'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 名簿の一括登録・一括更新。
--   no がある行 → その受付番号の人を更新（名前の聞き間違い・所属の差し替え）
--   no が無い行 → 新しく登録（まだ来ていない扱い）
--   当日データベースを直接触らずに済むように、管理画面から貼り付けで流せる形にしている
create or replace function mb_admin_import(p_admin_token text, p_event_id uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; v_added int := 0; v_updated int := 0; v_errors jsonb := '[]'::jsonb; v_line int := 0; v_no int; v_role text;
begin
  perform mb__require_admin(p_admin_token);
  if jsonb_typeof(p_rows) <> 'array' then perform mb__fail('BAD_ROWS', '取り込むデータの形が正しくありません'); end if;
  if jsonb_array_length(p_rows) > 1000 then perform mb__fail('TOO_MANY_ROWS', '一度に取り込めるのは1000行までです'); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_line := v_line + 1;
    v_role := nullif(r->>'role', '');
    if v_role is not null and v_role not in ('guest','staff','organizer','sponsor','vip') then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'message', '役割が読めません: ' || v_role);
      continue;
    end if;
    v_no := nullif(r->>'no', '')::int;
    if v_no is not null then
      update participants set
        nickname = coalesce(nullif(left(trim(r->>'nickname'), 20), ''), nickname),
        affiliation = case when r ? 'affiliation' then nullif(left(trim(r->>'affiliation'), 40), '') else affiliation end,
        role = coalesce(v_role, role)
      where event_id = p_event_id and entry_no = v_no and deleted_at is null;
      if found then v_updated := v_updated + 1;
      else v_errors := v_errors || jsonb_build_object('line', v_line, 'message', 'No.' || v_no || ' の人がいません');
      end if;
    elsif trim(coalesce(r->>'nickname', '')) = '' then
      v_errors := v_errors || jsonb_build_object('line', v_line, 'message', '名前が空です');
    else
      perform mb__join(p_event_id, r->>'nickname', null, coalesce(v_role, 'guest'), r->>'affiliation', false);
      v_added := v_added + 1;
    end if;
  end loop;
  return jsonb_build_object('added', v_added, 'updated', v_updated, 'errors', v_errors);
end $$;

-- 受付カード用のログイン情報（QR＝本人としてログインできるURL、番号＋4桁PIN）を発行する。
--   ログイン情報は作り直すので、すでにその人が使っているスマホはログアウトされる（管理画面で確認を出す）。
--   平文のPINとトークンはこの応答にしか出ない（DBにはハッシュだけ）。印刷したら画面を閉じる運用にする
--   p_participant_ids は JSON の配列（["uuid", ...]）。uuid[] にしないのは、ブラウザからの受け渡しで型の解釈が揺れないように
create or replace function mb_admin_issue_logins(p_admin_token text, p_event_id uuid, p_participant_ids jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_session text; v_pin text; v_out jsonb := '[]'::jsonb; v_ids uuid[];
begin
  perform mb__require_admin(p_admin_token);
  if jsonb_typeof(p_participant_ids) is distinct from 'array' then perform mb__fail('BAD_IDS', '発行する参加者の指定が正しくありません'); end if;
  select coalesce(array_agg(x::uuid), '{}') into v_ids from jsonb_array_elements_text(p_participant_ids) x;
  if array_length(v_ids, 1) > 500 then perform mb__fail('TOO_MANY', '一度に発行できるのは500人までです'); end if;
  for r in
    select p.*, m.name as monster_name, m.emoji as monster_emoji from participants p left join monsters m on m.id = p.monster_id
    where p.event_id = p_event_id and p.id = any(v_ids) and p.deleted_at is null
    order by p.entry_no
  loop
    -- カード用は24バイト（192bit・英数32文字）。32バイトより URL が短くなり、QR の升目が一回り大きくなる
    --   （薄いコピーでも読める率が上がる。推測されにくさは24バイトで十分）
    v_session := mb__token(24);
    -- 乱数は暗号用の gen_random_bytes から作る（random() は予測されうる）
    v_pin := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 10000)::text, 4, '0');
    update participants set session_token_hash = mb__hash(v_session), pin_hash = mb__hash(r.id::text || ':' || v_pin) where id = r.id;
    v_out := v_out || jsonb_build_object('id', r.id, 'entryNo', r.entry_no, 'nickname', r.nickname, 'affiliation', r.affiliation,
      'role', r.role, 'monsterName', r.monster_name, 'monsterEmoji', r.monster_emoji, 'sessionToken', v_session, 'pin', v_pin,
      'wasCheckedIn', r.checked_in_at is not null);
  end loop;
  return v_out;
end $$;

-- 全体へのお知らせ。古いものは20件を超えたら消す（参加者の画面には直近5件だけ）
create or replace function mb_admin_announce(p_admin_token text, p_event_id uuid, p_message text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_message text := left(trim(coalesce(p_message, '')), 200);
begin
  perform mb__require_admin(p_admin_token);
  if v_message = '' then perform mb__fail('MESSAGE_REQUIRED', 'お知らせの本文を入力してください'); end if;
  if not exists (select 1 from events where id = p_event_id) then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;
  insert into announcements (event_id, message) values (p_event_id, v_message);
  delete from announcements where event_id = p_event_id
    and id not in (select id from announcements where event_id = p_event_id order by id desc limit 20);
  return jsonb_build_object('ok', true);
end $$;

create or replace function mb_admin_delete_announcement(p_admin_token text, p_event_id uuid, p_announcement_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform mb__require_admin(p_admin_token);
  delete from announcements where id = p_announcement_id and event_id = p_event_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function mb_admin_remove_participant(p_admin_token text, p_event_id uuid, p_participant_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform mb__require_admin(p_admin_token);
  update participants set deleted_at = now() where id = p_participant_id and event_id = p_event_id;
  update participant_qr_tokens set revoked_at = now() where participant_id = p_participant_id and revoked_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- スクショ共有が疑われる時：古いQRを無効化して新しいQRを発行
create or replace function mb_admin_rotate_qr(p_admin_token text, p_event_id uuid, p_participant_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform mb__require_admin(p_admin_token);
  update participant_qr_tokens set revoked_at = now()
  where participant_id = p_participant_id and event_id = p_event_id and revoked_at is null;
  return jsonb_build_object('ok', true, 'token', mb__issue_qr(p_event_id, p_participant_id));
end $$;

create or replace function mb_admin_encounters(p_admin_token text, p_event_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform mb__require_admin(p_admin_token);
  return (select coalesce(jsonb_agg(row_to_json(x) order by x.created_at desc), '[]'::jsonb) from (
    select e.id, e.created_at, e.exchange_mode, s.nickname as scanner_nickname, t.nickname as target_nickname,
           sm.name as scanner_received_monster, tm.name as target_received_monster
    from encounters e
    join participants s on s.id = e.scanner_participant_id
    join participants t on t.id = e.target_participant_id
    left join monsters sm on sm.id = e.scanner_received_monster_id
    left join monsters tm on tm.id = e.target_received_monster_id
    where e.event_id = p_event_id order by e.created_at desc limit 300) x);
end $$;

create or replace function mb_admin_fraud_logs(p_admin_token text, p_event_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform mb__require_admin(p_admin_token);
  return (select coalesce(jsonb_agg(row_to_json(x) order by x.created_at desc), '[]'::jsonb) from (
    select f.id, f.kind, f.detail, f.created_at, f.participant_id, p.nickname
    from fraud_logs f left join participants p on p.id = f.participant_id
    where f.event_id = p_event_id order by f.created_at desc limit 300) x);
end $$;

-- 使うモンスターの状況（管理画面用）。
--   here = 当日いる人（入場済み・欠席でない）。unheld = カードの未開放マスに載っているのに、いる人が誰も持っていないモンスター
--   （そのマスは誰とも交換できず開かない＝ビンゴできない原因）
create or replace function mb__pool_status(p_event uuid) returns jsonb
language sql stable set search_path = public, extensions as $$
  with here as (
    select * from participants where event_id = p_event and deleted_at is null and absent_at is null and checked_in_at is not null
  ),
  normal_total as (select count(*)::int as n from monsters where event_id = p_event and is_active and rarity = 'normal'),
  unheld as (
    select m.id, m.name, m.emoji from monsters m
    where m.id in (select mb__card_monster_ids(p_event))
      and not exists (select 1 from here h where h.monster_id = m.id)
      and exists (select 1 from bingo_cells c join bingo_cards b on b.id = c.card_id
                  join participants p on p.id = b.participant_id and p.deleted_at is null and p.absent_at is null
                  where b.event_id = p_event and c.monster_id = m.id and c.opened_at is null)
  )
  select jsonb_build_object(
    'poolSize', (select monster_pool_size from events where id = p_event),
    'normalTotal', (select n from normal_total),
    'inPlay', (select count(*) from mb__card_monster_ids(p_event)),
    'present', (select count(*) from here),
    'recommended', (select case when count(*) > 0 then least((select n from normal_total), count(*))::int end from here),
    'unheld', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'emoji', emoji) order by name), '[]'::jsonb) from unheld))
$$;

-- 使うモンスターを N 種類に制限する（p_size が null なら制限を外して全種類に戻す）。
--   1) 残す N 種類は「今いる人が多く持っているもの」から選ぶ（配り直す人をなるべく少なくするため）。RARE はいる人が持っていれば使う
--   2) 使わないモンスターを持っている人のうち、まだ一度も交換していない人だけ、使うモンスターに配り直す
--      （交換済みの人のモンスターを変えると、相手の図鑑や本人の画面と食い違うので変えない）
--   3) 使うモンスターなのに、いる人が誰も持っていないものがあれば、交換前で同じモンスターを2人以上が持っている人から回す
--   4) 全員のカードの「まだ開いていないマス」のうち、使わないモンスターのマスを使うモンスターに差し替える。
--      開いたマス・ビンゴ数はそのまま（進んでいる人の成果を消さない）。すでにもらったモンスターになったマスはその場で開く
create or replace function mb_admin_set_monster_pool(p_admin_token text, p_event_id uuid, p_size integer) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  ev events;
  v_normal int;
  v_n int;
  v_reassigned int := 0;
  v_cells int := 0;
  v_cards int := 0;
  r record;
  c record;
  v_pool uuid[];
  v_on_card uuid[];
  v_got uuid[];
  v_pick uuid;
  v_changed boolean;
  v_layout uuid[];
  v_hash text;
  v_after int;
  v_done boolean;
begin
  perform mb__require_admin(p_admin_token);
  select * into ev from events where id = p_event_id for update;
  if ev.id is null then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;

  if p_size is null then
    update monsters set in_pool = true where event_id = ev.id;
    update events set monster_pool_size = null, updated_at = now() where id = ev.id;
    return jsonb_build_object('ok', true, 'poolSize', null, 'reassigned', 0, 'cardsChanged', 0, 'cellsChanged', 0,
                              'pool', mb__pool_status(ev.id));
  end if;

  select count(*) into v_normal from monsters where event_id = ev.id and is_active and rarity = 'normal';
  if v_normal = 0 then perform mb__fail('NO_MONSTERS', '使える通常モンスターがありません'); end if;
  if p_size < 1 then perform mb__fail('INVALID_POOL_SIZE', '使うモンスターは1種類以上にしてください'); end if;
  v_n := least(p_size, v_normal);

  -- 1) 残すモンスターを決める
  with ranked as (
    select m.id, row_number() over (order by
      (select count(*) from participants p where p.monster_id = m.id and p.deleted_at is null and p.absent_at is null and p.checked_in_at is not null) desc,
      (select count(*) from participants p where p.monster_id = m.id and p.deleted_at is null and p.absent_at is null) desc,
      m.sort_order, m.created_at) as rk
    from monsters m where m.event_id = ev.id and m.is_active and m.rarity = 'normal'
  )
  update monsters m set in_pool = case
      when m.rarity = 'normal' then coalesce((select rk <= v_n from ranked where ranked.id = m.id), false)
      when m.rarity = 'rare' then exists (select 1 from participants p where p.monster_id = m.id and p.deleted_at is null
                                          and p.absent_at is null and p.checked_in_at is not null)
      else m.in_pool end
  where m.event_id = ev.id;
  update events set monster_pool_size = v_n, updated_at = now() where id = ev.id returning * into ev;

  -- 2) 使わないモンスターを持つ、交換前の人を配り直す（いる人から先に。均等配布の偏りを当日いる人で整えるため）
  for r in
    select p.id from participants p join monsters m on m.id = p.monster_id
    where p.event_id = ev.id and p.deleted_at is null and p.absent_at is null and m.rarity = 'normal'
      and m.id not in (select mb__card_monster_ids(ev.id))
      and not exists (select 1 from encounters e where e.scanner_participant_id = p.id or e.target_participant_id = p.id)
    order by p.checked_in_at nulls last, p.entry_no
  loop
    update participants set monster_id = mb__pick_monster(ev.id) where id = r.id;
    v_reassigned := v_reassigned + 1;
  end loop;

  -- 3) 誰も持っていない使うモンスターを、ダブっている交換前の人から回す
  for r in
    select m.id from monsters m
    where m.event_id = ev.id and m.rarity = 'normal' and m.id in (select mb__card_monster_ids(ev.id))
      and not exists (select 1 from participants p where p.monster_id = m.id and p.deleted_at is null and p.absent_at is null and p.checked_in_at is not null)
    order by m.sort_order
  loop
    update participants set monster_id = r.id where id = (
      select p.id from participants p
      where p.event_id = ev.id and p.deleted_at is null and p.absent_at is null and p.checked_in_at is not null
        and p.monster_id in (select mb__card_monster_ids(ev.id))
        and (select count(*) from participants q where q.monster_id = p.monster_id and q.deleted_at is null
             and q.absent_at is null and q.checked_in_at is not null) >= 2
        and not exists (select 1 from encounters e where e.scanner_participant_id = p.id or e.target_participant_id = p.id)
      order by (select count(*) from participants q where q.monster_id = p.monster_id and q.deleted_at is null
                and q.absent_at is null and q.checked_in_at is not null) desc, random()
      limit 1);
    if found then v_reassigned := v_reassigned + 1; end if;
  end loop;

  -- 4) カードの未開放マスの差し替え
  select array_agg(id) into v_pool from mb__card_monster_ids(ev.id) id;
  for r in select b.id, b.participant_id, p.monster_id as own from bingo_cards b join participants p on p.id = b.participant_id
           where b.event_id = ev.id loop
    v_changed := false;
    select coalesce(array_agg(distinct monster_id), '{}') into v_got from monster_collections where participant_id = r.participant_id;
    select coalesce(array_agg(monster_id) filter (where monster_id = any(v_pool)), '{}') into v_on_card
    from bingo_cells where card_id = r.id and not is_free;
    for c in
      select position from bingo_cells
      where card_id = r.id and not is_free and opened_at is null and monster_id is not null
        and (not (monster_id = any(v_pool))
             -- 自分のモンスターのマスは、ほかに持っている人がいなければ開かないので差し替える
             or (monster_id = r.own and not exists (select 1 from participants q where q.monster_id = r.own and q.id <> r.participant_id
                                                     and q.deleted_at is null and q.absent_at is null and q.checked_in_at is not null)))
      order by random()
    loop
      -- なるべく「このカードにまだ無く、まだもらっていない」モンスターにする（同じマスが固まって一度に開くのを避ける）
      select x into v_pick from unnest(v_pool) x order by (x is not distinct from r.own), (x = any(v_on_card)), (x = any(v_got)),
        (select count(*) from unnest(v_on_card) y where y = x), random() limit 1;
      update bingo_cells set monster_id = v_pick where card_id = r.id and position = c.position;
      v_on_card := v_on_card || v_pick;
      v_cells := v_cells + 1;
      v_changed := true;
    end loop;
    if v_changed then
      v_cards := v_cards + 1;
      -- 差し替えたマスが、もうもらっているモンスターならその場で開く
      update bingo_cells bc set opened_at = now(), opened_by_participant_id = (
          select mc.source_participant_id from monster_collections mc
          where mc.participant_id = r.participant_id and mc.monster_id = bc.monster_id order by mc.created_at limit 1)
      where bc.card_id = r.id and bc.opened_at is null and bc.monster_id = any(v_got);
      select array_agg(monster_id order by position) into v_layout from bingo_cells where card_id = r.id;
      v_hash := md5(array_to_string(v_layout, '|', 'FREE'));
      if exists (select 1 from bingo_cards where event_id = ev.id and layout_hash = v_hash and id <> r.id) then
        v_hash := md5(v_hash || r.id::text);   -- 同じ配置がもうある時は、カードごとに違う値にする（一意制約を保つ）
      end if;
      v_after := mb__lines(r.id);
      select bool_and(opened_at is not null) into v_done from bingo_cells where card_id = r.id;
      update bingo_cards set layout_hash = v_hash, bingo_lines = v_after,
        first_bingo_at = coalesce(first_bingo_at, case when v_after > 0 then now() end),
        completed_at = coalesce(completed_at, case when v_done then now() end)
      where id = r.id;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'poolSize', v_n, 'reassigned', v_reassigned, 'cardsChanged', v_cards,
                            'cellsChanged', v_cells, 'pool', mb__pool_status(ev.id));
end $$;

create or replace function mb_admin_reset(p_admin_token text, p_event_id uuid, p_regenerate_cards boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ev events; r record;
begin
  perform mb__require_admin(p_admin_token);
  select * into ev from events where id = p_event_id for update;
  if ev.id is null then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;
  delete from monster_collections where event_id = ev.id;
  delete from encounters where event_id = ev.id;
  delete from fraud_logs where event_id = ev.id;
  if coalesce(p_regenerate_cards, false) then
    delete from bingo_cards where event_id = ev.id;
    for r in select id from participants where event_id = ev.id and deleted_at is null order by created_at loop
      perform mb__create_card(ev, r.id);
    end loop;
  else
    update bingo_cells set opened_at = null, opened_by_participant_id = null
    where not is_free and card_id in (select id from bingo_cards where event_id = ev.id);
    update bingo_cards set bingo_lines = 0, first_bingo_at = null, completed_at = null where event_id = ev.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- イベントの削除。参加者・カード・交換履歴・お知らせなど、そのイベントのデータをすべて消す（元に戻せない）。
--   押し間違い防止のため、イベントコードをもう一度入力してもらい、一致した時だけ消す
create or replace function mb_admin_delete_event(p_admin_token text, p_event_id uuid, p_confirm_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ev events;
begin
  perform mb__require_admin(p_admin_token);
  select * into ev from events where id = p_event_id for update;
  if ev.id is null then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;
  if upper(trim(coalesce(p_confirm_code, ''))) <> upper(ev.code) then
    perform mb__fail('CONFIRM_MISMATCH', '確認のイベントコードが一致しません');
  end if;
  -- 外部キーの連鎖削除に任せると、モンスターを消す時点でカードのマスがまだ参照していて止まる。
  -- 参照している側から順に消す（獲得 → 交換 → カード（マスも一緒）→ 参加者 → モンスター → イベント）
  delete from monster_collections where event_id = ev.id;
  delete from encounters where event_id = ev.id;
  delete from bingo_cards where event_id = ev.id;
  delete from fraud_logs where event_id = ev.id;
  delete from announcements where event_id = ev.id;
  delete from pin_login_failures where event_id = ev.id;
  delete from participants where event_id = ev.id;
  delete from monsters where event_id = ev.id;
  delete from events where id = ev.id;
  return jsonb_build_object('ok', true, 'deletedCode', ev.code);
end $$;

-- 管理者の作成・パスワード変更（SQL Editor からのみ実行できる）
create or replace function mb_create_admin(p_email text, p_password text) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  if length(coalesce(p_password, '')) < 10 then raise exception 'パスワードは10文字以上にしてください'; end if;
  insert into admins (email, password_hash) values (lower(trim(p_email)), crypt(p_password, gen_salt('bf', 10)))
  on conflict (email) do update set password_hash = excluded.password_hash;
  delete from admin_sessions where admin_id = (select id from admins where email = lower(trim(p_email)));
  return '管理者を登録しました: ' || lower(trim(p_email));
end $$;

-- ---------------------------------------------------------------- 権限
-- このアプリのテーブルと関数だけを対象に、すべて閉じてからブラウザ用の関数だけを開ける
-- （同じ Supabase プロジェクトにある別アプリのテーブル・関数には触れません）
do $$
declare
  t text;
  fn record;
  has_supabase_roles boolean := exists (select 1 from pg_roles where rolname = 'anon');
begin
  foreach t in array array['events','monsters','participants','participant_qr_tokens','bingo_cards','bingo_cells',
                           'encounters','monster_collections','fraud_logs','admins','admin_sessions','admin_login_failures',
                           'announcements','pin_login_failures'] loop
    execute format('revoke all on table %I from public', t);
    if has_supabase_roles then execute format('revoke all on table %I from anon, authenticated', t); end if;
  end loop;
  for fn in
    select p.oid::regprocedure::text as signature, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'mb\_%'
  loop
    execute format('revoke execute on function %s from public', fn.signature);
    if has_supabase_roles then
      execute format('revoke execute on function %s from anon, authenticated', fn.signature);
      if fn.proname not like 'mb\_\_%' and fn.proname not in ('mb_create_admin', 'mb_line_login') then
        execute format('grant execute on function %s to anon, authenticated', fn.signature);
      end if;
      -- LINEログインは、IDトークンを照合する Edge Function（service_role）からだけ呼べる
      if fn.proname = 'mb_line_login' and exists (select 1 from pg_roles where rolname = 'service_role') then
        execute format('grant execute on function %s to service_role', fn.signature);
      end if;
    end if;
  end loop;
end $$;

-- identity 列の採番（announcements.id）も閉じておく
revoke all on sequence announcements_id_seq from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on sequence announcements_id_seq from anon, authenticated';
  end if;
end $$;

-- ---------------------------------------------------------------- 最後にこれを実行（メールとパスワードを書き換えて）
-- select mb_create_admin('you@example.com', '10文字以上のパスワード');
