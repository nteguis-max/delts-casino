-- Washed Delts Casino: add craps
-- Paste into Supabase > SQL Editor and press Run.

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

revoke execute on function play_craps(int,text,int,text) from public;
grant execute on function play_craps(int,text,int,text) to anon, authenticated;
notify pgrst, 'reload schema';
