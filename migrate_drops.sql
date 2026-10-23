-- Primetime drops, and the casino now closes when MNF ends. Paste into the Supabase SQL Editor and run once.
-- ---------- Primetime drops + the casino now closes when Monday Night Football ends ----------
-- Every touchdown or field goal in a TNF, SNF or MNF game drops free FAAB on the site.
-- Anyone logged in can claim each drop once while its window is open (10 minutes by default).
alter table config add column if not exists drop_td int not null default 150;
alter table config add column if not exists drop_fg int not null default 30;
alter table config add column if not exists drop_minutes int not null default 10;

create table if not exists drops (
  id bigserial primary key,
  game_id text not null references sb_games(id),
  team text not null,                       -- abbreviation of the team that scored
  kind text not null check (kind in ('td', 'fg')),
  amount int not null,
  label text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create table if not exists drop_claims (
  drop_id bigint not null references drops(id),
  team_id int not null references teams(id),
  amount int not null,
  created_at timestamptz not null default now(),
  primary key (drop_id, team_id)
);
alter table drops enable row level security;
alter table drop_claims enable row level security;
revoke all on drops, drop_claims from anon, authenticated;

-- Thursday, Sunday or Monday night games (kickoff 7 PM Eastern or later)
create or replace function _is_primetime(k timestamptz) returns boolean language sql stable as $$
  select extract(isodow from k at time zone 'America/New_York') in (1, 4, 7)
     and extract(hour from k at time zone 'America/New_York') >= 19 $$;

-- closed once every Monday night game is final, until waivers clear at 3 AM Wednesday.
-- Safety net: closed from 3 AM Tuesday no matter what, in case the score feed stalls.
create or replace function _blackout() returns boolean
language sql stable security definer set search_path = public as $$
  with n as (select now() at time zone 'America/New_York' as t),
  d as (select extract(isodow from t)::int as dow, extract(hour from t)::int as hr,
               case extract(isodow from t)::int when 1 then t::date when 2 then t::date - 1 end as monday from n),
  m as (select exists (select 1 from sb_games g, d
          where d.monday is not null and (g.kickoff at time zone 'America/New_York')::date = d.monday
            and extract(hour from g.kickoff at time zone 'America/New_York') >= 17 and not g.final) as mnf_on)
  select (d.dow = 1 and d.hr >= 20 and not m.mnf_on)
      or (d.dow = 2 and (d.hr >= 3 or not m.mnf_on))
      or (d.dow = 3 and d.hr < 3)
  from d, m $$;
grant execute on function _blackout() to anon, authenticated;

-- watch the score: a jump of 6 to 8 is a touchdown, 3 is a field goal (9 to 11 is both)
create or replace function _sb_drop_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare c config; side record; d int; tds int; fgs int; i int; nm text; scoreline text;
begin
  if old.final or not _is_primetime(new.kickoff) then return new; end if;
  select * into c from config where id = 1;
  scoreline := new.away || ' ' || coalesce(new.away_score, 0) || ', ' || new.home || ' ' || coalesce(new.home_score, 0);
  for side in select * from (values (new.home, new.home_name, coalesce(new.home_score, 0) - coalesce(old.home_score, 0)),
                                    (new.away, new.away_name, coalesce(new.away_score, 0) - coalesce(old.away_score, 0))) v(abbr, name, delta) loop
    d := side.delta;
    if d is null or d <= 0 then continue; end if;
    tds := 0; fgs := 0;
    if d between 6 and 8 then tds := 1;
    elsif d = 3 then fgs := 1;
    elsif d between 9 and 11 then tds := 1; fgs := 1;
    elsif d >= 12 then tds := d / 7; end if;
    nm := coalesce(side.name, side.abbr);
    for i in 1 .. tds loop
      if c.drop_td > 0 then
        insert into drops(game_id, team, kind, amount, label, expires_at)
        values (new.id, side.abbr, 'td', c.drop_td, nm || ' touchdown · ' || scoreline, now() + make_interval(mins => c.drop_minutes));
      end if;
    end loop;
    for i in 1 .. fgs loop
      if c.drop_fg > 0 then
        insert into drops(game_id, team, kind, amount, label, expires_at)
        values (new.id, side.abbr, 'fg', c.drop_fg, nm || ' field goal · ' || scoreline, now() + make_interval(mins => c.drop_minutes));
      end if;
    end loop;
  end loop;
  return new;
end $$;
drop trigger if exists sb_drop on sb_games;
create trigger sb_drop after update of home_score, away_score on sb_games
  for each row when (new.home_score is distinct from old.home_score or new.away_score is distinct from old.away_score)
  execute function _sb_drop_trg();

-- during primetime games, check the scoreboard every minute instead of every five
create or replace function sb_live_poll() returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from sb_games where _is_primetime(kickoff) and not final
               and kickoff < now() + interval '10 minutes' and kickoff > now() - interval '6 hours') then
    perform sb_poll();
  end if;
end $$;

