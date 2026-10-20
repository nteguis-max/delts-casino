-- Washed Delts Casino: weather markets (Kalshi daily highs)
-- Paste into Supabase > SQL Editor and press Run.

-- ---------- Markets: Kalshi daily high temperature, bet against the house at Kalshi's price ----------
create table if not exists mk_series (
  ticker text primary key, city text not null, sort int not null default 0, enabled boolean not null default true
);
insert into mk_series(ticker, city, sort) values
  ('KXHIGHNY',   'New York',      1),
  ('KXHIGHTBOS', 'Boston',        2),
  ('KXHIGHTSFO', 'San Francisco', 3),
  ('KXHIGHTDC',  'Washington, DC', 4)
on conflict (ticker) do nothing;

create table if not exists mk_markets (
  ticker text primary key,
  series text not null references mk_series(ticker),
  event_ticker text not null,
  day date not null,                     -- the day whose high temperature this settles on
  title text, range_label text, strike_type text, floor_strike numeric, cap_strike numeric,
  yes_ask numeric, no_ask numeric, yes_bid numeric, no_bid numeric,
  status text, result text, close_time timestamptz,
  prices_at timestamptz, updated_at timestamptz not null default now()
);
create table if not exists mk_bets (
  id bigserial primary key,
  team_id int not null references teams(id),
  ticker text not null references mk_markets(ticker),
  side text not null check (side in ('yes','no')),
  price numeric not null, stake int not null,
  status text not null default 'open' check (status in ('open','won','lost','void')),
  payout int, created_at timestamptz not null default now(), graded_at timestamptz
);
create index if not exists mk_bets_open on mk_bets(ticker) where status = 'open';
create table if not exists mk_requests (id bigint primary key, url text, created_at timestamptz not null default now(), done boolean not null default false);
create table if not exists mk_status (id int primary key default 1 check (id = 1), last_ok timestamptz, last_error text);
insert into mk_status(id) values (1) on conflict (id) do nothing;
alter table mk_series enable row level security;
alter table mk_markets enable row level security;
alter table mk_bets enable row level security;
alter table mk_requests enable row level security;
alter table mk_status enable row level security;
revoke all on mk_series, mk_markets, mk_bets, mk_requests, mk_status from anon, authenticated;

-- betting on a day closes at 10 PM Eastern the night before
create or replace function _mk_cutoff(p_day date) returns timestamptz language sql immutable as $$
  select ((p_day - 1) + time '22:00') at time zone 'America/New_York' $$;

