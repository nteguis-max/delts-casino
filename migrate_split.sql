-- Washed Delts Casino: add blackjack splits
-- Paste into Supabase > SQL Editor and press Run. Safe to run once.

-- refund any blackjack hand that is mid-play (the hand table is rebuilt below)
update teams t set net = t.net + (to_jsonb(b) ->> 'bet')::int
from bj_hands b where b.team_id = t.id and to_jsonb(b) ? 'bet';

drop table if exists bj_hands cascade;
create table bj_hands (
  team_id int primary key references teams(id),
  hands jsonb not null, active int not null default 0, dealer jsonb not null,
  created_at timestamptz not null default now()
);
alter table bj_hands enable row level security;
revoke all on bj_hands from anon, authenticated;

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

-- ---------- permissions: only the public functions are callable ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function claim_team(int,text), login(int,text),
  play_roulette(int,text,int,text,int), play_slots(int,text,int), play_dice(int,text,int,int), play_plinko(int,text,int),
  bj_state(int,text), bj_deal(int,text,int), bj_action(int,text,text),
  admin_overview(text), admin_set_config(text,boolean,int,int), admin_set_base(text,int,int),
  admin_settle(text), admin_reset_pin(text,int)
  to anon, authenticated;


notify pgrst, 'reload schema';
