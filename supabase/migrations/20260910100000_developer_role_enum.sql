-- Standalone: enum value additions must be committed in their own migration/transaction,
-- separate from anything that uses the new value (Postgres restriction) -- see the same
-- pattern used for the 'services' tracker_kind value.
alter type user_role add value 'developer';
