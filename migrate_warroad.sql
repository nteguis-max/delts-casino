-- Washed Delts Casino: Warroad, MN house weather market
-- Paste into Supabase > SQL Editor and press Run. Run migrate_markets.sql first.

-- ---------- Warroad, MN: house-made daily high market ----------
-- Priced from the National Weather Service forecast; settles on the highest reading at
-- Warroad International Memorial Airport (KRRT) between midnight and midnight Central.
alter table mk_series add column if not exists source text not null default 'kalshi';
insert into mk_series(ticker, city, sort, source) values ('WARROAD', 'Warroad, MN', 0, 'house')
on conflict (ticker) do update set source = 'house';
alter table mk_requests add column if not exists kind text not null default 'kalshi';
alter table mk_requests add column if not exists day date;

create table if not exists wr_config (
  id int primary key default 1 check (id = 1),
  lat numeric not null default 48.905, lon numeric not null default -95.3144, station text not null default 'KRRT',
  forecast_url text, forecast_at timestamptz, last_error text,
  max_bet int not null default 250,
  margin numeric not null default 0.06,   -- house markup on each side's probability
  spread numeric not null default 0.01    -- flat add-on per side
);
insert into wr_config(id) values (1) on conflict (id) do nothing;
create table if not exists wr_forecast (day date primary key, high int not null, fetched_at timestamptz not null default now());
create table if not exists wr_results (day date primary key, high int, readings int, source text, settled_at timestamptz not null default now());
alter table wr_config enable row level security;
alter table wr_forecast enable row level security;
alter table wr_results enable row level security;
revoke all on wr_config, wr_forecast, wr_results from anon, authenticated;

-- standard normal CDF (Abramowitz & Stegun 7.1.26, error < 1.5e-7)
create or replace function _wr_phi(z numeric) returns numeric language plpgsql immutable as $$
declare x numeric := abs(z) / sqrt(2); t numeric; y numeric;
begin
  t := 1 / (1 + 0.3275911 * x);
  y := 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
  return case when z >= 0 then 0.5 * (1 + y) else 0.5 * (1 - y) end;
end $$;

-- chance a whole-degree high lands in [lo, hi] (null = open-ended)
create or replace function _wr_prob(lo numeric, hi numeric, mu numeric, sd numeric) returns numeric language sql immutable as $$
  select (case when hi is null then 1 else _wr_phi((hi + 0.5 - mu) / sd) end)
       - (case when lo is null then 0 else _wr_phi((lo - 0.5 - mu) / sd) end) $$;

create or replace function _wr_today() returns date language sql stable as $$ select (now() at time zone 'America/Chicago')::date $$;

-- create a day's six ranges (once, centered on the first forecast) and reprice every open range
create or replace function _wr_price() returns int
language plpgsql security definer set search_path = public as $$
declare f record; m record; c wr_config; h int; lead int; mu numeric; sd numeric; p numeric; tk text; n int := 0;
begin
  select * into c from wr_config where id = 1;
  for f in select * from wr_forecast where day > _wr_today() and day <= _wr_today() + 4 loop
    tk := 'WARROAD-' || upper(to_char(f.day, 'YYMonDD'));
    if not exists (select 1 from mk_markets where event_ticker = tk) then
      h := f.high;
      insert into mk_markets(ticker, series, event_ticker, day, title, range_label, strike_type, floor_strike, cap_strike, status)
      values (tk || '-T' || (h - 4), 'WARROAD', tk, f.day, 'Warroad high', (h - 5) || '° or below', 'less', null, h - 4, 'active'),
             (tk || '-B' || (h - 4), 'WARROAD', tk, f.day, 'Warroad high', (h - 4) || '° to ' || (h - 3) || '°', 'between', h - 4, h - 3, 'active'),
             (tk || '-B' || (h - 2), 'WARROAD', tk, f.day, 'Warroad high', (h - 2) || '° to ' || (h - 1) || '°', 'between', h - 2, h - 1, 'active'),
             (tk || '-B' || h,       'WARROAD', tk, f.day, 'Warroad high', h || '° to ' || (h + 1) || '°', 'between', h, h + 1, 'active'),
             (tk || '-B' || (h + 2), 'WARROAD', tk, f.day, 'Warroad high', (h + 2) || '° to ' || (h + 3) || '°', 'between', h + 2, h + 3, 'active'),
             (tk || '-T' || (h + 3), 'WARROAD', tk, f.day, 'Warroad high', (h + 4) || '° or above', 'greater', h + 3, null, 'active');
    end if;
    lead := f.day - _wr_today();
    mu := f.high - 0.5;                      -- hourly readings run a touch under the true peak
    sd := 3.0 + 0.5 * greatest(lead - 1, 0); -- forecasts get fuzzier further out
    for m in select * from mk_markets where event_ticker = tk and result is null loop
      p := case m.strike_type
        when 'less' then _wr_prob(null, m.cap_strike - 1, mu, sd)
        when 'greater' then _wr_prob(m.floor_strike + 1, null, mu, sd)
        else _wr_prob(m.floor_strike, m.cap_strike, mu, sd) end;
      update mk_markets set
        yes_ask = least(0.99, round(p * (1 + c.margin) + c.spread, 2)),
        no_ask  = least(0.99, round((1 - p) * (1 + c.margin) + c.spread, 2)),
        yes_bid = null, no_bid = null, status = 'active', prices_at = now(), updated_at = now()
      where ticker = m.ticker;
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;

