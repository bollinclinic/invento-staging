-- Surgeon names have been free text since day one -- 23 distinct raw strings in production
-- turned out to be only 19 real people (e.g. "Mr Siddiqui" / "Aftab Siddiqui" / "Mr siddiqui"
-- casing variants), which fragments any "per surgeon" report. Introduces a real surgeons
-- roster; procedures.surgeon stays the display text (unchanged everywhere it's already shown
-- -- lists, PDFs, reports), but now also links to surgeon_id for reliable grouping, and every
-- historical row gets both its link AND its display text corrected to the verified canonical
-- name at the same time, so old records read right everywhere immediately, not just in new
-- reports.
create table surgeons (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);

alter table surgeons enable row level security;
create policy "surgeons: read" on surgeons
  for select to authenticated
  using ((select app_role_rank()) >= 0);
-- Anyone can add a new surgeon -- this is the "no match found, add new" flow from the picker.
-- Making that a deliberate, visible action (rather than admin-only) is what actually fixes
-- the free-text-typo problem: staff aren't blocked waiting on an admin for a legitimately new
-- surgeon, but they're no longer just typing a name into a plain text box either.
create policy "surgeons: common+ insert" on surgeons
  for insert to authenticated
  with check ((select app_role_rank()) >= 0);

insert into surgeons (name) values
  ('Gerard Lambe'), ('Shafiq Rahman'), ('Aftab Siddiqui'), ('Deemish Oudit'), ('Mark Gorman'),
  ('Zygimantas Macys'), ('Anca Breahna'), ('Ali Juma'), ('Amer Hussain'), ('Azhar Iqbal'),
  ('Ben Khoda'), ('Hisham Abouzeid'), ('Mabroor Bhatty'), ('Massimo Maranzano'),
  ('Maurizio Persico'), ('Mubashir Cheema'), ('Sherif Elamari'), ('Ebba Sabri'),
  ('Tarek Eltantaway');

alter table procedures add column surgeon_id uuid references surgeons(id);

-- Verified mapping (checked programmatically against every distinct raw value in production
-- before writing this -- zero unmatched, zero ambiguous) from each of the 23 raw strings to
-- exactly one of the 19 canonical names above.
update procedures set surgeon = 'Aftab Siddiqui', surgeon_id = (select id from surgeons where name = 'Aftab Siddiqui') where surgeon = 'Aftab Siddiqui';
update procedures set surgeon = 'Anca Breahna', surgeon_id = (select id from surgeons where name = 'Anca Breahna') where surgeon = 'Anca Breahna';
update procedures set surgeon = 'Deemish Oudit', surgeon_id = (select id from surgeons where name = 'Deemish Oudit') where surgeon = 'Deemish Oudit';
update procedures set surgeon = 'Mark Gorman', surgeon_id = (select id from surgeons where name = 'Mark Gorman') where surgeon = 'Mark Gorman';
update procedures set surgeon = 'Anca Breahna', surgeon_id = (select id from surgeons where name = 'Anca Breahna') where surgeon = 'Miss Breahna';
update procedures set surgeon = 'Mabroor Bhatty', surgeon_id = (select id from surgeons where name = 'Mabroor Bhatty') where surgeon = 'Mr Bhatty';
update procedures set surgeon = 'Mubashir Cheema', surgeon_id = (select id from surgeons where name = 'Mubashir Cheema') where surgeon = 'Mr Cheema';
update procedures set surgeon = 'Sherif Elamari', surgeon_id = (select id from surgeons where name = 'Sherif Elamari') where surgeon = 'Mr Elamari';
update procedures set surgeon = 'Tarek Eltantaway', surgeon_id = (select id from surgeons where name = 'Tarek Eltantaway') where surgeon = 'Mr Eltantaway';
update procedures set surgeon = 'Mark Gorman', surgeon_id = (select id from surgeons where name = 'Mark Gorman') where surgeon = 'Mr Gorman';
update procedures set surgeon = 'Azhar Iqbal', surgeon_id = (select id from surgeons where name = 'Azhar Iqbal') where surgeon = 'Mr Iqbal';
update procedures set surgeon = 'Ali Juma', surgeon_id = (select id from surgeons where name = 'Ali Juma') where surgeon = 'Mr Juma';
update procedures set surgeon = 'Gerard Lambe', surgeon_id = (select id from surgeons where name = 'Gerard Lambe') where surgeon = 'Mr Lambe';
update procedures set surgeon = 'Zygimantas Macys', surgeon_id = (select id from surgeons where name = 'Zygimantas Macys') where surgeon = 'Mr Macys';
update procedures set surgeon = 'Massimo Maranzano', surgeon_id = (select id from surgeons where name = 'Massimo Maranzano') where surgeon = 'Mr Maranzano';
update procedures set surgeon = 'Deemish Oudit', surgeon_id = (select id from surgeons where name = 'Deemish Oudit') where surgeon = 'Mr Oudit';
update procedures set surgeon = 'Maurizio Persico', surgeon_id = (select id from surgeons where name = 'Maurizio Persico') where surgeon = 'Mr Persico';
update procedures set surgeon = 'Shafiq Rahman', surgeon_id = (select id from surgeons where name = 'Shafiq Rahman') where surgeon = 'Mr Rahman';
update procedures set surgeon = 'Ebba Sabri', surgeon_id = (select id from surgeons where name = 'Ebba Sabri') where surgeon = 'Mr Sabri';
update procedures set surgeon = 'Aftab Siddiqui', surgeon_id = (select id from surgeons where name = 'Aftab Siddiqui') where surgeon = 'Mr Siddiqui';
update procedures set surgeon = 'Gerard Lambe', surgeon_id = (select id from surgeons where name = 'Gerard Lambe') where surgeon = 'Mr lambe';
update procedures set surgeon = 'Shafiq Rahman', surgeon_id = (select id from surgeons where name = 'Shafiq Rahman') where surgeon = 'Shafiq Rahman';
update procedures set surgeon = 'Zygimantas Macys', surgeon_id = (select id from surgeons where name = 'Zygimantas Macys') where surgeon = 'Žygimantas Mačys';

