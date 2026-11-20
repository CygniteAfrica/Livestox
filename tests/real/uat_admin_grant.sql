-- Gives the admin role to ONE temporary test account, for a UAT run on Lovable.
--
-- Nothing in the app can make an admin, by design, so a test of the admin screens
-- needs this done by hand. Run it in the SQL editor right after Lovable has
-- created its first temporary test user and before it creates any other.
--
-- It refuses to act unless exactly one account qualifies: an email starting
-- 'agent-test+', created in the last 15 minutes, with no party yet and no role.
-- Take the role away afterwards with uat_admin_revoke.sql.

do $$
declare
  v_ids uuid[];
begin
  select array_agg(u.id) into v_ids
  from auth.users u
  where u.email like 'agent-test+%'
    and u.created_at > now() - interval '15 minutes'
    and not exists (select 1 from public.party_member m where m.profile_id = u.id)
    and not exists (select 1 from public.user_role r where r.profile_id = u.id);

  if coalesce(array_length(v_ids, 1), 0) <> 1 then
    raise exception 'UAT_ADMIN_NOT_GRANTED: % accounts qualify, expected exactly 1', coalesce(array_length(v_ids, 1), 0);
  end if;

  insert into public.user_role (profile_id, role) values (v_ids[1], 'admin');
end $$;

select 'UAT admin granted to ' || left(u.email, 14) || '...' as result
from public.user_role r join auth.users u on u.id = r.profile_id
where u.email like 'agent-test+%';
