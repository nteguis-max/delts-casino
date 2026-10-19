-- Washed Delts Casino: weekly loss rebate
-- Paste into Supabase > SQL Editor and press Run.
alter table config add column if not exists rebate_pct int not null default 100;

-- ---------- weekly loss rebate ----------
-- Each settle, the bank built up since the last settle (all players' net losses) is
-- split among the teams that finished down for the period, in proportion to their losses.
-- rebate_pct sets how much of that bank goes back (100 = all of it).
create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or (extract(isodow from now() at time zone 'America/New_York') = 2 and extract(hour from now() at time zone 'America/New_York') < 6) as blackout,
    rebate_pct
  from config;
grant select on v_config to anon, authenticated;

create or replace function _rebates() returns table(team_id int, week_net int, rebate int)
language sql stable security definer set search_path = public as $$
  with c as (select coalesce(last_settled, '-infinity'::timestamptz) as since, rebate_pct as pct from config where id = 1),
  wk as (
    select t.id as tid, coalesce((select sum(p.payout - p.bet) from plays p, c
             where p.team_id = t.id and p.created_at > c.since and p.game <> 'rebate'), 0)::int as wn
    from teams t),
  tot as (
    select floor(greatest(0, -sum(wn)) * (select pct from c) / 100.0) as pool,
           coalesce(sum(-wn) filter (where wn < 0), 0) as losses
    from wk)
  select wk.tid, wk.wn,
    case when wk.wn < 0 and tot.losses > 0 then floor(tot.pool * (-wk.wn)::numeric / tot.losses)::int else 0 end
  from wk, tot order by wk.tid
$$;

create or replace function admin_overview(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  return (select json_agg(json_build_object('id', t.id, 'name', t.name, 'base', t.base,
    'unsettled', t.net - t.settled, 'weekNet', r.week_net, 'rebate', r.rebate,
    'setTo', t.base + t.net - t.settled + r.rebate, 'claimed', t.pin_hash is not null) order by t.id)
    from teams t join _rebates() r on r.team_id = t.id);
end $$;

create or replace function admin_set_rebate(p_pin text, p_pct int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set rebate_pct = least(100, greatest(0, coalesce(p_pct, 100))) where id = 1;
  return json_build_object('ok', true);
end $$;

create or replace function admin_settle(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare r record; pct int; paid int := 0;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  if exists (select 1 from bj_hands) then raise exception 'A blackjack hand is still in play. Try again in a minute.'; end if;
  select rebate_pct into pct from config where id = 1;
  for r in select * from _rebates() where rebate > 0 loop
    update teams set net = net + r.rebate where id = r.team_id;
    insert into plays(team_id, game, bet, payout, detail)
      values (r.team_id, 'rebate', 0, r.rebate, 'Weekly loss rebate · ' || pct || '% of the bank, split by losses');
    paid := paid + r.rebate;
  end loop;
  update teams set base = base + net - settled, settled = net;
  update config set last_settled = now() where id = 1;
  return json_build_object('ok', true, 'rebated', paid);
end $$;

revoke execute on function _rebates() from public, anon, authenticated;
grant execute on function admin_set_rebate(text,int) to anon, authenticated;
notify pgrst, 'reload schema';