-- get_procedures() returns setof procedures, matched by column POSITION -- surgeon_id is a
-- new trailing column, so it must be appended at the end of this list, not next to surgeon.
create or replace function get_procedures() returns setof procedures
language sql stable security definer set search_path = public as $$
  select
    id, date, surgeon, procedure_name, patient_ref, started_by, status,
    start_time, end_time,
    case when app_role_rank() >= 2 then total_cost else null end,
    notes, cart, room, created_at, updated_at, surgeon_id
  from procedures;
$$;

create or replace function proc_start(
  p_date date,
  p_surgeon text,
  p_procedure_name text,
  p_patient_ref text,
  p_room theatre_room,
  p_surgeon_id uuid default null
) returns procedures
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_row procedures;
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  begin
    insert into procedures (date, surgeon, surgeon_id, procedure_name, patient_ref, started_by, room)
    values (p_date, p_surgeon, p_surgeon_id, p_procedure_name, p_patient_ref, v_by, p_room)
    returning * into v_row;
  exception when unique_violation then
    raise exception '% already has an open case', p_room;
  end;

  return v_row;
end;
$$;
drop function if exists proc_start(date,text,text,text,theatre_room);

create or replace function proc_update_meta(p_procedure_id uuid, p_date date, p_surgeon text,
  p_procedure_name text, p_patient_ref text, p_room theatre_room default null, p_surgeon_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update procedures set date = coalesce(p_date, date), surgeon = p_surgeon, surgeon_id = p_surgeon_id,
    procedure_name = p_procedure_name, patient_ref = p_patient_ref, room = p_room
  where id = p_procedure_id;
  if not found then
    raise exception 'Procedure not found';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
drop function if exists proc_update_meta(uuid,date,text,text,text,theatre_room);

do $$
declare fn text;
begin
  foreach fn in array array[
    'proc_start(date,text,text,text,theatre_room,uuid)',
    'proc_update_meta(uuid,date,text,text,text,theatre_room,uuid)'
  ]
  loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end;
$$;
