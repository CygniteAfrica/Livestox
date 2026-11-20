-- LiveStox increment 8: let an invited person see who is inviting them.
--
-- An invitation to join a party, or to work on a farm, is addressed to an email
-- or phone number. Until it is accepted the invited person belongs to nothing,
-- so the access rules rightly stop them reading the party or the farm. The inbox
-- could therefore only say 'Join a team' or 'Farm invitation'.
--
-- my_invitations() returns the caller's own open invitations with just enough to
-- decide: the name of the party, the name of the farm, the role offered, and the
-- display name of whoever sent it. It matches on the caller's confirmed email or
-- phone, exactly as accepting does. It shows nothing else about the party or farm.

create function public.my_invitations() returns table (
  invitation_kind text,
  invitation_id uuid,
  offered_role text,
  party_name text,
  place_name text,
  invited_by_name text,
  invited_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select 'party'::text, m.id, m.member_role, p.full_name, null::text,
         (select pr.display_name from public.profile pr where pr.id = m.created_by),
         m.created_at
  from public.party_member m
  join public.party p on p.id = m.party_id
  where m.status = 'invited'
    and m.invited_contact = any (public.my_contacts())
  union all
  select 'place'::text, a.id, a.access_role, kp.full_name, pl.name,
         (select pr.display_name from public.profile pr where pr.id = a.created_by),
         a.created_at
  from public.place_access a
  join public.place pl on pl.id = a.place_id
  join public.party kp on kp.id = pl.keeper_party_id
  where a.status = 'invited'
    and a.invited_contact = any (public.my_contacts())
  order by 7 desc, 2
$$;

revoke execute on function public.my_invitations() from public, anon, authenticated;
grant execute on function public.my_invitations() to authenticated, service_role;

notify pgrst, 'reload schema';
