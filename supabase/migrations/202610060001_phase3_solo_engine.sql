-- SportStack Phase 3, step 1: Solo Challenge engine and the first question set.
-- Rules (from the frozen blueprint): 15 questions, 15 seconds each, mixed difficulty
-- (3 easy, 6 medium, 6 hard), 100 points per correct answer, +25 bonus on every
-- third consecutive correct answer, answers lock immediately, and the correct answer
-- is only revealed after the full 15 second timer has finished.
-- Blueprint change agreed by the owner: a wrong answer loses 25 points (the score
-- never drops below zero). A timeout scores zero with no penalty. Both reset the streak.
-- Correct answers never leave the database until the reveal.

create unique index if not exists questions_category_prompt_key
  on public.questions (category_slug, prompt);

create table if not exists public.solo_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category_slug text not null references public.question_categories(slug),
  status text not null default 'in_progress' check (status in ('in_progress', 'finished')),
  current_position smallint not null default 1,
  question_started_at timestamptz,
  score integer not null default 0,
  streak integer not null default 0,
  best_streak integer not null default 0,
  correct_count integer not null default 0,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);

create table if not exists public.solo_attempt_questions (
  attempt_id uuid not null references public.solo_attempts(id) on delete cascade,
  position smallint not null,
  question_id uuid not null references public.questions(id),
  selected_answer text,
  answered_at timestamptz,
  resolved boolean not null default false,
  is_correct boolean not null default false,
  points_awarded integer not null default 0,
  response_ms integer,
  primary key (attempt_id, position)
);

create index if not exists solo_attempts_user_idx on public.solo_attempts (user_id, started_at desc);

alter table public.solo_attempts enable row level security;
alter table public.solo_attempt_questions enable row level security;
revoke all on table public.solo_attempts from anon, authenticated;
revoke all on table public.solo_attempt_questions from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Which categories have enough questions for a full challenge (15 or more).
-- ---------------------------------------------------------------------------
create or replace function public.list_solo_categories_v1()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(t.category_slug order by t.category_slug), '[]'::jsonb)
  from (
    select q.category_slug
    from public.questions q
    where q.is_active
    group by q.category_slug
    having count(*) >= 15
  ) t;
$$;

