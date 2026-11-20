-- LiveStox increment 7: Kenya, and which countries the app offers.
--
-- The core was seeded with one country, Ethiopia, from the SSA workbook. The app
-- is being stitched together for Kenya first, priced in Kenya shillings. This
-- migration adds Kenya and gives every country an 'open' switch:
--
--   * a visitor or signed-in user sees only open countries in the country list;
--   * a farm or other place can be created only in an open country;
--   * an admin opens or closes a country with admin_set_country_open.
--
-- Kenya is open. Ethiopia stays in the table, closed, until it is launched.
-- Nothing is deleted. Opening a country later is one function call.

alter table public.country add column is_open boolean not null default false;

insert into public.country (code, name, currency, level_names, time_zone, is_open)
values ('KE', 'Kenya', 'KES', array['County', 'Sub-county', 'Ward', 'Village'], 'Africa/Nairobi', true);

drop policy country_read on public.country;
create policy country_read on public.country for select to anon, authenticated
  using (is_open);
create policy country_read_admin on public.country for select to authenticated
  using (public.is_admin());

-- The rule lives here, not in the country picker on a screen.
create function public.place_country_must_be_open() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.country_code is not null
     and (tg_op = 'INSERT' or new.country_code is distinct from old.country_code)
     and not exists (select 1 from public.country c where c.code = new.country_code and c.is_open) then
    raise exception 'COUNTRY_NOT_OPEN';
  end if;
  return new;
end $$;

create trigger place_country_open
  before insert or update of country_code on public.place
  for each row execute function public.place_country_must_be_open();

create function public.admin_set_country_open(p_country_code text, p_open boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  update public.country set is_open = p_open where code = upper(p_country_code);
  if not found then
    raise exception 'COUNTRY_NOT_FOUND';
  end if;
end $$;

-- New functions pick up the database's default grants. Take them back and grant
-- only what is meant, as the hardening migration does for everything before it.
revoke execute on function public.place_country_must_be_open() from public, anon, authenticated;
revoke execute on function public.admin_set_country_open(text, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_country_open(text, boolean) to authenticated, service_role;
grant execute on function public.place_country_must_be_open() to service_role;

notify pgrst, 'reload schema';
