-- Washed Delts Casino: parlays + league bet ticker
-- Paste into Supabase > SQL Editor and press Run.

-- ---------- sportsbook parlays + league bet ticker ----------
alter table config add column if not exists parlay_max_payout int not null default 20000;

create table if not exists sb_parlays (
  id bigserial primary key,
  team_id int not null references teams(id),
  stake int not null,
  status text not null default 'open' check (status in ('open','won','lost','push')),
  payout int, created_at timestamptz not null default now(), graded_at timestamptz
);
create table if not exists sb_parlay_legs (
  parlay_id bigint not null references sb_parlays(id),
  game_id text not null references sb_games(id),
  market text not null, pick text not null, line numeric, price int not null,
  result text check (result in ('won','lost','push')),
  primary key (parlay_id, game_id)
);
alter table sb_parlays enable row level security;
alter table sb_parlay_legs enable row level security;
revoke all on sb_parlays, sb_parlay_legs from anon, authenticated;

-- American odds to decimal (+150 -> 2.5, -110 -> 1.909)
create or replace function _sb_dec(p int) returns numeric language sql immutable as $$
  select case when p > 0 then 1 + p / 100.0 else 1 + 100.0 / abs(p) end $$;

-- win (>0), push (=0) or loss (<0) margin for a bet on a finished game
create or replace function _sb_margin(g sb_games, p_market text, p_pick text, p_line numeric) returns numeric language sql immutable as $$
  select case p_market
    when 'ml' then case when p_pick = 'home' then g.home_score - g.away_score else g.away_score - g.home_score end
    when 'spread' then case when p_pick = 'home' then g.home_score + p_line - g.away_score else g.away_score + p_line - g.home_score end
    else case when p_pick = 'over' then (g.home_score + g.away_score) - p_line else p_line - (g.home_score + g.away_score) end end $$;

create or replace function _sb_label(g sb_games, p_market text, p_pick text, p_line numeric) returns text language sql immutable as $$
  select case p_market
    when 'ml' then (case when p_pick = 'home' then g.home else g.away end) || ' ML'
    when 'spread' then (case when p_pick = 'home' then g.home else g.away end) || ' ' || (case when p_line > 0 then '+' else '' end) || trim_scale(p_line)
    else initcap(p_pick) || ' ' || trim_scale(p_line) end $$;

-- current line/price for a pick, or an error if it can't be bet right now
create or replace function _sb_quote(p_game text, p_market text, p_pick text, out g sb_games, out ln numeric, out pr int)
language plpgsql stable security definer set search_path = public as $$
begin
  select * into g from sb_games where id = p_game;
  if not found then raise exception 'That game isn''t on the board.'; end if;
  if g.state <> 'pre' or g.kickoff <= now() then raise exception '% @ % already kicked off.', g.away, g.home; end if;
  if g.lines_at is null or g.lines_at < now() - interval '45 minutes' then raise exception 'Lines are refreshing. Try again in a few minutes.'; end if;
  if p_market = 'ml' and p_pick in ('home','away') then
    ln := null; pr := case when p_pick = 'home' then g.ml_home else g.ml_away end;
  elsif p_market = 'spread' and p_pick in ('home','away') then
    ln := case when p_pick = 'home' then g.spread_home else g.spread_away end;
    pr := case when p_pick = 'home' then g.spread_home_price else g.spread_away_price end;
  elsif p_market = 'total' and p_pick in ('over','under') then
    ln := g.total; pr := case when p_pick = 'over' then g.over_price else g.under_price end;
  else raise exception 'Unknown bet.'; end if;
  if pr is null or pr between -99 and 99 or (p_market <> 'ml' and ln is null) then raise exception 'No line on that bet right now.'; end if;
end $$;

