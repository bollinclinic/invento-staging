-- TML Report (Records, developer only): theatre over-runs plus billable items and services,
-- per company.
--
--   tml_companies / tml_company_surgeons : who a report covers, and their over-run terms
--   tml_lists / tml_list_items           : named lists of what gets invoiced
--   tml_list_prices                      : a list's own prices, each from a date, so a price
--                                          change never alters a report for earlier dates
--   tml_exclusions                       : a patient, day or surgeon's list taken out of a
--                                          company's reports (e.g. a private list), with a reason
--   tml_name_decisions                   : "these two surgeon names are the same / different"
--   tml_fix_log                          : every correction made to the theatre sheet from here
--
-- No company, price, contract term or surgeon list is in this file, because it is public. They
-- are entered in the app and live only in these tables. All of these
-- tables have row level security on and NO policies: they are reached only through the
-- functions below, and each one checks app_can('tml.manage').

insert into app_permissions (sort, key, grp, label, kind, min_rank, locked, server, detail) values
  (255, 'tml.manage', 'Records', 'TML Report', 'manage', 4, true, true,
   'Company over-run and invoice reports, price lists, and fixes to the theatre sheet');

create table tml_lists (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  company_id uuid,
  surgeon text,
  updated_at timestamptz not null default clock_timestamp()
);
create unique index tml_lists_name_uq on tml_lists (lower(btrim(name)));

create table tml_companies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  active boolean not null default true,
  start_time time,
  finish_time time not null,
  grace_min int not null check (grace_min between 0 and 240),
  hourly_rate numeric(10,2) not null check (hourly_rate >= 0),
  max_hours int not null check (max_hours between 0 and 24),
  count_from text not null default 'finish' check (count_from in ('finish', 'grace')),
  shared_hours numeric(4,2) not null check (shared_hours > 0 and shared_hours <= 24),
  default_list_id uuid references tml_lists(id) on delete set null,
  updated_at timestamptz not null default clock_timestamp()
);
create unique index tml_companies_name_uq on tml_companies (lower(btrim(name)));
alter table tml_lists add constraint tml_lists_company_fk
  foreign key (company_id) references tml_companies(id) on delete set null;

create table tml_company_surgeons (
  company_id uuid not null references tml_companies(id) on delete cascade,
  surgeon text not null check (btrim(surgeon) <> ''),
  terms jsonb,            -- this surgeon's own over-run terms, when different from the company's
  primary key (company_id, surgeon)
);
create unique index tml_company_surgeons_uq on tml_company_surgeons (company_id, lower(btrim(surgeon)));

create table tml_list_items (
  list_id uuid not null references tml_lists(id) on delete cascade,
  item_id uuid not null references items(id) on delete cascade,
  selected boolean not null default true,
  primary key (list_id, item_id)
);

create table tml_list_prices (
  id bigint generated always as identity primary key,
  list_id uuid not null references tml_lists(id) on delete cascade,
  item_id uuid not null references items(id) on delete cascade,
  price numeric(10,2) not null check (price >= 0),
  from_date date not null default '1900-01-01',
  set_by text,
  set_at timestamptz not null default clock_timestamp(),
  unique (list_id, item_id, from_date)
);

create table tml_exclusions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references tml_companies(id) on delete cascade,
  kind text not null check (kind in ('patient', 'day', 'surgeon')),
  on_date date not null,
  pat text,
  surgeon text,
  reason text not null check (btrim(reason) <> ''),
  set_by text,
  created_at timestamptz not null default clock_timestamp(),
  check ((kind = 'patient' and pat is not null) or (kind = 'surgeon' and surgeon is not null) or kind = 'day')
);
create index tml_exclusions_company_idx on tml_exclusions (company_id, on_date);

create table tml_name_decisions (
  id uuid primary key default gen_random_uuid(),
  name_a text not null,   -- lower case, name_a < name_b
  name_b text not null,
  decision text not null check (decision in ('same', 'different')),
  canonical text,
  set_by text,
  created_at timestamptz not null default clock_timestamp(),
  unique (name_a, name_b),
  check (name_a < name_b),
  check (decision = 'different' or canonical is not null)
);