-- what everyone can see: open drops and the primetime game in progress
create or replace view v_drops as
  select d.id, d.kind, d.amount, d.label, d.team, d.created_at, d.expires_at,
         (select count(*) from drop_claims c where c.drop_id = d.id)::int as claims
  from drops d where d.created_at > now() - interval '6 hours'
  order by d.created_at desc limit 40;
create or replace view v_prime_live as
  select id, home, away, home_name, away_name, home_score, away_score, state, kickoff
  from sb_games where _is_primetime(kickoff) and not final
    and kickoff < now() + interval '30 minutes' and kickoff > now() - interval '6 hours'
  order by kickoff;
grant select on v_drops, v_prime_live to anon, authenticated;
grant execute on function _is_primetime(timestamptz) to anon, authenticated;

create or replace function drop_state(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return json_build_object(
    'claimed', (select coalesce(json_agg(drop_id), '[]') from drop_claims where team_id = p_team and created_at > now() - interval '6 hours'),
    'week', (select coalesce(sum(amount), 0) from drop_claims where team_id = p_team
               and created_at > coalesce((select last_settled from config where id = 1), '-infinity'::timestamptz)),
    'balance', _bal(p_team));
end $$;

create or replace function drop_claim(p_team int, p_pin text, p_drop bigint) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; d drops;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform 1 from teams where id = p_team for update;
  select * into d from drops where id = p_drop;
  if not found then raise exception 'That drop doesn''t exist.'; end if;
  if now() > d.expires_at then raise exception 'Too late, that drop expired.'; end if;
  if exists (select 1 from drop_claims where drop_id = p_drop and team_id = p_team) then raise exception 'You already grabbed that one.'; end if;
  insert into drop_claims(drop_id, team_id, amount) values (p_drop, p_team, d.amount);
  perform _apply(p_team, d.amount, 0);
  return json_build_object('ok', true, 'amount', d.amount, 'state', drop_state(p_team, p_pin));
end $$;

create or replace function admin_set_drops(p_pin text, p_td int, p_fg int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set drop_td = greatest(0, coalesce(p_td, 150)), drop_fg = greatest(0, coalesce(p_fg, 30)) where id = 1;
  return json_build_object('ok', true);
end $$;

create or replace view v_config as
  select open, max_bet, daily_limit, last_settled, _blackout() as blackout,
    rebate_pct, parlay_max_payout, sgp_pct, click_daily_cap, biz_week_cap, drop_td, drop_fg, drop_minutes
  from config;
grant select on v_config to anon, authenticated;

create or replace function _guard(t teams, p_bet int, p_capped boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare c config;
begin
  select * into c from config where id = 1;
  if not c.open then raise exception 'The casino is closed right now.'; end if;
  if _blackout() then raise exception 'Betting is closed from the end of Monday Night Football until waivers clear at 3 AM Wednesday (Eastern).'; end if;
  if p_bet is null or p_bet < 10 then raise exception 'Minimum bet is $10.'; end if;
  if p_capped and p_bet > c.max_bet then raise exception 'Max bet is $%.', c.max_bet; end if;
  if p_bet > t.base + t.net - t.settled then raise exception 'You don''t have that much FAAB.'; end if;
  if t.day_wagered + p_bet > c.daily_limit then raise exception 'That would pass today''s wager limit of $%.', c.daily_limit; end if;
end $$;

grant execute on function drop_state(int,text), drop_claim(int,text,bigint), admin_set_drops(text,int,int) to anon, authenticated;

create or replace function biz_buy(p_team int, p_pin text, p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; bt biz_types; q int; cost int; c config;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform 1 from teams where id = p_team for update;
  select * into c from config where id = 1;
  if not c.open then raise exception 'The casino is closed right now.'; end if;
  if _blackout() then raise exception 'Businesses can''t be bought from the end of Monday Night Football until waivers clear at 3 AM Wednesday (Eastern).'; end if;
  select * into bt from biz_types where code = p_code;
  if not found then raise exception 'Unknown business.'; end if;
  perform _biz_collect(p_team);
  select coalesce((select qty from biz_owned where team_id = p_team and code = p_code), 0) into q;
  cost := _biz_cost(bt.base_cost, q);
  if cost > _bal(p_team) then raise exception 'You need % to buy that. You have %.', '$' || cost, '$' || _bal(p_team); end if;
  perform _apply(p_team, -cost, 0);
  insert into biz_owned(team_id, code, qty) values (p_team, p_code, 1) on conflict (team_id, code) do update set qty = biz_owned.qty + 1;
  insert into biz_ledger(team_id, kind, amount, detail) values (p_team, 'buy', -cost, 'Bought ' || bt.name || ' #' || (q + 1));
  return json_build_object('ok', true, 'cost', cost, 'state', _biz_view(p_team));
end $$;

-- check the scoreboard every minute (it only actually fetches during TNF, SNF and MNF)
select cron.schedule('delts-live', '* * * * *', 'select public.sb_live_poll()');

notify pgrst, 'reload schema';
