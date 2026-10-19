-- Washed Delts Casino: database setup
-- Paste this whole file into Supabase > SQL Editor and press Run.
-- BEFORE running: change 'SET-YOUR-PIN' near the bottom to your commish PIN.

create extension if not exists pgcrypto with schema extensions;

-- ---------- tables (no direct access for the public) ----------
create table if not exists teams (
  id int primary key,
  name text not null,
  owner text not null,
  pin_hash text,
  base int not null default 0,        -- Sleeper FAAB as of last sync/settle
  settled int not null default 0,     -- casino net already pushed into Sleeper
  net int not null default 0,         -- all-time casino profit/loss
  wagered int not null default 0,
  plays int not null default 0,
  best int not null default 0,
  day date,
  day_wagered int not null default 0,
  fails int not null default 0,
  locked_until timestamptz
);
create table if not exists plays (
  id bigserial primary key,
  team_id int not null references teams(id),
  game text not null, bet int not null, payout int not null, detail text,
  created_at timestamptz not null default now()
);
create index if not exists plays_created on plays(created_at desc);
create table if not exists config (
  id int primary key default 1 check (id = 1),
  open boolean not null default true,
  max_bet int not null default 1000,
  daily_limit int not null default 3000,
  admin_pin_hash text not null,
  admin_fails int not null default 0,
  admin_locked_until timestamptz,
  rebate_pct int not null default 100,
  last_settled timestamptz
);
create table if not exists bj_hands (
  team_id int primary key references teams(id),
  hands jsonb not null, active int not null default 0, dealer jsonb not null,
  created_at timestamptz not null default now()
);
alter table teams enable row level security;
alter table plays enable row level security;
alter table config enable row level security;
alter table bj_hands enable row level security;
revoke all on teams, plays, config, bj_hands from anon, authenticated;

-- ---------- public read-only views ----------
create or replace view v_teams as
  select id, name, owner, (pin_hash is not null) as claimed, net, (net - settled) as unsettled,
         (base + net - settled) as available, base, plays, wagered,
         case when day = (now() at time zone 'America/New_York')::date then day_wagered else 0 end as day_wagered
  from teams;
create or replace view v_feed as
  select p.id, p.team_id, t.name, p.game, p.bet, p.payout, p.detail, p.created_at
  from plays p join teams t on t.id = p.team_id
  order by p.created_at desc limit 40;
create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or (extract(isodow from now() at time zone 'America/New_York') = 2 and extract(hour from now() at time zone 'America/New_York') < 6) as blackout
  from config;
grant select on v_teams, v_feed, v_config to anon, authenticated;

