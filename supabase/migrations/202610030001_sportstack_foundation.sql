-- SportStack Phase 1 foundation.
-- Clients never write room state or read answer keys directly; the Edge Function
-- uses server credentials after verifying the caller's Supabase guest session.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.question_categories (
  slug text primary key,
  sport text not null,
  label text not null,
  sort_order smallint not null unique,
  is_launch_category boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.question_categories (slug, sport, label, sort_order, is_launch_category) values
  ('football-premier-league', 'Football', 'Premier League', 1, true),
  ('football-champions-league', 'Football', 'Champions League', 2, true),
  ('cricket-international', 'Cricket', 'International Cricket', 3, true),
  ('cricket-ipl', 'Cricket', 'IPL', 4, true),
  ('tennis-grand-slams', 'Tennis', 'Grand Slam Tournaments', 5, true),
  ('tennis-general', 'Tennis', 'General Tennis', 6, true),
  ('f1-drivers-champions', 'Formula 1', 'Drivers & Champions', 7, true),
  ('f1-teams-constructors', 'Formula 1', 'Teams & Constructors', 8, true),
  ('motogp-riders-champions', 'MotoGP', 'Riders & Champions', 9, true),
  ('motogp-circuits-grands-prix', 'MotoGP', 'Circuits & Grands Prix', 10, true),
  ('basketball-nba', 'Basketball', 'NBA', 11, true),
  ('basketball-fiba', 'Basketball', 'International/FIBA Basketball', 12, true),
  ('olympics-history-records', 'Olympics & Other Sports', 'Olympic History & Records', 13, true),
  ('other-sports-rules-history', 'Olympics & Other Sports', 'Other Sports: Rules & History', 14, true)
on conflict (slug) do update set
  sport = excluded.sport,
  label = excluded.label,
  sort_order = excluded.sort_order,
  is_launch_category = excluded.is_launch_category;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9]{6}$'),
  host_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'waiting' check (status in ('waiting', 'countdown', 'in_progress', 'results', 'closed')),
  max_players smallint not null default 4 check (max_players between 2 and 4),
  selected_categories text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  match_started_at timestamptz,
  closed_at timestamptz
);

create table if not exists public.room_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 2 and 24),
  player_tag text not null check (player_tag ~ '^[A-Z0-9]{3,4}$'),
  is_ready boolean not null default false,
  category_votes text[] not null default '{}',
  score integer not null default 0 check (score >= 0),
  correct_answers smallint not null default 0 check (correct_answers between 0 and 15),
  current_streak smallint not null default 0 check (current_streak >= 0),
  longest_streak smallint not null default 0 check (longest_streak >= 0),
  status text not null default 'active' check (status in ('active', 'forfeited', 'left')),
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (room_id, user_id),
  unique (room_id, player_tag),
  check (cardinality(category_votes) <= 2)
);

create index if not exists room_players_active_room_idx
  on public.room_players (room_id, status, joined_at);
create index if not exists room_players_user_active_idx
  on public.room_players (user_id, status);
create index if not exists rooms_waiting_created_idx
  on public.rooms (status, created_at desc);

create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  category_slug text not null references public.question_categories(slug),
  difficulty text not null check (difficulty in ('easy', 'medium', 'hard')),
  answer_format text not null check (answer_format in ('multiple_choice', 'true_false')),
  prompt text not null,
  options jsonb not null,
  correct_answer text not null,
  explanation text not null,
  source_title text not null,
  source_url text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint questions_source_url_http check (source_url ~ '^https?://')
);
create index if not exists questions_category_draw_idx
  on public.questions (category_slug, difficulty, answer_format) where is_active;

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  status text not null default 'in_progress' check (status in ('in_progress', 'completed', 'abandoned')),
  question_count smallint not null default 15 check (question_count = 15),
  started_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists public.match_questions (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  question_id uuid not null references public.questions(id),
  position smallint not null check (position between 1 and 15),
  category_slug text not null references public.question_categories(slug),
  opened_at timestamptz,
  reveal_at timestamptz,
  unique (match_id, position),
  unique (match_id, question_id)
);

