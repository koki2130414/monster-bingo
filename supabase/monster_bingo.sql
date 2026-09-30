-- =====================================================================
-- MONSTER BINGO — Supabase 用 SQL（これ1本で完結）
--   Supabase → SQL Editor に全文を貼って Run。何度実行しても安全です。
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

do $$
declare t text;
begin
  foreach t in array array['events','monsters','participants','participant_qr_tokens','bingo_cards','bingo_cells',
                           'encounters','monster_collections','fraud_logs','admins','admin_sessions','admin_login_failures'] loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

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
language plpgsql as $$
begin
  raise exception using message = p_message, hint = p_code;
end $$;

create or replace function mb__display_name(p_mode text, p_nickname text, p_full_name text) returns text
language sql immutable as $$
  select case p_mode when 'hidden' then null
                     when 'full_name' then coalesce(nullif(trim(p_full_name), ''), p_nickname)
                     else p_nickname end
$$;

create or replace function mb__monster_json(m monsters) returns jsonb
language sql stable as $$
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
language sql stable as $$
  with c as (select position, opened_at is not null as is_open from bingo_cells where card_id = p_card),
  l as (
    select 'r' || (position / 5) as k, is_open from c
    union all select 'c' || (position % 5), is_open from c
    union all select 'd1', is_open from c where position in (0, 6, 12, 18, 24)
    union all select 'd2', is_open from c where position in (4, 8, 12, 16, 20)
  )
  select count(*)::int from (select k from l group by k having count(*) = 5 and bool_and(is_open)) done
$$;

-- 均等ランダム配布：担当人数が最も少ない NORMAL モンスターから1体をランダムに
create or replace function mb__pick_monster(p_event uuid) returns uuid
language sql volatile as $$
  select m.id from monsters m
  left join participants p on p.monster_id = m.id and p.deleted_at is null
  where m.event_id = p_event and m.is_active and m.rarity = 'normal'
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
  select array_agg(id) into v_ids from monsters where event_id = p_event.id and is_active and rarity <> 'secret';
  if v_ids is null then perform mb__fail('NO_MONSTERS', 'カードに載せるモンスターが登録されていません'); end if;
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
create or replace function mb__join(p_event_id uuid, p_nickname text, p_full_name text, p_role text)
returns jsonb
language plpgsql set search_path = public, extensions as $$
declare
  ev events;
  v_nickname text := left(trim(coalesce(p_nickname, '')), 20);
  v_session text := mb__token(32);
  v_monster uuid;
  v_participant uuid;
  v_count int;
begin
  if v_nickname = '' then perform mb__fail('NICKNAME_REQUIRED', 'ニックネームを入力してください'); end if;
  select * into ev from events where id = p_event_id for update;   -- 同時参加でも集計がずれないようロック
  if ev.id is null then perform mb__fail('EVENT_NOT_FOUND', 'イベントが見つかりません'); end if;
  if ev.status = 'ended' then perform mb__fail('EVENT_ENDED', 'このイベントは終了しました'); end if;
  select count(*) into v_count from participants where event_id = ev.id and deleted_at is null;
  if v_count >= ev.max_participants then perform mb__fail('EVENT_FULL', '参加人数の上限に達しました。運営スタッフに声をかけてください'); end if;

  v_monster := mb__pick_monster(ev.id);
  if v_monster is null then perform mb__fail('NO_MONSTERS', '配布できるモンスターが登録されていません'); end if;

  insert into participants (event_id, nickname, full_name, role, monster_id, session_token_hash)
  values (ev.id, v_nickname, nullif(left(trim(coalesce(p_full_name, '')), 40), ''), coalesce(p_role, 'guest'), v_monster, mb__hash(v_session))
  returning id into v_participant;
  perform mb__issue_qr(ev.id, v_participant);
  perform mb__create_card(ev, v_participant);
  return jsonb_build_object('sessionToken', v_session, 'eventCode', ev.code, 'participantId', v_participant);
end $$;

-- 獲得を記録し、該当マスを OPEN にして、ライン数を更新
create or replace function mb__grant(p_event uuid, p_receiver uuid, p_source uuid, p_monster uuid, p_encounter uuid)
returns jsonb
language plpgsql as $$
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
returns void language plpgsql as $$
begin
  if p_once_per_minute and exists (
    select 1 from fraud_logs where participant_id = p_participant and kind = p_kind and created_at > now() - interval '60 seconds'
  ) then return; end if;
  insert into fraud_logs (event_id, participant_id, kind, detail) values (p_event, p_participant, p_kind, coalesce(p_detail, '{}'));
end $$;

