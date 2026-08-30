-- Superadmin-only bulk operations on items: bulk-set category/location/supplier across a
-- ticked set of items, bulk-generate fresh unique barcodes, and bulk-obsolete. Gated at
-- rank>=3 (superadmin), one tier stricter than the single-item item_update (rank>=2) --
-- deliberately: touching many items at once in one click is higher blast-radius than
-- editing one, so it's reserved for superadmins per the explicit request.

create or replace function item_bulk_update(p_item_ids uuid[], p_fields jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update items set
    category = case when p_fields ? 'category' then nullif(p_fields->>'category','') else category end,
    location = case when p_fields ? 'location' then nullif(p_fields->>'location','') else location end,
    supplier = case when p_fields ? 'supplier' then nullif(p_fields->>'supplier','') else supplier end
  where id = any(p_item_ids);
  return jsonb_build_object('ok', true, 'updated', array_length(p_item_ids, 1));
end;
$$;

create or replace function item_bulk_obsolete(p_item_ids uuid[], p_by text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  update items set obsolete = true, obsolete_by = p_by, obsolete_at = now()
  where id = any(p_item_ids);
  return jsonb_build_object('ok', true, 'updated', array_length(p_item_ids, 1));
end;
$$;

-- Generates a fresh internal numeric barcode per item (13-digit, EAN-13-shaped) guaranteed
-- not to collide with any barcode already in use, retrying per-item until unique. Existing
-- manufacturer barcodes are typically alphanumeric product codes, so a random numeric scheme
-- can't accidentally collide with real stock -- only with other generated ones.
create or replace function item_bulk_generate_barcodes(p_item_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_new_barcode text;
  v_result jsonb := '{}'::jsonb;
begin
  if (select app_role_rank()) < 3 then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  foreach v_id in array p_item_ids loop
    loop
      v_new_barcode := to_char(floor(random()*9000000000000+1000000000000), 'FM9999999999999');
      exit when not exists(select 1 from items where barcode = v_new_barcode);
    end loop;
    update items set barcode = v_new_barcode where id = v_id;
    v_result := v_result || jsonb_build_object(v_id::text, v_new_barcode);
  end loop;
  return jsonb_build_object('ok', true, 'barcodes', v_result);
end;
$$;

do $$
declare fn text;
begin
  foreach fn in array array[
    'item_bulk_update(uuid[],jsonb)',
    'item_bulk_obsolete(uuid[],text)',
    'item_bulk_generate_barcodes(uuid[])'
  ]
  loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end;
$$;

-- Users & roles: tighten from admin+ to superadmin-only, matching the explicit request that
-- only superadmins manage accounts/roles (was rank>=2, now rank>=3). This was the only
-- direct-client UPDATE against `profiles` in the app, so no other flow depends on the wider
-- rank -- self password-change goes through Supabase Auth directly, not this table.
drop policy if exists "profiles: admin updates any row" on profiles;
create policy "profiles: superadmin updates any row" on profiles
  for update to authenticated
  using ((select app_role_rank()) >= 3) with check ((select app_role_rank()) >= 3);
