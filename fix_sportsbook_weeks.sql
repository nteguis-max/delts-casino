-- Washed Delts Casino: fetch the next two weeks of lines on every update
-- Paste into Supabase > SQL Editor and press Run.

-- called by the scheduler: read finished fetches, then ask ESPN again
create or replace function sb_poll() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r record; wk int; i int; base text := 'https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard';
begin
  for r in select q.id, s.status_code, s.content from sb_requests q join net._http_response s on s.id = q.id where not q.done loop
    begin
      if r.status_code = 200 then
        perform sb_ingest(r.content::jsonb);
        update sb_status set last_ok = now(), last_error = null where id = 1;
      else
        update sb_status set last_error = 'ESPN returned ' || coalesce(r.status_code::text, 'nothing') where id = 1;
      end if;
    exception when others then
      update sb_status set last_error = left(sqlerrm, 200) where id = 1;
    end;
    update sb_requests set done = true where id = r.id;
  end loop;
  delete from sb_requests where created_at < now() - interval '1 day';
  -- this week's board
  insert into sb_requests(id, url) values (net.http_get(base, timeout_milliseconds := 15000), base);
  -- any week that still has ungraded bets
  for wk in select distinct g.week from sb_bets b join sb_games g on g.id = b.game_id where b.status = 'open' and not g.final and g.week is not null loop
    insert into sb_requests(id, url) values (net.http_get(base || '?seasontype=2&week=' || wk, timeout_milliseconds := 15000), base || '?week=' || wk);
  end loop;
  -- the next two weeks, so upcoming lines show up as soon as DraftKings posts them
  select coalesce(max(week) filter (where kickoff <= now()), min(week) - 1) into wk from sb_games;
  if wk is not null then
    for i in 1 .. 2 loop
      if wk + i <= 18 then
        insert into sb_requests(id, url) values (net.http_get(base || '?seasontype=2&week=' || (wk + i), timeout_milliseconds := 15000), base || '?week=' || (wk + i));
      end if;
    end loop;
  end if;
end $$;

select public.sb_poll();
