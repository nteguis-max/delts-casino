-- Washed Delts Casino: same-game parlays (side + total)
-- Paste into Supabase > SQL Editor and press Run. Run migrate_parlays.sql first.

-- ---------- same-game parlays: one side (spread or moneyline) + the total ----------
alter table config add column if not exists sgp_pct int not null default 90;
alter table sb_parlays add column if not exists sgp_pct int not null default 100;
alter table sb_parlay_legs drop constraint if exists sb_parlay_legs_pkey;
alter table sb_parlay_legs add primary key (parlay_id, game_id, market);

-- parlay multiplier: each game's picks multiply together; a game with two picks
-- pays p_pct% of that pair's winnings. p_won_only = true counts only legs that won (for grading).
create or replace function _parlay_dec(p_parlay bigint, p_won_only boolean) returns numeric
language sql stable security definer set search_path = public as $$
  with legs as (
    select l.game_id, _sb_dec(l.price) d from sb_parlay_legs l
    where l.parlay_id = p_parlay and (not p_won_only or l.result = 'won')),
  per_game as (
    select game_id, count(*) n, exp(sum(ln(d))) d from legs group by game_id),
  pct as (select sgp_pct from sb_parlays where id = p_parlay)
  select coalesce(exp(sum(ln(case when n > 1 then 1 + (d - 1) * (select sgp_pct from pct) / 100.0 else d end))), 1)
  from per_game $$;

