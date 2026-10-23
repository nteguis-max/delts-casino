-- Skyline + better odds. Paste the whole thing into the Supabase SQL Editor and run it once.

-- Washed Delts Casino: Tycoons board includes what each team owns (for the skylines)
-- Paste into Supabase > SQL Editor and press Run.

create or replace function biz_stats() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'board', (select coalesce(json_agg(x order by x.rate desc, x.invested desc), '[]') from (
      select t.id, t.name, t.owner,
        round(_biz_rate(t.id) * 24, 2) as rate,     -- dollars per day
        coalesce((select sum(qty) from biz_owned where team_id = t.id), 0)::int as units,
        coalesce((select json_object_agg(code, qty) from biz_owned where team_id = t.id and qty > 0), '{}'::json) as owned,
        coalesce((select -sum(amount) from biz_ledger where team_id = t.id and kind = 'buy'), 0)::int as invested,
        coalesce((select sum(amount) from biz_ledger where team_id = t.id and kind = 'collect'), 0)::int as collected,
        coalesce((select sum(amount) from biz_ledger where team_id = t.id and kind = 'click'), 0)::int as clicked
      from teams t) x),
    'recent', (select coalesce(json_agg(r order by r.created_at desc), '[]') from (
      select l.created_at, t.name, l.kind, l.amount, l.detail from biz_ledger l join teams t on t.id = l.team_id
      where l.kind = 'buy' order by l.created_at desc limit 15) r),
    'totals', json_build_object(
      'minted', coalesce((select sum(amount) from biz_ledger where kind in ('collect','click')), 0),
      'invested', coalesce((select -sum(amount) from biz_ledger where kind = 'buy'), 0),
      'mintedWeek', coalesce((select sum(amount) from biz_ledger where kind in ('collect','click') and created_at >= _biz_week()::timestamp at time zone 'America/New_York'), 0))
  ) $$;