-- p_legs: [{"game":"401873023","market":"spread","pick":"home"}, ...]
create or replace function sb_place_parlay(p_team int, p_pin text, p_legs jsonb, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; l jsonb; q record; dec numeric := 1; pid bigint; n int; cap int; mult numeric;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  n := jsonb_array_length(coalesce(p_legs, '[]'));
  if n < 2 then raise exception 'A parlay needs at least 2 picks.'; end if;
  if n > 6 then raise exception 'Parlays max out at 6 picks.'; end if;
  if (select count(distinct x ->> 'game') from jsonb_array_elements(p_legs) x) <> n then
    raise exception 'One pick per game in a parlay.'; end if;
  perform _guard(t, p_bet, false);
  select parlay_max_payout into cap from config where id = 1;
  for l in select * from jsonb_array_elements(p_legs) loop
    select * into q from _sb_quote(l ->> 'game', l ->> 'market', l ->> 'pick');
    dec := dec * _sb_dec(q.pr);
  end loop;
  if floor(p_bet * dec) > cap then
    raise exception 'Parlay payouts max out at $%. Lower your bet to $% or less.', cap, floor(cap / dec);
  end if;
  perform _apply(p_team, -p_bet, p_bet);
  insert into sb_parlays(team_id, stake) values (p_team, p_bet) returning id into pid;
  for l in select * from jsonb_array_elements(p_legs) loop
    select * into q from _sb_quote(l ->> 'game', l ->> 'market', l ->> 'pick');
    insert into sb_parlay_legs(parlay_id, game_id, market, pick, line, price) values (pid, l ->> 'game', l ->> 'market', l ->> 'pick', q.ln, q.pr);
  end loop;
  mult := round(dec, 2);
  return json_build_object('ok', true, 'id', pid, 'multiplier', mult, 'toWin', floor(p_bet * dec)::int - p_bet, 'balance', _bal(p_team));
end $$;

-- grade parlay legs on finished games, then settle any parlay that's decided
create or replace function _sb_grade_parlays() returns int
language plpgsql security definer set search_path = public as $$
declare lg record; p record; g sb_games; m numeric; dec numeric; pay int; res text; n int := 0; legs text; cap int;
begin
  for lg in select l.* from sb_parlay_legs l join sb_parlays pp on pp.id = l.parlay_id
            where l.result is null and pp.status = 'open' and l.game_id in (select id from sb_games where final) loop
    select * into g from sb_games where id = lg.game_id;
    m := _sb_margin(g, lg.market, lg.pick, lg.line);
    update sb_parlay_legs set result = case when m > 0 then 'won' when m = 0 then 'push' else 'lost' end
      where parlay_id = lg.parlay_id and game_id = lg.game_id;
  end loop;
  select parlay_max_payout into cap from config where id = 1;
  for p in select * from sb_parlays where status = 'open' for update loop
    if exists (select 1 from sb_parlay_legs where parlay_id = p.id and result = 'lost') then
      res := 'lost'; pay := 0;
    elsif not exists (select 1 from sb_parlay_legs where parlay_id = p.id and result is null) then
      select coalesce(exp(sum(ln(_sb_dec(price)))), 1) into dec from sb_parlay_legs where parlay_id = p.id and result = 'won';
      if dec = 1 then res := 'push'; pay := p.stake; else res := 'won'; pay := least(floor(p.stake * dec)::int, greatest(cap, p.stake)); end if;
    else continue; end if;
    update sb_parlays set status = res, payout = pay, graded_at = now() where id = p.id;
    select string_agg(_sb_label(g2, l.market, l.pick, l.line) || coalesce(case l.result when 'won' then ' ✓' when 'lost' then ' ✗' when 'push' then ' push' end, ''), ', ' order by g2.kickoff)
      into legs from sb_parlay_legs l join sb_games g2 on g2.id = l.game_id where l.parlay_id = p.id;
    perform _apply(p.team_id, pay, 0);
    perform _log(p.team_id, 'parlay', p.stake, pay, (select count(*) from sb_parlay_legs where parlay_id = p.id) || '-leg parlay · ' || legs);
    n := n + 1;
  end loop;
  return n;
end $$;

-- straight-bet grading now also settles parlays
create or replace function _sb_grade() returns int
language plpgsql security definer set search_path = public as $$
declare b record; g sb_games; m numeric; res text; pay int; n int := 0;
begin
  for b in select * from sb_bets where status = 'open' and game_id in (select id from sb_games where final) for update loop
    select * into g from sb_games where id = b.game_id;
    m := _sb_margin(g, b.market, b.pick, b.line);
    res := case when m > 0 then 'won' when m = 0 then 'push' else 'lost' end;
    pay := case res when 'won' then _sb_return(b.stake, b.price) when 'push' then b.stake else 0 end;
    update sb_bets set status = res, payout = pay, graded_at = now() where id = b.id;
    perform _apply(b.team_id, pay, 0);
    perform _log(b.team_id, 'sportsbook', b.stake, pay,
      _sb_label(g, b.market, b.pick, b.line) || ' (' || (case when b.price > 0 then '+' else '' end) || b.price || ') · ' || g.away || ' ' || g.away_score || ', ' || g.home || ' ' || g.home_score);
    n := n + 1;
  end loop;
  return n + _sb_grade_parlays();
end $$;

-- straight bets reuse the shared quote check
create or replace function sb_place(p_team int, p_pin text, p_game text, p_market text, p_pick text, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; q record; bid bigint;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into q from _sb_quote(p_game, p_market, p_pick);
  perform _guard(t, p_bet, false);   -- no max bet on the sportsbook
  perform _apply(p_team, -p_bet, p_bet);
  insert into sb_bets(team_id, game_id, market, pick, line, price, stake) values (p_team, p_game, p_market, p_pick, q.ln, q.pr, p_bet) returning id into bid;
  return json_build_object('ok', true, 'id', bid, 'line', q.ln, 'price', q.pr, 'toWin', _sb_return(p_bet, q.pr) - p_bet, 'balance', _bal(p_team));
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
      'toWin', least(floor(p.stake * (select exp(sum(ln(_sb_dec(price)))) from sb_parlay_legs where parlay_id = p.id))::int,
                     greatest((select parlay_max_payout from config where id = 1), p.stake)) - p.stake,
      'legs', (select json_agg(json_build_object('label', _sb_label(g, l.market, l.pick, l.line), 'price', l.price, 'game', g.away || ' @ ' || g.home,
                 'kickoff', g.kickoff, 'result', l.result) order by g.kickoff) from sb_parlay_legs l join sb_games g on g.id = l.game_id where l.parlay_id = p.id))::jsonb
    from sb_parlays p where p.team_id = p_team and (p.status = 'open' or p.graded_at > now() - interval '7 days')
  ) s(x)), '[]'::json);
