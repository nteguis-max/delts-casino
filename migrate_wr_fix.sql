-- Lets the commish correct a Warroad day that already settled. Paste into the Supabase SQL Editor and run once.
-- ---------- Warroad: the commish can correct a day that already settled ----------
-- Reverses every graded bet on that day (takes back payouts, removes the old feed lines),
-- then settles again at the high you enter. A day that hasn't settled yet works the same as before.
create or replace function admin_wr_settle(p_pin text, p_day date, p_high int) returns json
language plpgsql security definer set search_path = public as $$
declare b record; n int := 0; old_high int;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  if p_day >= _wr_today() then raise exception 'You can only settle a day that''s over.'; end if;
  if p_high is null or p_high < -60 or p_high > 130 then raise exception 'That high doesn''t look right.'; end if;
  if not exists (select 1 from mk_markets where series = 'WARROAD' and day = p_day) then
    raise exception 'There were no Warroad ranges for %.', p_day; end if;
  select high into old_high from wr_results where day = p_day;
  -- undo anything already graded for that day
  for b in select mb.* from mk_bets mb join mk_markets m on m.ticker = mb.ticker
           where m.series = 'WARROAD' and m.day = p_day and mb.status <> 'open' for update of mb loop
    perform _apply(b.team_id, -coalesce(b.payout, 0), 0);
    delete from plays where ctid = (select ctid from plays where team_id = b.team_id and game = 'weather'
      and bet = b.stake and payout = coalesce(b.payout, 0) and created_at = b.graded_at limit 1);
    update mk_bets set status = 'open', payout = null, graded_at = null where id = b.id;
    n := n + 1;
  end loop;
  update mk_markets set result = null, status = 'closed', updated_at = now() where series = 'WARROAD' and day = p_day;
  perform _wr_settle(p_day, p_high, 0, case when old_high is null then 'entered by the commish'
                                            else 'corrected by the commish (was ' || old_high || ')' end);
  return json_build_object('ok', true, 'regraded', n, 'was', old_high);
end $$;
grant execute on function admin_wr_settle(text,date,int) to anon, authenticated;

notify pgrst, 'reload schema';
