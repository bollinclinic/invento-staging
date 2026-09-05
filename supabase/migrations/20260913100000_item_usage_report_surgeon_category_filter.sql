-- Adds two optional filters to the existing (developer-only) item usage report: a specific
-- surgeon, and an item category (e.g. "Skin Closure") -- lets a developer ask either "what did
-- surgeon X use from category Y, across every case" or "has surgeon X ever used item Z, and
-- when" without leaving the tab. Category isn't captured on procedure_lines itself (unlike
-- tracker/code/name, which are deliberately snapshotted at time of use), so it's read live via
-- item_id -- categories are a fixed classification that basically never changes after the
-- fact, unlike price, so there's no snapshot to preserve here; a left join tolerates the rare
-- case where the item has since been deleted (item_id set null) by simply never matching a
-- category filter for that row, same as it already doesn't show a code/name (it still shows
-- the row via its own snapshotted tracker/name/code either way).
-- New parameter -> new overload in Postgres; drop the old 3-arg signature explicitly.
drop function if exists item_usage_report(text, date, date);

create or replace function item_usage_report(p_query text, p_from date default null, p_to date default null,
  p_surgeon_id uuid default null, p_category text default null)
returns table (
  procedure_id uuid, date date, surgeon text, patient_ref text, procedure_name text,
  item_name text, code text, tracker tracker_kind, qty numeric, by text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 4 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  return query
  select p.id, p.date, p.surgeon, p.patient_ref, p.procedure_name,
    pl.name, pl.code, pl.tracker, pl.qty, pl.by
  from procedure_lines pl
  join procedures p on p.id = pl.procedure_id
  left join items it on it.id = pl.item_id
  where pl.tracker <> 'instruments'
    and (p_query is null or p_query = '' or pl.name ilike '%'||p_query||'%' or pl.code ilike '%'||p_query||'%')
    and (p_from is null or p.date >= p_from)
    and (p_to is null or p.date <= p_to)
    and (p_surgeon_id is null or p.surgeon_id = p_surgeon_id)
    and (p_category is null or p_category = '' or it.category = p_category)
  order by p.date desc, pl.ts desc;
end;
$$;

revoke execute on function item_usage_report(text,date,date,uuid,text) from public, anon;
grant execute on function item_usage_report(text,date,date,uuid,text) to authenticated;
