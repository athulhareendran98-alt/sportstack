-- SportStack Phase 3, step 3: the Multiplayer quiz.
-- When the countdown ends the server builds a match of 15 questions (3 easy, 6 medium,
-- 6 hard) from the winning category. Every question runs on one shared server timeline:
--   15 seconds to answer, then an 8 second reveal, then the next question starts.
-- Scoring matches Solo Challenge: +100 per correct answer, +25 on every third correct
-- answer in a row, -25 for a wrong answer (the score never drops below zero), 0 for a timeout.
-- Correct answers are only revealed after the full 15 second timer has finished.

alter table public.matches
  add column if not exists category_slug text references public.question_categories(slug),
  add column if not exists current_position smallint not null default 1,
  add column if not exists question_started_at timestamptz;

-- match_answers.points_awarded must stay >= 0, so the signed change is stored separately.
alter table public.match_answers
  add column if not exists score_delta integer not null default 0;

-- ---------------------------------------------------------------------------
-- Categories that have enough questions (15 or more) to be played.
-- ---------------------------------------------------------------------------
create or replace function public.playable_category_slugs_v1()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(t.category_slug order by t.category_slug), '{}'::text[])
  from (
    select q.category_slug
    from public.questions q
    where q.is_active
    group by q.category_slug
    having count(*) >= 15
  ) t;
$$;

