-- Washed Delts Casino: Rocket and Chicken
-- Paste into Supabase > SQL Editor and press Run.

-- ---------- Rocket (crash): the multiplier climbs until the rocket blows up; cash out first ----------
-- Each round's crash point is drawn on the server when you launch and stays secret until the round ends.
-- P(crash >= m) = 0.97 / m, so the house keeps 3% at any cash-out target. Capped at 100x.
-- The multiplier grows as e^(0.06 * seconds): 2x at ~11.6s, 10x at ~38s, 100x at ~77s.
create table if not exists rk_rounds (
  team_id int primary key references teams(id),
  bet int not null, crash numeric not null, started_at timestamptz not null default clock_timestamp()
);
alter table rk_rounds enable row level security;
revoke all on rk_rounds from anon, authenticated;

create or replace function _rk_mult(p_secs numeric) returns numeric language sql immutable as $$
  select floor(exp(0.06 * greatest(p_secs, 0)) * 100) / 100 $$;
create or replace function _rk_crash_at(r rk_rounds) returns timestamptz language sql immutable as $$
  select r.started_at + make_interval(secs => ln(r.crash) / 0.06) $$;

-- end any round whose rocket has already blown up (a loss)
create or replace function _rk_sweep(p_team int default null) returns void
language plpgsql security definer set search_path = public as $$
declare r rk_rounds;
begin
  for r in select * from rk_rounds where (p_team is null or team_id = p_team) for update loop
    if clock_timestamp() >= _rk_crash_at(r) then
      perform _log(r.team_id, 'rocket', r.bet, 0, 'Blew up at ' || to_char(r.crash, 'FM990.00') || 'x');
      delete from rk_rounds where team_id = r.team_id;
    end if;
  end loop;
end $$;

-- p_auto: optional auto cash-out (1.01x to 100x). With it, the round resolves right away.
create or replace function rk_launch(p_team int, p_pin text, p_bet int, p_auto numeric default null) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; u numeric; cr numeric; pay int; r rk_rounds;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform _rk_sweep(p_team);
  if exists (select 1 from rk_rounds where team_id = p_team) then raise exception 'Your rocket is still in the air.'; end if;
  if p_auto is not null and (p_auto < 1.01 or p_auto > 100) then raise exception 'Auto cash-out has to be between 1.01x and 100x.'; end if;
  perform _guard(t, p_bet);
  perform _apply(p_team, -p_bet, p_bet);
  u := (_rnd(1000000) + 1) / 1000000.0;                  -- (0, 1]
  cr := least(100, greatest(1, floor(0.97 / u * 100) / 100));
  if p_auto is not null then
    p_auto := floor(p_auto * 100) / 100;
    pay := case when cr >= p_auto then floor(p_bet * p_auto)::int else 0 end;
    perform _apply(p_team, pay, 0);
    perform _log(p_team, 'rocket', p_bet, pay, case when pay > 0 then 'Auto cash-out at ' || to_char(p_auto, 'FM990.00') || 'x · rocket went to ' || to_char(cr, 'FM990.00') || 'x'
                                                   else 'Blew up at ' || to_char(cr, 'FM990.00') || 'x · auto target ' || to_char(p_auto, 'FM990.00') || 'x' end);
    return json_build_object('mode', 'auto', 'crash', cr, 'auto', p_auto, 'payout', pay, 'balance', _bal(p_team));
  end if;
  insert into rk_rounds(team_id, bet, crash, started_at) values (p_team, p_bet, cr, clock_timestamp()) returning * into r;
  if cr <= 1 then perform _rk_sweep(p_team); return json_build_object('mode', 'live', 'state', 'crashed', 'crash', cr, 'elapsed', 0, 'payout', 0, 'balance', _bal(p_team)); end if;
  return json_build_object('mode', 'live', 'state', 'flying', 'elapsed', 0, 'balance', _bal(p_team));
end $$;

