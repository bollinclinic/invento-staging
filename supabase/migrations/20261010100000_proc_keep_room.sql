-- A running procedure case must always keep its theatre.
--
-- Bug (found 2026-10-10): "Edit details" on a running case called proc_update_meta without
-- p_room, and proc_update_meta saved `room = p_room`, i.e. NULL. The case lost its theatre in
-- the database while its own screen still showed it in the right room. Every other device then
-- had to guess where it was (the page put it under Theatre 1, and could hide a real Theatre 1
-- case), and the one-open-case-per-room index no longer reserved that theatre, so a second
-- case could be started there.
--
-- Fix, server side (the page is fixed too, but devices still running the old page must not be
-- able to cause it again):
--   * proc_update_meta: on an OPEN case a missing room means "leave it as it is"; moving it
--     into a theatre that already has an open case is refused with a clear message.
--     A CLOSED case can still be set to "unassigned" from the history table, as before.
--   * proc_reopen: a closed case with no theatre is reopened into the first free theatre; a
--     case whose theatre is busy is refused up front with a clear message, before any stock
--     is touched (it used to fail half-way on the unique index with a raw error).
--   * a CHECK constraint makes "open case with no theatre" impossible from now on.

create or replace function proc_update_meta(p_procedure_id uuid, p_date date, p_surgeon text,
  p_procedure_name text, p_patient_ref text, p_room theatre_room default null, p_surgeon_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_status procedure_status;
  v_room   theatre_room;
  v_new    theatre_room;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select status, room into v_status, v_room from procedures where id = p_procedure_id for update;
  if not found then
    raise exception 'Procedure not found';
  end if;

  if v_status = 'Open' then
    v_new := coalesce(p_room, v_room);          -- never blank the theatre of a running case
    if v_new is distinct from v_room
       and exists(select 1 from procedures where room = v_new and status = 'Open' and id <> p_procedure_id) then
      raise exception '% already has a case running', v_new;
    end if;
  else
    v_new := p_room;                            -- closed case: may be set to unassigned
  end if;

  update procedures set date = coalesce(p_date, date), surgeon = p_surgeon, surgeon_id = p_surgeon_id,
    procedure_name = p_procedure_name, patient_ref = p_patient_ref, room = v_new
  where id = p_procedure_id;
  return jsonb_build_object('ok', true, 'room', v_new);
end;
$$;

create or replace function proc_reopen(p_procedure_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_line procedure_lines%rowtype;
  v_cart jsonb := '[]'::jsonb;
  v_restored int := 0;
  v_failed jsonb := '[]'::jsonb;
  v_by text;
  v_status procedure_status;
  v_room theatre_room;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  select status, room into v_status, v_room from procedures where id = p_procedure_id for update;
  if not found or v_status <> 'Closed' then
    raise exception 'Only a closed case can be reopened';
  end if;

  -- decide the theatre BEFORE touching stock, so a refusal changes nothing
  if v_room is null then
    select r into v_room from unnest(enum_range(null::theatre_room)) r
     where not exists(select 1 from procedures where room = r and status = 'Open')
     limit 1;
    if v_room is null then
      raise exception 'Every theatre already has a case running. End one first, then reopen this case.';
    end if;
  elsif exists(select 1 from procedures where room = v_room and status = 'Open' and id <> p_procedure_id) then
    raise exception '% already has a case running. End it first, then reopen this case.', v_room;
  end if;

  for v_line in select * from procedure_lines where procedure_id = p_procedure_id loop
    if v_line.item_id is not null then
      update items set qty = qty + v_line.qty where id = v_line.item_id;
      v_restored := v_restored + 1;
    else
      v_failed := v_failed || jsonb_build_object('name', v_line.name, 'reason', 'item no longer exists');
    end if;
    v_cart := v_cart || jsonb_build_object('item_id', v_line.item_id, 'tracker', v_line.tracker,
      'code', v_line.code, 'name', v_line.name, 'qty', v_line.qty);
  end loop;

  delete from procedure_lines where procedure_id = p_procedure_id;

  update procedures set status = 'Open', cart = v_cart, total_cost = null, end_time = null, room = v_room
  where id = p_procedure_id;

  insert into activity_log (code, name, by, note, activity)
  values (p_procedure_id::text, 'Case reopened', v_by,
    v_restored || ' line(s) stock restored' ||
      case when jsonb_array_length(v_failed) > 0 then ' · ' || jsonb_array_length(v_failed) || ' could not be restored' else '' end,
    'Procedure reopened');

  return jsonb_build_object('ok', true, 'restored', v_restored, 'failed', v_failed, 'room', v_room);
end;
$$;

-- An open case must have a theatre. (Closed cases may stay unassigned: four old ones are.)
alter table procedures add constraint procedures_open_needs_room
  check (status <> 'Open' or room is not null);