-- Votes are limited to playable categories.
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
    where not (t.c = any (public.playable_category_slugs_v1()))
  ) then raise exception using message = 'INVALID_CATEGORY'; end if;

  update public.room_players
  set category_votes = v_clean, last_seen_at = now()
  where room_id = p_room_id and user_id = p_user_id and status = 'active';
  if not found then raise exception using message = 'NOT_A_ROOM_MEMBER'; end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- The winning category must be playable, including the random fallback.
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
    select v.slug, count(*) as total
    from votes v
    where v.slug = any (public.playable_category_slugs_v1())
    group by v.slug
  ),
  leaders as (
    select t.slug from tally t where t.total = (select max(total) from tally)
  )
  select l.slug into v_winner from leaders l order by random() limit 1;

  if v_winner is null then
    select u.s into v_winner
    from unnest(public.playable_category_slugs_v1()) as u(s)
    order by random()
    limit 1;
  end if;
  if v_winner is null then raise exception using message = 'NOT_ENOUGH_QUESTIONS'; end if;

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
-- Build the match when the countdown ends: 15 questions, scores reset, first
-- question opens 3 seconds from now so every player is ready.
-- ---------------------------------------------------------------------------
create or replace function public.start_match_v1(p_room_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_category text;
  v_match uuid;
  v_rows integer;
begin
  select r.selected_categories[1] into v_category from public.rooms r where r.id = p_room_id;
  if v_category is null then raise exception using message = 'INVALID_CATEGORY'; end if;

  insert into public.matches (room_id, category_slug, current_position, question_started_at)
  values (p_room_id, v_category, 1, now() + interval '3 seconds')
  returning id into v_match;

  with picked as (
    (select q.id, 1 as rank from public.questions q
      where q.category_slug = v_category and q.is_active and q.difficulty = 'easy'
      order by random() limit 3)
    union all
    (select q.id, 2 as rank from public.questions q
      where q.category_slug = v_category and q.is_active and q.difficulty = 'medium'
      order by random() limit 6)
    union all
    (select q.id, 3 as rank from public.questions q
      where q.category_slug = v_category and q.is_active and q.difficulty = 'hard'
      order by random() limit 6)
  )
  insert into public.match_questions (match_id, question_id, position, category_slug)
  select v_match, p.id, (row_number() over (order by p.rank, random()))::smallint, v_category
  from picked p;

  get diagnostics v_rows = row_count;
  if v_rows <> 15 then raise exception using message = 'NOT_ENOUGH_QUESTIONS'; end if;

  update public.room_players
  set score = 0, correct_answers = 0, current_streak = 0, longest_streak = 0
  where room_id = p_room_id and status = 'active';

  update public.rooms
  set status = 'in_progress', match_started_at = now(), updated_at = now()
  where id = p_room_id;

  return v_match;
end;
$$;

-- The countdown now hands over to the match instead of stopping at "in progress".
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

  perform public.start_match_v1(p_room_id);
  return jsonb_build_object('status', 'in_progress');
end;
$$;

-- ---------------------------------------------------------------------------
-- Lock in an answer (before the 15 second timer ends, once per question).
-- ---------------------------------------------------------------------------
create or replace function public.submit_match_answer_v1(p_room_id uuid, p_user_id uuid, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_mq public.match_questions%rowtype;
  v_rows integer;
begin
  if not exists (
    select 1 from public.room_players rp
    where rp.room_id = p_room_id and rp.user_id = p_user_id and rp.status = 'active'
  ) then raise exception using message = 'NOT_A_ROOM_MEMBER'; end if;

  select m.* into v_match
  from public.matches m
  where m.room_id = p_room_id and m.status = 'in_progress'
  order by m.started_at desc
  limit 1
  for update;
  if not found then raise exception using message = 'TOO_LATE'; end if;

  if now() < v_match.question_started_at
     or now() >= v_match.question_started_at + interval '15 seconds' then
    raise exception using message = 'TOO_LATE';
  end if;

  select mq.* into v_mq
  from public.match_questions mq
  where mq.match_id = v_match.id and mq.position = v_match.current_position;

  if not exists (
    select 1
    from public.questions q
    cross join lateral jsonb_array_elements_text(q.options) as o(value)
    where q.id = v_mq.question_id and o.value = p_answer
  ) then raise exception using message = 'INVALID_ANSWER'; end if;

  insert into public.match_answers (match_question_id, user_id, selected_answer, answered_at, response_ms)
  values (
    v_mq.id, p_user_id, p_answer, now(),
    least(15000, floor(extract(epoch from (now() - v_match.question_started_at)) * 1000))::integer
  )
  on conflict (match_question_id, user_id) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then raise exception using message = 'ALREADY_ANSWERED'; end if;

  -- Lets the other players see that this player has locked in an answer.
  update public.rooms set updated_at = now() where id = p_room_id;

  return jsonb_build_object('locked', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Internal: score the current question for every active player once its timer ends.
-- ---------------------------------------------------------------------------
create or replace function public.mp_resolve_question_v1(p_match_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_mq public.match_questions%rowtype;
  v_q public.questions%rowtype;
  v_player record;
  v_answer public.match_answers%rowtype;
  v_has_answer boolean;
  v_is_correct boolean;
  v_new_streak integer;
  v_delta integer;
  v_points integer;
begin
  select * into v_match from public.matches where id = p_match_id;
  if not found then return; end if;

  select * into v_mq from public.match_questions
  where match_id = p_match_id and position = v_match.current_position
  for update;
  if not found or v_mq.reveal_at is not null then return; end if;

  select * into v_q from public.questions where id = v_mq.question_id;

  for v_player in
    select rp.user_id, rp.score, rp.current_streak
    from public.room_players rp
    where rp.room_id = v_match.room_id and rp.status = 'active'
    for update
  loop
    select * into v_answer from public.match_answers
    where match_question_id = v_mq.id and user_id = v_player.user_id;
    v_has_answer := found;

    v_is_correct := v_has_answer and v_answer.selected_answer is not null
                    and v_answer.selected_answer = v_q.correct_answer;

    if v_is_correct then
      v_new_streak := v_player.current_streak + 1;
      v_delta := 100 + case when v_new_streak % 3 = 0 then 25 else 0 end;
      v_points := v_delta;
    elsif v_has_answer and v_answer.selected_answer is not null then
      v_new_streak := 0;
      v_delta := -least(25, v_player.score);
      v_points := 0;
    else
      v_new_streak := 0;
      v_delta := 0;
      v_points := 0;
    end if;

    insert into public.match_answers (match_question_id, user_id, selected_answer, is_correct, points_awarded, score_delta)
    values (v_mq.id, v_player.user_id, null, v_is_correct, v_points, v_delta)
    on conflict (match_question_id, user_id) do update
      set is_correct = excluded.is_correct,
          points_awarded = excluded.points_awarded,
          score_delta = excluded.score_delta;

    update public.room_players
    set score = score + v_delta,
        current_streak = v_new_streak,
        longest_streak = greatest(longest_streak, v_new_streak),
        correct_answers = correct_answers + case when v_is_correct then 1 else 0 end
    where room_id = v_match.room_id and user_id = v_player.user_id;
  end loop;

  update public.match_questions set reveal_at = now() where id = v_mq.id;
  update public.rooms set updated_at = now() where id = v_match.room_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Internal: move the shared timeline forward. Safe to call from any player at any
-- time, and it catches up if several steps are overdue.
-- ---------------------------------------------------------------------------
create or replace function public.mp_tick_v1(p_match_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_guard integer := 0;
begin
  loop
    v_guard := v_guard + 1;
    exit when v_guard > 40;

    select * into v_match from public.matches where id = p_match_id for update;
    exit when not found or v_match.status <> 'in_progress';
    exit when now() < v_match.question_started_at + interval '15 seconds';

    perform public.mp_resolve_question_v1(p_match_id);
    exit when now() < v_match.question_started_at + interval '23 seconds';

    if v_match.current_position >= 15 then
      update public.matches set status = 'completed', completed_at = now() where id = p_match_id;
      update public.rooms set status = 'results', updated_at = now() where id = v_match.room_id;
      exit;
    end if;

    update public.matches
    set current_position = current_position + 1,
        question_started_at = question_started_at + interval '23 seconds'
    where id = p_match_id;
    update public.rooms set updated_at = now() where id = v_match.room_id;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- What a player sees right now: get ready, the question, the reveal or the final results.
-- ---------------------------------------------------------------------------
create or replace function public.get_match_state_v1(p_room_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_mq public.match_questions%rowtype;
  v_q public.questions%rowtype;
  v_players jsonb;
  v_mine text;
  v_results jsonb;
  v_review jsonb;
begin
  if not exists (
    select 1 from public.room_players rp
    where rp.room_id = p_room_id and rp.user_id = p_user_id and rp.status = 'active'
  ) then raise exception using message = 'NOT_A_ROOM_MEMBER'; end if;

  select m.* into v_match
  from public.matches m
  where m.room_id = p_room_id
  order by m.started_at desc
  limit 1;
  if not found then raise exception using message = 'MATCH_NOT_FOUND'; end if;

  perform public.mp_tick_v1(v_match.id);
  select m.* into v_match from public.matches m where m.id = v_match.id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', rp.user_id,
      'display_name', rp.display_name,
      'player_tag', rp.player_tag,
      'score', rp.score,
      'streak', rp.current_streak,
      'longest_streak', rp.longest_streak,
      'correct_answers', rp.correct_answers,
      'answered', exists (
        select 1
        from public.match_answers a
        join public.match_questions mq on mq.id = a.match_question_id
        where mq.match_id = v_match.id
          and mq.position = v_match.current_position
          and a.user_id = rp.user_id
          and a.selected_answer is not null
      )
    ) order by rp.score desc, rp.joined_at), '[]'::jsonb)
  into v_players
  from public.room_players rp
  where rp.room_id = p_room_id and rp.status = 'active';

  if v_match.status = 'completed' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'position', mq.position,
        'difficulty', q.difficulty,
        'prompt', q.prompt,
        'selected_answer', a.selected_answer,
        'correct_answer', q.correct_answer,
        'is_correct', coalesce(a.is_correct, false),
        'points_awarded', coalesce(a.score_delta, 0),
        'explanation', q.explanation,
        'source_title', q.source_title,
        'source_url', q.source_url
      ) order by mq.position), '[]'::jsonb)
    into v_review
    from public.match_questions mq
    join public.questions q on q.id = mq.question_id
    left join public.match_answers a on a.match_question_id = mq.id and a.user_id = p_user_id
    where mq.match_id = v_match.id;

    return jsonb_build_object(
      'status', 'completed',
      'category_slug', v_match.category_slug,
      'players', v_players,
      'review', v_review
    );
  end if;

  select mq.* into v_mq
  from public.match_questions mq
  where mq.match_id = v_match.id and mq.position = v_match.current_position;
  select q.* into v_q from public.questions q where q.id = v_mq.question_id;

  if now() < v_match.question_started_at then
    return jsonb_build_object(
      'status', 'in_progress',
      'phase', 'get_ready',
      'position', v_match.current_position,
      'total', 15,
      'category_slug', v_match.category_slug,
      'ms_left', greatest(0, floor(extract(epoch from (v_match.question_started_at - now())) * 1000))::integer,
      'players', v_players
    );
  end if;

  select a.selected_answer into v_mine
  from public.match_answers a
  where a.match_question_id = v_mq.id and a.user_id = p_user_id;

  if v_mq.reveal_at is null then
    return jsonb_build_object(
      'status', 'in_progress',
      'phase', 'answering',
      'position', v_match.current_position,
      'total', 15,
      'category_slug', v_match.category_slug,
      'difficulty', v_q.difficulty,
      'prompt', v_q.prompt,
      'options', v_q.options,
      'my_answer', v_mine,
      'ms_left', greatest(0, floor(extract(epoch from (v_match.question_started_at + interval '15 seconds' - now())) * 1000))::integer,
      'players', v_players
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', a.user_id,
      'selected_answer', a.selected_answer,
      'is_correct', a.is_correct,
      'delta', a.score_delta
    )), '[]'::jsonb)
  into v_results
  from public.match_answers a
  where a.match_question_id = v_mq.id;

  return jsonb_build_object(
    'status', 'in_progress',
    'phase', 'reveal',
    'position', v_match.current_position,
    'total', 15,
    'category_slug', v_match.category_slug,
    'difficulty', v_q.difficulty,
    'prompt', v_q.prompt,
    'options', v_q.options,
    'my_answer', v_mine,
    'correct_answer', v_q.correct_answer,
    'explanation', v_q.explanation,
    'source_title', v_q.source_title,
    'source_url', v_q.source_url,
    'results', v_results,
    'is_last', v_match.current_position >= 15,
    'ms_left', greatest(0, floor(extract(epoch from (v_match.question_started_at + interval '23 seconds' - now())) * 1000))::integer,
    'players', v_players
  );