create or replace function play_roulette(p_team int, p_pin text, p_bet int, p_pick text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; n int; mult int := 0; reds int[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]; pay int; lbl text;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if; perform _guard(t, p_bet);
  if p_pick = 'num' and (p_num is null or p_num < 0 or p_num > 36) then raise exception 'Pick a number from 0 to 36.'; end if;
  n := _rnd(37);
  mult := case p_pick
    when 'red' then case when n > 0 and n = any(reds) then 2 else 0 end
    when 'black' then case when n > 0 and not n = any(reds) then 2 else 0 end
    when 'odd' then case when n > 0 and n % 2 = 1 then 2 else 0 end
    when 'even' then case when n > 0 and n % 2 = 0 then 2 else 0 end
    when 'low' then case when n between 1 and 18 then 2 else 0 end
    when 'high' then case when n >= 19 then 2 else 0 end
    when 'd1' then case when n between 1 and 12 then 3 else 0 end
    when 'd2' then case when n between 13 and 24 then 3 else 0 end
    when 'd3' then case when n between 25 and 36 then 3 else 0 end
    when 'num' then case when n = p_num then 36 else 0 end
    else null end;
  if mult is null then raise exception 'Unknown bet.'; end if;
  pay := p_bet * mult;
  if n = 0 and p_pick in ('red','black','odd','even','low','high') then pay := floor(p_bet / 2.0); end if;  -- la partage: zero returns half
  lbl := case p_pick when 'num' then '#' || p_num when 'low' then '1 to 18' when 'high' then '19 to 36'
         when 'd1' then '1st 12' when 'd2' then '2nd 12' when 'd3' then '3rd 12' else initcap(p_pick) end;
  perform _apply(p_team, pay - p_bet, p_bet);
  perform _log(p_team, 'roulette', p_bet, pay, lbl || ' · landed ' || n);
  return json_build_object('n', n, 'payout', pay, 'balance', _bal(p_team));
end $$;


create or replace function play_slots(p_team int, p_pin text, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r text[] := '{}'; x int; s text; i int; mult numeric := 0; td int; pay int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if; perform _guard(t, p_bet);
  for i in 1..3 loop
    x := _rnd(15);  -- weights TD1 2PT2 FG3 PAT4 SACK5
    s := case when x < 1 then 'TD' when x < 3 then '2PT' when x < 6 then 'FG' when x < 10 then 'PAT' else 'SACK' end;
    r := r || s;
  end loop;
  td := (select count(*) from unnest(r) u where u = 'TD');
  if r[1] = r[2] and r[2] = r[3] then
    mult := case r[1] when 'TD' then 150 when '2PT' then 40 when 'FG' then 16 when 'PAT' then 8 else 5 end;
  elsif td = 2 then mult := 8; elsif td = 1 then mult := 1.6; end if;
  pay := floor(p_bet * mult);
  perform _apply(p_team, pay - p_bet, p_bet);
  perform _log(p_team, 'slots', p_bet, pay, array_to_string(r, ' '));
  return json_build_object('reels', r, 'payout', pay, 'balance', _bal(p_team));
end $$;


create or replace function play_dice(p_team int, p_pin text, p_bet int, p_target int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; roll int; pay int := 0;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if; perform _guard(t, p_bet);
  if p_target < 2 or p_target > 95 then raise exception 'Target must be 2 to 95.'; end if;
  roll := _rnd(10000);
  if roll < p_target * 100 then pay := floor(p_bet * 99.5 / p_target); end if;
  perform _apply(p_team, pay - p_bet, p_bet);
  perform _log(p_team, 'dice', p_bet, pay, 'rolled ' || to_char(roll / 100.0, 'FM90.00') || ' under ' || p_target);
  return json_build_object('roll', round(roll / 100.0, 2), 'payout', pay, 'balance', _bal(p_team));
end $$;


create or replace function play_plinko(p_team int, p_pin text, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; path int[] := '{}'; k int := 0; i int; b int;
  m numeric[] := array[40,9,3.5,1.8,1.2,0.6,0.4,0.6,1.2,1.8,3.5,9,40]; pay int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if; perform _guard(t, p_bet);
  for i in 1..12 loop b := _rnd(2); path := path || b; k := k + b; end loop;
  pay := floor(p_bet * m[k + 1]);
  perform _apply(p_team, pay - p_bet, p_bet);
  perform _log(p_team, 'plinko', p_bet, pay, m[k + 1] || 'x bucket');
  return json_build_object('path', path, 'mult', m[k + 1], 'payout', pay, 'balance', _bal(p_team));
end $$;


create or replace function _bj_resolve(p_team int) returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands; x jsonb; i int; n int; pv int; dv int; pay int; total_pay int := 0; total_bet int := 0;
  live boolean := false; is_nat boolean; dbj boolean; note text; notes text[] := '{}'; hs jsonb := '[]';
begin
  select * into h from bj_hands where team_id = p_team;
  n := jsonb_array_length(h.hands);
  for i in 0 .. n - 1 loop if _bj_val(h.hands -> i -> 'c') <= 21 then live := true; end if; end loop;
  is_nat := n = 1 and jsonb_array_length(h.hands -> 0 -> 'c') = 2 and _bj_val(h.hands -> 0 -> 'c') = 21;
  dbj := jsonb_array_length(h.dealer) = 2 and _bj_val(h.dealer) = 21;
  if live and not is_nat and not dbj then
    while _bj_val(h.dealer) < 17 loop h.dealer := h.dealer || to_jsonb(_card()); end loop;
  end if;
  dv := _bj_val(h.dealer);
  for i in 0 .. n - 1 loop
    x := h.hands -> i; pv := _bj_val(x -> 'c'); pay := 0;
    if pv > 21 then note := 'bust ' || pv;
    elsif is_nat and not dbj then pay := floor((x ->> 'bet')::int * 2.5); note := 'blackjack';
    elsif is_nat and dbj then pay := floor((x ->> 'bet')::int * 2.5); note := 'blackjack beats dealer blackjack';
    elsif dbj then note := 'dealer blackjack';
    elsif jsonb_array_length(x -> 'c') >= 6 then pay := (x ->> 'bet')::int * 2; note := 'six-card charlie';
    elsif dv > 21 then pay := (x ->> 'bet')::int * 2; note := pv || ', dealer bust';
    elsif pv > dv then pay := (x ->> 'bet')::int * 2; note := pv || ' vs ' || dv;
    elsif pv = dv then pay := (x ->> 'bet')::int; note := 'push ' || pv;
    else note := pv || ' vs ' || dv; end if;
    if (x ->> 'dbl')::boolean then note := note || ' doubled'; end if;
    total_pay := total_pay + pay; total_bet := total_bet + (x ->> 'bet')::int;
    notes := notes || (case when n > 1 then 'hand ' || (i + 1) || ': ' else '' end || note);
    hs := hs || jsonb_build_array(jsonb_build_object('cards', x -> 'c', 'total', pv, 'bet', (x ->> 'bet')::int,
      'payout', pay, 'note', note, 'doubled', x -> 'dbl', 'done', true));
  end loop;
  perform _apply(p_team, total_pay, 0);
  perform _log(p_team, 'blackjack', total_bet, total_pay, array_to_string(notes, ' · ') || case when n > 1 then ' · split' else '' end);
  delete from bj_hands where team_id = p_team;
  return json_build_object('phase', 'done', 'hands', hs, 'dealer', h.dealer, 'dealerTotal', dv,
    'bet', total_bet, 'payout', total_pay, 'note', array_to_string(notes, ' · '), 'balance', _bal(p_team));
end $$;


create or replace function _bj_advance(p_team int) returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands; x jsonb; i int; n int;
begin
  select * into h from bj_hands where team_id = p_team;
  n := jsonb_array_length(h.hands);
  x := h.hands -> h.active;
  if _bj_val(x -> 'c') >= 21 or jsonb_array_length(x -> 'c') >= 6 or coalesce((x ->> 'ace')::boolean, false) then
    h.hands := jsonb_set(h.hands, array[h.active::text, 'done'], 'true');
  end if;
  for i in 0 .. n - 1 loop
    if not (h.hands -> i ->> 'done')::boolean then
      update bj_hands set hands = h.hands, active = i where team_id = p_team returning * into h;
      return _bj_view(h);
    end if;
  end loop;
  update bj_hands set hands = h.hands where team_id = p_team;
  return _bj_resolve(p_team);
end $$;


create or replace function rk_launch(p_team int, p_pin text, p_bet int, p_auto numeric default null) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; u numeric; cr numeric; pay int; r rk_rounds;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform _rk_sweep(p_team);
  if exists (select 1 from rk_rounds where team_id = p_team) then raise exception 'Your rocket is still in the air.'; end if;
  if p_auto is not null and (p_auto < 1.01 or p_auto > 100) then raise exception 'Auto cash-out has to be between 1.01x and 100x.'; end if;
  perform _guard(t, p_bet);
  perform _apply(p_team, -p_bet, p_bet);
  u := (_rnd(1000000) + 1) / 1000000.0;                  -- (0, 1]
  cr := least(100, greatest(1, floor(0.99 / u * 100) / 100));
  if p_auto is not null then
    p_auto := floor(p_auto * 100) / 100;
    pay := case when cr >= p_auto then floor(p_bet * p_auto)::int else 0 end;
    perform _apply(p_team, pay, 0);
    perform _log(p_team, 'rocket', p_bet, pay, case when pay > 0 then 'Auto cash-out at ' || to_char(p_auto, 'FM990.00') || 'x · rocket went to ' || to_char(cr, 'FM990.00') || 'x'
                                                   else 'Blew up at ' || to_char(cr, 'FM990.00') || 'x · auto target ' || to_char(p_auto, 'FM990.00') || 'x' end);
    return json_build_object('mode', 'auto', 'crash', cr, 'auto', p_auto, 'payout', pay, 'balance', _bal(p_team));
  end if;
  insert into rk_rounds(team_id, bet, crash, started_at) values (p_team, p_bet, cr, clock_timestamp()) returning * into r;
  if cr <= 1 then perform _rk_sweep(p_team); return json_build_object('mode', 'live', 'state', 'crashed', 'crash', cr, 'elapsed', 0, 'payout', 0, 'balance', _bal(p_team)); end if;
  return json_build_object('mode', 'live', 'state', 'flying', 'elapsed', 0, 'balance', _bal(p_team));
end $$;


create or replace function _ck_mult(p_level text, p_step int) returns numeric language sql immutable as $$
  select case when p_step <= 0 then 1 else least(100, floor(0.98 / power((select survive from _ck_level(p_level)), p_step) * 100) / 100) end $$;


notify pgrst, 'reload schema';
