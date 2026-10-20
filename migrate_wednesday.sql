-- Washed Delts Casino: closed Monday 8 PM until waivers clear Wednesday 3 AM ET
-- Paste into Supabase > SQL Editor and press Run.

create or replace function _blackout() returns boolean language sql stable as $$
  select (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
      or extract(isodow from now() at time zone 'America/New_York') = 2
      or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) $$;

create or replace function _guard(t teams, p_bet int, p_capped boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare c config;
begin
  select * into c from config where id = 1;
  if not c.open then raise exception 'The casino is closed right now.'; end if;
  if _blackout() then raise exception 'Betting is closed from 8 PM Monday until waivers clear at 3 AM Wednesday (Eastern).'; end if;
  if p_bet is null or p_bet < 10 then raise exception 'Minimum bet is $10.'; end if;
  if p_capped and p_bet > c.max_bet then raise exception 'Max bet is $%.', c.max_bet; end if;
  if p_bet > t.base + t.net - t.settled then raise exception 'You don''t have that much FAAB.'; end if;
  if t.day_wagered + p_bet > c.daily_limit then raise exception 'That would pass today''s wager limit of $%.', c.daily_limit; end if;
end $$;

create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or extract(isodow from now() at time zone 'America/New_York') = 2
    or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) as blackout,
    rebate_pct
  from config;
grant select on v_config to anon, authenticated;

create or replace function admin_pay_rebates(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare r record; pct int; paid int := 0;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  -- only after the Wednesday 3 AM ET waiver run that follows the settle
  if exists (select 1 from pending_rebates p,
               lateral (select date_trunc('week', p.created_at at time zone 'America/New_York') + interval '2 days 3 hours' as tue) w
             where (case when w.tue > (p.created_at at time zone 'America/New_York') then w.tue else w.tue + interval '7 days' end)
                   at time zone 'America/New_York' > now()) then
    raise exception 'Rebates pay out after waivers clear at 3 AM Wednesday.';
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

notify pgrst, 'reload schema';
