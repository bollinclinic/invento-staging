-- item_move_qty's first version only checked for an existing row at the destination when
-- splitting a partial quantity, not when moving a row's full remaining quantity -- so moving
-- the last of a partially-split item (e.g. the final 30 of what's left of 100 receivers) tried
-- to relocate the source row in place and collided with the unique (tracker, code, location)
-- index against the row already sitting there from the earlier partial moves. Fixed by always
-- checking for a destination row first: merge into it if one exists (deleting the now-empty
-- source when the move takes all of it, decrementing otherwise), and only fall back to a plain
-- in-place relocate or a freshly cloned row when nothing already exists there.
create or replace function item_move_qty(p_item_id uuid, p_qty numeric, p_to_location text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tracker tracker_kind;
  v_code text;
  v_current_qty numeric;
  v_dest_id uuid;
  v_full boolean;
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
  v_full := (p_qty = v_current_qty);

  select id into v_dest_id from items
    where tracker = v_tracker and location = p_to_location and id <> p_item_id
      and coalesce(code,'') = coalesce(v_code,'') and coalesce(code,'') <> ''
    for update;

  if v_dest_id is not null then
    update items set qty = qty + p_qty where id = v_dest_id;
    if v_full then
      delete from items where id = p_item_id;
    else
      update items set qty = qty - p_qty where id = p_item_id;
    end if;
    return jsonb_build_object('ok', true, 'split', true, 'merged', true, 'item_id', v_dest_id, 'qty', p_qty);
  end if;

  if v_full then
    update items set location = p_to_location where id = p_item_id;
    return jsonb_build_object('ok', true, 'split', false, 'merged', false, 'item_id', p_item_id, 'qty', p_qty);
  end if;

  update items set qty = qty - p_qty where id = p_item_id;
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
