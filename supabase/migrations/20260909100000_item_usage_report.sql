-- Superadmin-only: search which procedures used a given item (by name or code, e.g. "Lighted
-- Retractor" or "C100110") across every tracker except sterilisation -- instruments have their
-- own dispatch/use history already, this is for the trackers billing decisions get made
-- around. Matches against procedure_lines' own snapshotted name/code (the item as it was named
-- at the moment it was used), not a live join to items, consistent with how bill_price/
-- unit_cost are already snapshotted rather than looked up live.
create or replace function item_usage_report(p_query text, p_from date default null, p_to date default null)
returns table (
  procedure_id uuid, date date, surgeon text, patient_ref text, procedure_name text,
  item_name text, code text, tracker tracker_kind, qty numeric, by text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  return query
  select p.id, p.date, p.surgeon, p.patient_ref, p.procedure_name,
    pl.name, pl.code, pl.tracker, pl.qty, pl.by
  from procedure_lines pl
  join procedures p on p.id = pl.procedure_id
  where pl.tracker <> 'instruments'
    and (p_query is null or p_query = '' or pl.name ilike '%'||p_query||'%' or pl.code ilike '%'||p_query||'%')
    and (p_from is null or p.date >= p_from)
    and (p_to is null or p.date <= p_to)
  order by p.date desc, pl.ts desc;
end;
$$;

revoke execute on function item_usage_report(text,date,date) from public, anon;
grant execute on function item_usage_report(text,date,date) to authenticated;
