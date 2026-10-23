-- Washed Delts Casino: database setup
-- Paste this whole file into Supabase > SQL Editor and press Run.
-- BEFORE running: change 'SET-YOUR-PIN' near the bottom to your commish PIN.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;


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
  where p.created_at > now() - interval '24 hours'
  order by p.created_at desc limit 1000;
create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or extract(isodow from now() at time zone 'America/New_York') = 2
    or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) as blackout
  from config;
grant select on v_teams, v_feed, v_config to anon, authenticated;

-- ---------- internal helpers ----------
create or replace function _rnd(n int) returns int language sql volatile as $$
  select (('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint % n)::int $$;

create or replace function _blackout() returns boolean language sql stable as $$
  select (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
      or extract(isodow from now() at time zone 'America/New_York') = 2
      or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) $$;

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
  if _blackout() then raise exception 'Betting is closed from 8 PM Monday until waivers clear at 3 AM Wednesday (Eastern).'; end if;
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

-- ---------- craps (street rules: shooter or fader, even money, no odds) ----------
-- shooter = pass line: 7/11 on the come out wins, 2/3/12 loses, otherwise hit the point before a 7.
-- fader = against the shooter: 2/3 on the come out wins, 7/11 loses, 12 is a push; 7 before the point wins.
create or replace function play_craps(p_team int, p_pin text, p_bet int, p_side text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; rolls jsonb := '[]'; d1 int; d2 int; s int; pt int := null; res text; pay int; note text; i int := 0;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  if p_side not in ('shooter', 'fader') then raise exception 'Pick shooter or fader.'; end if;
  perform _guard(t, p_bet);
  loop
    i := i + 1;
    d1 := _rnd(6) + 1; d2 := _rnd(6) + 1; s := d1 + d2;
    rolls := rolls || jsonb_build_array(jsonb_build_array(d1, d2));
    if pt is null then
      if s in (7, 11) then res := 'natural'; exit;
      elsif s in (2, 3, 12) then res := 'craps'; exit;
      else pt := s; end if;
    else
      if s = pt then res := 'hit'; exit;
      elsif s = 7 then res := 'sevenout'; exit; end if;
    end if;
    if i >= 300 then raise exception 'Something went wrong with the dice.'; end if;
  end loop;
  s := (rolls -> -1 -> 0)::int + (rolls -> -1 -> 1)::int;
  if p_side = 'shooter' then
    pay := case when res in ('natural', 'hit') then p_bet * 2 else 0 end;
  else
    pay := case when res = 'craps' and s = 12 then p_bet
                when res in ('craps', 'sevenout') then p_bet * 2 else 0 end;
  end if;
  note := initcap(p_side) || ' · ' || case res
    when 'natural' then 'come out ' || s
    when 'craps' then 'craps ' || s
    when 'hit' then 'hit the ' || pt || ' in ' || jsonb_array_length(rolls) || ' rolls'
    else 'seven out on the ' || pt || ' after ' || jsonb_array_length(rolls) || ' rolls' end;
  perform _apply(p_team, pay - p_bet, p_bet);
  perform _log(p_team, 'craps', p_bet, pay, note);
  return json_build_object('rolls', rolls, 'point', pt, 'result', res, 'payout', pay, 'note', note, 'balance', _bal(p_team));
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

-- marks the active hand done if it is finished, moves to the next open hand, resolves when none are left
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
    or extract(isodow from now() at time zone 'America/New_York') = 2
    or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) as blackout,
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



create or replace function admin_set_rebate(p_pin text, p_pct int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set rebate_pct = least(100, greatest(0, coalesce(p_pct, 100))) where id = 1;
  return json_build_object('ok', true);
end $$;



-- ---------- rebates pay out after waivers ----------
-- Monday: Mark settled syncs casino results and records each loser's rebate as owed.
-- Wednesday after 3 AM ET: Pay rebates credits them, so nobody can use a rebate in that week's waivers.
create table if not exists pending_rebates (
  team_id int not null references teams(id),
  amount int not null,
  created_at timestamptz not null default now()
);
alter table pending_rebates enable row level security;
revoke all on pending_rebates from anon, authenticated;

create or replace function admin_overview(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  return (select json_agg(json_build_object('id', t.id, 'name', t.name, 'base', t.base,
    'unsettled', t.net - t.settled, 'weekNet', r.week_net, 'estRebate', r.rebate,
    'owed', coalesce(o.amt, 0), 'setTo', t.base + t.net - t.settled,
    'withRebate', t.base + coalesce(o.amt, 0), 'claimed', t.pin_hash is not null) order by t.id)
    from teams t join _rebates() r on r.team_id = t.id
    left join (select team_id, sum(amount)::int amt from pending_rebates group by team_id) o on o.team_id = t.id);
end $$;

create or replace function admin_settle(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare owed int := 0;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  if exists (select 1 from bj_hands) then raise exception 'A blackjack hand is still in play. Try again in a minute.'; end if;
  insert into pending_rebates(team_id, amount) select team_id, rebate from _rebates() where rebate > 0;
  select coalesce(sum(rebate), 0) into owed from _rebates();
  update teams set base = base + net - settled, settled = net where id is not null;
  update config set last_settled = now() where id = 1;
  return json_build_object('ok', true, 'owed', owed);
end $$;

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

-- ---------- sportsbook (real NFL games vs the house, DraftKings lines from ESPN) ----------
create table if not exists sb_games (
  id text primary key,                 -- ESPN event id
  week int, kickoff timestamptz not null,
  home text not null, away text not null, home_name text, away_name text,
  state text not null default 'pre',   -- pre | in | post
  final boolean not null default false,
  home_score int, away_score int,
  ml_home int, ml_away int,
  spread_home numeric, spread_home_price int, spread_away numeric, spread_away_price int,
  total numeric, over_price int, under_price int,
  lines_at timestamptz, updated_at timestamptz not null default now()
);
create table if not exists sb_bets (
  id bigserial primary key,
  team_id int not null references teams(id),
  game_id text not null references sb_games(id),
  market text not null check (market in ('ml','spread','total')),
  pick text not null check (pick in ('home','away','over','under')),
  line numeric, price int not null, stake int not null,
  status text not null default 'open' check (status in ('open','won','lost','push')),
  payout int, created_at timestamptz not null default now(), graded_at timestamptz
);
create index if not exists sb_bets_open on sb_bets(game_id) where status = 'open';
create table if not exists sb_requests (id bigint primary key, url text, created_at timestamptz not null default now(), done boolean not null default false);
create table if not exists sb_status (id int primary key default 1 check (id = 1), last_ok timestamptz, last_error text);
insert into sb_status(id) values (1) on conflict (id) do nothing;
alter table sb_games enable row level security;
alter table sb_bets enable row level security;
alter table sb_requests enable row level security;
alter table sb_status enable row level security;
revoke all on sb_games, sb_bets, sb_requests, sb_status from anon, authenticated;

-- "+275" -> 275, "-110" -> -110, "EVEN" -> 100
create or replace function _sb_odds(x text) returns int language sql immutable as $$
  select case when x is null or btrim(x) = '' then null
              when upper(btrim(x)) in ('EVEN','EV') then 100
              when btrim(x) ~ '^[+-]?[0-9]+$' then replace(btrim(x), '+', '')::int
              else null end $$;
-- "-7" -> -7, "+3.5" -> 3.5, "o45.5" -> 45.5, "PK" -> 0
create or replace function _sb_line(x text) returns numeric language sql immutable as $$
  select case when x is null or btrim(x) = '' then null
              when upper(btrim(x)) in ('PK','PICK','EVEN') then 0
              when regexp_replace(btrim(x), '^[oOuU]', '') ~ '^[+-]?[0-9]+(\.[0-9]+)?$'
                then replace(regexp_replace(btrim(x), '^[oOuU]', ''), '+', '')::numeric
              else null end $$;
-- total returned on a winning bet (stake included)
create or replace function _sb_return(p_stake int, p_price int) returns int language sql immutable as $$
  select p_stake + floor(case when p_price > 0 then p_stake * p_price / 100.0 else p_stake * 100.0 / abs(p_price) end)::int $$;

-- one ESPN scoreboard payload in, games upserted, finished games graded
create or replace function sb_ingest(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare e jsonb; c jsonb; o jsonb; h jsonb; a jsonb; n int := 0; st text; fin boolean;
begin
  for e in select * from jsonb_array_elements(coalesce(p -> 'events', '[]')) loop
    c := e -> 'competitions' -> 0;
    select x into h from jsonb_array_elements(c -> 'competitors') x where x ->> 'homeAway' = 'home';
    select x into a from jsonb_array_elements(c -> 'competitors') x where x ->> 'homeAway' = 'away';
    if h is null or a is null then continue; end if;
    st := coalesce(e -> 'status' -> 'type' ->> 'state', c -> 'status' -> 'type' ->> 'state', 'pre');
    fin := coalesce((e -> 'status' -> 'type' ->> 'completed')::boolean, false) and st = 'post';
    o := c -> 'odds' -> 0;
    insert into sb_games(id, week, kickoff, home, away, home_name, away_name, state, final, home_score, away_score, updated_at)
    values (e ->> 'id', (e -> 'week' ->> 'number')::int, (e ->> 'date')::timestamptz,
            h -> 'team' ->> 'abbreviation', a -> 'team' ->> 'abbreviation',
            h -> 'team' ->> 'displayName', a -> 'team' ->> 'displayName', st, fin,
            nullif(h ->> 'score', '')::int, nullif(a ->> 'score', '')::int, now())
    on conflict (id) do update set week = excluded.week, kickoff = excluded.kickoff, state = excluded.state,
      final = excluded.final, home_score = excluded.home_score, away_score = excluded.away_score, updated_at = now()
    where not sb_games.final;   -- a graded game never changes again
    -- refresh lines only before kickoff
    if o is not null and st = 'pre' and not fin and not exists (select 1 from sb_games where id = e ->> 'id' and final) then
      update sb_games set
        ml_home = _sb_odds(coalesce(o #>> '{moneyline,home,close,odds}', o #>> '{moneyline,home,open,odds}')),
        ml_away = _sb_odds(coalesce(o #>> '{moneyline,away,close,odds}', o #>> '{moneyline,away,open,odds}')),
        spread_home = _sb_line(coalesce(o #>> '{pointSpread,home,close,line}', o #>> '{pointSpread,home,open,line}')),
        spread_home_price = _sb_odds(coalesce(o #>> '{pointSpread,home,close,odds}', o #>> '{pointSpread,home,open,odds}')),
        spread_away = _sb_line(coalesce(o #>> '{pointSpread,away,close,line}', o #>> '{pointSpread,away,open,line}')),
        spread_away_price = _sb_odds(coalesce(o #>> '{pointSpread,away,close,odds}', o #>> '{pointSpread,away,open,odds}')),
        total = coalesce(_sb_line(o #>> '{total,over,close,line}'), _sb_line(o #>> '{total,over,open,line}'), (o ->> 'overUnder')::numeric),
        over_price = _sb_odds(coalesce(o #>> '{total,over,close,odds}', o #>> '{total,over,open,odds}')),
        under_price = _sb_odds(coalesce(o #>> '{total,under,close,odds}', o #>> '{total,under,open,odds}')),
        lines_at = now()
      where id = e ->> 'id';
    end if;
    n := n + 1;
  end loop;
  perform _sb_grade();
  return n;
end $$;

create or replace function _sb_grade() returns int
language plpgsql security definer set search_path = public as $$
declare b record; g sb_games; m numeric; res text; pay int; n int := 0; label text;
begin
  for b in select * from sb_bets where status = 'open' and game_id in (select id from sb_games where final) for update loop
    select * into g from sb_games where id = b.game_id;
    if b.market = 'ml' then
      m := case when b.pick = 'home' then g.home_score - g.away_score else g.away_score - g.home_score end;
    elsif b.market = 'spread' then
      m := case when b.pick = 'home' then g.home_score + b.line - g.away_score else g.away_score + b.line - g.home_score end;
    else
      m := case when b.pick = 'over' then (g.home_score + g.away_score) - b.line else b.line - (g.home_score + g.away_score) end;
    end if;
    res := case when m > 0 then 'won' when m = 0 then 'push' else 'lost' end;
    pay := case res when 'won' then _sb_return(b.stake, b.price) when 'push' then b.stake else 0 end;
    update sb_bets set status = res, payout = pay, graded_at = now() where id = b.id;
    label := case b.market
      when 'ml' then (case when b.pick = 'home' then g.home else g.away end) || ' ML'
      when 'spread' then (case when b.pick = 'home' then g.home else g.away end) || ' ' || (case when b.line > 0 then '+' else '' end) || trim_scale(b.line)
      else initcap(b.pick) || ' ' || trim_scale(b.line) end;
    perform _apply(b.team_id, pay, 0);
    perform _log(b.team_id, 'sportsbook', b.stake, pay,
      label || ' (' || (case when b.price > 0 then '+' else '' end) || b.price || ') · ' || g.away || ' ' || g.away_score || ', ' || g.home || ' ' || g.home_score);
    n := n + 1;
  end loop;
  return n;
end $$;

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

-- public board: upcoming games with fresh lines
create or replace view v_sb_games as
  select id, week, kickoff, home, away, home_name, away_name, state, final, home_score, away_score,
    ml_home, ml_away, spread_home, spread_home_price, spread_away, spread_away_price, total, over_price, under_price, lines_at,
    (state = 'pre' and kickoff > now() and lines_at > now() - interval '45 minutes') as open
  from sb_games
  where kickoff > now() - interval '4 days' and kickoff < now() + interval '10 days'
  order by kickoff, id;
create or replace view v_sb_status as select last_ok, last_error from sb_status;
grant select on v_sb_games, v_sb_status to anon, authenticated;

create or replace function sb_place(p_team int, p_pin text, p_game text, p_market text, p_pick text, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; g sb_games; ln numeric; pr int; bid bigint;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into g from sb_games where id = p_game for update;
  if not found then raise exception 'That game isn''t on the board.'; end if;
  if g.state <> 'pre' or g.kickoff <= now() then raise exception 'Betting on that game is closed. It already kicked off.'; end if;
  if g.lines_at is null or g.lines_at < now() - interval '45 minutes' then raise exception 'Lines are refreshing. Try again in a few minutes.'; end if;
  if p_market = 'ml' and p_pick in ('home','away') then
    ln := null; pr := case when p_pick = 'home' then g.ml_home else g.ml_away end;
  elsif p_market = 'spread' and p_pick in ('home','away') then
    ln := case when p_pick = 'home' then g.spread_home else g.spread_away end;
    pr := case when p_pick = 'home' then g.spread_home_price else g.spread_away_price end;
  elsif p_market = 'total' and p_pick in ('over','under') then
    ln := g.total; pr := case when p_pick = 'over' then g.over_price else g.under_price end;
  else raise exception 'Unknown bet.'; end if;
  if pr is null or pr between -99 and 99 or (p_market <> 'ml' and ln is null) then raise exception 'No line on that bet right now.'; end if;
  perform _guard(t, p_bet, false);   -- no max bet on the sportsbook
  perform _apply(p_team, -p_bet, p_bet);
  insert into sb_bets(team_id, game_id, market, pick, line, price, stake) values (p_team, p_game, p_market, p_pick, ln, pr, p_bet) returning id into bid;
  return json_build_object('ok', true, 'id', bid, 'line', ln, 'price', pr, 'toWin', _sb_return(p_bet, pr) - p_bet, 'balance', _bal(p_team));
end $$;

create or replace function sb_my_bets(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return coalesce((select json_agg(json_build_object('id', b.id, 'game', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
      'market', b.market, 'pick', b.pick, 'team', case when b.pick = 'home' then g.home when b.pick = 'away' then g.away end,
      'line', b.line, 'price', b.price, 'stake', b.stake, 'toWin', _sb_return(b.stake, b.price) - b.stake,
      'status', b.status, 'payout', b.payout) order by b.created_at desc)
    from (select * from sb_bets where team_id = p_team and (status = 'open' or graded_at > now() - interval '7 days') order by created_at desc limit 40) b
    join sb_games g on g.id = b.game_id), '[]'::json);
end $$;

-- ---------- sportsbook parlays + league bet ticker ----------
alter table config add column if not exists parlay_max_payout int not null default 20000;

create table if not exists sb_parlays (
  id bigserial primary key,
  team_id int not null references teams(id),
  stake int not null,
  status text not null default 'open' check (status in ('open','won','lost','push')),
  payout int, created_at timestamptz not null default now(), graded_at timestamptz
);
create table if not exists sb_parlay_legs (
  parlay_id bigint not null references sb_parlays(id),
  game_id text not null references sb_games(id),
  market text not null, pick text not null, line numeric, price int not null,
  result text check (result in ('won','lost','push')),
  primary key (parlay_id, game_id)
);
alter table sb_parlays enable row level security;
alter table sb_parlay_legs enable row level security;
revoke all on sb_parlays, sb_parlay_legs from anon, authenticated;

-- American odds to decimal (+150 -> 2.5, -110 -> 1.909)
create or replace function _sb_dec(p int) returns numeric language sql immutable as $$
  select case when p > 0 then 1 + p / 100.0 else 1 + 100.0 / abs(p) end $$;

-- win (>0), push (=0) or loss (<0) margin for a bet on a finished game
create or replace function _sb_margin(g sb_games, p_market text, p_pick text, p_line numeric) returns numeric language sql immutable as $$
  select case p_market
    when 'ml' then case when p_pick = 'home' then g.home_score - g.away_score else g.away_score - g.home_score end
    when 'spread' then case when p_pick = 'home' then g.home_score + p_line - g.away_score else g.away_score + p_line - g.home_score end
    else case when p_pick = 'over' then (g.home_score + g.away_score) - p_line else p_line - (g.home_score + g.away_score) end end $$;

create or replace function _sb_label(g sb_games, p_market text, p_pick text, p_line numeric) returns text language sql immutable as $$
  select case p_market
    when 'ml' then (case when p_pick = 'home' then g.home else g.away end) || ' ML'
    when 'spread' then (case when p_pick = 'home' then g.home else g.away end) || ' ' || (case when p_line > 0 then '+' else '' end) || trim_scale(p_line)
    else initcap(p_pick) || ' ' || trim_scale(p_line) end $$;

-- current line/price for a pick, or an error if it can't be bet right now
create or replace function _sb_quote(p_game text, p_market text, p_pick text, out g sb_games, out ln numeric, out pr int)
language plpgsql stable security definer set search_path = public as $$
begin
  select * into g from sb_games where id = p_game;
  if not found then raise exception 'That game isn''t on the board.'; end if;
  if g.state <> 'pre' or g.kickoff <= now() then raise exception '% @ % already kicked off.', g.away, g.home; end if;
  if g.lines_at is null or g.lines_at < now() - interval '45 minutes' then raise exception 'Lines are refreshing. Try again in a few minutes.'; end if;
  if p_market = 'ml' and p_pick in ('home','away') then
    ln := null; pr := case when p_pick = 'home' then g.ml_home else g.ml_away end;
  elsif p_market = 'spread' and p_pick in ('home','away') then
    ln := case when p_pick = 'home' then g.spread_home else g.spread_away end;
    pr := case when p_pick = 'home' then g.spread_home_price else g.spread_away_price end;
  elsif p_market = 'total' and p_pick in ('over','under') then
    ln := g.total; pr := case when p_pick = 'over' then g.over_price else g.under_price end;
  else raise exception 'Unknown bet.'; end if;
  if pr is null or pr between -99 and 99 or (p_market <> 'ml' and ln is null) then raise exception 'No line on that bet right now.'; end if;
end $$;

-- p_legs: [{"game":"401873023","market":"spread","pick":"home"}, ...]
create or replace function sb_place_parlay(p_team int, p_pin text, p_legs jsonb, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; l jsonb; q record; dec numeric := 1; pid bigint; n int; cap int; mult numeric;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  n := jsonb_array_length(coalesce(p_legs, '[]'));
  if n < 2 then raise exception 'A parlay needs at least 2 picks.'; end if;
  if n > 6 then raise exception 'Parlays max out at 6 picks.'; end if;
  if (select count(distinct x ->> 'game') from jsonb_array_elements(p_legs) x) <> n then
    raise exception 'One pick per game in a parlay.'; end if;
  perform _guard(t, p_bet, false);
  select parlay_max_payout into cap from config where id = 1;
  for l in select * from jsonb_array_elements(p_legs) loop
    select * into q from _sb_quote(l ->> 'game', l ->> 'market', l ->> 'pick');
    dec := dec * _sb_dec(q.pr);
  end loop;
  if floor(p_bet * dec) > cap then
    raise exception 'Parlay payouts max out at $%. Lower your bet to $% or less.', cap, floor(cap / dec);
  end if;
  perform _apply(p_team, -p_bet, p_bet);
  insert into sb_parlays(team_id, stake) values (p_team, p_bet) returning id into pid;
  for l in select * from jsonb_array_elements(p_legs) loop
    select * into q from _sb_quote(l ->> 'game', l ->> 'market', l ->> 'pick');
    insert into sb_parlay_legs(parlay_id, game_id, market, pick, line, price) values (pid, l ->> 'game', l ->> 'market', l ->> 'pick', q.ln, q.pr);
  end loop;
  mult := round(dec, 2);
  return json_build_object('ok', true, 'id', pid, 'multiplier', mult, 'toWin', floor(p_bet * dec)::int - p_bet, 'balance', _bal(p_team));
end $$;

-- grade parlay legs on finished games, then settle any parlay that's decided
create or replace function _sb_grade_parlays() returns int
language plpgsql security definer set search_path = public as $$
declare lg record; p record; g sb_games; m numeric; dec numeric; pay int; res text; n int := 0; legs text; cap int;
begin
  for lg in select l.* from sb_parlay_legs l join sb_parlays pp on pp.id = l.parlay_id
            where l.result is null and pp.status = 'open' and l.game_id in (select id from sb_games where final) loop
    select * into g from sb_games where id = lg.game_id;
    m := _sb_margin(g, lg.market, lg.pick, lg.line);
    update sb_parlay_legs set result = case when m > 0 then 'won' when m = 0 then 'push' else 'lost' end
      where parlay_id = lg.parlay_id and game_id = lg.game_id;
  end loop;
  select parlay_max_payout into cap from config where id = 1;
  for p in select * from sb_parlays where status = 'open' for update loop
    if exists (select 1 from sb_parlay_legs where parlay_id = p.id and result = 'lost') then
      res := 'lost'; pay := 0;
    elsif not exists (select 1 from sb_parlay_legs where parlay_id = p.id and result is null) then
      select coalesce(exp(sum(ln(_sb_dec(price)))), 1) into dec from sb_parlay_legs where parlay_id = p.id and result = 'won';
      if dec = 1 then res := 'push'; pay := p.stake; else res := 'won'; pay := least(floor(p.stake * dec)::int, greatest(cap, p.stake)); end if;
    else continue; end if;
    update sb_parlays set status = res, payout = pay, graded_at = now() where id = p.id;
    select string_agg(_sb_label(g2, l.market, l.pick, l.line) || coalesce(case l.result when 'won' then ' ✓' when 'lost' then ' ✗' when 'push' then ' push' end, ''), ', ' order by g2.kickoff)
      into legs from sb_parlay_legs l join sb_games g2 on g2.id = l.game_id where l.parlay_id = p.id;
    perform _apply(p.team_id, pay, 0);
    perform _log(p.team_id, 'parlay', p.stake, pay, (select count(*) from sb_parlay_legs where parlay_id = p.id) || '-leg parlay · ' || legs);
    n := n + 1;
  end loop;
  return n;
end $$;

-- straight-bet grading now also settles parlays
create or replace function _sb_grade() returns int
language plpgsql security definer set search_path = public as $$
declare b record; g sb_games; m numeric; res text; pay int; n int := 0;
begin
  for b in select * from sb_bets where status = 'open' and game_id in (select id from sb_games where final) for update loop
    select * into g from sb_games where id = b.game_id;
    m := _sb_margin(g, b.market, b.pick, b.line);
    res := case when m > 0 then 'won' when m = 0 then 'push' else 'lost' end;
    pay := case res when 'won' then _sb_return(b.stake, b.price) when 'push' then b.stake else 0 end;
    update sb_bets set status = res, payout = pay, graded_at = now() where id = b.id;
    perform _apply(b.team_id, pay, 0);
    perform _log(b.team_id, 'sportsbook', b.stake, pay,
      _sb_label(g, b.market, b.pick, b.line) || ' (' || (case when b.price > 0 then '+' else '' end) || b.price || ') · ' || g.away || ' ' || g.away_score || ', ' || g.home || ' ' || g.home_score);
    n := n + 1;
  end loop;
  return n + _sb_grade_parlays();
end $$;

-- straight bets reuse the shared quote check
create or replace function sb_place(p_team int, p_pin text, p_game text, p_market text, p_pick text, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; q record; bid bigint;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into q from _sb_quote(p_game, p_market, p_pick);
  perform _guard(t, p_bet, false);   -- no max bet on the sportsbook
  perform _apply(p_team, -p_bet, p_bet);
  insert into sb_bets(team_id, game_id, market, pick, line, price, stake) values (p_team, p_game, p_market, p_pick, q.ln, q.pr, p_bet) returning id into bid;
  return json_build_object('ok', true, 'id', bid, 'line', q.ln, 'price', q.pr, 'toWin', _sb_return(p_bet, q.pr) - p_bet, 'balance', _bal(p_team));
end $$;

create or replace function sb_my_bets(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return coalesce((select json_agg(x order by (x ->> 'created_at') desc) from (
    select json_build_object('kind', 'straight', 'id', b.id, 'created_at', b.created_at, 'game', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
      'label', _sb_label(g, b.market, b.pick, b.line), 'price', b.price, 'stake', b.stake, 'toWin', _sb_return(b.stake, b.price) - b.stake,
      'status', b.status, 'payout', b.payout)::jsonb x
    from sb_bets b join sb_games g on g.id = b.game_id
    where b.team_id = p_team and (b.status = 'open' or b.graded_at > now() - interval '7 days')
    union all
    select json_build_object('kind', 'parlay', 'id', p.id, 'created_at', p.created_at, 'stake', p.stake, 'status', p.status, 'payout', p.payout,
      'toWin', least(floor(p.stake * (select exp(sum(ln(_sb_dec(price)))) from sb_parlay_legs where parlay_id = p.id))::int,
                     greatest((select parlay_max_payout from config where id = 1), p.stake)) - p.stake,
      'legs', (select json_agg(json_build_object('label', _sb_label(g, l.market, l.pick, l.line), 'price', l.price, 'game', g.away || ' @ ' || g.home,
                 'kickoff', g.kickoff, 'result', l.result) order by g.kickoff) from sb_parlay_legs l join sb_games g on g.id = l.game_id where l.parlay_id = p.id))::jsonb
    from sb_parlays p where p.team_id = p_team and (p.status = 'open' or p.graded_at > now() - interval '7 days')
  ) s(x)), '[]'::json);
end $$;

-- everyone's open action, for tailing and fading
create or replace view v_sb_ticker as
  select 'straight' as kind, b.id, b.created_at, t.name as team_name, b.stake,
    _sb_return(b.stake, b.price) - b.stake as to_win,
    jsonb_build_array(jsonb_build_object('game', b.game_id, 'market', b.market, 'pick', b.pick, 'price', b.price,
      'label', _sb_label(g, b.market, b.pick, b.line), 'matchup', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
      'started', g.state <> 'pre' or g.kickoff <= now())) as legs
  from sb_bets b join sb_games g on g.id = b.game_id join teams t on t.id = b.team_id
  where b.status = 'open'
  union all
  select 'parlay', p.id, p.created_at, t.name, p.stake,
    least(floor(p.stake * (select exp(sum(ln(_sb_dec(price)))) from sb_parlay_legs where parlay_id = p.id))::int,
          greatest((select parlay_max_payout from config where id = 1), p.stake)) - p.stake,
    (select jsonb_agg(jsonb_build_object('game', l.game_id, 'market', l.market, 'pick', l.pick, 'price', l.price,
       'label', _sb_label(g, l.market, l.pick, l.line), 'matchup', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
       'started', g.state <> 'pre' or g.kickoff <= now(), 'result', l.result) order by g.kickoff)
     from sb_parlay_legs l join sb_games g on g.id = l.game_id where l.parlay_id = p.id)
  from sb_parlays p join teams t on t.id = p.team_id
  where p.status = 'open';
grant select on v_sb_ticker to anon, authenticated;

create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or extract(isodow from now() at time zone 'America/New_York') = 2
    or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) as blackout,
    rebate_pct, parlay_max_payout
  from config;
grant select on v_config to anon, authenticated;

create or replace function admin_set_parlay_cap(p_pin text, p_cap int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set parlay_max_payout = greatest(100, coalesce(p_cap, 20000)) where id = 1;
  return json_build_object('ok', true);
end $$;

-- the ticker view calls these display helpers, so viewers need to be able to run them
grant execute on function _sb_label(sb_games,text,text,numeric), _sb_return(int,int), _sb_dec(int) to anon, authenticated;

-- ---------- same-game parlays: one side (spread or moneyline) + the total ----------
alter table config add column if not exists sgp_pct int not null default 90;
alter table sb_parlays add column if not exists sgp_pct int not null default 100;
alter table sb_parlay_legs drop constraint if exists sb_parlay_legs_pkey;
alter table sb_parlay_legs add primary key (parlay_id, game_id, market);

-- parlay multiplier: each game's picks multiply together; a game with two picks
-- pays p_pct% of that pair's winnings. p_won_only = true counts only legs that won (for grading).
create or replace function _parlay_dec(p_parlay bigint, p_won_only boolean) returns numeric
language sql stable security definer set search_path = public as $$
  with legs as (
    select l.game_id, _sb_dec(l.price) d from sb_parlay_legs l
    where l.parlay_id = p_parlay and (not p_won_only or l.result = 'won')),
  per_game as (
    select game_id, count(*) n, exp(sum(ln(d))) d from legs group by game_id),
  pct as (select sgp_pct from sb_parlays where id = p_parlay)
  select coalesce(exp(sum(ln(case when n > 1 then 1 + (d - 1) * (select sgp_pct from pct) / 100.0 else d end))), 1)
  from per_game $$;

create or replace function sb_place_parlay(p_team int, p_pin text, p_legs jsonb, p_bet int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; l jsonb; q record; dec numeric; pid bigint; n int; cap int; pct int; bad text;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  n := jsonb_array_length(coalesce(p_legs, '[]'));
  if n < 2 then raise exception 'A parlay needs at least 2 picks.'; end if;
  if n > 6 then raise exception 'Parlays max out at 6 picks.'; end if;
  -- per game: at most one side pick (spread or moneyline) plus at most one total
  select string_agg(gid, ',') into bad from (
    select x ->> 'game' gid from jsonb_array_elements(p_legs) x
    group by x ->> 'game'
    having count(*) filter (where x ->> 'market' in ('spread','ml')) > 1
        or count(*) filter (where x ->> 'market' = 'total') > 1) z;
  if bad is not null then
    raise exception 'From one game you can combine a spread or moneyline with the total, but not the spread and moneyline together.';
  end if;
  perform _guard(t, p_bet, false);
  select parlay_max_payout, sgp_pct into cap, pct from config where id = 1;
  for l in select * from jsonb_array_elements(p_legs) loop
    select * into q from _sb_quote(l ->> 'game', l ->> 'market', l ->> 'pick');
  end loop;
  perform _apply(p_team, -p_bet, p_bet);
  insert into sb_parlays(team_id, stake, sgp_pct) values (p_team, p_bet, pct) returning id into pid;
  for l in select * from jsonb_array_elements(p_legs) loop
    select * into q from _sb_quote(l ->> 'game', l ->> 'market', l ->> 'pick');
    insert into sb_parlay_legs(parlay_id, game_id, market, pick, line, price) values (pid, l ->> 'game', l ->> 'market', l ->> 'pick', q.ln, q.pr);
  end loop;
  dec := _parlay_dec(pid, false);
  if floor(p_bet * dec) > cap then
    raise exception 'Parlay payouts max out at $%. Lower your bet to $% or less.', cap, floor(cap / dec);
  end if;
  return json_build_object('ok', true, 'id', pid, 'multiplier', round(dec, 2), 'toWin', floor(p_bet * dec)::int - p_bet, 'balance', _bal(p_team));
end $$;

create or replace function _sb_grade_parlays() returns int
language plpgsql security definer set search_path = public as $$
declare lg record; p record; g sb_games; m numeric; dec numeric; pay int; res text; n int := 0; legs text; cap int;
begin
  for lg in select l.* from sb_parlay_legs l join sb_parlays pp on pp.id = l.parlay_id
            where l.result is null and pp.status = 'open' and l.game_id in (select id from sb_games where final) loop
    select * into g from sb_games where id = lg.game_id;
    m := _sb_margin(g, lg.market, lg.pick, lg.line);
    update sb_parlay_legs set result = case when m > 0 then 'won' when m = 0 then 'push' else 'lost' end
      where parlay_id = lg.parlay_id and game_id = lg.game_id and market = lg.market;
  end loop;
  select parlay_max_payout into cap from config where id = 1;
  for p in select * from sb_parlays where status = 'open' for update loop
    if exists (select 1 from sb_parlay_legs where parlay_id = p.id and result = 'lost') then
      res := 'lost'; pay := 0;
    elsif not exists (select 1 from sb_parlay_legs where parlay_id = p.id and result is null) then
      dec := _parlay_dec(p.id, true);
      if dec = 1 then res := 'push'; pay := p.stake; else res := 'won'; pay := least(floor(p.stake * dec)::int, greatest(cap, p.stake)); end if;
    else continue; end if;
    update sb_parlays set status = res, payout = pay, graded_at = now() where id = p.id;
    select string_agg(_sb_label(g2, l.market, l.pick, l.line) || coalesce(case l.result when 'won' then ' ✓' when 'lost' then ' ✗' when 'push' then ' push' end, ''), ', ' order by g2.kickoff, l.market)
      into legs from sb_parlay_legs l join sb_games g2 on g2.id = l.game_id where l.parlay_id = p.id;
    perform _apply(p.team_id, pay, 0);
    perform _log(p.team_id, 'parlay', p.stake, pay, (select count(*) from sb_parlay_legs where parlay_id = p.id) || '-leg parlay · ' || legs);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function sb_my_bets(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return coalesce((select json_agg(x order by (x ->> 'created_at') desc) from (
    select json_build_object('kind', 'straight', 'id', b.id, 'created_at', b.created_at, 'game', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
      'label', _sb_label(g, b.market, b.pick, b.line), 'price', b.price, 'stake', b.stake, 'toWin', _sb_return(b.stake, b.price) - b.stake,
      'status', b.status, 'payout', b.payout)::jsonb x
    from sb_bets b join sb_games g on g.id = b.game_id
    where b.team_id = p_team and (b.status = 'open' or b.graded_at > now() - interval '7 days')
    union all
    select json_build_object('kind', 'parlay', 'id', p.id, 'created_at', p.created_at, 'stake', p.stake, 'status', p.status, 'payout', p.payout,
      'toWin', least(floor(p.stake * _parlay_dec(p.id, false))::int, greatest((select parlay_max_payout from config where id = 1), p.stake)) - p.stake,
      'legs', (select json_agg(json_build_object('label', _sb_label(g, l.market, l.pick, l.line), 'price', l.price, 'game', g.away || ' @ ' || g.home,
                 'kickoff', g.kickoff, 'result', l.result) order by g.kickoff, l.market) from sb_parlay_legs l join sb_games g on g.id = l.game_id where l.parlay_id = p.id))::jsonb
    from sb_parlays p where p.team_id = p_team and (p.status = 'open' or p.graded_at > now() - interval '7 days')
  ) s(x)), '[]'::json);
end $$;

create or replace view v_sb_ticker as
  select 'straight' as kind, b.id, b.created_at, t.name as team_name, b.stake,
    _sb_return(b.stake, b.price) - b.stake as to_win,
    jsonb_build_array(jsonb_build_object('game', b.game_id, 'market', b.market, 'pick', b.pick, 'price', b.price,
      'label', _sb_label(g, b.market, b.pick, b.line), 'matchup', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
      'started', g.state <> 'pre' or g.kickoff <= now())) as legs
  from sb_bets b join sb_games g on g.id = b.game_id join teams t on t.id = b.team_id
  where b.status = 'open'
  union all
  select 'parlay', p.id, p.created_at, t.name, p.stake,
    least(floor(p.stake * _parlay_dec(p.id, false))::int, greatest((select parlay_max_payout from config where id = 1), p.stake)) - p.stake,
    (select jsonb_agg(jsonb_build_object('game', l.game_id, 'market', l.market, 'pick', l.pick, 'price', l.price,
       'label', _sb_label(g, l.market, l.pick, l.line), 'matchup', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
       'started', g.state <> 'pre' or g.kickoff <= now(), 'result', l.result) order by g.kickoff, l.market)
     from sb_parlay_legs l join sb_games g on g.id = l.game_id where l.parlay_id = p.id)
  from sb_parlays p join teams t on t.id = p.team_id
  where p.status = 'open';
grant select on v_sb_ticker to anon, authenticated;

create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or extract(isodow from now() at time zone 'America/New_York') = 2
    or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) as blackout,
    rebate_pct, parlay_max_payout, sgp_pct
  from config;
grant select on v_config to anon, authenticated;

create or replace function admin_set_sgp(p_pin text, p_pct int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set sgp_pct = least(100, greatest(10, coalesce(p_pct, 90))) where id = 1;
  return json_build_object('ok', true);
end $$;

grant execute on function _parlay_dec(bigint, boolean) to anon, authenticated;

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

-- ---------- Rocket (crash): the multiplier climbs until the rocket blows up; cash out first ----------
-- Each round's crash point is drawn on the server when you launch and stays secret until the round ends.
-- P(crash >= m) = 0.99 / m, so the house keeps 1% at any cash-out target. Capped at 100x.
-- The multiplier grows as e^(0.06 * seconds): 2x at ~11.6s, 10x at ~38s, 100x at ~77s.
create table if not exists rk_rounds (
  team_id int primary key references teams(id),
  bet int not null, crash numeric not null, started_at timestamptz not null default clock_timestamp()
);
alter table rk_rounds enable row level security;
revoke all on rk_rounds from anon, authenticated;

create or replace function _rk_mult(p_secs numeric) returns numeric language sql immutable as $$
  select floor(exp(0.06 * greatest(p_secs, 0)) * 100) / 100 $$;
create or replace function _rk_crash_at(r rk_rounds) returns timestamptz language sql immutable as $$
  select r.started_at + make_interval(secs => ln(r.crash) / 0.06) $$;

-- end any round whose rocket has already blown up (a loss)
create or replace function _rk_sweep(p_team int default null) returns void
language plpgsql security definer set search_path = public as $$
declare r rk_rounds;
begin
  for r in select * from rk_rounds where (p_team is null or team_id = p_team) for update loop
    if clock_timestamp() >= _rk_crash_at(r) then
      perform _log(r.team_id, 'rocket', r.bet, 0, 'Blew up at ' || to_char(r.crash, 'FM990.00') || 'x');
      delete from rk_rounds where team_id = r.team_id;
    end if;
  end loop;
end $$;

-- p_auto: optional auto cash-out (1.01x to 100x). With it, the round resolves right away.
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

-- where the round stands right now; never reveals the crash point before it happens
create or replace function rk_status(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r rk_rounds; el numeric;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from rk_rounds where team_id = p_team;
  if not found then return json_build_object('state', 'idle', 'balance', _bal(p_team)); end if;
  el := extract(epoch from clock_timestamp() - r.started_at);
  if clock_timestamp() >= _rk_crash_at(r) then
    perform _rk_sweep(p_team);
    return json_build_object('state', 'crashed', 'crash', r.crash, 'bet', r.bet, 'payout', 0, 'balance', _bal(p_team));
  end if;
  return json_build_object('state', 'flying', 'bet', r.bet, 'elapsed', el, 'mult', _rk_mult(el), 'balance', _bal(p_team));
end $$;

create or replace function rk_cashout(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r rk_rounds; el numeric; m numeric; pay int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from rk_rounds where team_id = p_team for update;
  if not found then return json_build_object('state', 'idle', 'balance', _bal(p_team)); end if;
  el := extract(epoch from clock_timestamp() - r.started_at);
  if clock_timestamp() >= _rk_crash_at(r) then
    perform _rk_sweep(p_team);
    return json_build_object('state', 'crashed', 'crash', r.crash, 'bet', r.bet, 'payout', 0, 'balance', _bal(p_team));
  end if;
  m := least(_rk_mult(el), r.crash);
  pay := floor(r.bet * m)::int;
  delete from rk_rounds where team_id = p_team;
  perform _apply(p_team, pay, 0);
  perform _log(p_team, 'rocket', r.bet, pay, 'Cashed out at ' || to_char(m, 'FM990.00') || 'x');
  return json_build_object('state', 'cashed', 'mult', m, 'bet', r.bet, 'payout', pay, 'balance', _bal(p_team));
end $$;

create or replace function rk_history(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return coalesce((select json_agg(substring(detail from '([0-9]+\.[0-9]{2})x(?!.*[0-9]+\.[0-9]{2}x)') order by created_at desc)
    from (select * from plays where team_id = p_team and game = 'rocket' and detail ~ '(Blew up|went to)' order by created_at desc limit 12) x), '[]'::json);
end $$;

-- settling waits for rockets in the air, same as blackjack hands
create or replace function admin_settle(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare owed int := 0;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  if exists (select 1 from bj_hands) then raise exception 'A blackjack hand is still in play. Try again in a minute.'; end if;
  perform _rk_sweep();
  if exists (select 1 from rk_rounds) then raise exception 'A rocket is still in the air. Try again in a minute.'; end if;
  insert into pending_rebates(team_id, amount) select team_id, rebate from _rebates() where rebate > 0;
  select coalesce(sum(rebate), 0) into owed from _rebates();
  update teams set base = base + net - settled, settled = net where id is not null;
  update config set last_settled = now() where id = 1;
  return json_build_object('ok', true, 'owed', owed);
end $$;

-- ---------- Chicken: cross lane by lane, cash out before you get hit ----------
-- Every step is rolled on the server when you take it. After k safe steps the multiplier is
-- 0.97 / survive^k, so the house keeps 3% wherever you stop.
create table if not exists ck_rounds (
  team_id int primary key references teams(id),
  bet int not null, level text not null, step int not null default 0,
  created_at timestamptz not null default now()
);
alter table ck_rounds enable row level security;
revoke all on ck_rounds from anon, authenticated;

-- survive chance per lane and number of lanes by difficulty
create or replace function _ck_level(p text, out survive numeric, out lanes int) language sql immutable as $$
  select case p when 'easy' then 0.90 when 'medium' then 0.80 when 'hard' then 0.70 when 'hardcore' then 0.55 end,
         case p when 'easy' then 15 when 'medium' then 12 when 'hard' then 10 when 'hardcore' then 8 end $$;
create or replace function _ck_mult(p_level text, p_step int) returns numeric language sql immutable as $$
  select case when p_step <= 0 then 1 else least(100, floor(0.98 / power((select survive from _ck_level(p_level)), p_step) * 100) / 100) end $$;
grant execute on function _ck_level(text), _ck_mult(text,int) to anon, authenticated;

create or replace function _ck_view(r ck_rounds) returns json language sql stable as $$
  select json_build_object('state', 'crossing', 'level', r.level, 'step', r.step, 'lanes', (select lanes from _ck_level(r.level)),
    'bet', r.bet, 'mult', _ck_mult(r.level, r.step), 'next', _ck_mult(r.level, r.step + 1),
    'cashout', floor(r.bet * _ck_mult(r.level, r.step))::int, 'balance', _bal(r.team_id)) $$;

create or replace function ck_start(p_team int, p_pin text, p_bet int, p_level text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r ck_rounds;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from ck_rounds where team_id = p_team;
  if found then return _ck_view(r); end if;
  if p_level not in ('easy','medium','hard','hardcore') then raise exception 'Pick a difficulty.'; end if;
  perform _guard(t, p_bet);
  perform _apply(p_team, -p_bet, p_bet);
  insert into ck_rounds(team_id, bet, level) values (p_team, p_bet, p_level) returning * into r;
  return _ck_view(r);
end $$;

create or replace function ck_state(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r ck_rounds;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from ck_rounds where team_id = p_team;
  if not found then return json_build_object('state', 'idle', 'balance', _bal(p_team)); end if;
  return _ck_view(r);
end $$;

create or replace function _ck_pay(r ck_rounds, p_note text) returns json
language plpgsql security definer set search_path = public as $$
declare m numeric := _ck_mult(r.level, r.step); pay int := floor(r.bet * m)::int;
begin
  delete from ck_rounds where team_id = r.team_id;
  perform _apply(r.team_id, pay, 0);
  perform _log(r.team_id, 'chicken', r.bet, pay, initcap(r.level) || ' · ' || p_note || ' ' || r.step || ' lane' || case when r.step = 1 then '' else 's' end || ' · ' || to_char(m, 'FM990.00') || 'x');
  return json_build_object('state', 'cashed', 'level', r.level, 'step', r.step, 'mult', m, 'bet', r.bet, 'payout', pay, 'balance', _bal(r.team_id));
end $$;

create or replace function ck_step(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r ck_rounds; lv record;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from ck_rounds where team_id = p_team for update;
  if not found then raise exception 'Start a round first.'; end if;
  select * into lv from _ck_level(r.level);
  if _rnd(1000000) >= lv.survive * 1000000 then
    delete from ck_rounds where team_id = p_team;
    perform _log(p_team, 'chicken', r.bet, 0, initcap(r.level) || ' · hit in lane ' || (r.step + 1));
    return json_build_object('state', 'hit', 'level', r.level, 'step', r.step + 1, 'bet', r.bet, 'payout', 0, 'balance', _bal(p_team));
  end if;
  update ck_rounds set step = step + 1 where team_id = p_team returning * into r;
  if r.step >= lv.lanes then return _ck_pay(r, 'made it across all'); end if;
  return _ck_view(r);
end $$;

create or replace function ck_cashout(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; r ck_rounds;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  select * into r from ck_rounds where team_id = p_team for update;
  if not found then return json_build_object('state', 'idle', 'balance', _bal(p_team)); end if;
  if r.step = 0 then raise exception 'Take at least one step first.'; end if;
  return _ck_pay(r, 'cashed out after');
end $$;

-- settling also handles rockets and chickens: rockets have to land, chickens get cashed out where they stand
create or replace function admin_settle(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare owed int := 0; r ck_rounds;
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  if exists (select 1 from bj_hands) then raise exception 'A blackjack hand is still in play. Try again in a minute.'; end if;
  perform _rk_sweep();
  if exists (select 1 from rk_rounds) then raise exception 'A rocket is still in the air. Try again in a minute.'; end if;
  for r in select * from ck_rounds for update loop
    if r.step = 0 then
      delete from ck_rounds where team_id = r.team_id; perform _apply(r.team_id, r.bet, -r.bet);   -- never stepped: refund
    else perform _ck_pay(r, 'auto cashed out at settle after'); end if;
  end loop;
  insert into pending_rebates(team_id, amount) select team_id, rebate from _rebates() where rebate > 0;
  select coalesce(sum(rebate), 0) into owed from _rebates();
  update teams set base = base + net - settled, settled = net where id is not null;
  update config set last_settled = now() where id = 1;
  return json_build_object('ok', true, 'owed', owed);
end $$;

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

-- ---------- Business: the FAAB clicker and FAAB businesses ----------
-- Both create new FAAB. They pay into the casino balance (so they show up in the Monday
-- Sleeper sync) but are kept out of the gambling stats, the live feed and the loss rebate.
alter table config add column if not exists click_daily_cap int not null default 250;   -- dollars per team per day
alter table config add column if not exists biz_week_cap int not null default 3000;     -- dollars per team per week

create table if not exists biz_types (
  code text primary key, name text not null, blurb text, base_cost int not null, rate numeric not null, sort int not null
);
-- rate = dollars per hour per unit; every first unit pays back its cost in 14 days (336 hours)
insert into biz_types(code, name, blurb, base_cost, rate, sort) values
  ('stand',  'Waiver Wire Stand',      'Sells hot takes on the waiver wire.',          200,   round(200   / 336.0, 4), 1),
  ('mine',   'FAAB Mine',              'Digs FAAB out of the ground. Don''t ask.',     1000,  round(1000  / 336.0, 4), 2),
  ('scalp',  'Ticket Scalping Ring',   'Flips playoff tickets at a markup.',           5000,  round(5000  / 336.0, 4), 3),
  ('book',   'Underground Bookie',     'Takes action the casino won''t.',              20000, round(20000 / 336.0, 4), 4)
on conflict (code) do nothing;

create table if not exists biz_owned (team_id int not null references teams(id), code text not null references biz_types(code), qty int not null default 0, primary key (team_id, code));
create table if not exists biz_state (
  team_id int primary key references teams(id),
  last_collect timestamptz not null default now(),
  carry numeric not null default 0,          -- fractional dollars not paid out yet
  week_start date, week_made int not null default 0,
  click_day date, clicks_today int not null default 0, click_carry int not null default 0, click_paid_today int not null default 0,
  last_click timestamptz
);
create table if not exists biz_ledger (
  id bigserial primary key, team_id int not null references teams(id),
  kind text not null check (kind in ('buy','collect','click')), amount int not null, detail text,
  created_at timestamptz not null default now()
);
create index if not exists biz_ledger_team on biz_ledger(team_id, created_at desc);
alter table biz_types enable row level security;
alter table biz_owned enable row level security;
alter table biz_state enable row level security;
alter table biz_ledger enable row level security;
revoke all on biz_types, biz_owned, biz_state, biz_ledger from anon, authenticated;
grant select on biz_types to anon, authenticated;
create policy biz_types_read on biz_types for select using (true);

create or replace function _biz_week() returns date language sql stable as $$
  select date_trunc('week', now() at time zone 'America/New_York')::date $$;   -- Monday, Eastern
create or replace function _biz_today() returns date language sql stable as $$
  select (now() at time zone 'America/New_York')::date $$;
create or replace function _biz_cost(p_base int, p_qty int) returns int language sql immutable as $$
  select round(p_base * power(1.15, p_qty))::int $$;
grant execute on function _biz_cost(int,int) to anon, authenticated;

create or replace function _biz_rate(p_team int) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(o.qty * t.rate), 0) from biz_owned o join biz_types t on t.code = o.code where o.team_id = p_team $$;

-- make sure a state row exists and roll the week/day counters
create or replace function _biz_state(p_team int) returns biz_state
language plpgsql security definer set search_path = public as $$
declare s biz_state;
begin
  insert into biz_state(team_id, week_start, click_day) values (p_team, _biz_week(), _biz_today()) on conflict (team_id) do nothing;
  update biz_state set
    week_start = case when week_start is distinct from _biz_week() then _biz_week() else week_start end,
    week_made  = case when week_start is distinct from _biz_week() then 0 else week_made end,
    click_day  = case when click_day is distinct from _biz_today() then _biz_today() else click_day end,
    clicks_today = case when click_day is distinct from _biz_today() then 0 else clicks_today end,
    click_paid_today = case when click_day is distinct from _biz_today() then 0 else click_paid_today end
  where team_id = p_team returning * into s;
  return s;
end $$;

-- what's sitting in the safe right now (capped at 24 hours of output and the weekly cap)
create or replace function _biz_pending(s biz_state, p_rate numeric, p_cap int) returns numeric language sql stable as $$
  select greatest(0, least(
    p_rate * extract(epoch from now() - s.last_collect) / 3600.0 + s.carry,
    p_rate * 24 + s.carry,
    p_cap - s.week_made)) $$;

create or replace function _biz_view(p_team int) returns json
language plpgsql security definer set search_path = public as $$
declare s biz_state; r numeric; c config;
begin
  s := _biz_state(p_team); r := _biz_rate(p_team); select * into c from config where id = 1;
  return json_build_object(
    'rate', round(r, 4), 'pending', floor(_biz_pending(s, r, c.biz_week_cap)), 'pendingExact', round(_biz_pending(s, r, c.biz_week_cap), 4),
    'lastCollect', s.last_collect, 'safeHours', 24, 'weekMade', s.week_made, 'weekCap', c.biz_week_cap,
    'clicksToday', s.clicks_today, 'clickCarry', s.click_carry, 'clickPaidToday', s.click_paid_today, 'clickCap', c.click_daily_cap,
    'owned', coalesce((select json_object_agg(code, qty) from biz_owned where team_id = p_team), '{}'::json),
    'invested', coalesce((select -sum(amount) from biz_ledger where team_id = p_team and kind = 'buy'), 0),
    'collected', coalesce((select sum(amount) from biz_ledger where team_id = p_team and kind = 'collect'), 0),
    'clicked', coalesce((select sum(amount) from biz_ledger where team_id = p_team and kind = 'click'), 0),
    'balance', _bal(p_team));
end $$;

create or replace function biz_state_get(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  return _biz_view(p_team);
end $$;

-- pay out whatever's in the safe
create or replace function _biz_collect(p_team int) returns int
language plpgsql security definer set search_path = public as $$
declare s biz_state; r numeric; c config; amt numeric; paid int;
begin
  s := _biz_state(p_team); r := _biz_rate(p_team); select * into c from config where id = 1;
  amt := _biz_pending(s, r, c.biz_week_cap); paid := floor(amt);
  update biz_state set last_collect = now(), carry = amt - paid, week_made = week_made + paid where team_id = p_team;
  if paid > 0 then
    perform _apply(p_team, paid, 0);
    insert into biz_ledger(team_id, kind, amount, detail) values (p_team, 'collect', paid, 'Collected from the safe');
  end if;
  return paid;
end $$;

create or replace function biz_collect(p_team int, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; paid int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform 1 from teams where id = p_team for update;
  paid := _biz_collect(p_team);
  return json_build_object('paid', paid, 'state', _biz_view(p_team));
end $$;

-- buying collects first, so the new business only earns from now on
create or replace function biz_buy(p_team int, p_pin text, p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; bt biz_types; q int; cost int; c config;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform 1 from teams where id = p_team for update;
  select * into c from config where id = 1;
  if not c.open then raise exception 'The casino is closed right now.'; end if;
  if _blackout() then raise exception 'Businesses can''t be bought from 8 PM Monday until waivers clear at 3 AM Wednesday (Eastern).'; end if;
  select * into bt from biz_types where code = p_code;
  if not found then raise exception 'Unknown business.'; end if;
  perform _biz_collect(p_team);
  select coalesce((select qty from biz_owned where team_id = p_team and code = p_code), 0) into q;
  cost := _biz_cost(bt.base_cost, q);
  if cost > _bal(p_team) then raise exception 'You need % to buy that. You have %.', '$' || cost, '$' || _bal(p_team); end if;
  perform _apply(p_team, -cost, 0);
  insert into biz_owned(team_id, code, qty) values (p_team, p_code, 1) on conflict (team_id, code) do update set qty = biz_owned.qty + 1;
  insert into biz_ledger(team_id, kind, amount, detail) values (p_team, 'buy', -cost, 'Bought ' || bt.name || ' #' || (q + 1));
  return json_build_object('ok', true, 'cost', cost, 'state', _biz_view(p_team));
end $$;

-- the clicker: the page sends clicks in batches; the server allows about 20 a second and the daily cap
create or replace function biz_click(p_team int, p_pin text, p_clicks int) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; s biz_state; c config; allowed int; el numeric; tot int; dollars int; room int;
begin
  t := _auth(p_team, p_pin); if t.id is null then return json_build_object('error', 'Wrong PIN'); end if;
  perform 1 from teams where id = p_team for update;
  s := _biz_state(p_team); select * into c from config where id = 1;
  el := least(30, extract(epoch from now() - coalesce(s.last_click, now() - interval '30 seconds')));
  allowed := greatest(0, least(coalesce(p_clicks, 0), ceil(el * 20)::int, 2000));
  room := greatest(0, c.click_daily_cap - s.click_paid_today);
  allowed := least(allowed, room * 100 - s.click_carry);
  allowed := greatest(allowed, 0);
  tot := s.click_carry + allowed;
  dollars := tot / 100;
  update biz_state set clicks_today = clicks_today + allowed, click_carry = tot % 100,
    click_paid_today = click_paid_today + dollars, last_click = now() where team_id = p_team;
  if dollars > 0 then
    perform _apply(p_team, dollars, 0);
    insert into biz_ledger(team_id, kind, amount, detail) values (p_team, 'click', dollars, (dollars * 100) || ' clicks');
  end if;
  return json_build_object('accepted', allowed, 'paid', dollars, 'state', _biz_view(p_team));
end $$;

-- public business leaderboard and recent activity (kept separate from gambling stats)
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

create or replace function admin_set_business(p_pin text, p_click_cap int, p_week_cap int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not _admin(p_pin) then return json_build_object('error', 'Wrong commish PIN'); end if;
  update config set click_daily_cap = greatest(0, coalesce(p_click_cap, 250)), biz_week_cap = greatest(0, coalesce(p_week_cap, 3000)) where id = 1;
  return json_build_object('ok', true);
end $$;

create or replace view v_config as
  select open, max_bet, daily_limit, last_settled,
    (extract(isodow from now() at time zone 'America/New_York') = 1 and extract(hour from now() at time zone 'America/New_York') >= 20)
    or extract(isodow from now() at time zone 'America/New_York') = 2
    or (extract(isodow from now() at time zone 'America/New_York') = 3 and extract(hour from now() at time zone 'America/New_York') < 3) as blackout,
    rebate_pct, parlay_max_payout, sgp_pct, click_daily_cap, biz_week_cap
  from config;
grant select on v_config to anon, authenticated;

-- ---------- permissions: only the public functions are callable ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function claim_team(int,text), login(int,text),
  play_roulette(int,text,int,text,int), play_slots(int,text,int), play_dice(int,text,int,int), play_plinko(int,text,int),
  play_craps(int,text,int,text), sb_place(int,text,text,text,text,int), sb_my_bets(int,text),
  sb_place_parlay(int,text,jsonb,int), mk_place(int,text,text,text,int), mk_my_bets(int,text), stats(text), biz_state_get(int,text), biz_collect(int,text), biz_buy(int,text,text), biz_click(int,text,int), biz_stats(), admin_set_business(text,int,int), _biz_cost(int,int), rk_launch(int,text,int,numeric), rk_status(int,text), rk_cashout(int,text), rk_history(int,text), ck_start(int,text,int,text), ck_state(int,text), ck_step(int,text), ck_cashout(int,text), _ck_level(text), _ck_mult(text,int), _mk_cutoff(date), _wr_today(), admin_wr_settle(text,date,int), admin_set_parlay_cap(text,int), admin_set_sgp(text,int), _parlay_dec(bigint,boolean), _sb_label(sb_games,text,text,numeric), _sb_return(int,int), _sb_dec(int),
  bj_state(int,text), bj_deal(int,text,int), bj_action(int,text,text),
  admin_overview(text), admin_set_config(text,boolean,int,int), admin_set_base(text,int,int),
  admin_settle(text), admin_reset_pin(text,int), admin_set_rebate(text,int), admin_pay_rebates(text)
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

-- check ESPN every 5 minutes for lines and final scores
select cron.schedule('delts-sportsbook', '*/5 * * * *', 'select public.sb_poll()');
select cron.schedule('delts-markets', '*/5 * * * *', 'select public.mk_poll()');

-- tell the API about the new tables and functions
notify pgrst, 'reload schema';
