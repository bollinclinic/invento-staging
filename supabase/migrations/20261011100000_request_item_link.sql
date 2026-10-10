-- Requests can now be raised by picking an item from the inventory instead of typing it.
-- The request then carries the item's reference, so the stock team sees exactly which
-- catalogue line was asked for. Typed (free-text) requests are unchanged: these stay null.
--
--   item_id    the inventory item (kept null-safe: if the item is later deleted the request
--              survives with its name and reference as text)
--   item_code  the item's reference at the time of the request (its code, else its barcode)
--   tracker    which tracker it was in
--
-- No policy change: the existing row-level policies ("common+ create", "read", "staff+
-- respond", "admin delete") already cover the new columns.
alter table stock_requests
  add column item_id   uuid references items(id) on delete set null,
  add column item_code text,
  add column tracker   tracker_kind;
create index stock_requests_item_idx on stock_requests (item_id);
