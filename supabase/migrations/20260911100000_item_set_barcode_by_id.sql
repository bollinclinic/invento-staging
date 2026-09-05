-- item_set_barcode(p_tracker, p_code, p_barcode) matches by (tracker, code) -- fine for
-- consumables/meds where staff always fill in a product code, but items_tracker_code_uq
-- explicitly allows multiple rows with a blank code per tracker (partial unique index, "where
-- code is not null and code <> ''"), so matching a blank code would silently stamp the same
-- barcode onto every such row. Services are the first tracker where a blank code is a normal,
-- expected in-between state (added via the dialog with just a name, code assigned later), so
-- generating a code for one service needs to target it by id, not by its possibly-blank code.
-- Mirrors item_clear_barcode's existing by-id shape.
create or replace function item_set_barcode_by_id(p_item_id uuid, p_barcode text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 2 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update items set barcode = p_barcode where id = p_item_id;
  if not found then
    raise exception 'Item not found';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function item_set_barcode_by_id(uuid,text) from public, anon;
grant execute on function item_set_barcode_by_id(uuid,text) to authenticated;
