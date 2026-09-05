-- Renuvion, VASER, Body Jet etc. are billable techniques, not physical stock -- they need a
-- code and a price so they can be added to a procedure's cart exactly like any consumable,
-- but their "quantity" must never run out. Adding a 6th tracker value rather than bolting a
-- flag onto an existing one keeps "show me every service used" a plain tracker filter, and
-- keeps every existing consumables/meds/garments/linen assumption (location, reorder level,
-- expiry) from silently applying to something they don't mean anything for.
-- Split into its own migration/transaction: a newly added enum value can't safely be used by
-- a statement later in the SAME transaction as the ALTER TYPE that added it.
alter type tracker_kind add value 'services';
