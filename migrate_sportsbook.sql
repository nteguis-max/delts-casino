-- Washed Delts Casino: sportsbook (real NFL games vs the house)
-- Paste into Supabase > SQL Editor and press Run.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- ---------- sportsbook (real NFL games vs the house, DraftKings lines from ESPN) ----------
create table if not exists sb_games (
  id text primary key,                 -- ESPN event id
  week int, kickoff timestamptz not null,
  home text not null, away text not null, home_name text, away_name text,
  state text not null default 'pre',   -- pre | in | post
  final boolean not null default false,
  home_score int, away_score int,
  ml_home int, ml_away int,
  spread_home numeric, spread_home_price int, spread_away numeric, spread_away_price int,
  total numeric, over_price int, under_price int,
  lines_at timestamptz, updated_at timestamptz not null default now()
);
create table if not exists sb_bets (
  id bigserial primary key,
  team_id int not null references teams(id),
  game_id text not null references sb_games(id),
  market text not null check (market in ('ml','spread','total')),
  pick text not null check (pick in ('home','away','over','under')),
  line numeric, price int not null, stake int not null,
  status text not null default 'open' check (status in ('open','won','lost','push')),
  payout int, created_at timestamptz not null default now(), graded_at timestamptz
);
create index if not exists sb_bets_open on sb_bets(game_id) where status = 'open';
create table if not exists sb_requests (id bigint primary key, url text, created_at timestamptz not null default now(), done boolean not null default false);
create table if not exists sb_status (id int primary key default 1 check (id = 1), last_ok timestamptz, last_error text);
insert into sb_status(id) values (1) on conflict (id) do nothing;
alter table sb_games enable row level security;
alter table sb_bets enable row level security;
alter table sb_requests enable row level security;
alter table sb_status enable row level security;
revoke all on sb_games, sb_bets, sb_requests, sb_status from anon, authenticated;

-- "+275" -> 275, "-110" -> -110, "EVEN" -> 100
create or replace function _sb_odds(x text) returns int language sql immutable as $$
  select case when x is null or btrim(x) = '' then null
              when upper(btrim(x)) in ('EVEN','EV') then 100
              when btrim(x) ~ '^[+-]?[0-9]+$' then replace(btrim(x), '+', '')::int
              else null end $$;
-- "-7" -> -7, "+3.5" -> 3.5, "o45.5" -> 45.5, "PK" -> 0
create or replace function _sb_line(x text) returns numeric language sql immutable as $$
  select case when x is null or btrim(x) = '' then null
              when upper(btrim(x)) in ('PK','PICK','EVEN') then 0
              when regexp_replace(btrim(x), '^[oOuU]', '') ~ '^[+-]?[0-9]+(\.[0-9]+)?$'
                then replace(regexp_replace(btrim(x), '^[oOuU]', ''), '+', '')::numeric
              else null end $$;
-- total returned on a winning bet (stake included)
create or replace function _sb_return(p_stake int, p_price int) returns int language sql immutable as $$
  select p_stake + floor(case when p_price > 0 then p_stake * p_price / 100.0 else p_stake * 100.0 / abs(p_price) end)::int $$;