-- 参加者ごとの集計（ランキング・管理画面・CSV で共通の定義）
create or replace function mb__participant_stats(p_event uuid)
returns table (id uuid, nickname text, full_name text, role text, monster_id uuid, created_at timestamptz,
               last_seen_at timestamptz, encounter_people int, species_found int, bingo_lines int, opened_cells int,
               first_bingo_at timestamptz, completed_at timestamptz)
language sql stable as $$
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
         b.first_bingo_at, b.completed_at
  from participants p
  left join people on people.pid = p.id
  left join species on species.pid = p.id
  left join opened on opened.pid = p.id
  left join bingo_cards b on b.participant_id = p.id
  where p.event_id = p_event and p.deleted_at is null
  order by p.created_at
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

create or replace function mb_state(p_session text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  me participants;
  ev events;
  v_card uuid;
  v_token text;
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
  select * into ev from events where id = me.event_id;
  update participants set last_seen_at = now() where id = me.id;

  select token into v_token from participant_qr_tokens
  where participant_id = me.id and revoked_at is null and (expires_at is null or expires_at > now())
  order by created_at desc limit 1;
  if v_token is null then v_token := mb__issue_qr(ev.id, me.id); end if;

  select id into v_card from bingo_cards where participant_id = me.id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'position', c.position,
      'monster', mb__monster_json(m),
      'isFree', c.is_free,
      'isOpen', c.opened_at is not null,
      'openedByName', case when o.id is null then null else mb__display_name(ev.name_display_mode, o.nickname, o.full_name) end
    ) order by c.position), '[]'::jsonb),
    count(*) filter (where c.opened_at is not null), count(*)
  into v_cells, v_opened, v_total
  from bingo_cells c left join monsters m on m.id = c.monster_id left join participants o on o.id = c.opened_by_participant_id
  where c.card_id = v_card;
  v_lines := coalesce(mb__lines(v_card), 0);

  with got as (select monster_id, count(*)::int as times from monster_collections where participant_id = me.id group by monster_id)
  select coalesce(jsonb_agg(jsonb_build_object('monster', mb__monster_json(m), 'found', got.monster_id is not null,
           'timesReceived', coalesce(got.times, 0)) order by m.rarity = 'secret', m.sort_order, m.created_at), '[]'::jsonb),
         count(*) filter (where m.rarity <> 'secret' and m.is_active),
         count(*) filter (where m.rarity <> 'secret' and m.is_active and got.monster_id is not null)
  into v_collection, v_species_total, v_species_found
  from monsters m left join got on got.monster_id = m.id
  where m.event_id = ev.id and ((m.is_active and m.rarity <> 'secret') or (m.rarity = 'secret' and got.monster_id is not null));

  select count(*) into v_secret_left from monsters m
  where m.event_id = ev.id and m.is_active and m.rarity = 'secret'
    and not exists (select 1 from monster_collections c where c.participant_id = me.id and c.monster_id = m.id);

  select coalesce(jsonb_agg(x.item order by x.created_at desc), '[]'::jsonb) into v_recent from (
    select jsonb_build_object('id', c.id, 'monster', mb__monster_json(m),
             'sourceName', mb__display_name(ev.name_display_mode, s.nickname, s.full_name), 'createdAt', c.created_at) as item,
           c.created_at
    from monster_collections c join monsters m on m.id = c.monster_id join participants s on s.id = c.source_participant_id
    where c.participant_id = me.id order by c.created_at desc limit 30
  ) x;

  select count(distinct case when scanner_participant_id = me.id then target_participant_id else scanner_participant_id end)::int
  into v_people from encounters where scanner_participant_id = me.id or target_participant_id = me.id;

  return jsonb_build_object(
    'event', jsonb_build_object('code', ev.code, 'name', ev.name, 'status', ev.status, 'freeCellEnabled', ev.free_cell_enabled,
       'exchangeMode', ev.exchange_mode, 'nameDisplayMode', ev.name_display_mode, 'rankingEnabled', ev.ranking_enabled,
       'rankingMetric', ev.ranking_metric),
    'me', jsonb_build_object('nickname', me.nickname, 'role', me.role),
    'myMonster', (select mb__monster_json(m) from monsters m where m.id = me.monster_id),
    'qrToken', v_token,
    'card', jsonb_build_object('size', 5, 'cells', v_cells),
    'stats', jsonb_build_object('speciesFound', v_species_found, 'speciesTotal', v_species_total,
       'completionRate', case when v_species_total > 0 then round(v_species_found * 100.0 / v_species_total)::int else 0 end,
       'bingoLines', v_lines, 'encounterPeople', v_people, 'openedCells', v_opened, 'totalCells', v_total,
       'cardCompleted', v_total > 0 and v_opened = v_total),
    'collection', v_collection,
    'undiscoveredSecretCount', v_secret_left,
    'recentAcquisitions', v_recent);
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
  select * into ev from events where id = me.event_id for update;
  if ev.status <> 'active' then
    return jsonb_build_object('ok', false, 'code', 'EVENT_NOT_ACTIVE', 'message', 'いまは交換できません（イベント開始前か終了後です）');
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
  select count(*) into v_total from monsters where event_id = ev.id and is_active and rarity <> 'secret';
  with s as (
    select st.*, case ev.ranking_metric
      when 'encounters' then st.encounter_people
      when 'bingo' then st.bingo_lines
      when 'completion' then case when v_total > 0 then round(st.species_found * 100.0 / v_total)::int else 0 end
      else st.species_found end as value
    from mb__participant_stats(ev.id) st where st.role = 'guest'
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
      (select count(*) from participants p where p.event_id = e.id and p.deleted_at is null)) order by e.created_at desc), '[]'::jsonb)
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
  with st as (select * from mb__participant_stats(ev.id))
  select jsonb_build_object(
    'event', to_jsonb(ev),
    'speciesTotal', (select count(*) from monsters where event_id = ev.id and is_active and rarity <> 'secret'),
    'totals', jsonb_build_object(
      'participants', (select count(*) from st),
      'encounters', (select count(*) from encounters where event_id = ev.id),
      'averageEncounterPeople', coalesce((select round(avg(encounter_people)::numeric, 1) from st), 0),
      'bingoAchievers', (select count(*) from st where bingo_lines > 0),
      'cardCompleters', (select count(*) from st where completed_at is not null),
      'fraudLogs', (select count(*) from fraud_logs where event_id = ev.id)),
    'monsters', (select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('assigned_count',
        (select count(*) from participants p where p.monster_id = m.id and p.deleted_at is null)) order by m.sort_order, m.created_at), '[]'::jsonb)
      from monsters m where m.event_id = ev.id),
    'notYetInteracted', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nickname', nickname, 'role', role,
        'encounterPeople', encounter_people, 'joinedAt', created_at) order by created_at), '[]'::jsonb) from st where encounter_people = 0),
    'fewInteractions', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nickname', nickname, 'role', role,
        'encounterPeople', encounter_people, 'joinedAt', created_at) order by encounter_people, created_at), '[]'::jsonb)
      from st where encounter_people between 1 and 2 and created_at < now() - interval '10 minutes')
  ) into v_result;
  return v_result;
