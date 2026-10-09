-- SportStack Phase 2: category voting, host start and automatic countdown.
-- Blueprint change agreed by the owner: each player votes for up to 2 categories,
-- the category with the most votes wins (random pick among ties), and no category
-- agreement is required. The host can start when at least two players are ready.

alter table public.rooms
  add column if not exists countdown_ends_at timestamptz;

-- ---------------------------------------------------------------------------
-- Category votes: each active player may vote for up to 2 launch categories.
-- ---------------------------------------------------------------------------
create or replace function public.set_category_votes_v1(
  p_room_id uuid,
  p_user_id uuid,
  p_categories text[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_clean text[];
begin
  if not exists (
    select 1 from public.rooms r
    where r.id = p_room_id and r.status = 'waiting'
  ) then raise exception using message = 'ROOM_NOT_WAITING'; end if;

  select coalesce(array_agg(distinct c order by c), '{}')
  into v_clean
  from unnest(coalesce(p_categories, '{}')) as t(c);

  if cardinality(v_clean) > 2 then raise exception using message = 'TOO_MANY_VOTES'; end if;

  if exists (
    select 1 from unnest(v_clean) as t(c)
    where not exists (
      select 1 from public.question_categories q
      where q.slug = t.c and q.is_launch_category
    )
  ) then raise exception using message = 'INVALID_CATEGORY'; end if;

  update public.room_players
  set category_votes = v_clean, last_seen_at = now()
  where room_id = p_room_id and user_id = p_user_id and status = 'active';
  if not found then raise exception using message = 'NOT_A_ROOM_MEMBER'; end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Host starts the match: needs at least two ready players. Picks the winning
-- category from the ready players' votes and starts a 5 second countdown.
-- ---------------------------------------------------------------------------
create or replace function public.start_countdown_v1(
  p_room_id uuid,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.rooms%rowtype;
  v_ready integer;
  v_winner text;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then raise exception using message = 'ROOM_NOT_FOUND'; end if;
  if v_room.host_id <> p_user_id then raise exception using message = 'NOT_HOST'; end if;
  if v_room.status <> 'waiting' then raise exception using message = 'ROOM_NOT_WAITING'; end if;

  select count(*) into v_ready
  from public.room_players
  where room_id = p_room_id and status = 'active' and is_ready;
  if v_ready < 2 then raise exception using message = 'NOT_ENOUGH_READY'; end if;

  with votes as (
    select unnest(category_votes) as slug
    from public.room_players
    where room_id = p_room_id and status = 'active' and is_ready
  ),
  tally as (
    select slug, count(*) as total from votes group by slug
  ),
  leaders as (
    select slug from tally where total = (select max(total) from tally)
  )
  select slug into v_winner from leaders order by random() limit 1;

  if v_winner is null then
    select slug into v_winner
    from public.question_categories
    where is_launch_category
    order by random()
    limit 1;
  end if;

  update public.rooms
  set status = 'countdown',
      selected_categories = array[v_winner],
      countdown_ends_at = now() + interval '5 seconds',
      updated_at = now()
  where id = p_room_id;

  return jsonb_build_object('ok', true, 'category', v_winner);
end;
$$;

-- ---------------------------------------------------------------------------
-- Any room member's browser calls this when the countdown reaches zero.
-- It is safe to call repeatedly: only the first valid call changes the room.
-- If fewer than two ready players remain, the room returns to waiting.
-- ---------------------------------------------------------------------------
create or replace function public.advance_countdown_v1(
  p_room_id uuid,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.rooms%rowtype;
  v_ready integer;
begin
  if not exists (
    select 1 from public.room_players rp
    where rp.room_id = p_room_id and rp.user_id = p_user_id and rp.status = 'active'
  ) then raise exception using message = 'NOT_A_ROOM_MEMBER'; end if;

  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then raise exception using message = 'ROOM_NOT_FOUND'; end if;

  if v_room.status <> 'countdown' then
    return jsonb_build_object('status', v_room.status);
  end if;
  if v_room.countdown_ends_at is not null and now() < v_room.countdown_ends_at then
    return jsonb_build_object('status', 'countdown');
  end if;

  select count(*) into v_ready
  from public.room_players
  where room_id = p_room_id and status = 'active' and is_ready;

  if v_ready < 2 then
    update public.rooms
    set status = 'waiting', selected_categories = '{}', countdown_ends_at = null, updated_at = now()
    where id = p_room_id;
    return jsonb_build_object('status', 'waiting');
  end if;

  update public.rooms
  set status = 'in_progress', match_started_at = now(), updated_at = now()
  where id = p_room_id;
  return jsonb_build_object('status', 'in_progress');
end;
$$;

-- ---------------------------------------------------------------------------
-- Room snapshot now also returns votes, the chosen category and countdown time.
-- ---------------------------------------------------------------------------
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
      'created_at', r.created_at,
      'selected_categories', to_jsonb(r.selected_categories),
      'countdown_ends_at', r.countdown_ends_at,
      'server_now', now()
    ),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', rp.user_id,
        'display_name', rp.display_name,
        'player_tag', rp.player_tag,
        'is_ready', rp.is_ready,
        'is_host', rp.user_id = r.host_id,
        'joined_at', rp.joined_at,
        'category_votes', to_jsonb(rp.category_votes)
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

revoke all on function public.set_category_votes_v1(uuid, uuid, text[]) from public, anon, authenticated;
revoke all on function public.start_countdown_v1(uuid, uuid) from public, anon, authenticated;
revoke all on function public.advance_countdown_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function public.set_category_votes_v1(uuid, uuid, text[]) to service_role;
grant execute on function public.start_countdown_v1(uuid, uuid) to service_role;
grant execute on function public.advance_countdown_v1(uuid, uuid) to service_role;