-- the over-run terms a new company starts with
create table tml_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default clock_timestamp()
);

create table tml_fix_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default clock_timestamp(),
  by text,
  on_date text,
  pat text,
  field text,
  old_value text,
  new_value text
);

do $$
declare t text;
begin
  foreach t in array array['tml_lists','tml_companies','tml_company_surgeons','tml_list_items',
                           'tml_list_prices','tml_exclusions','tml_name_decisions','tml_settings','tml_fix_log'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- helpers
create or replace function tml_gate() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not app_can('tml.manage') then
    raise exception 'insufficient privilege' using errcode = '42501';
  end if;
  return coalesce((select display_name from profiles where id = auth.uid()), 'unknown');
end;
$$;
revoke execute on function tml_gate() from public, anon, authenticated;

-- ---------------------------------------------------------------- everything the page needs
create or replace function tml_get_config() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform tml_gate();
  return jsonb_build_object(
    'defaults', (select value from tml_settings where key = 'default_terms'),
    'companies', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'active', c.active,
        'start', coalesce(to_char(c.start_time, 'HH24:MI'), ''),
        'finish', to_char(c.finish_time, 'HH24:MI'),
        'grace', c.grace_min, 'rate', c.hourly_rate, 'maxHours', c.max_hours,
        'countFrom', c.count_from, 'sharedHours', c.shared_hours,
        'defaultListId', c.default_list_id, 'updatedAt', c.updated_at,
        'surgeons', coalesce((select jsonb_agg(jsonb_build_object('name', s.surgeon, 'terms', s.terms) order by lower(s.surgeon))
                              from tml_company_surgeons s where s.company_id = c.id), '[]'::jsonb)
      ) order by lower(c.name)) from tml_companies c), '[]'::jsonb),
    'lists', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'name', l.name, 'companyId', l.company_id, 'surgeon', l.surgeon, 'updatedAt', l.updated_at,
        'items', coalesce((select jsonb_agg(jsonb_build_object(
              'itemId', i.item_id, 'selected', i.selected,
              'prices', coalesce((select jsonb_agg(jsonb_build_object('price', p.price, 'from', p.from_date) order by p.from_date desc)
                                  from tml_list_prices p where p.list_id = l.id and p.item_id = i.item_id), '[]'::jsonb)))
            from tml_list_items i where i.list_id = l.id), '[]'::jsonb)
      ) order by lower(l.name)) from tml_lists l), '[]'::jsonb),
    'exclusions', coalesce((select jsonb_agg(jsonb_build_object(
        'id', x.id, 'companyId', x.company_id, 'kind', x.kind, 'date', x.on_date, 'pat', x.pat,
        'surgeon', x.surgeon, 'reason', x.reason, 'by', x.set_by) order by x.on_date, x.created_at)
        from tml_exclusions x), '[]'::jsonb),
    'names', coalesce((select jsonb_agg(jsonb_build_object(
        'a', n.name_a, 'b', n.name_b, 'decision', n.decision, 'canonical', n.canonical))
        from tml_name_decisions n), '[]'::jsonb)
  );
end;
$$;

-- What was used in a period, for the chosen items. One jsonb value, so the 1000-row limit on
-- ordinary responses can never cut a report short. Older lines with no item link are matched by
-- their code or name.
create or replace function tml_report_lines(p_from date, p_to date, p_item_ids uuid[], p_codes text[], p_names text[])
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform tml_gate();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', pl.id, 'procedureId', p.id, 'date', p.date, 'surgeon', p.surgeon, 'procedure', p.procedure_name,
      'pat', p.patient_ref, 'room', p.room, 'itemId', pl.item_id, 'code', pl.code, 'name', pl.name,
      'tracker', pl.tracker, 'qty', pl.qty, 'billPrice', pl.bill_price) order by p.date, pl.ts)
    from procedure_lines pl
    join procedures p on p.id = pl.procedure_id
    where p.date between p_from and p_to
      and (pl.item_id = any(p_item_ids)
           or (pl.item_id is null and (lower(btrim(pl.code)) = any(p_codes) or lower(btrim(pl.name)) = any(p_names))))),
    '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------- companies
