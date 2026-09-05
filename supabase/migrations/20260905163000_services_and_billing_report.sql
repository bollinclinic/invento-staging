-- bill_price: the surgeon-group invoice rate for specific consumables and for services.
-- Entirely separate from unit_cost (the clinic's own purchase price, driving internal
-- financials/stock value) -- the two numbers are unrelated and must never be conflated.
alter table items add column if not exists bill_price numeric;

-- get_items() returns setof items positionally -- bill_price is a new trailing column, so it
-- must be appended at the end here, matching the same rank>=1 masking already applied to
-- unit_cost (both are financially sensitive in the same way).
create or replace function get_items() returns setof items
language sql stable security definer set search_path = public as $$
  select
    id, tracker, code, barcode, name, category, supplier, location, unit, qty,
    reorder_level,
    case when app_role_rank() >= 1 then unit_cost else null end,
    expiry, batch, notes, status, obsolete, obsolete_by, obsolete_at,
    qty_in_tray, cycles_to_date, created_at, updated_at,
    brand, size, color, description, material, method, max_cycles,
    case when app_role_rank() >= 1 then bill_price else null end
  from items;
$$;

create or replace function item_add(p_tracker tracker_kind, p_fields jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  insert into items (tracker, code, barcode, name, category, supplier, location, unit, qty,
    reorder_level, unit_cost, expiry, batch, notes, status, obsolete, obsolete_by, obsolete_at,
    qty_in_tray, cycles_to_date, brand, size, color, description, material, method, max_cycles,
    bill_price)
  values (
    p_tracker,
    nullif(p_fields->>'code',''), nullif(p_fields->>'barcode',''), p_fields->>'name',
    nullif(p_fields->>'category',''), nullif(p_fields->>'supplier',''), nullif(p_fields->>'location',''),
    coalesce(nullif(p_fields->>'unit',''), 'Each'), coalesce((p_fields->>'qty')::numeric, 0),
    coalesce((p_fields->>'reorder_level')::numeric, 0), nullif(p_fields->>'unit_cost','')::numeric,
    nullif(p_fields->>'expiry','')::date, nullif(p_fields->>'batch',''), nullif(p_fields->>'notes',''),
    nullif(p_fields->>'status',''), coalesce((p_fields->>'obsolete')::boolean, false),
    nullif(p_fields->>'obsolete_by',''), nullif(p_fields->>'obsolete_at','')::timestamptz,
    nullif(p_fields->>'qty_in_tray','')::numeric, coalesce((p_fields->>'cycles_to_date')::numeric, 0),
    nullif(p_fields->>'brand',''), nullif(p_fields->>'size',''), nullif(p_fields->>'color',''),
    nullif(p_fields->>'description',''), nullif(p_fields->>'material',''), nullif(p_fields->>'method',''),
    nullif(p_fields->>'max_cycles','')::numeric,
    nullif(p_fields->>'bill_price','')::numeric
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function item_update(p_item_id uuid, p_fields jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update items set
    code = case when p_fields ? 'code' then nullif(p_fields->>'code','') else code end,
    barcode = case when p_fields ? 'barcode' then nullif(p_fields->>'barcode','') else barcode end,
    name = case when p_fields ? 'name' then p_fields->>'name' else name end,
    category = case when p_fields ? 'category' then nullif(p_fields->>'category','') else category end,
    supplier = case when p_fields ? 'supplier' then nullif(p_fields->>'supplier','') else supplier end,
    location = case when p_fields ? 'location' then nullif(p_fields->>'location','') else location end,
    unit = case when p_fields ? 'unit' then coalesce(nullif(p_fields->>'unit',''),'Each') else unit end,
    qty = case when p_fields ? 'qty' then (p_fields->>'qty')::numeric else qty end,
    reorder_level = case when p_fields ? 'reorder_level' then (p_fields->>'reorder_level')::numeric else reorder_level end,
    unit_cost = case when p_fields ? 'unit_cost' then nullif(p_fields->>'unit_cost','')::numeric else unit_cost end,
    expiry = case when p_fields ? 'expiry' then nullif(p_fields->>'expiry','')::date else expiry end,
    batch = case when p_fields ? 'batch' then nullif(p_fields->>'batch','') else batch end,
    notes = case when p_fields ? 'notes' then nullif(p_fields->>'notes','') else notes end,
    status = case when p_fields ? 'status' then nullif(p_fields->>'status','') else status end,
    obsolete = case when p_fields ? 'obsolete' then (p_fields->>'obsolete')::boolean else obsolete end,
    obsolete_by = case when p_fields ? 'obsolete_by' then nullif(p_fields->>'obsolete_by','') else obsolete_by end,
    obsolete_at = case when p_fields ? 'obsolete_at' then nullif(p_fields->>'obsolete_at','')::timestamptz else obsolete_at end,
    qty_in_tray = case when p_fields ? 'qty_in_tray' then nullif(p_fields->>'qty_in_tray','')::numeric else qty_in_tray end,
    cycles_to_date = case when p_fields ? 'cycles_to_date' then (p_fields->>'cycles_to_date')::numeric else cycles_to_date end,
    brand = case when p_fields ? 'brand' then nullif(p_fields->>'brand','') else brand end,
    size = case when p_fields ? 'size' then nullif(p_fields->>'size','') else size end,
    color = case when p_fields ? 'color' then nullif(p_fields->>'color','') else color end,
    description = case when p_fields ? 'description' then nullif(p_fields->>'description','') else description end,
    material = case when p_fields ? 'material' then nullif(p_fields->>'material','') else material end,
    method = case when p_fields ? 'method' then nullif(p_fields->>'method','') else method end,
    max_cycles = case when p_fields ? 'max_cycles' then nullif(p_fields->>'max_cycles','')::numeric else max_cycles end,
    bill_price = case when p_fields ? 'bill_price' then nullif(p_fields->>'bill_price','')::numeric else bill_price end
  where id = p_item_id;
  if not found then
    raise exception 'Item not found';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Seed the 8 billable techniques from the rate list. qty/reorder are meaningless for a
-- service (there's nothing physical to count) and stay at 0 permanently -- proc_consume_batch
-- below explicitly never decrements a 'services' row regardless of what its qty happens to be,
-- so this is about a sane display default, not the actual non-decrementing guarantee.
insert into items (tracker, code, name, unit, qty, reorder_level, bill_price) values
  ('services', 'SVC-LIPO-HAND-REUSE',   'Handheld Lipo with reusable cannula',    'Use', 0, 0, 0.00),
  ('services', 'SVC-LIPO-HAND-SINGLE',  'Handheld Lipo with single use cannula',  'Use', 0, 0, 150.00),
  ('services', 'SVC-MICROAIRE-REUSE',   'Microaire with reusable cannula',        'Use', 0, 0, 250.00),
  ('services', 'SVC-MICROAIRE-SINGLE',  'Micro Aire with single use cannula',     'Use', 0, 0, 400.00),
  ('services', 'SVC-BODYJET',           'Body Jet liposuction',                   'Use', 0, 0, 550.00),
  ('services', 'SVC-BODYJET-FAT',       'Bodyjet liposuction with fat transfer',  'Use', 0, 0, 1050.00),
  ('services', 'SVC-VASER',             'VASER liposuction',                      'Use', 0, 0, 550.00),
  ('services', 'SVC-RENUVION',          'Renuvion',                                'Use', 0, 0, 1500.00);

-- Set bill_price on the 11 rate-list consumables already matched against inventory (the 12th,
-- SXPP2B403, doesn't exist in the inventory yet -- to be linked once it's added).
update items set bill_price = 30.00  where tracker='consumables' and code = 'SXPP1A406';
update items set bill_price = 30.00  where tracker='consumables' and code = 'SXPP1A404';
update items set bill_price = 30.00  where tracker='consumables' and code = 'SXMP1B102';
update items set bill_price = 35.00  where tracker='consumables' and code = 'SXMP1B113';
update items set bill_price = 55.00  where tracker='consumables' and code = 'C100110';
update items set bill_price = 55.00  where tracker='consumables' and code = 'C100165';
update items set bill_price = 55.00  where tracker='consumables' and code = 'REF_01KR';
update items set bill_price = 270.00 where tracker='consumables' and code = '66802003';
update items set bill_price = 250.00 where tracker='consumables' and code = '66802040';
update items set bill_price = 250.00 where tracker='consumables' and code = '66802025';
update items set bill_price = 250.00 where tracker='consumables' and code = '66802044';

-- procedure_lines needs its own bill_price/bill_line_cost, captured at the moment of
-- consumption (same reasoning as unit_cost/line_cost already being snapshotted rather than
-- looked up live) -- so a later change to the rate list can never silently rewrite what a
-- past case would have been invoiced.
alter table procedure_lines add column if not exists bill_price numeric;
alter table procedure_lines add column if not exists bill_line_cost numeric;

create or replace function proc_consume_batch(p_procedure_id uuid, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_line jsonb;
  v_item items%rowtype;
  v_item_id uuid;
  v_tracker tracker_kind;
  v_qty numeric;
  v_new_qty numeric;
  v_line_cost numeric;
  v_bill_line_cost numeric;
  v_running_total numeric := 0;
  v_consumed jsonb := '[]'::jsonb;
  v_failed jsonb := '[]'::jsonb;
begin
  if (select app_role_rank()) < 0 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  if not exists (select 1 from procedures where id = p_procedure_id and status = 'Open' for update) then
    raise exception 'Procedure not open or not found';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := greatest(1, coalesce((v_line->>'qty')::numeric, 1));
    begin
      v_item_id := nullif(v_line->>'item_id', '')::uuid;
      if v_item_id is not null then
        select * into v_item from items where id = v_item_id for update;
      else
        v_tracker := nullif(v_line->>'tracker', '')::tracker_kind;
        select * into v_item from items
          where tracker = v_tracker
            and ( (nullif(v_line->>'code','') is not null and code = v_line->>'code')
               or (nullif(v_line->>'barcode','') is not null and barcode = v_line->>'barcode')
               or (nullif(v_line->>'name','') is not null and name = v_line->>'name') )
          order by
            (nullif(v_line->>'code','') is not null and code = v_line->>'code') desc,
            (nullif(v_line->>'barcode','') is not null and barcode = v_line->>'barcode') desc
          limit 1
          for update;
      end if;
      if not found then
        v_failed := v_failed || jsonb_build_object('name', v_line->>'name', 'reason', 'item not found');
        continue;
      end if;

      if v_item.tracker = 'services' then
        -- a technique, not physical stock -- using it any number of times never runs it out
        v_new_qty := v_item.qty;
      else
        v_new_qty := greatest(0, v_item.qty - v_qty);
        update items set qty = v_new_qty where id = v_item.id;
      end if;

      v_line_cost := case when v_item.unit_cost is not null then round(v_item.unit_cost * v_qty, 2) else null end;
      if v_line_cost is not null then
        v_running_total := v_running_total + v_line_cost;
      end if;
      v_bill_line_cost := case when v_item.bill_price is not null then round(v_item.bill_price * v_qty, 2) else null end;

      insert into procedure_lines (procedure_id, tracker, item_id, code, name, qty, unit_cost, line_cost, by, bill_price, bill_line_cost)
      values (p_procedure_id, v_item.tracker, v_item.id, v_item.code, v_item.name, v_qty, v_item.unit_cost, v_line_cost, v_by, v_item.bill_price, v_bill_line_cost);

      insert into activity_log (direction, tracker, item_id, code, name, qty, by, note, activity)
      values ('out', v_item.tracker, v_item.id, v_item.code, v_item.name, v_qty, v_by,
        'Consumed — procedure ' || p_procedure_id, 'Stock out');

      v_consumed := v_consumed || jsonb_build_object('name', v_item.name, 'qty', v_qty, 'newQty', v_new_qty);
    exception when others then
      v_failed := v_failed || jsonb_build_object('name', v_line->>'name', 'reason', sqlerrm);
    end;
  end loop;

  update procedures set
    status = 'Closed',
    total_cost = round(v_running_total, 2),
    end_time = now(),
    cart = '[]'::jsonb
  where id = p_procedure_id;

  insert into activity_log (code, name, by, note, activity)
  values (p_procedure_id::text, 'Case closed', v_by,
    jsonb_array_length(v_consumed) || ' line(s) consumed · Total £' || v_running_total::text ||
      case when jsonb_array_length(v_failed) > 0 then ' · ' || jsonb_array_length(v_failed) || ' FAILED' else '' end,
    'Procedure ended');

  return jsonb_build_object('ok', jsonb_array_length(v_failed) = 0,
    'consumed', v_consumed, 'failed', v_failed, 'total', v_running_total);
end;
$$;

-- Surgeon-group billing report: every procedure_lines row with a captured bill_price (i.e.
-- was a rate-list item or a service at the moment it was used), joined back to its procedure
-- for surgeon/date/patient/procedure context. Admin+ only, same rank as procedure financials.
create or replace function billing_report(p_from date default null, p_to date default null, p_surgeon_id uuid default null)
returns table (
  procedure_id uuid, date date, surgeon text, surgeon_id uuid, procedure_name text, patient_ref text,
  item_name text, tracker tracker_kind, qty numeric, bill_price numeric, bill_line_cost numeric
)
language plpgsql stable security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
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

do $$
declare fn text;
begin
  foreach fn in array array[
    'proc_consume_batch(uuid,jsonb)',
    'billing_report(date,date,uuid)'
  ]
  loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end;
$$;
