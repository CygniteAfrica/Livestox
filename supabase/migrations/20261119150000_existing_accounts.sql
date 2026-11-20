-- LiveStox increment 6b: carry existing sign-in accounts into the core.
--
-- The core creates a profile when an account is created. Accounts that existed
-- before the core was installed have none, so they are given one here. Where the
-- prototype's profiles and roles were moved to the legacy schema, names, phone
-- numbers and the admin role are carried over from there.
--
-- Farms, animals, diary entries, shares and KYC status are not carried over. The
-- old model and the new one differ too much to copy row for row; that is its own
-- increment. The old rows stay readable in the legacy schema.

insert into public.profile (id, display_name)
select
  u.id,
  coalesce(
    nullif(u.raw_user_meta_data ->> 'display_name', ''),
    nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
    'New user')
from auth.users u
where not exists (select 1 from public.profile p where p.id = u.id);

do $$
begin
  if to_regclass('legacy.profiles') is not null then
    -- A name the person typed beats one guessed from their email address.
    execute $sql$
      update public.profile p
      set display_name = btrim(lp.display_name)
      from legacy.profiles lp
      where lp.id = p.id and nullif(btrim(lp.display_name), '') is not null
    $sql$;
    -- Only phone numbers already in international format pass the core's check.
    execute $sql$
      update public.profile p
      set phone = lp.phone
      from legacy.profiles lp
      where lp.id = p.id and p.phone is null and lp.phone ~ '^\+[1-9][0-9]{6,14}$'
    $sql$;
  end if;

  if to_regclass('legacy.user_roles') is not null then
    execute $sql$
      insert into public.user_role (profile_id, role)
      select distinct r.user_id, 'admin'
      from legacy.user_roles r
      join public.profile p on p.id = r.user_id
      where r.role::text = 'admin'
      on conflict do nothing
    $sql$;
  end if;
end $$;

-- Tell the API layer that tables and functions changed.
notify pgrst, 'reload schema';
