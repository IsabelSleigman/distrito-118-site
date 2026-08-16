begin;

create or replace function public.finish_temporary_password_on_auth_change()
returns trigger language plpgsql security definer set search_path=public,auth as $$
begin
  if old.encrypted_password is distinct from new.encrypted_password then
    update public.profiles set must_change_password=false where id=new.id;
    update public.members set access_status='active',updated_at=now()
    where profile_id=new.id and access_status='temporary_password';
  end if;
  return new;
end $$;

drop trigger if exists finish_temporary_password_after_change on auth.users;
create trigger finish_temporary_password_after_change
after update of encrypted_password on auth.users
for each row execute function public.finish_temporary_password_on_auth_change();

notify pgrst,'reload schema';
commit;