end $$;

create or replace function mb_admin_update_event(p_admin_token text, p_event_id uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ev events;
begin
  perform mb__require_admin(p_admin_token);
  update events set
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
    insert into monsters (event_id, name, emoji, image_url, color, rarity, sort_order)
    values (p_event_id, trim(p_data->>'name'), coalesce(nullif(trim(p_data->>'emoji'), ''), '👻'), v_image,
            coalesce(p_data->>'color', '#ff7a1a'), coalesce(p_data->>'rarity', 'normal'),
            (select coalesce(max(sort_order), -1) + 1 from monsters where event_id = p_event_id))
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
  return to_jsonb(m);
end $$;

-- 使われていれば無効化のみ（履歴を壊さない）、未使用なら削除
create or replace function mb_admin_delete_monster(p_admin_token text, p_event_id uuid, p_monster_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform mb__require_admin(p_admin_token);
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
      'monster_name', m.name, 'monster_emoji', m.emoji, 'monster_rarity', m.rarity) order by st.created_at), '[]'::jsonb)
    from mb__participant_stats(p_event_id) st left join monsters m on m.id = st.monster_id);
end $$;

create or replace function mb_admin_add_participant(p_admin_token text, p_event_id uuid, p_nickname text, p_role text default 'staff', p_monster_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_joined jsonb;
begin
  perform mb__require_admin(p_admin_token);
  v_joined := mb__join(p_event_id, p_nickname, null, coalesce(p_role, 'staff'));
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
    role = coalesce(p_patch->>'role', role),
    monster_id = case when p_patch ? 'monster_id' then nullif(p_patch->>'monster_id', '')::uuid else monster_id end
  where id = p_participant_id and event_id = p_event_id;
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
                           'encounters','monster_collections','fraud_logs','admins','admin_sessions','admin_login_failures'] loop
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
      if fn.proname not like 'mb\_\_%' and fn.proname <> 'mb_create_admin' then
        execute format('grant execute on function %s to anon, authenticated', fn.signature);
      end if;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- 最後にこれを実行（メールとパスワードを書き換えて）
-- select mb_create_admin('you@example.com', '10文字以上のパスワード');