end;
$$;

revoke all on function public.playable_category_slugs_v1() from public, anon, authenticated;
revoke all on function public.set_category_votes_v1(uuid, uuid, text[]) from public, anon, authenticated;
revoke all on function public.start_countdown_v1(uuid, uuid) from public, anon, authenticated;
revoke all on function public.start_match_v1(uuid) from public, anon, authenticated;
revoke all on function public.advance_countdown_v1(uuid, uuid) from public, anon, authenticated;
revoke all on function public.submit_match_answer_v1(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.mp_resolve_question_v1(uuid) from public, anon, authenticated;
revoke all on function public.mp_tick_v1(uuid) from public, anon, authenticated;
revoke all on function public.get_match_state_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function public.playable_category_slugs_v1() to service_role;
grant execute on function public.set_category_votes_v1(uuid, uuid, text[]) to service_role;
grant execute on function public.start_countdown_v1(uuid, uuid) to service_role;
grant execute on function public.start_match_v1(uuid) to service_role;
grant execute on function public.advance_countdown_v1(uuid, uuid) to service_role;
grant execute on function public.submit_match_answer_v1(uuid, uuid, text) to service_role;
grant execute on function public.mp_resolve_question_v1(uuid) to service_role;
grant execute on function public.mp_tick_v1(uuid) to service_role;
grant execute on function public.get_match_state_v1(uuid, uuid) to service_role;