create or replace function tml_company_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_by text := tml_gate();
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_now timestamptz;
  s jsonb;
begin
  if btrim(coalesce(p->>'name', '')) = '' then raise exception 'Enter a company name'; end if;
  if nullif(p->>'finish', '') is null or nullif(p->>'grace', '') is null or nullif(p->>'rate', '') is null
     or nullif(p->>'maxHours', '') is null or nullif(p->>'sharedHours', '') is null then
    raise exception 'Enter all the over-run terms';
  end if;
  if exists (select 1 from tml_companies c where lower(btrim(c.name)) = lower(btrim(p->>'name')) and c.id is distinct from v_id) then
    raise exception 'A company with this name already exists';
  end if;
  if v_id is null then
    insert into tml_companies (name, finish_time, grace_min, hourly_rate, max_hours, shared_hours)
    values (btrim(p->>'name'), (p->>'finish')::time, (p->>'grace')::int, (p->>'rate')::numeric, (p->>'maxHours')::int, (p->>'sharedHours')::numeric)
    returning id into v_id;
  else
    select updated_at into v_now from tml_companies where id = v_id for update;
    if not found then raise exception 'This company no longer exists. Refresh the page'; end if;
    if p ? 'updatedAt' and (p->>'updatedAt')::timestamptz is distinct from v_now then
      raise exception 'This company was changed on another screen. Refresh the page and try again';
    end if;
  end if;
  update tml_companies set
    name = btrim(p->>'name'),
    active = coalesce((p->>'active')::boolean, true),
    start_time = nullif(p->>'start', '')::time,
    finish_time = (p->>'finish')::time,
    grace_min = (p->>'grace')::int,
    hourly_rate = (p->>'rate')::numeric,
    max_hours = (p->>'maxHours')::int,
    count_from = coalesce(nullif(p->>'countFrom', ''), 'finish'),
    shared_hours = (p->>'sharedHours')::numeric,
    default_list_id = nullif(p->>'defaultListId', '')::uuid,
    updated_at = clock_timestamp()
  where id = v_id;
  delete from tml_company_surgeons where company_id = v_id;
  for s in select * from jsonb_array_elements(coalesce(p->'surgeons', '[]'::jsonb)) loop
    if btrim(coalesce(s->>'name', '')) <> '' then
      insert into tml_company_surgeons (company_id, surgeon, terms)
      values (v_id, btrim(s->>'name'), case when jsonb_typeof(s->'terms') = 'object' then s->'terms' end)
      on conflict do nothing;
    end if;
  end loop;
  insert into activity_log (activity, name, by, note)
  values ('TML company saved', btrim(p->>'name'), v_by, (select count(*) from tml_company_surgeons where company_id = v_id) || ' surgeons');
  return v_id;
end;
$$;

create or replace function tml_company_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_by text := tml_gate(); v_name text;
begin
  delete from tml_companies where id = p_id returning name into v_name;
  if v_name is not null then
    insert into activity_log (activity, name, by) values ('TML company deleted', v_name, v_by);
  end if;
end;
$$;