-- one ESPN scoreboard payload in, games upserted, finished games graded
create or replace function sb_ingest(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare e jsonb; c jsonb; o jsonb; h jsonb; a jsonb; n int := 0; st text; fin boolean;
begin
  for e in select * from jsonb_array_elements(coalesce(p -> 'events', '[]')) loop
    c := e -> 'competitions' -> 0;
    select x into h from jsonb_array_elements(c -> 'competitors') x where x ->> 'homeAway' = 'home';
    select x into a from jsonb_array_elements(c -> 'competitors') x where x ->> 'homeAway' = 'away';
    if h is null or a is null then continue; end if;
    st := coalesce(e -> 'status' -> 'type' ->> 'state', c -> 'status' -> 'type' ->> 'state', 'pre');
    fin := coalesce((e -> 'status' -> 'type' ->> 'completed')::boolean, false) and st = 'post';
    o := c -> 'odds' -> 0;
    insert into sb_games(id, week, kickoff, home, away, home_name, away_name, state, final, home_score, away_score, updated_at)
    values (e ->> 'id', (e -> 'week' ->> 'number')::int, (e ->> 'date')::timestamptz,
            h -> 'team' ->> 'abbreviation', a -> 'team' ->> 'abbreviation',
            h -> 'team' ->> 'displayName', a -> 'team' ->> 'displayName', st, fin,
            nullif(h ->> 'score', '')::int, nullif(a ->> 'score', '')::int, now())
    on conflict (id) do update set week = excluded.week, kickoff = excluded.kickoff, state = excluded.state,
      final = excluded.final, home_score = excluded.home_score, away_score = excluded.away_score, updated_at = now()
    where not sb_games.final;   -- a graded game never changes again
    -- refresh lines only before kickoff
    if o is not null and st = 'pre' and not fin and not exists (select 1 from sb_games where id = e ->> 'id' and final) then
      update sb_games set
        ml_home = _sb_odds(coalesce(o #>> '{moneyline,home,close,odds}', o #>> '{moneyline,home,open,odds}')),
        ml_away = _sb_odds(coalesce(o #>> '{moneyline,away,close,odds}', o #>> '{moneyline,away,open,odds}')),
        spread_home = _sb_line(coalesce(o #>> '{pointSpread,home,close,line}', o #>> '{pointSpread,home,open,line}')),
        spread_home_price = _sb_odds(coalesce(o #>> '{pointSpread,home,close,odds}', o #>> '{pointSpread,home,open,odds}')),
        spread_away = _sb_line(coalesce(o #>> '{pointSpread,away,close,line}', o #>> '{pointSpread,away,open,line}')),
        spread_away_price = _sb_odds(coalesce(o #>> '{pointSpread,away,close,odds}', o #>> '{pointSpread,away,open,odds}')),
        total = coalesce(_sb_line(o #>> '{total,over,close,line}'), _sb_line(o #>> '{total,over,open,line}'), (o ->> 'overUnder')::numeric),
        over_price = _sb_odds(coalesce(o #>> '{total,over,close,odds}', o #>> '{total,over,open,odds}')),
        under_price = _sb_odds(coalesce(o #>> '{total,under,close,odds}', o #>> '{total,under,open,odds}')),
        lines_at = now()
      where id = e ->> 'id';
    end if;
    n := n + 1;
  end loop;
  perform _sb_grade();
  return n;
end $$;

create or replace function _sb_grade() returns int
language plpgsql security definer set search_path = public as $$
declare b record; g sb_games; m numeric; res text; pay int; n int := 0; label text;
begin
  for b in select * from sb_bets where status = 'open' and game_id in (select id from sb_games where final) for update loop
    select * into g from sb_games where id = b.game_id;
    if b.market = 'ml' then
      m := case when b.pick = 'home' then g.home_score - g.away_score else g.away_score - g.home_score end;
    elsif b.market = 'spread' then
      m := case when b.pick = 'home' then g.home_score + b.line - g.away_score else g.away_score + b.line - g.home_score end;
    else
      m := case when b.pick = 'over' then (g.home_score + g.away_score) - b.line else b.line - (g.home_score + g.away_score) end;
    end if;
    res := case when m > 0 then 'won' when m = 0 then 'push' else 'lost' end;
    pay := case res when 'won' then _sb_return(b.stake, b.price) when 'push' then b.stake else 0 end;
    update sb_bets set status = res, payout = pay, graded_at = now() where id = b.id;
    label := case b.market
      when 'ml' then (case when b.pick = 'home' then g.home else g.away end) || ' ML'
      when 'spread' then (case when b.pick = 'home' then g.home else g.away end) || ' ' || (case when b.line > 0 then '+' else '' end) || trim_scale(b.line)
      else initcap(b.pick) || ' ' || trim_scale(b.line) end;
    perform _apply(b.team_id, pay, 0);
    perform _log(b.team_id, 'sportsbook', b.stake, pay,
      label || ' (' || (case when b.price > 0 then '+' else '' end) || b.price || ') · ' || g.away || ' ' || g.away_score || ', ' || g.home || ' ' || g.home_score);
    n := n + 1;
  end loop;
  return n;
end $$;

-- called by the scheduler: read finished fetches, then ask ESPN again
create or replace function sb_poll() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r record; wk int; i int; base text := 'https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard';
begin
  for r in select q.id, s.status_code, s.content from sb_requests q join net._http_response s on s.id = q.id where not q.done loop
    begin
      if r.status_code = 200 then
        perform sb_ingest(r.content::jsonb);
        update sb_status set last_ok = now(), last_error = null where id = 1;
      else
        update sb_status set last_error = 'ESPN returned ' || coalesce(r.status_code::text, 'nothing') where id = 1;
      end if;
    exception when others then
      update sb_status set last_error = left(sqlerrm, 200) where id = 1;
    end;
    update sb_requests set done = true where id = r.id;
  end loop;
  delete from sb_requests where created_at < now() - interval '1 day';
  -- this week's board
  insert into sb_requests(id, url) values (net.http_get(base, timeout_milliseconds := 15000), base);
  -- any week that still has ungraded bets
  for wk in select distinct g.week from sb_bets b join sb_games g on g.id = b.game_id where b.status = 'open' and not g.final and g.week is not null loop
    insert into sb_requests(id, url) values (net.http_get(base || '?seasontype=2&week=' || wk, timeout_milliseconds := 15000), base || '?week=' || wk);
  end loop;
  -- the next two weeks, so upcoming lines show up as soon as DraftKings posts them
  select coalesce(max(week) filter (where kickoff <= now()), min(week) - 1) into wk from sb_games;
  if wk is not null then
    for i in 1 .. 2 loop
      if wk + i <= 18 then
        insert into sb_requests(id, url) values (net.http_get(base || '?seasontype=2&week=' || (wk + i), timeout_milliseconds := 15000), base || '?week=' || (wk + i));
      end if;
    end loop;
  end if;
end $$;

-- public board: upcoming games with fresh lines
create or replace view v_sb_games as
  select id, week, kickoff, home, away, home_name, away_name, state, final, home_score, away_score,
    ml_home, ml_away, spread_home, spread_home_price, spread_away, spread_away_price, total, over_price, under_price, lines_at,
    (state = 'pre' and kickoff > now() and lines_at > now() - interval '45 minutes') as open
  from sb_games
  where kickoff > now() - interval '4 days' and kickoff < now() + interval '10 days'
  order by kickoff, id;
create or replace view v_sb_status as select last_ok, last_error from sb_status;
grant select on v_sb_games, v_sb_status to anon, authenticated;

create or replace function sb_place(p_team int, p_pin text, p_game text, p_market text, p_pick text, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; g sb_games; ln numeric; pr int; bid bigint;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into g from sb_games where id = p_game for update;
  if not found then raise exception 'That game isn''t on the board.'; end if;
  if g.state <> 'pre' or g.kickoff <= now() then raise exception 'Betting on that game is closed. It already kicked off.'; end if;
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
  perform _guard(t, p_bet, false);   -- no max bet on the sportsbook
  perform _apply(p_team, -p_bet, p_bet);
  insert into sb_bets(team_id, game_id, market, pick, line, price, stake) values (p_team, p_game, p_market, p_pick, ln, pr, p_bet) returning id into bid;
  return json_build_object('ok', true, 'id', bid, 'line', ln, 'price', pr, 'toWin', _sb_return(p_bet, pr) - p_bet, 'balance', _bal(p_team));
end $$;

create or replace function sb_my_bets(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return coalesce((select json_agg(json_build_object('id', b.id, 'game', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
      'market', b.market, 'pick', b.pick, 'team', case when b.pick = 'home' then g.home when b.pick = 'away' then g.away end,
      'line', b.line, 'price', b.price, 'stake', b.stake, 'toWin', _sb_return(b.stake, b.price) - b.stake,
      'status', b.status, 'payout', b.payout) order by b.created_at desc)
    from (select * from sb_bets where team_id = p_team and (status = 'open' or graded_at > now() - interval '7 days') order by created_at desc limit 40) b
    join sb_games g on g.id = b.game_id), '[]'::json);
end $$;

revoke execute on function sb_ingest(jsonb), sb_poll(), _sb_grade(), _sb_odds(text), _sb_line(text), _sb_return(int,int) from public, anon, authenticated;
grant execute on function sb_place(int,text,text,text,text,int), sb_my_bets(int,text) to anon, authenticated;

-- check ESPN every 5 minutes for lines and final scores
select cron.schedule('delts-sportsbook', '*/5 * * * *', 'select public.sb_poll()');
select public.sb_poll();
notify pgrst, 'reload schema';
