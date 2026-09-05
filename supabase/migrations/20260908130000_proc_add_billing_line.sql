-- Backfills a service onto an already-closed (or open) procedure for billing purposes only --
-- e.g. going through old cases and adding a Histology that's known to have been used but was
-- never logged at the time. Deliberately NOT the same path as reopening a procedure: reopen is
-- built for genuinely re-working a case (returns consumed stock, expects re-ending), which is
-- more machinery than backfilling a single line needs and could have side effects that aren't
-- wanted on an old, otherwise-settled case. Scoped to services only -- they never touch stock
-- either way, so there's no question of whether to retroactively decrement inventory for
-- something used months ago; that's a separate decision for real consumables, not made here.
create or replace function proc_add_billing_line(p_procedure_id uuid, p_item_id uuid, p_qty numeric default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_by text;
  v_item items%rowtype;
  v_line_cost numeric;
  v_bill_line_cost numeric;
  v_line_id bigint;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  if not exists (select 1 from procedures where id = p_procedure_id) then
    raise exception 'Procedure not found';
  end if;
  select * into v_item from items where id = p_item_id;
  if not found then
    raise exception 'Item not found';
  end if;
  if v_item.tracker <> 'services' then
    raise exception 'Only services can be added to a procedure retroactively';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'Quantity must be greater than zero';
  end if;
  select display_name into v_by from profiles where id = auth.uid();

  v_line_cost := case when v_item.unit_cost is not null then round(v_item.unit_cost * p_qty, 2) else null end;
  v_bill_line_cost := case when v_item.bill_price is not null then round(v_item.bill_price * p_qty, 2) else null end;

  insert into procedure_lines (procedure_id, tracker, item_id, code, name, qty, unit_cost, line_cost, by, bill_price, bill_line_cost)
  values (p_procedure_id, v_item.tracker, v_item.id, v_item.code, v_item.name, p_qty, v_item.unit_cost, v_line_cost, v_by, v_item.bill_price, v_bill_line_cost)
  returning id into v_line_id;

  insert into activity_log (code, name, by, note, activity)
  values (v_item.code, v_item.name, v_by,
    'Added retroactively to procedure ' || p_procedure_id || ' (qty ' || p_qty || ')', 'Billing line added');

  return jsonb_build_object('ok', true, 'line_id', v_line_id);
end;
$$;

revoke execute on function proc_add_billing_line(uuid,uuid,numeric) from public, anon;
grant execute on function proc_add_billing_line(uuid,uuid,numeric) to authenticated;