-- NWS /points response: remember the forecast URL for Warroad's grid square
create or replace function wr_ingest_points(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  update wr_config set forecast_url = p -> 'properties' ->> 'forecast' where id = 1 and p -> 'properties' ->> 'forecast' is not null;
end $$;

-- NWS forecast response: one daytime high per day
create or replace function wr_ingest_forecast(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare e jsonb; d date; hi int; n int := 0;
begin
  for e in select * from jsonb_array_elements(coalesce(p -> 'properties' -> 'periods', '[]')) loop
    if not coalesce((e ->> 'isDaytime')::boolean, false) or e ->> 'temperature' is null then continue; end if;
    d := ((e ->> 'startTime')::timestamptz at time zone 'America/Chicago')::date;
    hi := case when e ->> 'temperatureUnit' = 'C' then round((e ->> 'temperature')::numeric * 9 / 5 + 32)
               else round((e ->> 'temperature')::numeric) end;
    insert into wr_forecast(day, high, fetched_at) values (d, hi, now())
    on conflict (day) do update set high = excluded.high, fetched_at = now();
    n := n + 1;
  end loop;
  update wr_config set forecast_at = now(), last_error = null where id = 1;
  perform _wr_price();
  return n;
end $$;

-- mark a day's ranges with the official high and grade bets
create or replace function _wr_settle(p_day date, p_high int, p_readings int, p_source text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update mk_markets set status = 'finalized', updated_at = now(),
    result = case
      when strike_type = 'less' then case when p_high < cap_strike then 'yes' else 'no' end
      when strike_type = 'greater' then case when p_high > floor_strike then 'yes' else 'no' end
      else case when p_high between floor_strike and cap_strike then 'yes' else 'no' end end
  where series = 'WARROAD' and day = p_day and result is null;
  insert into wr_results(day, high, readings, source) values (p_day, p_high, p_readings, p_source)
  on conflict (day) do update set high = excluded.high, readings = excluded.readings, source = excluded.source, settled_at = now();
  perform _mk_grade();
end $$;

-- NWS observations for KRRT over one Central-time day
create or replace function wr_ingest_obs(p jsonb, p_day date) returns void
language plpgsql security definer set search_path = public as $$
declare mx numeric; n int;
begin
  select max((f -> 'properties' -> 'temperature' ->> 'value')::numeric), count(*)
    into mx, n
  from jsonb_array_elements(coalesce(p -> 'features', '[]')) f
  where f -> 'properties' -> 'temperature' ->> 'value' is not null
    and ((f -> 'properties' ->> 'timestamp')::timestamptz at time zone 'America/Chicago')::date = p_day;
  if n >= 16 and mx is not null then
    perform _wr_settle(p_day, round(mx * 9 / 5 + 32)::int, n, 'KRRT hourly readings');
  elsif now() > ((p_day + 3)::timestamp at time zone 'America/Chicago') then
    -- station mostly offline that day: void the ranges so every bet is refunded
    update mk_markets set status = 'finalized', result = null, updated_at = now()
    where series = 'WARROAD' and day = p_day and result is null;
    insert into wr_results(day, high, readings, source) values (p_day, null, coalesce(n, 0), 'voided: not enough readings')
    on conflict (day) do nothing;
    perform _mk_grade();
  end if;
end $$;

-- grading: a finalized house market with no result is a void (refund)
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
      res := 'void'; pay := b.stake;
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

-- scheduler: Kalshi cities plus Warroad's forecast and readings
create or replace function mk_poll() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare r record; s record; u text; c wr_config; d date; since bigint := extract(epoch from now() - interval '4 days')::bigint;
  hdr jsonb := '{"User-Agent":"washed-delts-casino (github.com/nteguis-max/delts-casino)","Accept":"application/geo+json"}';
begin
  for r in select q.id, q.kind, q.day, h.status_code, h.content from mk_requests q join net._http_response h on h.id = q.id where not q.done loop
    begin
      if r.status_code = 200 then
        if r.kind = 'kalshi' then perform mk_ingest(r.content::jsonb); update mk_status set last_ok = now(), last_error = null where id = 1;
        elsif r.kind = 'wr_points' then perform wr_ingest_points(r.content::jsonb);
        elsif r.kind = 'wr_forecast' then perform wr_ingest_forecast(r.content::jsonb);
        elsif r.kind = 'wr_obs' then perform wr_ingest_obs(r.content::jsonb, r.day);
        end if;
      elsif r.kind = 'kalshi' then
        update mk_status set last_error = 'Kalshi returned ' || coalesce(r.status_code::text, 'nothing') where id = 1;
      else
        update wr_config set last_error = 'Weather service returned ' || coalesce(r.status_code::text, 'nothing') || ' (' || r.kind || ')' where id = 1;
      end if;
    exception when others then
      if r.kind = 'kalshi' then update mk_status set last_error = left(sqlerrm, 200) where id = 1;
      else update wr_config set last_error = left(r.kind || ': ' || sqlerrm, 200) where id = 1; end if;
    end;
    update mk_requests set done = true where id = r.id;
  end loop;
  delete from mk_requests where created_at < now() - interval '1 day';

  for s in select ticker from mk_series where enabled and source = 'kalshi' loop
    u := 'https://api.elections.kalshi.com/trade-api/v2/markets?limit=200&series_ticker=' || s.ticker || '&min_close_ts=' || since;
    insert into mk_requests(id, url, kind) values (net.http_get(u, timeout_milliseconds := 15000), u, 'kalshi');
  end loop;

  if exists (select 1 from mk_series where ticker = 'WARROAD' and enabled) then
    select * into c from wr_config where id = 1;
    if c.forecast_url is null then
      u := 'https://api.weather.gov/points/' || c.lat || ',' || c.lon;
      insert into mk_requests(id, url, kind) values (net.http_get(u, headers := hdr, timeout_milliseconds := 15000), u, 'wr_points');
    else
      insert into mk_requests(id, url, kind) values (net.http_get(c.forecast_url, headers := hdr, timeout_milliseconds := 15000), c.forecast_url, 'wr_forecast');
    end if;
    -- readings for any finished day that still needs a result (wait until 3 AM Central the next morning)
    for d in select distinct day from mk_markets where series = 'WARROAD' and result is null and status <> 'finalized'
             and now() > ((day + 1)::timestamp + interval '3 hours') at time zone 'America/Chicago' loop
      u := 'https://api.weather.gov/stations/' || c.station || '/observations?start='
        || to_char((d::timestamp at time zone 'America/Chicago') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        || '&end=' || to_char(((d + 1)::timestamp at time zone 'America/Chicago') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
      insert into mk_requests(id, url, kind, day) values (net.http_get(u, headers := hdr, timeout_milliseconds := 15000), u, 'wr_obs', d);
    end loop;
  end if;
end $$;

-- board view gets the source, plus Warroad's forecast and recent results
create or replace view v_mk_markets as
  select m.ticker, m.series, s.city, s.sort, m.day, m.range_label, m.strike_type, m.floor_strike, m.cap_strike,
    m.yes_ask, m.no_ask, m.status, m.result, _mk_cutoff(m.day) as cutoff,
    (m.result is null and m.status = 'active' and now() < _mk_cutoff(m.day)
       and m.prices_at > now() - interval '45 minutes') as open,
    s.source
  from mk_markets m join mk_series s on s.ticker = m.series
  where s.enabled and m.day >= (now() at time zone 'America/New_York')::date - 2
    and m.day <= (now() at time zone 'America/New_York')::date + 4
  order by s.sort, m.day, coalesce(m.floor_strike, m.cap_strike - 100);
create or replace view v_wr_info as
  select f.day, f.high as forecast_high, r.high as official_high, r.source as result_source,
    (select max_bet from wr_config where id = 1) as max_bet, (select last_error from wr_config where id = 1) as last_error
  from wr_forecast f full join wr_results r on r.day = f.day
  where coalesce(f.day, r.day) >= _wr_today() - 3;
grant select on v_mk_markets, v_wr_info to anon, authenticated;
grant execute on function _wr_today() to anon, authenticated;

-- house markets have their own max bet
create or replace function mk_place(p_team int, p_pin text, p_ticker text, p_side text, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; mk mk_markets; pr numeric; bid bigint; src text; wmax int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  if p_side not in ('yes','no') then raise exception 'Pick Yes or No.'; end if;
  select * into mk from mk_markets where ticker = p_ticker for update;
  if not found then raise exception 'That market isn''t on the board.'; end if;
  if mk.result is not null or mk.status <> 'active' then raise exception 'That market is closed.'; end if;
  if now() >= _mk_cutoff(mk.day) then raise exception 'Betting on % closes at 10 PM ET the night before.', to_char(mk.day, 'Mon FMDD'); end if;
  if mk.prices_at < now() - interval '45 minutes' then raise exception 'Prices are refreshing. Try again in a few minutes.'; end if;
  select source into src from mk_series where ticker = mk.series;
  if src = 'house' then
    select max_bet into wmax from wr_config where id = 1;
    if p_bet > wmax then raise exception 'Max bet on Warroad is $%.', wmax; end if;
  end if;
  pr := case when p_side = 'yes' then mk.yes_ask else mk.no_ask end;
  if pr is null or pr < 0.05 or pr > 0.95 then raise exception 'That side is priced at %¢. Bets have to be between 5¢ and 95¢.', coalesce(round(pr * 100)::text, '?'); end if;
  perform _guard(t, p_bet, true);
  perform _apply(p_team, -p_bet, p_bet);
  insert into mk_bets(team_id, ticker, side, price, stake) values (p_team, p_ticker, p_side, pr, p_bet) returning id into bid;
  return json_build_object('ok', true, 'id', bid, 'price', pr, 'toWin', floor(p_bet / pr)::int - p_bet, 'balance', _bal(p_team));
end $$;

-- commish backup: settle a Warroad day by hand if the station feed fails
create or replace function admin_wr_settle(p_pin text, p_day date, p_high int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  if p_day >= _wr_today() then raise exception 'You can only settle a day that''s over.'; end if;
  if not exists (select 1 from mk_markets where series = 'WARROAD' and day = p_day and result is null) then
    raise exception 'Nothing open to settle for %.', p_day; end if;
  perform _wr_settle(p_day, p_high, 0, 'entered by the commish');
  return json_build_object('ok', true);
end $$;

revoke execute on function _wr_price(), wr_ingest_points(jsonb), wr_ingest_forecast(jsonb), wr_ingest_obs(jsonb,date), _wr_settle(date,int,int,text), _mk_grade(), mk_poll() from public, anon, authenticated;
revoke execute on function mk_place(int,text,text,text,int), admin_wr_settle(text,date,int) from public;
grant execute on function mk_place(int,text,text,text,int), admin_wr_settle(text,date,int) to anon, authenticated;
select public.mk_poll();
notify pgrst, 'reload schema';
