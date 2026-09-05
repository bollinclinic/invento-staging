-- Surgeon billing report and Item usage search tighten from superadmin (rank>=3) to
-- developer-only (rank>=4), per explicit request -- contract pricing data and the item-level
-- usage audit trail are restricted one tier further than the rest of the superadmin surface.
create or replace function billing_report(p_from date default null, p_to date default null, p_surgeon_id uuid default null)
returns table (
  procedure_id uuid, date date, surgeon text, surgeon_id uuid, procedure_name text, patient_ref text,
  item_name text, tracker tracker_kind, qty numeric, bill_price numeric, bill_line_cost numeric
)
language plpgsql stable security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 4 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  return query
  select p.id, p.date, p.surgeon, p.surgeon_id, p.procedure_name, p.patient_ref,
    pl.name, pl.tracker, pl.qty, pl.bill_price, pl.bill_line_cost
  from procedure_lines pl
  join procedures p on p.id = pl.procedure_id
  where pl.bill_price is not null
    and (p_from is null or p.date >= p_from)
    and (p_to is null or p.date <= p_to)
    and (p_surgeon_id is null or p.surgeon_id = p_surgeon_id)
  order by p.date desc, p.surgeon, pl.ts;
end;
$$;

create or replace function item_usage_report(p_query text, p_from date default null, p_to date default null)
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
  where pl.tracker <> 'instruments'
    and (p_query is null or p_query = '' or pl.name ilike '%'||p_query||'%' or pl.code ilike '%'||p_query||'%')
    and (p_from is null or p.date >= p_from)
    and (p_to is null or p.date <= p_to)
  order by p.date desc, pl.ts desc;
end;
$$;

-- Yasar's own account moves from superadmin to developer, the sole holder of the new tier.
update profiles set role = 'developer' where username = 'yasar';
