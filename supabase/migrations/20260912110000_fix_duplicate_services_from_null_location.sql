-- The previous migration's `on conflict (tracker, code, location) where code is not null and
-- code <> '' do nothing` never actually caught anything for services: every service row has
-- location = NULL, and Postgres unique indexes treat NULL as never equal to another NULL for
-- conflict-detection purposes (standard SQL semantics, not a bug in the index itself) -- so
-- rows the user had already hand-added (6 of the 8 new Theatre Histology variants) got a
-- second, duplicate copy inserted alongside the original instead of being skipped. Confirmed
-- neither copy of any pair has a barcode set or appears in any procedure_lines row, so this
-- removes exactly the duplicate (the one this migration's timestamp created), keeping the
-- original. These ids are production-specific (staging never had the pre-existing rows that
-- caused the collision, so it was never duplicated) -- harmless no-op there.
delete from items where id in (
  '6a7ff4f9-271d-457f-a992-e51c4d15dc95', -- HIST1SK duplicate
  '918ddf9f-d7ae-4c92-b53c-d7675b9a551e', -- HIST2SK duplicate
  'c32c7686-ee8a-4a04-ac28-b4ad6efad2f2', -- HIST3SK duplicate
  '0c1a7670-5ce9-4a52-ac6d-20a41a49aa6d', -- HIST5SK duplicate
  '5ec109df-5f29-4143-9c18-ccbbc86fb54c', -- HISTHBR2 duplicate
  '81be0ca0-aea3-4ec7-bfbf-fe0d67117f2a'  -- HISTHIS3 duplicate
);