create table if not exists public.match_answers (
  id uuid primary key default gen_random_uuid(),
  match_question_id uuid not null references public.match_questions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  selected_answer text,
  is_correct boolean not null default false,
  answered_at timestamptz,
  response_ms integer check (response_ms is null or response_ms between 0 and 15000),
  points_awarded integer not null default 0 check (points_awarded >= 0),
  unique (match_question_id, user_id)
);

create table if not exists public.question_reports (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions(id),
  reporter_user_id uuid not null references auth.users(id) on delete cascade,
  room_id uuid references public.rooms(id) on delete set null,
  reason text not null check (char_length(reason) between 5 and 1000),
  status text not null default 'pending' check (status in ('pending', 'reviewing', 'resolved', 'dismissed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

-- Deny direct client access. The browser calls the Edge Function; server-side
-- code verifies the caller and performs allowed operations with elevated access.
alter table public.question_categories enable row level security;
alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
alter table public.questions enable row level security;
alter table public.matches enable row level security;
alter table public.match_questions enable row level security;
alter table public.match_answers enable row level security;
alter table public.question_reports enable row level security;

-- A private Realtime channel is readable only by an active member of that room.
create or replace function public.can_receive_room_broadcast(p_topic text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.room_players rp
    where rp.user_id = (select auth.uid())
      and rp.status = 'active'
      and ('room:' || rp.room_id::text) = p_topic
  );
$$;
revoke all on function public.can_receive_room_broadcast(text) from public, anon;
grant execute on function public.can_receive_room_broadcast(text) to authenticated;

drop policy if exists "Room members can receive room broadcasts" on realtime.messages;
create policy "Room members can receive room broadcasts"
on realtime.messages
for select
to authenticated
using (
  extension = 'broadcast'
  and public.can_receive_room_broadcast(realtime.topic())
);

create or replace function public.broadcast_room_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room_id uuid;
begin
  if tg_table_name = 'rooms' then
    if tg_op = 'DELETE' then v_room_id := old.id; else v_room_id := new.id; end if;
  else
    if tg_op = 'DELETE' then v_room_id := old.room_id; else v_room_id := new.room_id; end if;
    -- Heartbeat-only updates should not fan out room events.
    if tg_op = 'UPDATE' then
      if row(new.display_name, new.player_tag, new.is_ready, new.category_votes, new.score,
             new.correct_answers, new.current_streak, new.longest_streak, new.status)
           is not distinct from
         row(old.display_name, old.player_tag, old.is_ready, old.category_votes, old.score,
             old.correct_answers, old.current_streak, old.longest_streak, old.status)
      then return null;
      end if;
    end if;
  end if;

  if v_room_id is not null then
    perform realtime.send(
      jsonb_build_object('room_id', v_room_id, 'changed', true),
      'room_updated',
      'room:' || v_room_id::text,
      true
    );
  end if;
  return null;
end;
$$;

-- Room state changes and public player-state changes emit a minimal payload.
drop trigger if exists rooms_broadcast_change on public.rooms;
create trigger rooms_broadcast_change
after insert or update or delete on public.rooms
for each row execute function public.broadcast_room_change();
drop trigger if exists room_players_broadcast_change on public.room_players;
create trigger room_players_broadcast_change
after insert or update or delete on public.room_players
for each row execute function public.broadcast_room_change();

create or replace function public.create_room_v1(
  p_user_id uuid,
  p_display_name text,
  p_player_tag text,
  p_room_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room_id uuid;
begin
  if p_user_id is null then raise exception using message = 'AUTH_REQUIRED'; end if;
  if char_length(trim(p_display_name)) not between 2 and 24 then raise exception using message = 'INVALID_DISPLAY_NAME'; end if;
  insert into public.rooms (code, host_id, status, max_players)
  values (upper(p_room_code), p_user_id, 'waiting', 4)
  returning id into v_room_id;

  insert into public.room_players (room_id, user_id, display_name, player_tag)
  values (v_room_id, p_user_id, trim(p_display_name), upper(p_player_tag));

  return jsonb_build_object('room_id', v_room_id, 'code', upper(p_room_code));
end;
$$;

create or replace function public.join_room_v1(
  p_room_code text,
  p_user_id uuid,
  p_display_name text,
  p_player_tag text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.rooms%rowtype;
  v_count integer;
  v_player public.room_players%rowtype;
begin
  if p_user_id is null then raise exception using message = 'AUTH_REQUIRED'; end if;
  if char_length(trim(p_display_name)) not between 2 and 24 then raise exception using message = 'INVALID_DISPLAY_NAME'; end if;

  select * into v_room
  from public.rooms
  where code = upper(trim(p_room_code))
  for update;
  if not found then raise exception using message = 'ROOM_NOT_FOUND'; end if;
  if v_room.status <> 'waiting' then raise exception using message = 'ROOM_NOT_JOINABLE'; end if;

  select * into v_player
  from public.room_players
  where room_id = v_room.id and user_id = p_user_id and status = 'active';
  if found then
    update public.room_players set last_seen_at = now() where id = v_player.id;
    return jsonb_build_object('room_id', v_room.id, 'code', v_room.code);
  end if;

  -- A guest who left a still-open waiting room may rejoin it.
  select * into v_player
  from public.room_players
  where room_id = v_room.id and user_id = p_user_id;
  if found then
    update public.room_players
    set display_name = trim(p_display_name),
        player_tag = upper(p_player_tag),
        is_ready = false,
        category_votes = '{}',
        status = 'active',
        joined_at = now(),
        last_seen_at = now()
    where id = v_player.id;
    return jsonb_build_object('room_id', v_room.id, 'code', v_room.code);
  end if;

  select count(*) into v_count
  from public.room_players
  where room_id = v_room.id and status = 'active';
  if v_count >= v_room.max_players then raise exception using message = 'ROOM_FULL'; end if;

  insert into public.room_players (room_id, user_id, display_name, player_tag)
  values (v_room.id, p_user_id, trim(p_display_name), upper(p_player_tag));
  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code);
end;
$$;

create or replace function public.set_room_ready_v1(
  p_room_id uuid,
  p_user_id uuid,
  p_ready boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.rooms r
    where r.id = p_room_id and r.status = 'waiting'
  ) then raise exception using message = 'ROOM_NOT_JOINABLE'; end if;
  update public.room_players
  set is_ready = p_ready, last_seen_at = now()
  where room_id = p_room_id and user_id = p_user_id and status = 'active';
  if not found then raise exception using message = 'NOT_A_ROOM_MEMBER'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.get_room_snapshot_v1(p_room_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if not exists (
    select 1 from public.room_players rp
    where rp.room_id = p_room_id and rp.user_id = p_user_id and rp.status = 'active'
  ) then raise exception using message = 'NOT_A_ROOM_MEMBER'; end if;

  select jsonb_build_object(
    'room', jsonb_build_object(
      'id', r.id,
      'code', r.code,
      'status', r.status,
      'host_id', r.host_id,
      'max_players', r.max_players,
      'created_at', r.created_at
    ),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', rp.user_id,
        'display_name', rp.display_name,
        'player_tag', rp.player_tag,
        'is_ready', rp.is_ready,
        'is_host', rp.user_id = r.host_id,
        'joined_at', rp.joined_at
      ) order by rp.joined_at)
      from public.room_players rp
      where rp.room_id = r.id and rp.status = 'active'
    ), '[]'::jsonb)
  ) into v_result
  from public.rooms r
  where r.id = p_room_id;

  if v_result is null then raise exception using message = 'ROOM_NOT_FOUND'; end if;
  return v_result;
end;
$$;

create or replace function public.leave_room_v1(p_room_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_host_id uuid;
  v_status text;
  v_remaining integer;
begin
  select host_id, status into v_host_id, v_status
  from public.rooms where id = p_room_id for update;
  if not found then return jsonb_build_object('ok', true); end if;

  if not exists (
    select 1 from public.room_players
    where room_id = p_room_id and user_id = p_user_id and status = 'active'
  ) then return jsonb_build_object('ok', true); end if;

  if v_host_id = p_user_id and v_status = 'waiting' then
    update public.rooms set status = 'closed', closed_at = now(), updated_at = now() where id = p_room_id;
    update public.room_players set status = 'left', is_ready = false
    where room_id = p_room_id and status = 'active';
  else
    update public.room_players set status = 'left', is_ready = false
    where room_id = p_room_id and user_id = p_user_id and status = 'active';
    select count(*) into v_remaining from public.room_players where room_id = p_room_id and status = 'active';
    if v_remaining = 0 then
      update public.rooms set status = 'closed', closed_at = now(), updated_at = now() where id = p_room_id;
    end if;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.touch_room_presence_v1(p_room_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.rooms%rowtype;
  v_new_host uuid;
begin
  update public.room_players
  set last_seen_at = now()
  where room_id = p_room_id and user_id = p_user_id and status = 'active';
  if not found then raise exception using message = 'NOT_A_ROOM_MEMBER'; end if;

  select * into v_room from public.rooms where id = p_room_id;
  if not found then raise exception using message = 'ROOM_NOT_FOUND'; end if;

  if v_room.status = 'waiting' then
    if exists (
      select 1 from public.room_players host_player
      where host_player.room_id = p_room_id
        and host_player.user_id = v_room.host_id
        and host_player.status = 'active'
        and host_player.last_seen_at < now() - interval '45 seconds'
    ) then
      select rp.user_id into v_new_host
      from public.room_players rp
      where rp.room_id = p_room_id
        and rp.status = 'active'
        and rp.user_id <> v_room.host_id
        and rp.last_seen_at >= now() - interval '45 seconds'
      order by rp.joined_at asc
      limit 1;
      if v_new_host is not null then
        update public.rooms set host_id = v_new_host, updated_at = now() where id = p_room_id;
      end if;
    end if;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.cleanup_stale_waiting_rooms_v1()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  delete from public.rooms r
  where r.status = 'waiting'
    and r.created_at < now() - interval '5 minutes'
    and not exists (
      select 1 from public.room_players rp
      where rp.room_id = r.id
        and rp.status = 'active'
        and rp.last_seen_at >= now() - interval '5 minutes'
    );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Only the trusted Edge Function's service-role client may call these RPCs.
revoke all on function public.create_room_v1(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.join_room_v1(text, uuid, text, text) from public, anon, authenticated;
revoke all on function public.set_room_ready_v1(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.get_room_snapshot_v1(uuid, uuid) from public, anon, authenticated;
revoke all on function public.leave_room_v1(uuid, uuid) from public, anon, authenticated;
revoke all on function public.touch_room_presence_v1(uuid, uuid) from public, anon, authenticated;
revoke all on function public.cleanup_stale_waiting_rooms_v1() from public, anon, authenticated;
grant execute on function public.create_room_v1(uuid, text, text, text) to service_role;
grant execute on function public.join_room_v1(text, uuid, text, text) to service_role;
grant execute on function public.set_room_ready_v1(uuid, uuid, boolean) to service_role;
grant execute on function public.get_room_snapshot_v1(uuid, uuid) to service_role;
grant execute on function public.leave_room_v1(uuid, uuid) to service_role;
grant execute on function public.touch_room_presence_v1(uuid, uuid) to service_role;
grant execute on function public.cleanup_stale_waiting_rooms_v1() to service_role;