-- ---------------------------------------------------------------------------
-- Latest unfinished attempt for a player, so a refresh can resume it.
-- ---------------------------------------------------------------------------
create or replace function public.get_active_solo_attempt_v1(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('attempt_id', (
    select a.id from public.solo_attempts a
    where a.user_id = p_user_id and a.status = 'in_progress'
    order by a.started_at desc
    limit 1
  ));
$$;

-- ---------------------------------------------------------------------------
-- Start a challenge: 3 easy, 6 medium and 6 hard questions from one category,
-- played in rising difficulty with a random order inside each level.
-- ---------------------------------------------------------------------------
create or replace function public.start_solo_challenge_v1(p_user_id uuid, p_category text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt uuid;
  v_rows integer;
begin
  if not exists (
    select 1 from public.question_categories c
    where c.slug = p_category and c.is_launch_category
  ) then raise exception using message = 'INVALID_CATEGORY'; end if;

  delete from public.solo_attempts where user_id = p_user_id and status = 'in_progress';

  insert into public.solo_attempts (user_id, category_slug, question_started_at)
  values (p_user_id, p_category, now())
  returning id into v_attempt;

  with picked as (
    (select q.id, 1 as rank from public.questions q
      where q.category_slug = p_category and q.is_active and q.difficulty = 'easy'
      order by random() limit 3)
    union all
    (select q.id, 2 as rank from public.questions q
      where q.category_slug = p_category and q.is_active and q.difficulty = 'medium'
      order by random() limit 6)
    union all
    (select q.id, 3 as rank from public.questions q
      where q.category_slug = p_category and q.is_active and q.difficulty = 'hard'
      order by random() limit 6)
  )
  insert into public.solo_attempt_questions (attempt_id, position, question_id)
  select v_attempt, (row_number() over (order by p.rank, random()))::smallint, p.id
  from picked p;

  get diagnostics v_rows = row_count;
  if v_rows <> 15 then raise exception using message = 'NOT_ENOUGH_QUESTIONS'; end if;

  return jsonb_build_object('attempt_id', v_attempt);
end;
$$;

-- ---------------------------------------------------------------------------
-- Internal: once the 15 second timer has ended, mark the current question as
-- resolved and apply points and streak. Safe to call repeatedly.
-- ---------------------------------------------------------------------------
create or replace function public.solo_resolve_current_v1(p_attempt_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt public.solo_attempts%rowtype;
  v_row public.solo_attempt_questions%rowtype;
  v_correct text;
  v_is_correct boolean;
  v_new_streak integer;
  v_points integer;
begin
  select * into v_attempt from public.solo_attempts where id = p_attempt_id for update;
  if not found or v_attempt.status <> 'in_progress' then return; end if;
  if now() < v_attempt.question_started_at + interval '15 seconds' then return; end if;

  select * into v_row from public.solo_attempt_questions
  where attempt_id = p_attempt_id and position = v_attempt.current_position
  for update;
  if not found or v_row.resolved then return; end if;

  select q.correct_answer into v_correct from public.questions q where q.id = v_row.question_id;
  v_is_correct := v_row.selected_answer is not null and v_row.selected_answer = v_correct;

  if v_is_correct then
    v_new_streak := v_attempt.streak + 1;
    v_points := 100 + case when v_new_streak % 3 = 0 then 25 else 0 end;
  elsif v_row.selected_answer is not null then
    -- Wrong answer: lose 25 points (the score never drops below zero) and reset the streak.
    v_new_streak := 0;
    v_points := -least(25, v_attempt.score);
  else
    -- No answer before the timer ended: no penalty, but the streak resets.
    v_new_streak := 0;
    v_points := 0;
  end if;

  update public.solo_attempt_questions
  set resolved = true, is_correct = v_is_correct, points_awarded = v_points
  where attempt_id = p_attempt_id and position = v_attempt.current_position;

  update public.solo_attempts
  set score = score + v_points,
      streak = v_new_streak,
      best_streak = greatest(best_streak, v_new_streak),
      correct_count = correct_count + case when v_is_correct then 1 else 0 end
  where id = p_attempt_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Current state: the question being answered (no answer included), the reveal
-- once the timer has ended, or the final results with a full answer review.
-- ---------------------------------------------------------------------------
create or replace function public.get_solo_state_v1(p_attempt_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt public.solo_attempts%rowtype;
  v_row public.solo_attempt_questions%rowtype;
  v_q public.questions%rowtype;
  v_total integer;
  v_ms_left integer;
  v_review jsonb;
begin
  if not exists (
    select 1 from public.solo_attempts a where a.id = p_attempt_id and a.user_id = p_user_id
  ) then raise exception using message = 'ATTEMPT_NOT_FOUND'; end if;

  perform public.solo_resolve_current_v1(p_attempt_id);

  select * into v_attempt from public.solo_attempts where id = p_attempt_id;
  select count(*) into v_total from public.solo_attempt_questions where attempt_id = p_attempt_id;

  if v_attempt.status = 'finished' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'position', r.position,
        'difficulty', q.difficulty,
        'prompt', q.prompt,
        'selected_answer', r.selected_answer,
        'correct_answer', q.correct_answer,
        'is_correct', r.is_correct,
        'points_awarded', r.points_awarded,
        'explanation', q.explanation,
        'source_title', q.source_title,
        'source_url', q.source_url
      ) order by r.position), '[]'::jsonb)
    into v_review
    from public.solo_attempt_questions r
    join public.questions q on q.id = r.question_id
    where r.attempt_id = p_attempt_id;

    return jsonb_build_object(
      'status', 'finished',
      'category_slug', v_attempt.category_slug,
      'score', v_attempt.score,
      'correct_count', v_attempt.correct_count,
      'total', v_total,
      'accuracy', case when v_total = 0 then 0 else round(v_attempt.correct_count * 100.0 / v_total) end,
      'best_streak', v_attempt.best_streak,
      'review', v_review
    );
  end if;

  select * into v_row from public.solo_attempt_questions
  where attempt_id = p_attempt_id and position = v_attempt.current_position;
  select * into v_q from public.questions where id = v_row.question_id;

  v_ms_left := greatest(0, floor(extract(epoch from (v_attempt.question_started_at + interval '15 seconds' - now())) * 1000))::integer;

  if not v_row.resolved then
    return jsonb_build_object(
      'status', 'in_progress',
      'phase', 'answering',
      'position', v_attempt.current_position,
      'total', v_total,
      'difficulty', v_q.difficulty,
      'prompt', v_q.prompt,
      'options', v_q.options,
      'selected_answer', v_row.selected_answer,
      'ms_left', v_ms_left,
      'score', v_attempt.score,
      'streak', v_attempt.streak
    );
  end if;

  return jsonb_build_object(
    'status', 'in_progress',
    'phase', 'reveal',
    'position', v_attempt.current_position,
    'total', v_total,
    'difficulty', v_q.difficulty,
    'prompt', v_q.prompt,
    'options', v_q.options,
    'selected_answer', v_row.selected_answer,
    'correct_answer', v_q.correct_answer,
    'is_correct', v_row.is_correct,
    'points_awarded', v_row.points_awarded,
    'explanation', v_q.explanation,
    'source_title', v_q.source_title,
    'source_url', v_q.source_url,
    'score', v_attempt.score,
    'streak', v_attempt.streak,
    'is_last', v_attempt.current_position >= v_total
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Lock in an answer. Only one answer per question and only before the timer ends.
-- Nothing about correctness is returned here.
-- ---------------------------------------------------------------------------
create or replace function public.submit_solo_answer_v1(p_attempt_id uuid, p_user_id uuid, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt public.solo_attempts%rowtype;
  v_row public.solo_attempt_questions%rowtype;
begin
  select * into v_attempt from public.solo_attempts
  where id = p_attempt_id and user_id = p_user_id
  for update;
  if not found then raise exception using message = 'ATTEMPT_NOT_FOUND'; end if;
  if v_attempt.status <> 'in_progress' then raise exception using message = 'TOO_LATE'; end if;
  if now() >= v_attempt.question_started_at + interval '15 seconds' then
    raise exception using message = 'TOO_LATE';
  end if;

  select * into v_row from public.solo_attempt_questions
  where attempt_id = p_attempt_id and position = v_attempt.current_position
  for update;
  if v_row.answered_at is not null then raise exception using message = 'ALREADY_ANSWERED'; end if;

  if not exists (
    select 1
    from public.questions q
    cross join lateral jsonb_array_elements_text(q.options) as o(value)
    where q.id = v_row.question_id and o.value = p_answer
  ) then raise exception using message = 'INVALID_ANSWER'; end if;

  update public.solo_attempt_questions
  set selected_answer = p_answer,
      answered_at = now(),
      response_ms = least(15000, floor(extract(epoch from (now() - v_attempt.question_started_at)) * 1000))::integer
  where attempt_id = p_attempt_id and position = v_attempt.current_position;

  return jsonb_build_object('locked', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Move on after the reveal: next question, or finish the challenge.
-- ---------------------------------------------------------------------------
create or replace function public.advance_solo_v1(p_attempt_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt public.solo_attempts%rowtype;
  v_total integer;
  v_resolved boolean;
begin
  if not exists (
    select 1 from public.solo_attempts a where a.id = p_attempt_id and a.user_id = p_user_id
  ) then raise exception using message = 'ATTEMPT_NOT_FOUND'; end if;

  perform public.solo_resolve_current_v1(p_attempt_id);

  select * into v_attempt from public.solo_attempts where id = p_attempt_id for update;
  if v_attempt.status = 'finished' then return jsonb_build_object('ok', true); end if;

  select r.resolved into v_resolved from public.solo_attempt_questions r
  where r.attempt_id = p_attempt_id and r.position = v_attempt.current_position;
  if not coalesce(v_resolved, false) then raise exception using message = 'NOT_REVEALED'; end if;

  select count(*) into v_total from public.solo_attempt_questions where attempt_id = p_attempt_id;

  if v_attempt.current_position >= v_total then
    update public.solo_attempts set status = 'finished', finished_at = now() where id = p_attempt_id;
  else
    update public.solo_attempts
    set current_position = current_position + 1, question_started_at = now()
    where id = p_attempt_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.list_solo_categories_v1() from public, anon, authenticated;
revoke all on function public.get_active_solo_attempt_v1(uuid) from public, anon, authenticated;
revoke all on function public.start_solo_challenge_v1(uuid, text) from public, anon, authenticated;
revoke all on function public.solo_resolve_current_v1(uuid) from public, anon, authenticated;
revoke all on function public.get_solo_state_v1(uuid, uuid) from public, anon, authenticated;
revoke all on function public.submit_solo_answer_v1(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.advance_solo_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_solo_categories_v1() to service_role;
grant execute on function public.get_active_solo_attempt_v1(uuid) to service_role;
grant execute on function public.start_solo_challenge_v1(uuid, text) to service_role;
grant execute on function public.solo_resolve_current_v1(uuid) to service_role;
grant execute on function public.get_solo_state_v1(uuid, uuid) to service_role;
grant execute on function public.submit_solo_answer_v1(uuid, uuid, text) to service_role;
grant execute on function public.advance_solo_v1(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- First question sets: Football (Premier League and Champions League).
-- Each category has 3 easy, 6 medium and 6 hard questions.
-- ---------------------------------------------------------------------------
insert into public.questions
  (category_slug, difficulty, answer_format, prompt, options, correct_answer, explanation, source_title, source_url)
values
  ('football-premier-league', 'easy', 'multiple_choice',
   'Which club has won the most Premier League titles?',
   '["Liverpool", "Manchester City", "Manchester United", "Arsenal"]'::jsonb,
   'Manchester United',
   'Manchester United have won the Premier League 13 times, all of them under Sir Alex Ferguson.',
   'Premier League (Wikipedia)', 'https://en.wikipedia.org/wiki/Premier_League'),

  ('football-premier-league', 'easy', 'multiple_choice',
   'In which year did the Premier League begin?',
   '["1986", "1989", "1992", "1996"]'::jsonb,
   '1992',
   'The Premier League began on 15 August 1992, replacing the old First Division as the top tier of English football.',
   'Premier League (Wikipedia)', 'https://en.wikipedia.org/wiki/Premier_League'),

  ('football-premier-league', 'easy', 'true_false',
   'True or false: Arsenal went unbeaten through a full 38-game Premier League season in 2003-04.',
   '["True", "False"]'::jsonb,
   'True',
   'Arsenal won 26 and drew 12 of their 38 games, and the team became known as The Invincibles.',
   '2003-04 Arsenal F.C. season (Wikipedia)', 'https://en.wikipedia.org/wiki/2003%E2%80%9304_Arsenal_F.C._season'),

  ('football-premier-league', 'medium', 'multiple_choice',
   'Who is the Premier Leagues all-time leading goalscorer with 260 goals?',
   '["Wayne Rooney", "Alan Shearer", "Harry Kane", "Thierry Henry"]'::jsonb,
   'Alan Shearer',
   'Alan Shearer scored 260 Premier League goals for Blackburn Rovers and Newcastle United.',
   'List of Premier League top scorers (Wikipedia)', 'https://en.wikipedia.org/wiki/List_of_Premier_League_top_scorers'),

  ('football-premier-league', 'medium', 'multiple_choice',
   'Which club won the 2015-16 Premier League after starting the season as 5000-1 outsiders?',
   '["Tottenham Hotspur", "Leicester City", "Southampton", "West Ham United"]'::jsonb,
   'Leicester City',
   'Leicester City, managed by Claudio Ranieri, were priced at 5000-1 before the season and went on to win the title.',
   '2015-16 Leicester City F.C. season (Wikipedia)', 'https://en.wikipedia.org/wiki/2015%E2%80%9316_Leicester_City_F.C._season'),

  ('football-premier-league', 'medium', 'multiple_choice',
   'Which manager led Arsenals unbeaten Invincibles team of 2003-04?',
   '["Arsène Wenger", "George Graham", "Unai Emery", "Mikel Arteta"]'::jsonb,
   'Arsène Wenger',
   'Arsène Wenger managed Arsenal from 1996 to 2018 and won three Premier League titles, including the unbeaten 2003-04 season.',
   'Arsène Wenger (Wikipedia)', 'https://en.wikipedia.org/wiki/Ars%C3%A8ne_Wenger'),

  ('football-premier-league', 'medium', 'multiple_choice',
   'Who scored 36 goals in 2022-23 to set the Premier League record for a 38-game season?',
   '["Mohamed Salah", "Harry Kane", "Erling Haaland", "Alan Shearer"]'::jsonb,
   'Erling Haaland',
   'Haaland scored 36 in his first Premier League season with Manchester City, beating the previous 38-game record of 32 set by Mohamed Salah in 2017-18.',
   'Erling Haaland (Wikipedia)', 'https://en.wikipedia.org/wiki/Erling_Haaland'),

  ('football-premier-league', 'medium', 'multiple_choice',
   'Which club became the first to reach 100 points in a Premier League season, in 2017-18?',
   '["Chelsea", "Manchester City", "Liverpool", "Manchester United"]'::jsonb,
   'Manchester City',
   'Manchester City, managed by Pep Guardiola, finished the 2017-18 season on 100 points.',
   '2017-18 Manchester City F.C. season (Wikipedia)', 'https://en.wikipedia.org/wiki/2017%E2%80%9318_Manchester_City_F.C._season'),

  ('football-premier-league', 'medium', 'multiple_choice',
   'Mohamed Salah joined Liverpool in 2017 from which Italian club?',
   '["Juventus", "Fiorentina", "Roma", "Napoli"]'::jsonb,
   'Roma',
   'Liverpool signed Salah from Roma in June 2017.',
   'Mohamed Salah (Wikipedia)', 'https://en.wikipedia.org/wiki/Mohamed_Salah'),

  ('football-premier-league', 'hard', 'multiple_choice',
   'Who scored the first goal in Premier League history, on 15 August 1992?',
   '["Eric Cantona", "Teddy Sheringham", "Brian Deane", "Alan Shearer"]'::jsonb,
   'Brian Deane',
   'Brian Deane headed in for Sheffield United against Manchester United after five minutes at Bramall Lane.',
   'Brian Deane (Wikipedia)', 'https://en.wikipedia.org/wiki/Brian_Deane'),

  ('football-premier-league', 'hard', 'multiple_choice',
   'Which club, managed by Kenny Dalglish, won the Premier League title in 1994-95?',
   '["Newcastle United", "Blackburn Rovers", "Leeds United", "Aston Villa"]'::jsonb,
   'Blackburn Rovers',
   'Blackburn finished one point ahead of Manchester United to win the 1994-95 title, led by Alan Shearers goals.',
   '1994-95 Blackburn Rovers F.C. season (Wikipedia)', 'https://en.wikipedia.org/wiki/1994%E2%80%9395_Blackburn_Rovers_F.C._season'),

  ('football-premier-league', 'hard', 'multiple_choice',
   'Which goalkeeper holds the record for the most Premier League clean sheets, with 202?',
   '["Petr Čech", "David James", "Edwin van der Sar", "Peter Schmeichel"]'::jsonb,
   'Petr Čech',
   'Petr Čech kept 202 clean sheets in 443 Premier League games for Chelsea and Arsenal.',
   'Petr Čech (Wikipedia)', 'https://en.wikipedia.org/wiki/Petr_%C4%8Cech'),

  ('football-premier-league', 'hard', 'multiple_choice',
   'Whose stoppage-time goal on the final day of 2011-12 won Manchester City the Premier League title?',
   '["Edin Džeko", "Carlos Tevez", "Sergio Agüero", "Mario Balotelli"]'::jsonb,
   'Sergio Agüero',
   'Agüero scored in stoppage time against Queens Park Rangers to give City a 3-2 win and the title on goal difference over Manchester United.',
   '2011-12 Premier League (Wikipedia)', 'https://en.wikipedia.org/wiki/2011%E2%80%9312_Premier_League'),

  ('football-premier-league', 'hard', 'multiple_choice',
   'Which club won the 2004-05 Premier League with 95 points, its first top-flight title in 50 years?',
   '["Arsenal", "Chelsea", "Manchester United", "Everton"]'::jsonb,
   'Chelsea',
   'José Mourinhos Chelsea won their first top-flight title since 1955 and set a then-record total of 95 points.',
   '2004-05 Chelsea F.C. season (Wikipedia)', 'https://en.wikipedia.org/wiki/2004%E2%80%9305_Chelsea_F.C._season'),

  ('football-premier-league', 'hard', 'multiple_choice',
   'How many clubs competed in the first Premier League season, 1992-93?',
   '["18", "20", "22", "24"]'::jsonb,
   '22',
   'The league had 22 clubs until it was reduced to 20 after the 1994-95 season.',
   '1992-93 FA Premier League (Wikipedia)', 'https://en.wikipedia.org/wiki/1992%E2%80%9393_FA_Premier_League'),

  ('football-champions-league', 'easy', 'multiple_choice',
   'Which club has won the most European Cup and Champions League titles?',
   '["AC Milan", "Real Madrid", "Bayern Munich", "Liverpool"]'::jsonb,
   'Real Madrid',
   'Real Madrid have won the competition more times than any other club, including the first five editions from 1956 to 1960.',
   'UEFA Champions League (Wikipedia)', 'https://en.wikipedia.org/wiki/UEFA_Champions_League'),

  ('football-champions-league', 'easy', 'multiple_choice',
   'What is the nickname of the Champions League trophy, because of its large handles?',
   '["Big Ears", "The Golden Boot", "The Silver Cup", "The Old Lady"]'::jsonb,
   'Big Ears',
   'The trophy is known as Big Ears because of its large handles.',
   'UEFA Champions League (Wikipedia)', 'https://en.wikipedia.org/wiki/UEFA_Champions_League'),

  ('football-champions-league', 'easy', 'true_false',
   'True or false: the Champions League final is played as a single match, not over two legs.',
   '["True", "False"]'::jsonb,
   'True',
   'The final is a single match played at a pre-selected venue.',
   'UEFA Champions League (Wikipedia)', 'https://en.wikipedia.org/wiki/UEFA_Champions_League'),

  ('football-champions-league', 'medium', 'multiple_choice',
   'Which club came back from 3-0 down at half-time to beat AC Milan on penalties in the 2005 Champions League final?',
   '["Chelsea", "Liverpool", "Barcelona", "Manchester United"]'::jsonb,
   'Liverpool',
   'Liverpool scored three goals in six minutes after half-time in Istanbul and won the shootout.',
   '2005 UEFA Champions League final (Wikipedia)', 'https://en.wikipedia.org/wiki/2005_UEFA_Champions_League_final'),

  ('football-champions-league', 'medium', 'multiple_choice',
   'Who is the all-time leading goalscorer in Champions League history?',
   '["Lionel Messi", "Robert Lewandowski", "Karim Benzema", "Cristiano Ronaldo"]'::jsonb,
   'Cristiano Ronaldo',
   'Cristiano Ronaldo scored 140 goals in the competition, ahead of Lionel Messi.',
   'List of UEFA Champions League top scorers (Wikipedia)', 'https://en.wikipedia.org/wiki/List_of_UEFA_Champions_League_top_scorers'),

  ('football-champions-league', 'medium', 'multiple_choice',
   'Which Italian club has won the European Cup or Champions League seven times?',
   '["Juventus", "Inter Milan", "AC Milan", "Roma"]'::jsonb,
   'AC Milan',
   'AC Milan have won seven titles, most recently in 2007. Inter Milan have won three and Juventus two.',
   'AC Milan (Wikipedia)', 'https://en.wikipedia.org/wiki/AC_Milan'),

  ('football-champions-league', 'medium', 'multiple_choice',
   'Which club beat Juventus 3-1 in the 2015 Champions League final in Berlin?',
   '["Bayern Munich", "Real Madrid", "Barcelona", "Chelsea"]'::jsonb,
   'Barcelona',
   'Barcelona completed a treble that season, winning La Liga, the Copa del Rey and the Champions League.',
   '2015 UEFA Champions League final (Wikipedia)', 'https://en.wikipedia.org/wiki/2015_UEFA_Champions_League_final'),

  ('football-champions-league', 'medium', 'multiple_choice',
   'Which club won its second Champions League title in 2021 by beating Manchester City in Porto?',
   '["Liverpool", "Chelsea", "Atlético Madrid", "Paris Saint-Germain"]'::jsonb,
   'Chelsea',
   'Kai Havertz scored the only goal of the final in Porto.',
   '2021 UEFA Champions League final (Wikipedia)', 'https://en.wikipedia.org/wiki/2021_UEFA_Champions_League_final'),

  ('football-champions-league', 'medium', 'multiple_choice',
   'Which club won its first Champions League title in 2023 by beating Inter Milan in Istanbul?',
   '["Paris Saint-Germain", "Atlético Madrid", "Manchester City", "Tottenham Hotspur"]'::jsonb,
   'Manchester City',
   'Manchester City won 1-0 and completed a treble that season.',
   '2023 UEFA Champions League final (Wikipedia)', 'https://en.wikipedia.org/wiki/2023_UEFA_Champions_League_final'),

  ('football-champions-league', 'hard', 'multiple_choice',
   'Which English club was the first to win the European Cup, in 1968?',
   '["Liverpool", "Manchester United", "Nottingham Forest", "Leeds United"]'::jsonb,
   'Manchester United',
   'Manchester United beat Benfica 4-1 after extra time at Wembley.',
   '1967-68 European Cup (Wikipedia)', 'https://en.wikipedia.org/wiki/1967%E2%80%9368_European_Cup'),

  ('football-champions-league', 'hard', 'multiple_choice',
   'Who scored a famous volley to win the 2002 Champions League final for Real Madrid at Hampden Park?',
   '["Raúl", "Zinedine Zidane", "Luís Figo", "Roberto Carlos"]'::jsonb,
   'Zinedine Zidane',
   'Zidanes left-footed volley made it 2-1 against Bayer Leverkusen.',
   '2002 UEFA Champions League final (Wikipedia)', 'https://en.wikipedia.org/wiki/2002_UEFA_Champions_League_final'),

  ('football-champions-league', 'hard', 'multiple_choice',
   'Which English club, managed by Brian Clough, won the European Cup in both 1979 and 1980?',
   '["Aston Villa", "Nottingham Forest", "Derby County", "Leeds United"]'::jsonb,
   'Nottingham Forest',
   'Nottingham Forest won back-to-back European Cups under Brian Clough.',
   '1979-80 European Cup (Wikipedia)', 'https://en.wikipedia.org/wiki/1979%E2%80%9380_European_Cup'),

  ('football-champions-league', 'hard', 'multiple_choice',
   'In which stadium did Manchester United win the 1999 Champions League final against Bayern Munich?',
   '["Wembley Stadium", "Camp Nou", "Santiago Bernabéu", "Olympiastadion"]'::jsonb,
   'Camp Nou',
   'United scored twice in stoppage time in Barcelona to win 2-1.',
   '1999 UEFA Champions League final (Wikipedia)', 'https://en.wikipedia.org/wiki/1999_UEFA_Champions_League_final'),

  ('football-champions-league', 'hard', 'multiple_choice',
   'From the 2024-25 season, how many clubs take part in the Champions League league phase?',
   '["24", "32", "36", "40"]'::jsonb,
   '36',
   'The league phase replaced the group stage and has 36 clubs, each playing eight matches.',
   '2024-25 UEFA Champions League (Wikipedia)', 'https://en.wikipedia.org/wiki/2024%E2%80%9325_UEFA_Champions_League'),

  ('football-champions-league', 'hard', 'multiple_choice',
   'Which manager has won the most European Cup and Champions League titles, with five?',
   '["Pep Guardiola", "Zinedine Zidane", "Carlo Ancelotti", "Bob Paisley"]'::jsonb,
   'Carlo Ancelotti',
   'Ancelotti won with AC Milan in 2003 and 2007 and with Real Madrid in 2014, 2022 and 2024.',
   'Carlo Ancelotti (Wikipedia)', 'https://en.wikipedia.org/wiki/Carlo_Ancelotti')
on conflict (category_slug, prompt) do nothing;

-- Safety check: every correct answer must be one of its options.
do $$
begin
  if exists (
    select 1 from public.questions q
    where not (q.options @> to_jsonb(array[q.correct_answer]))
  ) then
    raise exception 'Question check failed: a correct answer is not among its options.';
  end if;
end;
$$;