-- one Kalshi /markets payload in
create or replace function mk_ingest(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare m jsonb; n int := 0; d date; ser text;
begin
  for m in select * from jsonb_array_elements(coalesce(p -> 'markets', '[]')) loop
    ser := split_part(m ->> 'event_ticker', '-', 1);
    if not exists (select 1 from mk_series where ticker = ser) then continue; end if;
    begin
      d := to_date(substring(m ->> 'event_ticker' from '-([0-9]{2}[A-Z]{3}[0-9]{2})$'), 'YYMONDD');
    exception when others then continue; end;
    if d is null then continue; end if;
    insert into mk_markets(ticker, series, event_ticker, day, title, range_label, strike_type, floor_strike, cap_strike,
                           yes_ask, no_ask, yes_bid, no_bid, status, result, close_time, prices_at, updated_at)
    values (m ->> 'ticker', ser, m ->> 'event_ticker', d, m ->> 'title', m ->> 'yes_sub_title', m ->> 'strike_type',
            nullif(m ->> 'floor_strike', '')::numeric, nullif(m ->> 'cap_strike', '')::numeric,
            nullif(m ->> 'yes_ask_dollars', '')::numeric, nullif(m ->> 'no_ask_dollars', '')::numeric,
            nullif(m ->> 'yes_bid_dollars', '')::numeric, nullif(m ->> 'no_bid_dollars', '')::numeric,
            m ->> 'status', nullif(m ->> 'result', ''), (m ->> 'close_time')::timestamptz, now(), now())
    on conflict (ticker) do update set
      title = excluded.title, range_label = excluded.range_label,
      yes_ask = excluded.yes_ask, no_ask = excluded.no_ask, yes_bid = excluded.yes_bid, no_bid = excluded.no_bid,
      status = excluded.status, result = excluded.result, close_time = excluded.close_time,
      prices_at = now(), updated_at = now()
    where mk_markets.result is null;   -- a settled market never changes again
    n := n + 1;
  end loop;
  perform _mk_grade();
  return n;
end $$;

create or replace function _mk_grade() returns int
language plpgsql security definer set search_path = public as $$
declare b record; mk mk_markets; res text; pay int; n int := 0; s text;
begin
  for b in select * from mk_bets where status = 'open' for update loop
    select * into mk from mk_markets where ticker = b.ticker;
    if mk.result in ('yes','no') then
      res := case when mk.result = b.side then 'won' else 'lost' end;
      pay := case when res = 'won' then floor(b.stake / b.price)::int else 0 end;
    elsif mk.status in ('settled','finalized','determined') and coalesce(mk.result, '') not in ('yes','no') then
      res := 'void'; pay := b.stake;     -- Kalshi voided it: refund
    else continue; end if;
    update mk_bets set status = res, payout = pay, graded_at = now() where id = b.id;
    select city into s from mk_series where ticker = mk.series;
    perform _apply(b.team_id, pay, 0);
    perform _log(b.team_id, 'weather', b.stake, pay,
      s || ' high ' || to_char(mk.day, 'Mon FMDD') || ' · ' || upper(b.side) || ' ' || coalesce(mk.range_label, mk.ticker)
        || ' @ ' || round(b.price * 100) || '¢' || case when res = 'void' then ' · voided, refunded' else '' end);
    n := n + 1;
  end loop;
  return n;
end $$;

-- scheduler: read finished fetches, then ask Kalshi again for each city
create or replace function mk_poll() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r record; s record; u text; since bigint := extract(epoch from now() - interval '4 days')::bigint;
begin
  for r in select q.id, h.status_code, h.content from mk_requests q join net._http_response h on h.id = q.id where not q.done loop
    begin
      if r.status_code = 200 then
        perform mk_ingest(r.content::jsonb);
        update mk_status set last_ok = now(), last_error = null where id = 1;
      else
        update mk_status set last_error = 'Kalshi returned ' || coalesce(r.status_code::text, 'nothing') where id = 1;
      end if;
    exception when others then
      update mk_status set last_error = left(sqlerrm, 200) where id = 1;
    end;
    update mk_requests set done = true where id = r.id;
  end loop;
  delete from mk_requests where created_at < now() - interval '1 day';
  for s in select ticker from mk_series where enabled loop
    u := 'https://api.elections.kalshi.com/trade-api/v2/markets?limit=200&series_ticker=' || s.ticker || '&min_close_ts=' || since;
    insert into mk_requests(id, url) values (net.http_get(u, timeout_milliseconds := 15000), u);
  end loop;
end $$;

-- public board: recent and upcoming days per city
create or replace view v_mk_markets as
  select m.ticker, m.series, s.city, s.sort, m.day, m.range_label, m.strike_type, m.floor_strike, m.cap_strike,
    m.yes_ask, m.no_ask, m.status, m.result, _mk_cutoff(m.day) as cutoff,
    (m.result is null and m.status = 'active' and now() < _mk_cutoff(m.day)
       and m.prices_at > now() - interval '45 minutes') as open
  from mk_markets m join mk_series s on s.ticker = m.series
  where s.enabled and m.day >= (now() at time zone 'America/New_York')::date - 2
    and m.day <= (now() at time zone 'America/New_York')::date + 4
  order by s.sort, m.day, coalesce(m.floor_strike, m.cap_strike - 100);
create or replace view v_mk_status as select last_ok, last_error from mk_status;
grant select on v_mk_markets, v_mk_status to anon, authenticated;
grant execute on function _mk_cutoff(date) to anon, authenticated;

create or replace function mk_place(p_team int, p_pin text, p_ticker text, p_side text, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; mk mk_markets; pr numeric; bid bigint;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  if p_side not in ('yes','no') then raise exception 'Pick Yes or No.'; end if;
  select * into mk from mk_markets where ticker = p_ticker for update;
  if not found then raise exception 'That market isn''t on the board.'; end if;
  if mk.result is not null or mk.status <> 'active' then raise exception 'That market is closed.'; end if;
  if now() >= _mk_cutoff(mk.day) then raise exception 'Betting on % closes at 10 PM ET the night before.', to_char(mk.day, 'Mon FMDD'); end if;
  if mk.prices_at < now() - interval '45 minutes' then raise exception 'Prices are refreshing. Try again in a few minutes.'; end if;
  pr := case when p_side = 'yes' then mk.yes_ask else mk.no_ask end;
  if pr is null or pr < 0.05 or pr > 0.95 then raise exception 'That side is priced at %¢. Bets have to be between 5¢ and 95¢.', coalesce(round(pr * 100)::text, '?'); end if;
  perform _guard(t, p_bet, true);
  perform _apply(p_team, -p_bet, p_bet);
  insert into mk_bets(team_id, ticker, side, price, stake) values (p_team, p_ticker, p_side, pr, p_bet) returning id into bid;
  return json_build_object('ok', true, 'id', bid, 'price', pr, 'toWin', floor(p_bet / pr)::int - p_bet, 'balance', _bal(p_team));
end $$;

create or replace function mk_my_bets(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return coalesce((select json_agg(json_build_object('id', b.id, 'city', s.city, 'day', m.day, 'range', m.range_label, 'side', b.side,
      'price', b.price, 'stake', b.stake, 'toWin', floor(b.stake / b.price)::int - b.stake, 'status', b.status, 'payout', b.payout)
      order by b.created_at desc)
    from (select * from mk_bets where team_id = p_team and (status = 'open' or graded_at > now() - interval '7 days') order by created_at desc limit 40) b
    join mk_markets m on m.ticker = b.ticker join mk_series s on s.ticker = m.series), '[]'::json);
end $$;

revoke execute on function mk_ingest(jsonb), _mk_grade(), mk_poll() from public, anon, authenticated;
revoke execute on function mk_place(int,text,text,text,int), mk_my_bets(int,text) from public;
grant execute on function mk_place(int,text,text,text,int), mk_my_bets(int,text) to anon, authenticated;

-- check Kalshi every 5 minutes
select cron.schedule('delts-markets', '*/5 * * * *', 'select public.mk_poll()');
select public.mk_poll();
notify pgrst, 'reload schema';
