-- item_move_store/item_move_qty replace an item's location wholesale -- fine for "move
-- everything", but there's no way to move part of a quantity (e.g. 50 of 100 receivers to
-- MS Offsite Store, keeping 50 active) since location lives on the row, not per-unit.
-- item_move_qty splits the row instead: decrement the source by the moved amount, then either
-- merge into an existing row already at the destination with the same tracker+code (keeping
-- the item list from fragmenting every time stock shuttles back and forth), or clone a new row
-- there carrying just the moved quantity. Moving the FULL current quantity is still a plain
-- location update on the same row (no split needed, matches the old item_move_store behaviour).
create or replace function item_move_qty(p_item_id uuid, p_qty numeric, p_to_location text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tracker tracker_kind;
  v_code text;
  v_current_qty numeric;
  v_dest_id uuid;
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;

  select tracker, code, qty into v_tracker, v_code, v_current_qty
  from items where id = p_item_id for update;
  if not found then
    raise exception 'Item not found';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'Quantity to move must be greater than zero';
  end if;
  if p_qty > v_current_qty then
    raise exception 'Cannot move % — only % in stock', p_qty, v_current_qty;
  end if;

  if p_qty = v_current_qty then
    update items set location = p_to_location where id = p_item_id;
    return jsonb_build_object('ok', true, 'split', false, 'item_id', p_item_id, 'qty', p_qty);
  end if;

  update items set qty = qty - p_qty where id = p_item_id;

  select id into v_dest_id from items
    where tracker = v_tracker and location = p_to_location and id <> p_item_id
      and coalesce(code,'') = coalesce(v_code,'') and coalesce(code,'') <> ''
    limit 1;

  if v_dest_id is not null then
    update items set qty = qty + p_qty where id = v_dest_id;
    return jsonb_build_object('ok', true, 'split', true, 'merged', true, 'item_id', v_dest_id, 'qty', p_qty);
  end if;

  insert into items (tracker, code, barcode, name, category, supplier, location, unit, qty,
    reorder_level, unit_cost, expiry, batch, notes, status)
  select tracker, code, barcode, name, category, supplier, p_to_location, unit, p_qty,
    reorder_level, unit_cost, expiry, batch, notes, status
  from items where id = p_item_id
  returning id into v_dest_id;

  return jsonb_build_object('ok', true, 'split', true, 'merged', false, 'item_id', v_dest_id, 'qty', p_qty);
end;
$$;

revoke execute on function item_move_qty(uuid,numeric,text) from public, anon;
grant execute on function item_move_qty(uuid,numeric,text) to authenticated;
