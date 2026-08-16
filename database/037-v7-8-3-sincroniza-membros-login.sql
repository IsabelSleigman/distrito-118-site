begin;

insert into public.user_roles(name,description) values
 ('membro','Membro com acesso pessoal.'),('gerencia','Gerência operacional.'),
 ('01','Liderança 01.'),('02','Liderança 02.'),('03','Liderança 03.')
on conflict(name) do update set description=excluded.description;

-- Corrige imediatamente os nomes já editados na nova tela.
update public.profiles p set
 name=m.name,member_code=coalesce(m.member_code,p.member_code)
from public.members m where m.profile_id=p.id;

-- Sincroniza os cargos atuais dos cadastros que já possuem conta de acesso.
delete from public.profile_roles pr using public.user_roles ur,public.members m
where pr.role_id=ur.id and pr.profile_id=m.profile_id
and lower(ur.name) in('membro','gerente','gerencia','management','lideranca','01','02','03');
insert into public.profile_roles(profile_id,role_id)
select m.profile_id,r.id from public.members m join public.user_roles r on lower(r.name)=lower(m.access_level)
where m.profile_id is not null on conflict do nothing;

create or replace function public.save_member(
 p_id uuid,p_name text,p_member_code text,p_email text,p_access_level text,p_discord_user_id text,p_discord_channel_id text,p_status text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare m members;r uuid;
begin
 if not public.is_admin() then raise exception 'Apenas a liderança pode gerenciar usuários.'; end if;
 if nullif(trim(p_name),'') is null then raise exception 'Informe o nome.'; end if;
 if p_access_level not in('membro','gerencia','01','02','03') or p_status not in('active','absent','away','dismissed') then raise exception 'Cargo ou situação inválida.'; end if;
 if p_id is null then
  insert into members(name,member_code,email,access_level,discord_user_id,discord_channel_id,status,joined_at,created_by)
  values(trim(p_name),nullif(trim(coalesce(p_member_code,'')),''),nullif(trim(coalesce(p_email,'')),''),p_access_level,
   nullif(trim(coalesce(p_discord_user_id,'')),''),nullif(trim(coalesce(p_discord_channel_id,'')),''),p_status,current_date,auth.uid()) returning * into m;
 else
  update members set name=trim(p_name),member_code=nullif(trim(coalesce(p_member_code,'')),''),email=nullif(trim(coalesce(p_email,'')),''),
   access_level=p_access_level,discord_user_id=nullif(trim(coalesce(p_discord_user_id,'')),''),discord_channel_id=nullif(trim(coalesce(p_discord_channel_id,'')),''),
   status=p_status,updated_at=now() where id=p_id returning * into m;
  if not found then raise exception 'Membro não encontrado.'; end if;
 end if;
 if m.profile_id is not null then
  update profiles set name=m.name,member_code=coalesce(m.member_code,member_code),is_active=(m.status<>'dismissed') where id=m.profile_id;
  delete from profile_roles pr using user_roles ur where pr.profile_id=m.profile_id and pr.role_id=ur.id
   and lower(ur.name) in('membro','gerente','gerencia','management','lideranca','01','02','03');
  select id into r from user_roles where lower(name)=lower(m.access_level) limit 1;
  if r is not null then insert into profile_roles(profile_id,role_id) values(m.profile_id,r) on conflict do nothing; end if;
 end if;
 insert into activity_logs(user_id,action,entity_type,entity_id,description,new_data)
 values(auth.uid(),case when p_id is null then 'create' else 'update' end,'member',m.id,'Cadastro de membro salvo e acesso sincronizado.',to_jsonb(m));
 return jsonb_build_object('success',true,'id',m.id,'profile_id',m.profile_id);
end $$;

grant execute on function public.save_member(uuid,text,text,text,text,text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