-- where the round stands right now; never reveals the crash point before it happens
create or replace function rk_status(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r rk_rounds; el numeric;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from rk_rounds where team_id = p_team;
  if not found then return json_build_object('state', 'idle', 'balance', _bal(p_team)); end if;
  el := extract(epoch from clock_timestamp() - r.started_at);
  if clock_timestamp() >= _rk_crash_at(r) then
    perform _rk_sweep(p_team);
    return json_build_object('state', 'crashed', 'crash', r.crash, 'bet', r.bet, 'payout', 0, 'balance', _bal(p_team));
  end if;
  return json_build_object('state', 'flying', 'bet', r.bet, 'elapsed', el, 'mult', _rk_mult(el), 'balance', _bal(p_team));
end $$;

create or replace function rk_cashout(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r rk_rounds; el numeric; m numeric; pay int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from rk_rounds where team_id = p_team for update;
  if not found then return json_build_object('state', 'idle', 'balance', _bal(p_team)); end if;
  el := extract(epoch from clock_timestamp() - r.started_at);
  if clock_timestamp() >= _rk_crash_at(r) then
    perform _rk_sweep(p_team);
    return json_build_object('state', 'crashed', 'crash', r.crash, 'bet', r.bet, 'payout', 0, 'balance', _bal(p_team));
  end if;
  m := least(_rk_mult(el), r.crash);
  pay := floor(r.bet * m)::int;
  delete from rk_rounds where team_id = p_team;
  perform _apply(p_team, pay, 0);
  perform _log(p_team, 'rocket', r.bet, pay, 'Cashed out at ' || to_char(m, 'FM990.00') || 'x');
  return json_build_object('state', 'cashed', 'mult', m, 'bet', r.bet, 'payout', pay, 'balance', _bal(p_team));
end $$;

create or replace function rk_history(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return coalesce((select json_agg(substring(detail from '([0-9]+\.[0-9]{2})x(?!.*[0-9]+\.[0-9]{2}x)') order by created_at desc)
    from (select * from plays where team_id = p_team and game = 'rocket' and detail ~ '(Blew up|went to)' order by created_at desc limit 12) x), '[]'::json);
end $$;

-- settling waits for rockets in the air, same as blackjack hands
create or replace function admin_settle(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare owed int := 0;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  if exists (select 1 from bj_hands) then raise exception 'A blackjack hand is still in play. Try again in a minute.'; end if;
  perform _rk_sweep();
  if exists (select 1 from rk_rounds) then raise exception 'A rocket is still in the air. Try again in a minute.'; end if;
  insert into pending_rebates(team_id, amount) select team_id, rebate from _rebates() where rebate > 0;
  select coalesce(sum(rebate), 0) into owed from _rebates();
  update teams set base = base + net - settled, settled = net where id is not null;
  update config set last_settled = now() where id = 1;
  return json_build_object('ok', true, 'owed', owed);
end $$;

-- ---------- Chicken: cross lane by lane, cash out before you get hit ----------
-- Every step is rolled on the server when you take it. After k safe steps the multiplier is
-- 0.97 / survive^k, so the house keeps 3% wherever you stop.
create table if not exists ck_rounds (
  team_id int primary key references teams(id),
  bet int not null, level text not null, step int not null default 0,
  created_at timestamptz not null default now()
);
alter table ck_rounds enable row level security;
revoke all on ck_rounds from anon, authenticated;

-- survive chance per lane and number of lanes by difficulty
create or replace function _ck_level(p text, out survive numeric, out lanes int) language sql immutable as $$
  select case p when 'easy' then 0.90 when 'medium' then 0.80 when 'hard' then 0.70 when 'hardcore' then 0.55 end,
         case p when 'easy' then 15 when 'medium' then 12 when 'hard' then 10 when 'hardcore' then 8 end $$;
create or replace function _ck_mult(p_level text, p_step int) returns numeric language sql immutable as $$
  select case when p_step <= 0 then 1 else least(100, floor(0.97 / power((select survive from _ck_level(p_level)), p_step) * 100) / 100) end $$;
grant execute on function _ck_level(text), _ck_mult(text,int) to anon, authenticated;

create or replace function _ck_view(r ck_rounds) returns json language sql stable as $$
  select json_build_object('state', 'crossing', 'level', r.level, 'step', r.step, 'lanes', (select lanes from _ck_level(r.level)),
    'bet', r.bet, 'mult', _ck_mult(r.level, r.step), 'next', _ck_mult(r.level, r.step + 1),
    'cashout', floor(r.bet * _ck_mult(r.level, r.step))::int, 'balance', _bal(r.team_id)) $$;

create or replace function ck_start(p_team int, p_pin text, p_bet int, p_level text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r ck_rounds;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from ck_rounds where team_id = p_team;
  if found then return _ck_view(r); end if;
  if p_level not in ('easy','medium','hard','hardcore') then raise exception 'Pick a difficulty.'; end if;
  perform _guard(t, p_bet);
  perform _apply(p_team, -p_bet, p_bet);
  insert into ck_rounds(team_id, bet, level) values (p_team, p_bet, p_level) returning * into r;
  return _ck_view(r);
end $$;

create or replace function ck_state(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r ck_rounds;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from ck_rounds where team_id = p_team;
  if not found then return json_build_object('state', 'idle', 'balance', _bal(p_team)); end if;
  return _ck_view(r);
end $$;

create or replace function _ck_pay(r ck_rounds, p_note text) returns json
language plpgsql security definer set search_path = public as $$
declare m numeric := _ck_mult(r.level, r.step); pay int := floor(r.bet * m)::int;
begin
  delete from ck_rounds where team_id = r.team_id;
  perform _apply(r.team_id, pay, 0);
  perform _log(r.team_id, 'chicken', r.bet, pay, initcap(r.level) || ' · ' || p_note || ' ' || r.step || ' lane' || case when r.step = 1 then '' else 's' end || ' · ' || to_char(m, 'FM990.00') || 'x');
  return json_build_object('state', 'cashed', 'level', r.level, 'step', r.step, 'mult', m, 'bet', r.bet, 'payout', pay, 'balance', _bal(r.team_id));
end $$;

create or replace function ck_step(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r ck_rounds; lv record;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from ck_rounds where team_id = p_team for update;
  if not found then raise exception 'Start a round first.'; end if;
  select * into lv from _ck_level(r.level);
  if _rnd(1000000) >= lv.survive * 1000000 then
    delete from ck_rounds where team_id = p_team;
    perform _log(p_team, 'chicken', r.bet, 0, initcap(r.level) || ' · hit in lane ' || (r.step + 1));
    return json_build_object('state', 'hit', 'level', r.level, 'step', r.step + 1, 'bet', r.bet, 'payout', 0, 'balance', _bal(p_team));
  end if;
  update ck_rounds set step = step + 1 where team_id = p_team returning * into r;
  if r.step >= lv.lanes then return _ck_pay(r, 'made it across all'); end if;
  return _ck_view(r);
end $$;

create or replace function ck_cashout(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r ck_rounds;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from ck_rounds where team_id = p_team for update;
  if not found then return json_build_object('state', 'idle', 'balance', _bal(p_team)); end if;
  if r.step = 0 then raise exception 'Take at least one step first.'; end if;
  return _ck_pay(r, 'cashed out after');
end $$;

-- settling also handles rockets and chickens: rockets have to land, chickens get cashed out where they stand
create or replace function admin_settle(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare owed int := 0; r ck_rounds;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  if exists (select 1 from bj_hands) then raise exception 'A blackjack hand is still in play. Try again in a minute.'; end if;
  perform _rk_sweep();
  if exists (select 1 from rk_rounds) then raise exception 'A rocket is still in the air. Try again in a minute.'; end if;
  for r in select * from ck_rounds for update loop
    if r.step = 0 then
      delete from ck_rounds where team_id = r.team_id; perform _apply(r.team_id, r.bet, -r.bet);   -- never stepped: refund
    else perform _ck_pay(r, 'auto cashed out at settle after'); end if;
  end loop;
  insert into pending_rebates(team_id, amount) select team_id, rebate from _rebates() where rebate > 0;
  select coalesce(sum(rebate), 0) into owed from _rebates();
  update teams set base = base + net - settled, settled = net where id is not null;
  update config set last_settled = now() where id = 1;
  return json_build_object('ok', true, 'owed', owed);
end $$;

revoke execute on function _rk_sweep(int), _rk_mult(numeric), _rk_crash_at(rk_rounds), _ck_view(ck_rounds), _ck_pay(ck_rounds,text) from public, anon, authenticated;
revoke execute on function rk_launch(int,text,int,numeric), rk_status(int,text), rk_cashout(int,text), rk_history(int,text), ck_start(int,text,int,text), ck_state(int,text), ck_step(int,text), ck_cashout(int,text) from public;
grant execute on function rk_launch(int,text,int,numeric), rk_status(int,text), rk_cashout(int,text), rk_history(int,text), ck_start(int,text,int,text), ck_state(int,text), ck_step(int,text), ck_cashout(int,text) to anon, authenticated;
notify pgrst, 'reload schema';
