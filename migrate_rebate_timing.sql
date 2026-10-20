-- Washed Delts Casino: pay loss rebates after Tuesday waivers
-- Paste into Supabase > SQL Editor and press Run.

-- ---------- rebates pay out after waivers ----------
-- Monday: Mark settled syncs casino results and records each loser's rebate as owed.
-- Tuesday after 6 AM ET: Pay rebates credits them, so nobody can use a rebate in that week's waivers.
create table if not exists pending_rebates (
  team_id int not null references teams(id),
  amount int not null,
  created_at timestamptz not null default now()
);
alter table pending_rebates enable row level security;
revoke all on pending_rebates from anon, authenticated;

create or replace function admin_overview(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  return (select json_agg(json_build_object('id', t.id, 'name', t.name, 'base', t.base,
    'unsettled', t.net - t.settled, 'weekNet', r.week_net, 'estRebate', r.rebate,
    'owed', coalesce(o.amt, 0), 'setTo', t.base + t.net - t.settled,
    'withRebate', t.base + coalesce(o.amt, 0), 'claimed', t.pin_hash is not null) order by t.id)
    from teams t join _rebates() r on r.team_id = t.id
    left join (select team_id, sum(amount)::int amt from pending_rebates group by team_id) o on o.team_id = t.id);
end $$;

create or replace function admin_settle(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare owed int := 0;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  if exists (select 1 from bj_hands) then raise exception 'A blackjack hand is still in play. Try again in a minute.'; end if;
  insert into pending_rebates(team_id, amount) select team_id, rebate from _rebates() where rebate > 0;
  select coalesce(sum(rebate), 0) into owed from _rebates();
  update teams set base = base + net - settled, settled = net where id is not null;
  update config set last_settled = now() where id = 1;
  return json_build_object('ok', true, 'owed', owed);
end $$;

create or replace function admin_pay_rebates(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare r record; pct int; paid int := 0;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  -- only after the Tuesday 6 AM ET waiver run that follows the settle
  if exists (select 1 from pending_rebates p,
               lateral (select date_trunc('week', p.created_at at time zone 'America/New_York') + interval '1 day 6 hours' as tue) w
             where (case when w.tue > (p.created_at at time zone 'America/New_York') then w.tue else w.tue + interval '7 days' end)
                   at time zone 'America/New_York' > now()) then
    raise exception 'Rebates pay out after waivers clear at 6 AM Tuesday.';
  end if;
  select rebate_pct into pct from config where id = 1;
  for r in select team_id, sum(amount)::int amt from pending_rebates group by team_id loop
    -- credit the casino balance and count it as already in Sleeper (the commish adds it there)
    update teams set net = net + r.amt, settled = settled + r.amt, base = base + r.amt where id = r.team_id;
    insert into plays(team_id, game, bet, payout, detail)
      values (r.team_id, 'rebate', 0, r.amt, 'Weekly loss rebate · ' || pct || '% of the bank, split by losses');
    paid := paid + r.amt;
  end loop;
  delete from pending_rebates where team_id is not null;
  return json_build_object('ok', true, 'paid', paid);
end $$;

revoke execute on function admin_pay_rebates(text) from public;
grant execute on function admin_pay_rebates(text) to anon, authenticated;
notify pgrst, 'reload schema';
