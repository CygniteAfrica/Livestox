-- LiveStox increment 9: a farm's own tag numbers belong to that farm.
--
-- Until now a live tag had to be unique across the whole platform within its
-- scheme. That is right for an official scheme, where a number names one animal
-- in the country. It is wrong for a keeper's own numbering: the second keeper to
-- tag an animal '001' was refused. Found by the review of the first screens.
--
-- From here on:
--   * a tag in the keeper's own scheme (the default, 'life.livestox.local') must
--     be unique among that keeper's live tags only;
--   * a tag in any other scheme stays unique across everyone.
--
-- Each identifier row now carries its keeper, copied from the animal, so the
-- database can enforce this with an index rather than a lookup.

alter table public.animal_identifier add column keeper_party_id uuid references public.party (id);

update public.animal_identifier i
set keeper_party_id = a.keeper_party_id
from public.animal a
where a.id = i.animal_id;

alter table public.animal_identifier alter column keeper_party_id set not null;

create function public.animal_identifier_set_keeper() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select a.keeper_party_id into new.keeper_party_id from public.animal a where a.id = new.animal_id;
  return new;
end $$;

create trigger animal_identifier_keeper
  before insert or update of animal_id, keeper_party_id on public.animal_identifier
  for each row execute function public.animal_identifier_set_keeper();

-- If an animal ever moves to another keeper, its tags move with it.
create function public.animal_keeper_sync_identifiers() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.animal_identifier set keeper_party_id = new.keeper_party_id where animal_id = new.id;
  return new;
end $$;

create trigger animal_keeper_identifiers
  after update of keeper_party_id on public.animal
  for each row when (old.keeper_party_id is distinct from new.keeper_party_id)
  execute function public.animal_keeper_sync_identifiers();

drop index public.animal_identifier_live_tag;

-- The names keep the old prefix so messages that match on it still work.
create unique index animal_identifier_live_tag_shared
  on public.animal_identifier (scheme, value)
  where valid_to is null and scheme <> 'life.livestox.local';
create unique index animal_identifier_live_tag_own
  on public.animal_identifier (keeper_party_id, value)
  where valid_to is null and scheme = 'life.livestox.local';

revoke execute on function public.animal_identifier_set_keeper() from public, anon, authenticated;
revoke execute on function public.animal_keeper_sync_identifiers() from public, anon, authenticated;
grant execute on function public.animal_identifier_set_keeper() to service_role;
grant execute on function public.animal_keeper_sync_identifiers() to service_role;

notify pgrst, 'reload schema';