create or replace function tml_default_terms_save(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_by text := tml_gate();
begin
  if nullif(p->>'finish', '') is null or nullif(p->>'grace', '') is null or nullif(p->>'rate', '') is null
     or nullif(p->>'maxHours', '') is null or nullif(p->>'sharedHours', '') is null then
    raise exception 'Enter all the over-run terms';
  end if;
  insert into tml_settings (key, value)
  values ('default_terms', jsonb_build_object('start', coalesce(p->>'start', ''), 'finish', p->>'finish', 'grace', (p->>'grace')::int,
          'rate', (p->>'rate')::numeric, 'maxHours', (p->>'maxHours')::int, 'countFrom', coalesce(nullif(p->>'countFrom', ''), 'finish'), 'sharedHours', (p->>'sharedHours')::numeric))
  on conflict (key) do update set value = excluded.value, updated_at = clock_timestamp();
  insert into activity_log (activity, by) values ('TML default terms saved', v_by);
end;
$$;

-- ---------------------------------------------------------------- item lists and prices
create or replace function tml_list_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_by text := tml_gate();
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_now timestamptz;
begin
  if btrim(coalesce(p->>'name', '')) = '' then raise exception 'Enter a name for the list'; end if;
  if exists (select 1 from tml_lists l where lower(btrim(l.name)) = lower(btrim(p->>'name')) and l.id is distinct from v_id) then
    raise exception 'A list with this name already exists';
  end if;
  if v_id is null then
    insert into tml_lists (name) values (btrim(p->>'name')) returning id into v_id;
  else
    select updated_at into v_now from tml_lists where id = v_id for update;
    if not found then raise exception 'This list no longer exists. Refresh the page'; end if;
    if p ? 'updatedAt' and (p->>'updatedAt')::timestamptz is distinct from v_now then
      raise exception 'This list was changed on another screen. Refresh the page and try again';
    end if;
  end if;
  update tml_lists set
    name = btrim(p->>'name'),
    company_id = nullif(p->>'companyId', '')::uuid,
    surgeon = nullif(btrim(coalesce(p->>'surgeon', '')), ''),
    updated_at = clock_timestamp()
  where id = v_id;
  -- an item taken off the list keeps its prices, in case it is put back
  delete from tml_list_items where list_id = v_id;
  insert into tml_list_items (list_id, item_id, selected)
  select v_id, (x->>'itemId')::uuid, coalesce((x->>'selected')::boolean, true)
  from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) x
  on conflict do nothing;
  insert into activity_log (activity, name, by, note)
  values ('TML list saved', btrim(p->>'name'), v_by, (select count(*) from tml_list_items where list_id = v_id) || ' items');
  return v_id;
end;
$$;

create or replace function tml_list_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_by text := tml_gate(); v_name text;
begin
  delete from tml_lists where id = p_id returning name into v_name;
  if v_name is not null then
    insert into activity_log (activity, name, by) values ('TML list deleted', v_name, v_by);
  end if;
end;
$$;

