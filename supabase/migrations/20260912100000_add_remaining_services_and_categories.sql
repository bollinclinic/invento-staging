-- Backfills the updated Rate List.xlsx: a "category" column was added (Theatre vs Ward/Preop --
-- the latter for services ward/admin staff will add to procedure costing later; we only need
-- them to exist for now), plus 20 new services beyond the original 8 (8 more Histology
-- variants, 12 Ward/Preop blood tests). Written to be safely re-runnable against both
-- staging and production even though the two have diverged (the user had already
-- hand-added some of these in production before asking for the rest to be scripted, and
-- staging has none of them) -- ON CONFLICT DO NOTHING per (tracker, code, location) means
-- whichever of these already exist in a given environment are left untouched, and only the
-- genuinely missing ones are inserted, in each environment independently.

-- Category backfill for the 16 pre-existing Theatre services (the 8 originally seeded, plus
-- whichever of the 8 Histology variants were already hand-added) -- all confirmed Theatre in
-- the rate list. Only touches rows that don't already have a category.
update items set category = 'Theatre'
where tracker = 'services' and category is null
  and code in (
    'SVC-BODYJET','SVC-BODYJET-FAT','SVC-LIPO-HAND-REUSE','SVC-LIPO-HAND-SINGLE',
    'SVC-MICROAIRE-SINGLE','SVC-MICROAIRE-REUSE','SVC-RENUVION','SVC-VASER',
    'HIST','HIST1SK','HIST2SK','HIST3SK','HIST4SK','HIST5SK','HISTHBR2','HISTHIS3'
  );

insert into items (tracker, code, name, category, unit, qty, reorder_level, bill_price) values
  ('services', 'HIST',     'Histology',                          'Theatre', 'Use', 0, 0, 150.00),
  ('services', 'HIST1SK',  'Histology - 1x Skin Lesion',          'Theatre', 'Use', 0, 0, 150.00),
  ('services', 'HIST2SK',  'Histology - 2x Skin Lesions',         'Theatre', 'Use', 0, 0, 280.00),
  ('services', 'HIST3SK',  'Histology - 3x Skin Lesions',         'Theatre', 'Use', 0, 0, 420.00),
  ('services', 'HIST4SK',  'Histology - 4x Skin Lesions',         'Theatre', 'Use', 0, 0, 550.00),
  ('services', 'HIST5SK',  'Histology - 5x Skin Lesions',         'Theatre', 'Use', 0, 0, 680.00),
  ('services', 'HISTHBR2', 'Histology - Breast Reduction (2)',    'Theatre', 'Use', 0, 0, 285.00),
  ('services', 'HISTHIS3', 'Histology - Breast Tissue',           'Theatre', 'Use', 0, 0, 285.00),
  ('services', 'TFT',      'Thyroid Profile',                     'Ward/Preop', 'Use', 0, 0, 35.00),
  ('services', 'NP31',     'Advanced Thyroid',                    'Ward/Preop', 'Use', 0, 0, 45.00),
  ('services', 'THP',      'Thyroid Panel',                       'Ward/Preop', 'Use', 0, 0, 93.00),
  ('services', 'BIP',      'Basic Biochemistry',                  'Ward/Preop', 'Use', 0, 0, 39.00),
  ('services', 'VBIP',     'Haematology and Biochemistry',        'Ward/Preop', 'Use', 0, 0, 51.50),
  ('services', 'BG',       'Blood Group',                         'Ward/Preop', 'Use', 0, 0, 24.50),
  ('services', 'FBC',      'Full Blood Count',                    'Ward/Preop', 'Use', 0, 0, 23.50),
  ('services', 'UEC',      'Renal Function',                      'Ward/Preop', 'Use', 0, 0, 22.50),
  ('services', 'EUEC',     'Extended Renal Function',             'Ward/Preop', 'Use', 0, 0, 25.00),
  ('services', 'COAG',     'Coagulation Screen',                  'Ward/Preop', 'Use', 0, 0, 65.50),
  ('services', 'GLU',      'Blood Glucose',                       'Ward/Preop', 'Use', 0, 0, 5.00),
  ('services', 'LFT',      'Liver Function',                      'Ward/Preop', 'Use', 0, 0, 23.00)
on conflict (tracker, code, location) where code is not null and code <> '' do nothing;

-- The rate list's 13th "Item" row (previously 12) -- already exists in inventory as a real
-- consumable, just needed its invoice price set, same as the original 12.
update items set bill_price = 70.40 where tracker = 'consumables' and code = '2030';
