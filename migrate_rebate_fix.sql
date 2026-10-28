-- Lets the commish pay rebates any time outside the closed window. Paste into the Supabase SQL Editor and run once.
create or replace function admin_pay_rebates(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare r record; pct int; paid int := 0;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  -- not while the casino is closed for waivers (end of MNF until 3 AM Wednesday ET); any other time is fine
  if _blackout() then
    raise exception 'Rebates pay out after waivers clear at 3 AM Wednesday.';
  end if;
  if not exists (select 1 from pending_rebates) then
    raise exception 'No rebates are owed. Press Mark settled first, then pay.';
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
