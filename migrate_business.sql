-- Washed Delts Casino: Business (FAAB clicker + businesses)
-- Paste into Supabase > SQL Editor and press Run.

-- ---------- Business: the FAAB clicker and FAAB businesses ----------
-- Both create new FAAB. They pay into the casino balance (so they show up in the Monday
-- Sleeper sync) but are kept out of the gambling stats, the live feed and the loss rebate.
alter table config add column if not exists click_daily_cap int not null default 250;   -- dollars per team per day
alter table config add column if not exists biz_week_cap int not null default 3000;     -- dollars per team per week

create table if not exists biz_types (
  code text primary key, name text not null, blurb text, base_cost int not null, rate numeric not null, sort int not null
);
-- rate = dollars per hour per unit; every first unit pays back its cost in 14 days (336 hours)
insert into biz_types(code, name, blurb, base_cost, rate, sort) values
  ('stand',  'Waiver Wire Stand',      'Sells hot takes on the waiver wire.',          200,   round(200   / 336.0, 4), 1),
  ('mine',   'FAAB Mine',              'Digs FAAB out of the ground. Don''t ask.',     1000,  round(1000  / 336.0, 4), 2),
  ('scalp',  'Ticket Scalping Ring',   'Flips playoff tickets at a markup.',           5000,  round(5000  / 336.0, 4), 3),
  ('book',   'Underground Bookie',     'Takes action the casino won''t.',              20000, round(20000 / 336.0, 4), 4)
on conflict (code) do nothing;

create table if not exists biz_owned (team_id int not null references teams(id), code text not null references biz_types(code), qty int not null default 0, primary key (team_id, code));
create table if not exists biz_state (
  team_id int primary key references teams(id),
  last_collect timestamptz not null default now(),
  carry numeric not null default 0,          -- fractional dollars not paid out yet
  week_start date, week_made int not null default 0,
  click_day date, clicks_today int not null default 0, click_carry int not null default 0, click_paid_today int not null default 0,
  last_click timestamptz
);
create table if not exists biz_ledger (
  id bigserial primary key, team_id int not null references teams(id),
  kind text not null check (kind in ('buy','collect','click')), amount int not null, detail text,
  created_at timestamptz not null default now()
);
create index if not exists biz_ledger_team on biz_ledger(team_id, created_at desc);
alter table biz_types enable row level security;
alter table biz_owned enable row level security;
alter table biz_state enable row level security;
alter table biz_ledger enable row level security;
revoke all on biz_types, biz_owned, biz_state, biz_ledger from anon, authenticated;
grant select on biz_types to anon, authenticated;
create policy biz_types_read on biz_types for select using (true);

create or replace function _biz_week() returns date language sql stable as $$
  select date_trunc('week', now() at time zone 'America/New_York')::date $$;   -- Monday, Eastern
create or replace function _biz_today() returns date language sql stable as $$
  select (now() at time zone 'America/New_York')::date $$;
create or replace function _biz_cost(p_base int, p_qty int) returns int language sql immutable as $$
  select round(p_base * power(1.15, p_qty))::int $$;
grant execute on function _biz_cost(int,int) to anon, authenticated;

create or replace function _biz_rate(p_team int) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(o.qty * t.rate), 0) from biz_owned o join biz_types t on t.code = o.code where o.team_id = p_team $$;

-- make sure a state row exists and roll the week/day counters
create or replace function _biz_state(p_team int) returns biz_state
language plpgsql security definer set search_path = public as $$
declare s biz_state;
begin
  insert into biz_state(team_id, week_start, click_day) values (p_team, _biz_week(), _biz_today()) on conflict (team_id) do nothing;
  update biz_state set
    week_start = case when week_start is distinct from _biz_week() then _biz_week() else week_start end,
    week_made  = case when week_start is distinct from _biz_week() then 0 else week_made end,
    click_day  = case when click_day is distinct from _biz_today() then _biz_today() else click_day end,
    clicks_today = case when click_day is distinct from _biz_today() then 0 else clicks_today end,
    click_paid_today = case when click_day is distinct from _biz_today() then 0 else click_paid_today end
  where team_id = p_team returning * into s;
  return s;
end $$;

-- what's sitting in the safe right now (capped at 24 hours of output and the weekly cap)
create or replace function _biz_pending(s biz_state, p_rate numeric, p_cap int) returns numeric language sql stable as $$
  select greatest(0, least(
    p_rate * extract(epoch from now() - s.last_collect) / 3600.0 + s.carry,
    p_rate * 24 + s.carry,
    p_cap - s.week_made)) $$;

create or replace function _biz_view(p_team int) returns json
language plpgsql security definer set search_path = public as $$
declare s biz_state; r numeric; c config;
begin
  s := _biz_state(p_team); r := _biz_rate(p_team); select * into c from config where id = 1;
  return json_build_object(
    'rate', round(r, 4), 'pending', floor(_biz_pending(s, r, c.biz_week_cap)), 'pendingExact', round(_biz_pending(s, r, c.biz_week_cap), 4),
    'lastCollect', s.last_collect, 'safeHours', 24, 'weekMade', s.week_made, 'weekCap', c.biz_week_cap,
    'clicksToday', s.clicks_today, 'clickCarry', s.click_carry, 'clickPaidToday', s.click_paid_today, 'clickCap', c.click_daily_cap,
    'owned', coalesce((select json_object_agg(code, qty) from biz_owned where team_id = p_team), '{}'::json),
    'invested', coalesce((select -sum(amount) from biz_ledger where team_id = p_team and kind = 'buy'), 0),
    'collected', coalesce((select sum(amount) from biz_ledger where team_id = p_team and kind = 'collect'), 0),
    'clicked', coalesce((select sum(amount) from biz_ledger where team_id = p_team and kind = 'click'), 0),
    'balance', _bal(p_team));
