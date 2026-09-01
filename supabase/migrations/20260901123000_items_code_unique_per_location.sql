-- item_move_qty needs to be able to split one item's quantity across two locations (e.g. 50 of
-- 100 receivers moved to MS Offsite Store, 50 staying at Bollin) -- which means the SAME
-- tracker+code legitimately existing as two rows, one per location. The original
-- items_tracker_code_uq / items_tracker_barcode_uq indexes were scoped to (tracker, code) only,
-- so the very first attempt at a split failed with a duplicate-key error. Rescoping them to
-- include location keeps the real guarantee (no true duplicate row for the same item at the
-- same place) while allowing the same item to exist at more than one place.
drop index if exists items_tracker_code_uq;
create unique index items_tracker_code_uq on items (tracker, code, location)
  where code is not null and code <> '';

drop index if exists items_tracker_barcode_uq;
create unique index items_tracker_barcode_uq on items (tracker, barcode, location)
  where barcode is not null and barcode <> '';
