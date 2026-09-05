-- Surgeon billing report tightened to superadmin only (was admin+) -- contract pricing data,
-- stricter than the procedure-financials gate it previously matched.
create or replace function billing_report(p_from date default null, p_to date default null, p_surgeon_id uuid default null)
returns table (
  procedure_id uuid, date date, surgeon text, surgeon_id uuid, procedure_name text, patient_ref text,
  item_name text, tracker tracker_kind, qty numeric, bill_price numeric, bill_line_cost numeric
)
language plpgsql stable security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 3 then
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

-- The 12th rate-list item, added to inventory after the original seeding pass.
update items set bill_price = 40.00 where tracker = 'consumables' and code = 'SXPP2B403';