end $$;

create or replace function biz_state_get(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return _biz_view(p_team);
end $$;

-- pay out whatever's in the safe
create or replace function _biz_collect(p_team int) returns int
language plpgsql security definer set search_path = public as $$
declare s biz_state; r numeric; c config; amt numeric; paid int;
begin
  s := _biz_state(p_team); r := _biz_rate(p_team); select * into c from config where id = 1;
  amt := _biz_pending(s, r, c.biz_week_cap); paid := floor(amt);
  update biz_state set last_collect = now(), carry = amt - paid, week_made = week_made + paid where team_id = p_team;
  if paid > 0 then
    perform _apply(p_team, paid, 0);
    insert into biz_ledger(team_id, kind, amount, detail) values (p_team, 'collect', paid, 'Collected from the safe');
  end if;
  return paid;
end $$;

create or replace function biz_collect(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; paid int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform 1 from teams where id = p_team for update;
  paid := _biz_collect(p_team);
  return json_build_object('paid', paid, 'state', _biz_view(p_team));
end $$;

-- buying collects first, so the new business only earns from now on
create or replace function biz_buy(p_team int, p_pin text, p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; bt biz_types; q int; cost int; c config;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform 1 from teams where id = p_team for update;
  select * into c from config where id = 1;
  if not c.open then raise exception 'The casino is closed right now.'; end if;
  if _blackout() then raise exception 'Businesses can''t be bought from 8 PM Monday until waivers clear at 3 AM Wednesday (Eastern).'; end if;
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

-- the clicker: the page sends clicks in batches; the server allows about 20 a second and the daily cap
create or replace function biz_click(p_team int, p_pin text, p_clicks int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; s biz_state; c config; allowed int; el numeric; tot int; dollars int; room int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform 1 from teams where id = p_team for update;
  s := _biz_state(p_team); select * into c from config where id = 1;
  el := least(30, extract(epoch from now() - coalesce(s.last_click, now() - interval '30 seconds')));
  allowed := greatest(0, least(coalesce(p_clicks, 0), ceil(el * 20)::int, 2000));
  room := greatest(0, c.click_daily_cap - s.click_paid_today);
  allowed := least(allowed, room * 100 - s.click_carry);
  allowed := greatest(allowed, 0);
  tot := s.click_carry + allowed;
  dollars := tot / 100;
  update biz_state set clicks_today = clicks_today + allowed, click_carry = tot % 100,
    click_paid_today = click_paid_today + dollars, last_click = now() where team_id = p_team;
  if dollars > 0 then
    perform _apply(p_team, dollars, 0);
    insert into biz_ledger(team_id, kind, amount, detail) values (p_team, 'click', dollars, (dollars * 100) || ' clicks');
  end if;
  return json_build_object('accepted', allowed, 'paid', dollars, 'state', _biz_view(p_team));
end $$;

-- public business leaderboard and recent activity (kept separate from gambling stats)
create or replace function biz_stats() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'board', (select coalesce(json_agg(x order by x.rate desc, x.invested desc), '[]') from (
      select t.id, t.name, t.owner,
        round(_biz_rate(t.id) * 24, 2) as rate,     -- dollars per day
        coalesce((select sum(qty) from biz_owned where team_id = t.id), 0)::int as units,
        coalesce((select -sum(amount) from biz_ledger where team_id = t.id and kind = 'buy'), 0)::int as invested,
        coalesce((select sum(amount) from biz_ledger where team_id = t.id and kind = 'collect'), 0)::int as collected,
        coalesce((select sum(amount) from biz_ledger where team_id = t.id and kind = 'click'), 0)::int as clicked
      from teams t) x),
    'recent', (select coalesce(json_agg(r order by r.created_at desc), '[]') from (
      select l.created_at, t.name, l.kind, l.amount, l.detail from biz_ledger l join teams t on t.id = l.team_id
      where l.kind = 'buy' order by l.created_at desc limit 15) r),
    'totals', json_build_object(
      'minted', coalesce((select sum(amount) from biz_ledger where kind in ('collect','click')), 0),
      'invested', coalesce((select -sum(amount) from biz_ledger where kind = 'buy'), 0),
      'mintedWeek', coalesce((select sum(amount) from biz_ledger where kind in ('collect','click') and created_at >= _biz_week()::timestamp at time zone 'America/New_York'), 0))
  ) $$;

create or replace function admin_set_business(p_pin text, p_click_cap int, p_week_cap int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set click_daily_cap = greatest(0, coalesce(p_click_cap, 250)), biz_week_cap = greatest(0, coalesce(p_week_cap, 3000)) where id = 1;
  return json_build_object('ok', true);
end $$;

create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or extract(isodow from now() at time zone 'America/New_York') = 2
    or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) as blackout,
    rebate_pct, parlay_max_payout, sgp_pct, click_daily_cap, biz_week_cap
  from config;
grant select on v_config to anon, authenticated;

revoke execute on function _biz_rate(int), _biz_state(int), _biz_pending(biz_state,numeric,int), _biz_view(int), _biz_collect(int), _biz_week(), _biz_today() from public, anon, authenticated;
revoke execute on function biz_state_get(int,text), biz_collect(int,text), biz_buy(int,text,text), biz_click(int,text,int), biz_stats(), admin_set_business(text,int,int) from public;
grant execute on function biz_state_get(int,text), biz_collect(int,text), biz_buy(int,text,text), biz_click(int,text,int), biz_stats(), admin_set_business(text,int,int), _biz_cost(int,int) to anon, authenticated;
notify pgrst, 'reload schema';