end $$;

-- everyone's open action, for tailing and fading
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
    least(floor(p.stake * (select exp(sum(ln(_sb_dec(price)))) from sb_parlay_legs where parlay_id = p.id))::int,
          greatest((select parlay_max_payout from config where id = 1), p.stake)) - p.stake,
    (select jsonb_agg(jsonb_build_object('game', l.game_id, 'market', l.market, 'pick', l.pick, 'price', l.price,
       'label', _sb_label(g, l.market, l.pick, l.line), 'matchup', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
       'started', g.state <> 'pre' or g.kickoff <= now(), 'result', l.result) order by g.kickoff)
     from sb_parlay_legs l join sb_games g on g.id = l.game_id where l.parlay_id = p.id)
  from sb_parlays p join teams t on t.id = p.team_id
  where p.status = 'open';
grant select on v_sb_ticker to anon, authenticated;

create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or extract(isodow from now() at time zone 'America/New_York') = 2
    or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) as blackout,
    rebate_pct, parlay_max_payout
  from config;
grant select on v_config to anon, authenticated;

create or replace function admin_set_parlay_cap(p_pin text, p_cap int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set parlay_max_payout = greatest(100, coalesce(p_cap, 20000)) where id = 1;
  return json_build_object('ok', true);
end $$;

-- the ticker view calls these display helpers, so viewers need to be able to run them
grant execute on function _sb_label(sb_games,text,text,numeric), _sb_return(int,int), _sb_dec(int) to anon, authenticated;

revoke execute on function _sb_quote(text,text,text), _sb_margin(sb_games,text,text,numeric), _sb_grade_parlays(), _sb_grade() from public, anon, authenticated;
revoke execute on function sb_place_parlay(int,text,jsonb,int), admin_set_parlay_cap(text,int), sb_place(int,text,text,text,text,int), sb_my_bets(int,text) from public;
grant execute on function sb_place_parlay(int,text,jsonb,int), admin_set_parlay_cap(text,int), sb_place(int,text,text,text,text,int), sb_my_bets(int,text) to anon, authenticated;
notify pgrst, 'reload schema';
