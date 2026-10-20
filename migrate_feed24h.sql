-- Washed Delts Casino: live feed shows the last 24 hours
-- Paste into Supabase > SQL Editor and press Run.

create or replace view v_feed as
  select p.id, p.team_id, t.name, p.game, p.bet, p.payout, p.detail, p.created_at
  from plays p join teams t on t.id = p.team_id
  where p.created_at > now() - interval '24 hours'
  order by p.created_at desc limit 1000;
grant select on v_feed to anon, authenticated;
notify pgrst, 'reload schema';
