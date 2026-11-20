-- Takes the admin role away from every temporary test account, after a UAT run.
-- Safe to run when there is nothing to remove. Real admins are not touched: only
-- accounts whose email starts 'agent-test+' are affected.

delete from public.user_role r
using auth.users u
where u.id = r.profile_id
  and u.email like 'agent-test+%';

select 'Admins now: ' || count(*)::text
       || ', of which test accounts: '
       || (count(*) filter (where u.email like 'agent-test+%'))::text as result
from public.user_role r join auth.users u on u.id = r.profile_id
where r.role = 'admin';
