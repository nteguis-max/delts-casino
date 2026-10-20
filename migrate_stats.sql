-- Washed Delts Casino: Stats tab (leaderboard, awards, recap)
-- Paste into Supabase > SQL Editor and press Run.

-- ---------- Stats: leaderboard, awards and the weekly recap ----------
-- p_period: 'week' = since the last Monday settle, 'all' = everything
create or replace function stats(p_period text default 'week') returns json
language sql stable security definer set search_path = public as $$
  with since as (
    select case when p_period = 'all' then '-infinity'::timestamptz
                else coalesce((select last_settled from config where id = 1), '-infinity'::timestamptz) end as t),
  p as (select pl.*, t.name from plays pl join teams t on t.id = pl.team_id, since where pl.created_at > since.t),
  bets as (select * from p where game <> 'rebate'),
  board as (
    select t.id, t.name, t.owner,
      coalesce(sum(p.payout - p.bet), 0)::int as net,
      coalesce(sum(p.bet) filter (where p.game <> 'rebate'), 0)::int as wagered,
      count(p.id) filter (where p.game <> 'rebate')::int as bets,
      coalesce(max(p.payout - p.bet) filter (where p.game <> 'rebate'), 0)::int as best,
      coalesce(sum(p.payout) filter (where p.game = 'rebate'), 0)::int as rebates,
      (select b2.game from bets b2 where b2.team_id = t.id group by b2.game order by sum(b2.bet) desc limit 1) as fav
    from teams t left join p on p.team_id = t.id
    group by t.id, t.name, t.owner)
  select json_build_object(
    'period', p_period,
    'since', (select case when t = '-infinity' then null else t end from since),
    'board', (select coalesce(json_agg(b order by b.net desc, b.wagered desc), '[]') from board b),
    'totals', (select json_build_object('bets', count(*), 'wagered', coalesce(sum(bet), 0), 'house', coalesce(-sum(payout - bet), 0),
                 'players', count(distinct team_id)) from bets),
    'games', (select coalesce(json_agg(g order by g.wagered desc), '[]') from (
                select game, count(*)::int as bets, sum(bet)::int as wagered, (-sum(payout - bet))::int as house,
                       count(distinct team_id)::int as players
                from bets group by game) g),
    'awards', json_build_object(
      'winner', (select row_to_json(x) from (select name, net from board where bets > 0 order by net desc limit 1) x),
      'loser',  (select row_to_json(x) from (select name, net from board where bets > 0 order by net asc limit 1) x),
      'degen',  (select row_to_json(x) from (select name, wagered, bets from board where bets > 0 order by wagered desc limit 1) x),
      'bestHit', (select row_to_json(x) from (select name, game, bet, payout, payout - bet as profit, detail, created_at from bets order by payout - bet desc, created_at limit 1) x),
      'worstBeat', (select row_to_json(x) from (select name, game, bet, payout, payout - bet as profit, detail, created_at from bets order by payout - bet asc, created_at limit 1) x),
      'parlay', (select row_to_json(x) from (select name, bet, payout, round(payout::numeric / bet, 2) as mult, detail from bets where game = 'parlay' and payout > bet order by payout::numeric / bet desc limit 1) x),
      'rocket', (select row_to_json(x) from (select name, bet, payout, round(payout::numeric / bet, 2) as mult from bets where game = 'rocket' and payout > bet order by payout::numeric / bet desc limit 1) x),
      'longshot', (select row_to_json(x) from (select name, game, bet, payout, round(payout::numeric / bet, 1) as mult, detail from bets where payout > bet order by payout::numeric / bet desc limit 1) x)
    ),
    'bank', (select coalesce(-sum(net), 0) from teams)
  ) $$;
grant execute on function stats(text) to anon, authenticated;

notify pgrst, 'reload schema';