create or replace function sb_place_parlay(p_team int, p_pin text, p_legs jsonb, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; l jsonb; q record; dec numeric; pid bigint; n int; cap int; pct int; bad text;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  n := jsonb_array_length(coalesce(p_legs, '[]'));
  if n < 2 then raise exception 'A parlay needs at least 2 picks.'; end if;
  if n > 6 then raise exception 'Parlays max out at 6 picks.'; end if;
  -- per game: at most one side pick (spread or moneyline) plus at most one total
  select string_agg(gid, ',') into bad from (
    select x ->> 'game' gid from jsonb_array_elements(p_legs) x
    group by x ->> 'game'
    having count(*) filter (where x ->> 'market' in ('spread','ml')) > 1
        or count(*) filter (where x ->> 'market' = 'total') > 1) z;
  if bad is not null then
    raise exception 'From one game you can combine a spread or moneyline with the total, but not the spread and moneyline together.';
  end if;
  perform _guard(t, p_bet, false);
  select parlay_max_payout, sgp_pct into cap, pct from config where id = 1;
  for l in select * from jsonb_array_elements(p_legs) loop
    select * into q from _sb_quote(l ->> 'game', l ->> 'market', l ->> 'pick');
  end loop;
  perform _apply(p_team, -p_bet, p_bet);
  insert into sb_parlays(team_id, stake, sgp_pct) values (p_team, p_bet, pct) returning id into pid;
  for l in select * from jsonb_array_elements(p_legs) loop
    select * into q from _sb_quote(l ->> 'game', l ->> 'market', l ->> 'pick');
    insert into sb_parlay_legs(parlay_id, game_id, market, pick, line, price) values (pid, l ->> 'game', l ->> 'market', l ->> 'pick', q.ln, q.pr);
  end loop;
  dec := _parlay_dec(pid, false);
  if floor(p_bet * dec) > cap then
    raise exception 'Parlay payouts max out at $%. Lower your bet to $% or less.', cap, floor(cap / dec);
  end if;
  return json_build_object('ok', true, 'id', pid, 'multiplier', round(dec, 2), 'toWin', floor(p_bet * dec)::int - p_bet, 'balance', _bal(p_team));
end $$;

create or replace function _sb_grade_parlays() returns int
language plpgsql security definer set search_path = public as $$
declare lg record; p record; g sb_games; m numeric; dec numeric; pay int; res text; n int := 0; legs text; cap int;
begin
  for lg in select l.* from sb_parlay_legs l join sb_parlays pp on pp.id = l.parlay_id
            where l.result is null and pp.status = 'open' and l.game_id in (select id from sb_games where final) loop
    select * into g from sb_games where id = lg.game_id;
    m := _sb_margin(g, lg.market, lg.pick, lg.line);
    update sb_parlay_legs set result = case when m > 0 then 'won' when m = 0 then 'push' else 'lost' end
      where parlay_id = lg.parlay_id and game_id = lg.game_id and market = lg.market;
  end loop;
  select parlay_max_payout into cap from config where id = 1;
  for p in select * from sb_parlays where status = 'open' for update loop
    if exists (select 1 from sb_parlay_legs where parlay_id = p.id and result = 'lost') then
      res := 'lost'; pay := 0;
    elsif not exists (select 1 from sb_parlay_legs where parlay_id = p.id and result is null) then
      dec := _parlay_dec(p.id, true);
      if dec = 1 then res := 'push'; pay := p.stake; else res := 'won'; pay := least(floor(p.stake * dec)::int, greatest(cap, p.stake)); end if;
    else continue; end if;
    update sb_parlays set status = res, payout = pay, graded_at = now() where id = p.id;
    select string_agg(_sb_label(g2, l.market, l.pick, l.line) || coalesce(case l.result when 'won' then ' ✓' when 'lost' then ' ✗' when 'push' then ' push' end, ''), ', ' order by g2.kickoff, l.market)
      into legs from sb_parlay_legs l join sb_games g2 on g2.id = l.game_id where l.parlay_id = p.id;
    perform _apply(p.team_id, pay, 0);
    perform _log(p.team_id, 'parlay', p.stake, pay, (select count(*) from sb_parlay_legs where parlay_id = p.id) || '-leg parlay · ' || legs);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function sb_my_bets(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return coalesce((select json_agg(x order by (x ->> 'created_at') desc) from (
    select json_build_object('kind', 'straight', 'id', b.id, 'created_at', b.created_at, 'game', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
      'label', _sb_label(g, b.market, b.pick, b.line), 'price', b.price, 'stake', b.stake, 'toWin', _sb_return(b.stake, b.price) - b.stake,
      'status', b.status, 'payout', b.payout)::jsonb x
    from sb_bets b join sb_games g on g.id = b.game_id
    where b.team_id = p_team and (b.status = 'open' or b.graded_at > now() - interval '7 days')
    union all
    select json_build_object('kind', 'parlay', 'id', p.id, 'created_at', p.created_at, 'stake', p.stake, 'status', p.status, 'payout', p.payout,
      'toWin', least(floor(p.stake * _parlay_dec(p.id, false))::int, greatest((select parlay_max_payout from config where id = 1), p.stake)) - p.stake,
      'legs', (select json_agg(json_build_object('label', _sb_label(g, l.market, l.pick, l.line), 'price', l.price, 'game', g.away || ' @ ' || g.home,
                 'kickoff', g.kickoff, 'result', l.result) order by g.kickoff, l.market) from sb_parlay_legs l join sb_games g on g.id = l.game_id where l.parlay_id = p.id))::jsonb
    from sb_parlays p where p.team_id = p_team and (p.status = 'open' or p.graded_at > now() - interval '7 days')
  ) s(x)), '[]'::json);
end $$;

create or replace view v_sb_ticker as
  select 'straight' as kind, b.id, b.created_at, t.name as team_name, b.stake,
    _sb_return(b.stake, b.price) - b.stake as to_win,
    jsonb_build_array(jsonb_build_object('game', b.game_id, 'market', b.market, 'pick', b.pick, 'price', b.price,
      'label', _sb_label(g, b.market, b.pick, b.line), 'matchup', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
      'started', g.state <> 'pre' or g.kickoff <= now())) as legs
  from sb_bets b join sb_games g on g.id = b.game_id join teams t on t.id = b.team_id
  where b.status = 'open'
  union all
  select 'parlay', p.id, p.created_at, t.name, p.stake,
    least(floor(p.stake * _parlay_dec(p.id, false))::int, greatest((select parlay_max_payout from config where id = 1), p.stake)) - p.stake,
    (select jsonb_agg(jsonb_build_object('game', l.game_id, 'market', l.market, 'pick', l.pick, 'price', l.price,
       'label', _sb_label(g, l.market, l.pick, l.line), 'matchup', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
       'started', g.state <> 'pre' or g.kickoff <= now(), 'result', l.result) order by g.kickoff, l.market)
     from sb_parlay_legs l join sb_games g on g.id = l.game_id where l.parlay_id = p.id)
  from sb_parlays p join teams t on t.id = p.team_id
  where p.status = 'open';
grant select on v_sb_ticker to anon, authenticated;

create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or extract(isodow from now() at time zone 'America/New_York') = 2
    or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) as blackout,
    rebate_pct, parlay_max_payout, sgp_pct
  from config;
grant select on v_config to anon, authenticated;

create or replace function admin_set_sgp(p_pin text, p_pct int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set sgp_pct = least(100, greatest(10, coalesce(p_pct, 90))) where id = 1;
  return json_build_object('ok', true);
end $$;

grant execute on function _parlay_dec(bigint, boolean) to anon, authenticated;

revoke execute on function admin_set_sgp(text,int), sb_place_parlay(int,text,jsonb,int), sb_my_bets(int,text) from public;
grant execute on function admin_set_sgp(text,int), sb_place_parlay(int,text,jsonb,int), sb_my_bets(int,text) to anon, authenticated;
revoke execute on function _sb_grade_parlays() from public, anon, authenticated;
notify pgrst, 'reload schema';
