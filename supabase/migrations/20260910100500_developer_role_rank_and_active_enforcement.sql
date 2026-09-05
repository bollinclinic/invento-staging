-- Developer sits one tier above superadmin: role_rank(developer)=4 means every existing
-- rank>=3 gate (Rota, item bulk edit/obsolete/barcode-gen, item inline-edit) already includes
-- it automatically -- a developer keeps every superadmin capability, plus the few new
-- developer-only ones added alongside this migration (Surgeon billing report, Item usage
-- search, Users & roles).
create or replace function role_rank(r user_role) returns int
language sql immutable set search_path = public as $$
  select case r
    when 'common' then 0
    when 'staff' then 1
    when 'admin' then 2
    when 'superadmin' then 3
    when 'developer' then 4
  end;
$$;

-- profiles.active existed but was purely decorative -- nothing anywhere actually checked it,
-- so toggling it (once exposed in the UI) would have done nothing. Folding the check into
-- app_role_rank() -- which every RLS policy and every rank-gated RPC already calls -- makes
-- deactivation take effect everywhere at once, including for a session that's already open,
-- rather than needing a separate enforcement point bolted onto each table/RPC.
create or replace function app_role_rank() returns int
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select case when active then role_rank(role) else -1 end from profiles where id = auth.uid()),
    -1
  );
$$;

-- Users & roles: tighten from superadmin (rank>=3) to developer-only (rank>=4) -- role
-- changes, activate/deactivate, and (via the manage-user edge function) username/password
-- changes are now all one tier stricter, per explicit request.
drop policy if exists "profiles: superadmin updates any row" on profiles;
create policy "profiles: developer updates any row" on profiles
  for update to authenticated
  using ((select app_role_rank()) >= 4) with check ((select app_role_rank()) >= 4);
