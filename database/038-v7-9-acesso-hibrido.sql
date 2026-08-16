begin;

alter table public.members add column if not exists username text;
alter table public.members add column if not exists access_status text not null default 'no_access';
alter table public.members add column if not exists access_created_at timestamptz;
alter table public.members add constraint members_access_status_check
 check(access_status in('no_access','temporary_password','active','blocked'));
create unique index if not exists members_username_uidx on public.members(lower(username)) where username is not null;

alter table public.profiles add column if not exists must_change_password boolean not null default false;

create or replace function public.normalize_member_username(p_value text)
returns text language sql immutable set search_path=public as $$
 select trim(both '.' from regexp_replace(translate(lower(trim(coalesce(p_value,''))),
 'áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc'),'[^a-z0-9._-]+','','g'));
$$;

create or replace function public.resolve_member_login(p_username text)
returns text language plpgsql security definer set search_path=public as $$
declare u text;
begin
 u:=public.normalize_member_username(p_username);
 if length(u)<3 then return null; end if;
 if not exists(select 1 from members where lower(username)=u and status<>'dismissed' and access_status<>'blocked') then return null; end if;
 return u||'@login.distrito.invalid';
end $$;

create or replace function public.mark_own_password_changed()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Sessão inválida.'; end if;
 update profiles set must_change_password=false where id=auth.uid();
 update members set access_status='active',updated_at=now() where profile_id=auth.uid();
 return jsonb_build_object('success',true);
end $$;

revoke all on function public.resolve_member_login(text) from public;
grant execute on function public.resolve_member_login(text) to anon,authenticated;
revoke all on function public.mark_own_password_changed() from public;
grant execute on function public.mark_own_password_changed() to authenticated;
grant execute on function public.normalize_member_username(text) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
