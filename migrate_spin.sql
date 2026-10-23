-- Daily free spin. Paste into the Supabase SQL Editor and run once.
-- ---------- Daily free spin: one per team per Eastern calendar day ----------
-- Prize odds live in spin_prizes (weight out of the total). Change them in the Table Editor any time.
-- Spins are free FAAB: they add to your balance but stay out of gambling stats and the loss rebate.
create table if not exists spin_prizes (amount int primary key, weight int not null check (weight >= 0));
insert into spin_prizes(amount, weight) values
  (20, 3000), (30, 2500), (40, 1500), (50, 1300), (75, 800), (100, 845), (2000, 50), (8000, 5)
on conflict (amount) do nothing;

create table if not exists spin_log (
  id bigserial primary key,
  team_id int not null references teams(id),
  day date not null,
  amount int not null,
  created_at timestamptz not null default now(),
  unique (team_id, day)
);
alter table spin_prizes enable row level security;
alter table spin_log enable row level security;
revoke all on spin_prizes, spin_log from anon, authenticated;

create or replace function _spin_today() returns date language sql stable as $$
  select (now() at time zone 'America/New_York')::date $$;

create or replace function _spin_next() returns timestamptz language sql stable as $$
  select ((_spin_today() + 1)::timestamp at time zone 'America/New_York') $$;

create or replace function _spin_view(p_team int) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'ready', not exists (select 1 from spin_log where team_id = p_team and day = _spin_today()),
    'today', (select amount from spin_log where team_id = p_team and day = _spin_today()),
    'nextAt', _spin_next(),
    'prizes', (select coalesce(json_agg(json_build_object('amount', amount, 'pct', round(weight * 100.0 / nullif((select sum(weight) from spin_prizes), 0), 2)) order by amount), '[]') from spin_prizes where weight > 0),
    'big', (select coalesce(json_agg(x order by x.created_at desc), '[]') from (
              select t.name, s.amount, s.created_at from spin_log s join teams t on t.id = s.team_id
              where s.amount >= 1000 order by s.created_at desc limit 8) x),
    'balance', _bal(p_team)) $$;

create or replace function spin_state(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return _spin_view(p_team);
end $$;

create or replace function spin_play(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; tot int; r int; acc int := 0; p spin_prizes; won int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform 1 from teams where id = p_team for update;
  if exists (select 1 from spin_log where team_id = p_team and day = _spin_today()) then
    raise exception 'You already spun today. Next spin at midnight Eastern.';
  end if;
  select sum(weight) into tot from spin_prizes where weight > 0;
  if coalesce(tot, 0) = 0 then raise exception 'The wheel is off right now.'; end if;
  r := _rnd(tot);
  for p in select * from spin_prizes where weight > 0 order by amount loop
    acc := acc + p.weight;
    if r < acc then won := p.amount; exit; end if;
  end loop;
  insert into spin_log(team_id, day, amount) values (p_team, _spin_today(), won);
  perform _apply(p_team, won, 0);
  return json_build_object('amount', won, 'state', _spin_view(p_team));
end $$;

-- the live feed also shows spins (bet 0) so the league sees the big hits
create or replace view v_feed as
  select * from (
    select p.id, p.team_id, t.name, p.game, p.bet, p.payout, p.detail, p.created_at
    from plays p join teams t on t.id = p.team_id
    where p.created_at > now() - interval '24 hours'
    union all
    select -s.id, s.team_id, t.name, 'spin', 0, s.amount, 'Daily free spin', s.created_at
    from spin_log s join teams t on t.id = s.team_id
    where s.created_at > now() - interval '24 hours'
  ) f order by created_at desc limit 1000;
grant select on v_feed to anon, authenticated;
grant execute on function spin_state(int,text), spin_play(int,text) to anon, authenticated;
grant execute on function _spin_today(), _spin_next() to anon, authenticated;

notify pgrst, 'reload schema';