-- ---------- internal helpers ----------
create or replace function _rnd(n int) returns int language sql volatile as $$
  select (('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint % n)::int $$;

create or replace function _blackout() returns boolean language sql stable as $$
  select (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
      or (extract(isodow from now() at time zone 'America/New_York') = 2 and extract(hour from now() at time zone 'America/New_York') < 6) $$;

create or replace function _auth(p_team int, p_pin text) returns teams
language plpgsql security definer set search_path = public, extensions as $$
declare t teams;
begin
  select * into t from teams where id = p_team for update;
  if not found then raise exception 'Unknown team'; end if;
  if t.locked_until > now() then raise exception 'Too many wrong PINs. Try again in 15 minutes.'; end if;
  if t.pin_hash is null then raise exception 'That team hasn''t been claimed yet.'; end if;
  if t.pin_hash <> crypt(coalesce(p_pin,''), t.pin_hash) then
    update teams set fails = fails + 1, locked_until = case when fails + 1 >= 8 then now() + interval '15 minutes' end where id = p_team;
    return null;
  end if;
  if t.fails > 0 then update teams set fails = 0, locked_until = null where id = p_team returning * into t; end if;
  if t.day is distinct from (now() at time zone 'America/New_York')::date then
    update teams set day = (now() at time zone 'America/New_York')::date, day_wagered = 0 where id = p_team returning * into t;
  end if;
  return t;
end $$;

-- checks a new wager; p_capped=false skips the max-bet check (blackjack doubles)
create or replace function _guard(t teams, p_bet int, p_capped boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare c config;
begin
  select * into c from config where id = 1;
  if not c.open then raise exception 'The casino is closed right now.'; end if;
  if _blackout() then raise exception 'Betting is closed from 8 PM Monday until waivers clear at 6 AM Tuesday (Eastern).'; end if;
  if p_bet is null or p_bet < 10 then raise exception 'Minimum bet is $10.'; end if;
  if p_capped and p_bet > c.max_bet then raise exception 'Max bet is $%.', c.max_bet; end if;
  if p_bet > t.base + t.net - t.settled then raise exception 'You don''t have that much FAAB.'; end if;
  if t.day_wagered + p_bet > c.daily_limit then raise exception 'That would pass today''s wager limit of $%.', c.daily_limit; end if;
end $$;

create or replace function _apply(p_team int, p_delta int, p_wager int) returns void
language sql security definer set search_path = public as $$
  update teams set net = net + p_delta, wagered = wagered + p_wager, day_wagered = day_wagered + p_wager where id = p_team $$;

create or replace function _log(p_team int, p_game text, p_bet int, p_payout int, p_detail text) returns void
language sql security definer set search_path = public as $$
  insert into plays(team_id, game, bet, payout, detail) values (p_team, p_game, p_bet, p_payout, p_detail);
  update teams set plays = plays + 1, best = greatest(best, p_payout - p_bet) where id = p_team; $$;

create or replace function _bal(p_team int) returns int language sql stable security definer set search_path = public as $$
  select base + net - settled from teams where id = p_team $$;

create or replace function _admin(p_pin text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare c config;
begin
  select * into c from config where id = 1;
  if c.admin_locked_until > now() then raise exception 'Too many wrong PINs. Try again in 15 minutes.'; end if;
  if c.admin_pin_hash <> crypt(coalesce(p_pin,''), c.admin_pin_hash) then
    update config set admin_fails = admin_fails + 1,
      admin_locked_until = case when admin_fails + 1 >= 5 then now() + interval '15 minutes' end where id = 1;
    return false;
  end if;
  update config set admin_fails = 0, admin_locked_until = null where id = 1;
  return true;
end $$;

-- ---------- team access ----------
create or replace function claim_team(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teams;
begin
  if p_pin !~ '^\d{4}$' then raise exception 'PIN must be 4 digits.'; end if;
  select * into t from teams where id = p_team for update;
  if not found then raise exception 'Unknown team'; end if;
  if t.pin_hash is not null then raise exception 'That team is already claimed. Ask the commish to reset it.'; end if;
  update teams set pin_hash = crypt(p_pin, gen_salt('bf')) where id = p_team;
  return json_build_object('ok', true);
end $$;

create or replace function login(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if; return json_build_object('ok', true, 'balance', _bal(p_team)); end $$;

-- ---------- games ----------
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
  elsif td = 2 then mult := 8; elsif td = 1 then mult := 1.5; end if;
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
  if roll < p_target * 100 then pay := floor(p_bet * 99.0 / p_target); end if;
  perform _apply(p_team, pay - p_bet, p_bet);
  perform _log(p_team, 'dice', p_bet, pay, 'rolled ' || to_char(roll / 100.0, 'FM90.00') || ' under ' || p_target);
  return json_build_object('roll', round(roll / 100.0, 2), 'payout', pay, 'balance', _bal(p_team));
end $$;

create or replace function play_plinko(p_team int, p_pin text, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; path int[] := '{}'; k int := 0; i int; b int;
  m numeric[] := array[25,8,3.5,1.8,1.2,0.6,0.4,0.6,1.2,1.8,3.5,8,25]; pay int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if; perform _guard(t, p_bet);
  for i in 1..12 loop b := _rnd(2); path := path || b; k := k + b; end loop;
  pay := floor(p_bet * m[k + 1]);
  perform _apply(p_team, pay - p_bet, p_bet);
  perform _log(p_team, 'plinko', p_bet, pay, m[k + 1] || 'x bucket');
  return json_build_object('path', path, 'mult', m[k + 1], 'payout', pay, 'balance', _bal(p_team));
end $$;

-- ---------- blackjack (state lives on the server, so a closed tab can resume) ----------
-- hands: [{"c":[cards], "bet":int, "dbl":bool, "done":bool, "ace":bool}]  (ace = split aces, one card only)
create or replace function _card() returns text language sql volatile as $$
  select (array['A','2','3','4','5','6','7','8','9','10','J','Q','K'])[_rnd(13)+1] || (array['♠','♥','♦','♣'])[_rnd(4)+1] $$;

create or replace function _rank(c text) returns text language sql immutable as $$ select left(c, length(c) - 1) $$;

create or replace function _rank_val(c text) returns int language sql immutable as $$
  select case when _rank(c) = 'A' then 11 when _rank(c) in ('J','Q','K') then 10 else _rank(c)::int end $$;

create or replace function _bj_val(h jsonb) returns int language plpgsql immutable as $$
declare c text; tot int := 0; aces int := 0;
begin
  for c in select jsonb_array_elements_text(h) loop
    if _rank(c) = 'A' then aces := aces + 1; end if;
    tot := tot + _rank_val(c);
  end loop;
  while tot > 21 and aces > 0 loop tot := tot - 10; aces := aces - 1; end loop;
  return tot;
end $$;

create or replace function _bj_view(h bj_hands) returns json language plpgsql stable as $$
declare cur jsonb := h.hands -> h.active; c jsonb := cur -> 'c'; hs jsonb := '[]';
  i int; x jsonb;
begin
  for i in 0 .. jsonb_array_length(h.hands) - 1 loop
    x := h.hands -> i;
    hs := hs || jsonb_build_array(jsonb_build_object('cards', x -> 'c', 'total', _bj_val(x -> 'c'), 'bet', x -> 'bet',
      'doubled', x -> 'dbl', 'done', x -> 'done'));
  end loop;
  return json_build_object('phase', 'player', 'hands', hs, 'active', h.active,
    'dealer', jsonb_build_array(h.dealer -> 0, '??'::text), 'dealerTotal', _bj_val(jsonb_build_array(h.dealer -> 0)),
    'canDouble', jsonb_array_length(c) = 2 and not coalesce((cur ->> 'ace')::boolean, false),
    'canSplit', jsonb_array_length(c) = 2 and jsonb_array_length(h.hands) < 4
                and _rank_val(c ->> 0) = _rank_val(c ->> 1),
    'balance', _bal(h.team_id));
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
    elsif is_nat and dbj then pay := (x ->> 'bet')::int; note := 'push, both blackjack';
    elsif dbj then note := 'dealer blackjack';
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

-- marks the active hand done if it is finished, moves to the next open hand, resolves when none are left
create or replace function _bj_advance(p_team int) returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands; x jsonb; i int; n int;
begin
  select * into h from bj_hands where team_id = p_team;
  n := jsonb_array_length(h.hands);
  x := h.hands -> h.active;
  if _bj_val(x -> 'c') >= 21 or coalesce((x ->> 'ace')::boolean, false) then
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

create or replace function bj_state(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; h bj_hands;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into h from bj_hands where team_id = p_team;
  if not found then return json_build_object('phase', 'idle', 'balance', _bal(p_team)); end if;
  return _bj_view(h);
end $$;

create or replace function bj_deal(p_team int, p_pin text, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; h bj_hands;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into h from bj_hands where team_id = p_team;
  if found then return _bj_view(h); end if;
  perform _guard(t, p_bet);
  perform _apply(p_team, -p_bet, p_bet);
  insert into bj_hands(team_id, hands, dealer)
    values (p_team, jsonb_build_array(jsonb_build_object('c', jsonb_build_array(_card(), _card()), 'bet', p_bet, 'dbl', false, 'done', false)),
            jsonb_build_array(_card(), _card())) returning * into h;
  if _bj_val(h.hands -> 0 -> 'c') = 21 or _bj_val(h.dealer) = 21 then return _bj_resolve(p_team); end if;
  return _bj_view(h);
end $$;

create or replace function bj_action(p_team int, p_pin text, p_action text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; h bj_hands; cur jsonb; c jsonb; b int; aces boolean; h1 jsonb; h2 jsonb;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into h from bj_hands where team_id = p_team for update;
  if not found then raise exception 'No hand in play. Deal first.'; end if;
  cur := h.hands -> h.active; c := cur -> 'c'; b := (cur ->> 'bet')::int;

  if p_action = 'hit' then
    if coalesce((cur ->> 'ace')::boolean, false) then raise exception 'Split aces get one card each.'; end if;
    update bj_hands set hands = jsonb_set(hands, array[active::text, 'c'], c || to_jsonb(_card())) where team_id = p_team;
    return _bj_advance(p_team);

  elsif p_action = 'stand' then
    update bj_hands set hands = jsonb_set(hands, array[active::text, 'done'], 'true') where team_id = p_team;
    return _bj_advance(p_team);

  elsif p_action = 'double' then
    if jsonb_array_length(c) <> 2 then raise exception 'You can only double on your first two cards.'; end if;
    if coalesce((cur ->> 'ace')::boolean, false) then raise exception 'You can''t double split aces.'; end if;
    perform _guard(t, b, false);
    perform _apply(p_team, -b, b);
    cur := jsonb_build_object('c', c || to_jsonb(_card()), 'bet', b * 2, 'dbl', true, 'done', true);
    update bj_hands set hands = jsonb_set(hands, array[active::text], cur) where team_id = p_team;
    return _bj_advance(p_team);

  elsif p_action = 'split' then
    if jsonb_array_length(c) <> 2 or _rank_val(c ->> 0) <> _rank_val(c ->> 1) then raise exception 'You can only split a pair.'; end if;
    if jsonb_array_length(h.hands) >= 4 then raise exception 'You can split up to 4 hands.'; end if;
    perform _guard(t, b, false);
    perform _apply(p_team, -b, b);
    aces := _rank(c ->> 0) = 'A';
    h1 := jsonb_build_object('c', jsonb_build_array(c -> 0, _card()), 'bet', b, 'dbl', false, 'done', aces, 'ace', aces);
    h2 := jsonb_build_object('c', jsonb_build_array(c -> 1, _card()), 'bet', b, 'dbl', false, 'done', aces, 'ace', aces);
    -- replace the active hand with h1 and insert h2 right after it
    update bj_hands set hands =
      coalesce((select jsonb_agg(e order by o) from jsonb_array_elements(hands) with ordinality as a(e, o) where o <= active), '[]'::jsonb)
      || jsonb_build_array(h1, h2)
      || coalesce((select jsonb_agg(e order by o) from jsonb_array_elements(hands) with ordinality as a(e, o) where o > active + 1), '[]'::jsonb)
    where team_id = p_team;
    return _bj_advance(p_team);
  end if;
  raise exception 'Unknown action.';
end $$;

-- ---------- commish ----------


create or replace function admin_set_config(p_pin text, p_open boolean, p_max int, p_daily int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set open = p_open, max_bet = greatest(p_max, 1), daily_limit = greatest(p_daily, 1) where id = 1;
  return json_build_object('ok', true);
end $$;

create or replace function admin_set_base(p_pin text, p_team int, p_base int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update teams set base = p_base where id = p_team;
  return json_build_object('ok', true);
end $$;



create or replace function admin_reset_pin(p_pin text, p_team int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update teams set pin_hash = null, fails = 0, locked_until = null where id = p_team;
  return json_build_object('ok', true);
end $$;

-- ---------- weekly loss rebate ----------
-- Each settle, the bank built up since the last settle (all players' net losses) is
-- split among the teams that finished down for the period, in proportion to their losses.
-- rebate_pct sets how much of that bank goes back (100 = all of it).
create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or (extract(isodow from now() at time zone 'America/New_York') = 2 and extract(hour from now() at time zone 'America/New_York') < 6) as blackout,
    rebate_pct
  from config;
grant select on v_config to anon, authenticated;

create or replace function _rebates() returns table(team_id int, week_net int, rebate int)
language sql stable security definer set search_path = public as $$
  with c as (select coalesce(last_settled, '-infinity'::timestamptz) as since, rebate_pct as pct from config where id = 1),
  wk as (
    select t.id as tid, coalesce((select sum(p.payout - p.bet) from plays p, c
             where p.team_id = t.id and p.created_at > c.since and p.game <> 'rebate'), 0)::int as wn
    from teams t),
  tot as (
    select floor(greatest(0, -sum(wn)) * (select pct from c) / 100.0) as pool,
           coalesce(sum(-wn) filter (where wn < 0), 0) as losses
    from wk)
  select wk.tid, wk.wn,
    case when wk.wn < 0 and tot.losses > 0 then floor(tot.pool * (-wk.wn)::numeric / tot.losses)::int else 0 end
  from wk, tot order by wk.tid
$$;

create or replace function admin_overview(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  return (select json_agg(json_build_object('id', t.id, 'name', t.name, 'base', t.base,
    'unsettled', t.net - t.settled, 'weekNet', r.week_net, 'rebate', r.rebate,
    'setTo', t.base + t.net - t.settled + r.rebate, 'claimed', t.pin_hash is not null) order by t.id)
    from teams t join _rebates() r on r.team_id = t.id);
end $$;

create or replace function admin_set_rebate(p_pin text, p_pct int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set rebate_pct = least(100, greatest(0, coalesce(p_pct, 100))) where id = 1;
  return json_build_object('ok', true);
end $$;

create or replace function admin_settle(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare r record; pct int; paid int := 0;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  if exists (select 1 from bj_hands) then raise exception 'A blackjack hand is still in play. Try again in a minute.'; end if;
  select rebate_pct into pct from config where id = 1;
  for r in select * from _rebates() where rebate > 0 loop
    update teams set net = net + r.rebate where id = r.team_id;
    insert into plays(team_id, game, bet, payout, detail)
      values (r.team_id, 'rebate', 0, r.rebate, 'Weekly loss rebate · ' || pct || '% of the bank, split by losses');
    paid := paid + r.rebate;
  end loop;
  update teams set base = base + net - settled, settled = net;
  update config set last_settled = now() where id = 1;
  return json_build_object('ok', true, 'rebated', paid);
end $$;

-- ---------- permissions: only the public functions are callable ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function claim_team(int,text), login(int,text),
  play_roulette(int,text,int,text,int), play_slots(int,text,int), play_dice(int,text,int,int), play_plinko(int,text,int),
  bj_state(int,text), bj_deal(int,text,int), bj_action(int,text,text),
  admin_overview(text), admin_set_config(text,boolean,int,int), admin_set_base(text,int,int),
  admin_settle(text), admin_reset_pin(text,int), admin_set_rebate(text,int)
  to anon, authenticated;

-- ---------- seed: teams with Sleeper FAAB as of Oct 16, 2026 ----------
insert into teams(id, name, owner, base) values
  (1,'Picken Diq','nickteguis',2452),(2,'Team Buttcheeks','williamh033',6300),
  (3,'Beckles’ Backshots!','pgakuba1',8200),(4,'Stribling out my Brock','domoney',7371),
  (5,'Death by Hamstrings','amiller1933',3000),(6,'Team ALEXI','shellist',9999),
  (7,'CF Inc.','TageColberg',1800),(8,'Team TRAUGGYDOGGY','TRAUGGYDOGGY',10500),
  (9,'Team conoro10','conoro10',8294),(10,'Ivy League','eyesk',9849),
  (11,'Dots Pretzels Death Squad','nboods',4694),(12,'Warm Milky Tets','Tedupnow',7552)
on conflict (id) do nothing;

-- ⬇ CHANGE THIS to your commish PIN before running
insert into config(id, admin_pin_hash) values (1, extensions.crypt('SET-YOUR-PIN', extensions.gen_salt('bf')))
on conflict (id) do nothing;

-- tell the API about the new tables and functions
notify pgrst, 'reload schema';