-- p_prices: [{itemId, price, from}]. No date = in force for every date.
create or replace function tml_prices_set(p_list uuid, p_prices jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare v_by text := tml_gate(); x jsonb; n int := 0;
begin
  if not exists (select 1 from tml_lists where id = p_list) then
    raise exception 'This list no longer exists. Refresh the page';
  end if;
  for x in select * from jsonb_array_elements(coalesce(p_prices, '[]'::jsonb)) loop
    if (x->>'price')::numeric < 0 then raise exception 'A price cannot be negative'; end if;
    insert into tml_list_prices (list_id, item_id, price, from_date, set_by)
    values (p_list, (x->>'itemId')::uuid, round((x->>'price')::numeric, 2),
            coalesce(nullif(x->>'from', '')::date, '1900-01-01'), v_by)
    on conflict (list_id, item_id, from_date)
    do update set price = excluded.price, set_by = excluded.set_by, set_at = clock_timestamp();
    n := n + 1;
  end loop;
  if n > 0 then
    insert into activity_log (activity, name, by, note)
    values ('TML prices set', (select name from tml_lists where id = p_list), v_by, n || ' prices');
  end if;
  return n;
end;
$$;

-- ---------------------------------------------------------------- taken out of a report
create or replace function tml_exclusion_add(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_by text := tml_gate(); v_id uuid;
begin
  if btrim(coalesce(p->>'reason', '')) = '' then raise exception 'Give a reason'; end if;
  insert into tml_exclusions (company_id, kind, on_date, pat, surgeon, reason, set_by)
  values ((p->>'companyId')::uuid, p->>'kind', (p->>'date')::date,
          case when p->>'kind' = 'patient' then nullif(btrim(p->>'pat'), '') end,
          case when p->>'kind' = 'surgeon' then nullif(btrim(p->>'surgeon'), '') end,
          btrim(p->>'reason'), v_by)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function tml_exclusion_remove(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform tml_gate();
  delete from tml_exclusions where id = p_id;
end;
$$;

-- ---------------------------------------------------------------- surgeon names
-- 'different' is remembered. 'same' is remembered and also combines the names in this database:
-- the surgeon list, costing cases, company lists and item lists all move to the correct name.
create or replace function tml_name_decide(p_a text, p_b text, p_decision text, p_canonical text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_by text := tml_gate();
  v_a text := lower(regexp_replace(btrim(p_a), '\s+', ' ', 'g'));
  v_b text := lower(regexp_replace(btrim(p_b), '\s+', ' ', 'g'));
  v_x text; v_y text;
  v_name text := nullif(regexp_replace(btrim(coalesce(p_canonical, '')), '\s+', ' ', 'g'), '');
  v_key text;
  v_canon uuid;
  v_old text;
begin
  if v_a = '' or v_b = '' or v_a = v_b then raise exception 'Choose two different names'; end if;
  if p_decision not in ('same', 'different') then raise exception 'Unknown decision'; end if;
  if p_decision = 'same' and v_name is null then raise exception 'Choose the correct name'; end if;
  v_x := least(v_a, v_b); v_y := greatest(v_a, v_b);

  insert into tml_name_decisions (name_a, name_b, decision, canonical, set_by)
  values (v_x, v_y, p_decision, case when p_decision = 'same' then v_name end, v_by)
  on conflict (name_a, name_b) do update
    set decision = excluded.decision, canonical = excluded.canonical, set_by = excluded.set_by, created_at = clock_timestamp();

  if p_decision = 'same' then
    v_key := lower(v_name);
    select id, name into v_canon, v_name from surgeons where lower(btrim(name)) = v_key
      order by (name = v_name) desc limit 1;
    if v_canon is null then
      v_name := regexp_replace(btrim(p_canonical), '\s+', ' ', 'g');
      insert into surgeons (name) values (v_name) returning id into v_canon;
    end if;
    foreach v_old in array array[v_x, v_y] loop
      continue when v_old = v_key;
      update procedures set surgeon = v_name, surgeon_id = v_canon
      where lower(regexp_replace(btrim(coalesce(surgeon, '')), '\s+', ' ', 'g')) = v_old
         or surgeon_id in (select id from surgeons where lower(regexp_replace(btrim(name), '\s+', ' ', 'g')) = v_old and id <> v_canon);
      delete from surgeons where lower(regexp_replace(btrim(name), '\s+', ' ', 'g')) = v_old and id <> v_canon;
      delete from tml_company_surgeons s
       where lower(btrim(s.surgeon)) = v_old
         and exists (select 1 from tml_company_surgeons t where t.company_id = s.company_id and lower(btrim(t.surgeon)) = v_key);
      update tml_company_surgeons set surgeon = v_name where lower(btrim(surgeon)) = v_old;
      update tml_lists set surgeon = v_name where lower(btrim(coalesce(surgeon, ''))) = v_old;
      update tml_exclusions set surgeon = v_name where lower(btrim(coalesce(surgeon, ''))) = v_old;
    end loop;
  end if;
  insert into activity_log (activity, name, by, note)
  values ('TML surgeon names', p_a || ' / ' || p_b, v_by,
          case when p_decision = 'same' then 'Same person: ' || v_name else 'Different people' end);
end;
$$;

-- every correction made to the theatre sheet from the report: [{date, pat, field, old, new}]
create or replace function tml_log_fixes(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_by text := tml_gate();
begin
  insert into tml_fix_log (by, on_date, pat, field, old_value, new_value)
  select v_by, x->>'date', x->>'pat', x->>'field', x->>'old', x->>'new'
  from jsonb_array_elements(coalesce(p, '[]'::jsonb)) x;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['tml_get_config()', 'tml_report_lines(date,date,uuid[],text[],text[])',
    'tml_company_save(jsonb)', 'tml_company_delete(uuid)', 'tml_default_terms_save(jsonb)', 'tml_list_save(jsonb)', 'tml_list_delete(uuid)',
    'tml_prices_set(uuid,jsonb)', 'tml_exclusion_add(jsonb)', 'tml_exclusion_remove(uuid)',
    'tml_name_decide(text,text,text,text)', 'tml_log_fixes(jsonb)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
