begin;

-- V7.8 — membros vinculados ao Discord e metas auditáveis por item.
alter table public.profiles add column if not exists discord_user_id text;
alter table public.profiles add column if not exists discord_channel_id text;
alter table public.profiles add column if not exists member_code text;
create unique index if not exists profiles_discord_user_uidx on public.profiles(discord_user_id) where discord_user_id is not null;
create unique index if not exists profiles_discord_channel_uidx on public.profiles(discord_channel_id) where discord_channel_id is not null;

insert into public.user_roles(name,description) values
 ('membro','Membro: calculadora, painel e metas próprias.'),
 ('lideranca','Liderança 01, 02 ou 03 com acesso administrativo completo.')
on conflict(name) do update set description=excluded.description;

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
 select public.has_role('admin') or public.has_role('lideranca') or public.has_role('01') or public.has_role('02') or public.has_role('03');
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path=public as $$
 select public.is_admin() or public.has_role('gerente') or public.has_role('management');
$$;

create table if not exists public.members(
 id uuid primary key default gen_random_uuid(),profile_id uuid unique references public.profiles(id) on delete set null,
 name text not null,member_code text,email text,access_level text not null default 'membro'
 check(access_level in('membro','gerencia','01','02','03')),
 discord_user_id text,discord_channel_id text,status text not null default 'active'
 check(status in('active','absent','away','dismissed')),
 joined_at date,dismissed_at timestamptz,dismissal_reason text,dismissed_by uuid references public.profiles(id),
 created_by uuid references public.profiles(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create unique index if not exists members_discord_user_uidx on public.members(discord_user_id) where discord_user_id is not null;
create unique index if not exists members_discord_channel_uidx on public.members(discord_channel_id) where discord_channel_id is not null;
insert into public.members(profile_id,name,member_code,email,discord_user_id,discord_channel_id,status)
select id,coalesce(nullif(trim(name),''),email,'Membro'),member_code,email,discord_user_id,discord_channel_id,
 case when coalesce(is_active,true) then 'active' else 'dismissed' end from public.profiles on conflict(profile_id) do nothing;

alter table public.weekly_goals alter column target_amount set default 0;
alter table public.weekly_goals drop constraint if exists weekly_goals_target_amount_check;
alter table public.weekly_goals add constraint weekly_goals_target_amount_check check(target_amount>=0);
alter table public.weekly_goals add column if not exists reward_name text;
alter table public.weekly_goals add column if not exists reminder_at timestamptz;
alter table public.weekly_goals add column if not exists closed_at timestamptz;

alter table public.weekly_goal_members add column if not exists status text not null default 'in_progress';
alter table public.weekly_goal_members add column if not exists discord_channel_id text;
alter table public.weekly_goal_members add column if not exists absence_id uuid;
alter table public.weekly_goal_members add column if not exists result_locked_at timestamptz;
alter table public.weekly_goal_members add column if not exists reward_eligible boolean not null default false;
alter table public.weekly_goal_members add column if not exists member_record_id uuid references public.members(id) on delete set null;
alter table public.weekly_goal_members drop constraint if exists weekly_goal_members_status_check;
alter table public.weekly_goal_members add constraint weekly_goal_members_status_check
 check(status in('in_progress','completed','completed_with_extra','absent','debt','excused'));

create table if not exists public.member_absences(
 id uuid primary key default gen_random_uuid(),member_id uuid references public.members(id) on delete cascade,profile_id uuid references public.profiles(id) on delete set null,
 discord_user_id text, member_name text not null, start_date date not null,end_date date not null,
 reason text not null, approved_by uuid references public.profiles(id), created_at timestamptz not null default now(),
 constraint member_absences_period_check check(end_date>=start_date)
);

create table if not exists public.weekly_goal_requirements(
 id uuid primary key default gen_random_uuid(), goal_id uuid not null references public.weekly_goals(id) on delete cascade,
 inventory_item_id uuid not null references public.inventory_items(id), required_quantity numeric not null check(required_quantity>0),
 created_at timestamptz not null default now(), unique(goal_id,inventory_item_id)
);

create table if not exists public.weekly_goal_submissions(
 id uuid primary key default gen_random_uuid(), goal_id uuid not null references public.weekly_goals(id) on delete cascade,
 member_id uuid not null references public.weekly_goal_members(id) on delete cascade,
 discord_message_id text,discord_channel_id text,discord_user_id text,
 evidence_url text,evidence_storage_path text,original_text text,
 status text not null default 'accepted' check(status in('pending','accepted','rejected','corrected')),
 submitted_at timestamptz not null default now(),created_by uuid references public.profiles(id),
 reviewed_by uuid references public.profiles(id),reviewed_at timestamptz,notes text
);
create unique index if not exists weekly_goal_submission_message_uidx on public.weekly_goal_submissions(discord_message_id) where discord_message_id is not null;

create table if not exists public.weekly_goal_submission_items(
 id uuid primary key default gen_random_uuid(),submission_id uuid not null references public.weekly_goal_submissions(id) on delete cascade,
 inventory_item_id uuid not null references public.inventory_items(id),quantity numeric not null check(quantity>0),
 classification text not null check(classification in('goal','outside_goal')),created_at timestamptz not null default now(),
 unique(submission_id,inventory_item_id)
);

create table if not exists public.weekly_goal_ledger(
 id uuid primary key default gen_random_uuid(),goal_id uuid not null references public.weekly_goals(id) on delete cascade,
 member_id uuid not null references public.weekly_goal_members(id) on delete cascade,
 inventory_item_id uuid references public.inventory_items(id),entry_type text not null
 check(entry_type in('submission','correction','carry_in','carry_out')),
 quantity numeric not null,submission_id uuid references public.weekly_goal_submissions(id),
 operation_key text,reason text,created_by uuid references public.profiles(id),created_at timestamptz not null default now()
);
create unique index if not exists weekly_goal_ledger_operation_uidx on public.weekly_goal_ledger(operation_key) where operation_key is not null;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('goal-evidence','goal-evidence',true,10485760,array['image/png','image/jpeg','image/webp'])
on conflict(id) do update set public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create table if not exists public.weekly_goal_notifications(
 id uuid primary key default gen_random_uuid(),goal_id uuid not null references public.weekly_goals(id) on delete cascade,
 member_id uuid not null references public.weekly_goal_members(id) on delete cascade,
 notification_type text not null check(notification_type in('opening','reminder','closed')),
 discord_message_id text,sent_at timestamptz not null default now(),unique(goal_id,member_id,notification_type)
);

create or replace view public.weekly_goal_member_progress with(security_invoker=true) as
select gm.id member_id,gm.goal_id,gm.member_name,gm.discord_user_id,gm.discord_channel_id,gm.status,gm.reward_eligible,
 r.inventory_item_id,i.name item_name,r.required_quantity,
 coalesce(sum(l.quantity) filter(where l.entry_type in('submission','correction','carry_in')),0) credited_quantity,
 greatest(r.required_quantity-coalesce(sum(l.quantity) filter(where l.entry_type in('submission','correction','carry_in')),0),0) remaining_quantity,
 greatest(coalesce(sum(l.quantity) filter(where l.entry_type in('submission','correction','carry_in')),0)-r.required_quantity,0) extra_quantity
from public.weekly_goal_members gm join public.weekly_goal_requirements r on r.goal_id=gm.goal_id
join public.inventory_items i on i.id=r.inventory_item_id
left join public.weekly_goal_ledger l on l.member_id=gm.id and l.inventory_item_id=r.inventory_item_id
group by gm.id,r.inventory_item_id,i.name,r.required_quantity;

create or replace function public.register_weekly_goal_submission(
 p_discord_user_id text,p_discord_channel_id text,p_discord_message_id text,p_original_text text,
 p_evidence_url text,p_evidence_storage_path text,p_items jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare g public.weekly_goals;m public.weekly_goal_members;s public.weekly_goal_submissions;x jsonb;iid uuid;q numeric;kind text;
begin
 select * into g from weekly_goals where status='active' and current_date between start_date and end_date order by start_date desc limit 1;
 if not found then raise exception 'Não existe meta ativa para hoje.'; end if;
 select * into m from weekly_goal_members where goal_id=g.id and (discord_user_id=trim(p_discord_user_id) or discord_channel_id=trim(p_discord_channel_id)) limit 1;
 if not found then raise exception 'Seu Discord/canal não está vinculado a esta meta.'; end if;
 if m.status in('absent','excused') then raise exception 'Este membro está dispensado desta meta.'; end if;
 insert into weekly_goal_submissions(goal_id,member_id,discord_message_id,discord_channel_id,discord_user_id,evidence_url,evidence_storage_path,original_text)
 values(g.id,m.id,p_discord_message_id,p_discord_channel_id,p_discord_user_id,p_evidence_url,p_evidence_storage_path,p_original_text) returning * into s;
 for x in select * from jsonb_array_elements(p_items) loop
  iid:=(x->>'item_id')::uuid;q:=(x->>'quantity')::numeric;
  kind:=case when exists(select 1 from weekly_goal_requirements where goal_id=g.id and inventory_item_id=iid) then 'goal' else 'outside_goal' end;
  insert into weekly_goal_submission_items(submission_id,inventory_item_id,quantity,classification) values(s.id,iid,q,kind);
  insert into weekly_goal_ledger(goal_id,member_id,inventory_item_id,entry_type,quantity,submission_id,operation_key,reason)
  values(g.id,m.id,iid,'submission',q,s.id,'discord-goal:'||p_discord_message_id||':'||iid,'Entrega pelo Discord');
 end loop;
 return jsonb_build_object('success',true,'submission_id',s.id,'member_id',m.id,'goal_id',g.id);
end $$;

create or replace function public.set_weekly_goal_member_status(p_member_id uuid,p_status text,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.is_staff() then raise exception 'Sem permissão.'; end if;
 if p_status not in('in_progress','completed','completed_with_extra','absent','debt','excused') then raise exception 'Situação inválida.'; end if;
 update weekly_goal_members set status=p_status,notes=nullif(trim(coalesce(p_reason,'')),''),updated_by=auth.uid(),updated_at=now() where id=p_member_id;
 if not found then raise exception 'Membro não encontrado.'; end if;
 insert into activity_logs(user_id,action,entity_type,entity_id,description,new_data)
 values(auth.uid(),'update','weekly_goal_member',p_member_id,'Situação da meta alterada.',jsonb_build_object('status',p_status,'reason',p_reason));
 return jsonb_build_object('success',true);
end $$;

create or replace function public.create_weekly_goal_v2(
 p_start_date date,p_end_date date,p_title text,p_target_amount numeric,p_reward_name text,p_requirements jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare g weekly_goals;x jsonb;n integer:=0;
begin
 if not public.is_staff() then raise exception 'Sem permissão.'; end if;
 if p_end_date-p_start_date<>7 then raise exception 'A meta deve ter exatamente 7 dias.'; end if;
 update weekly_goals set status='closed',closed_at=coalesce(closed_at,now()),updated_at=now() where status='active';
 insert into weekly_goals(title,start_date,end_date,target_amount,status,reward_name,reminder_at,created_by)
 values(coalesce(nullif(trim(p_title),''),'Meta semanal'),p_start_date,p_end_date,coalesce(p_target_amount,0),'active',nullif(trim(coalesce(p_reward_name,'')),''),
        (p_end_date::timestamp-interval '1 day') at time zone 'America/Sao_Paulo',auth.uid()) returning * into g;
 for x in select * from jsonb_array_elements(coalesce(p_requirements,'[]')) loop
  insert into weekly_goal_requirements(goal_id,inventory_item_id,required_quantity)
  values(g.id,(x->>'item_id')::uuid,(x->>'quantity')::numeric);
 end loop;
 insert into weekly_goal_members(goal_id,profile_id,member_record_id,member_name,discord_user_id,discord_channel_id,updated_by,status)
 select g.id,p.profile_id,p.id,p.name,p.discord_user_id,p.discord_channel_id,auth.uid(),
  case when exists(select 1 from member_absences a where (a.member_id=p.id or a.profile_id=p.profile_id or a.discord_user_id=p.discord_user_id)
   and daterange(a.start_date,a.end_date,'[]') && daterange(p_start_date,p_end_date,'[]')) then 'absent' else 'in_progress' end
 from members p where p.status='active' on conflict do nothing;
 get diagnostics n=row_count;
 return jsonb_build_object('success',true,'id',g.id,'members_added',n);
end $$;

create or replace function public.register_member_absence(p_member_id uuid,p_start_date date,p_end_date date,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare a member_absences;m members;
begin
 if not public.is_staff() then raise exception 'Sem permissão.'; end if;
 select * into m from members where id=p_member_id;
 if not found then raise exception 'Membro não encontrado.'; end if;
 insert into member_absences(member_id,profile_id,discord_user_id,member_name,start_date,end_date,reason,approved_by)
 values(m.id,m.profile_id,m.discord_user_id,m.name,p_start_date,p_end_date,trim(p_reason),auth.uid()) returning * into a;
 update members set status='absent',updated_at=now() where id=m.id;
 update weekly_goal_members gm set status='absent',absence_id=a.id,notes=a.reason,updated_by=auth.uid(),updated_at=now()
 from weekly_goals g where gm.goal_id=g.id and gm.member_record_id=m.id and g.status='active'
 and daterange(a.start_date,a.end_date,'[]') && daterange(g.start_date,g.end_date,'[]');
 return jsonb_build_object('success',true,'id',a.id);
end $$;

create or replace function public.save_member(
 p_id uuid,p_name text,p_member_code text,p_email text,p_access_level text,p_discord_user_id text,p_discord_channel_id text,p_status text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare m members;
begin
 if not public.is_admin() and not public.has_role('lideranca') then raise exception 'Apenas a liderança pode gerenciar usuários.'; end if;
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
 end if;
 insert into activity_logs(user_id,action,entity_type,entity_id,description,new_data)
 values(auth.uid(),case when p_id is null then 'create' else 'update' end,'member',m.id,'Cadastro de membro salvo.',to_jsonb(m));
 return jsonb_build_object('success',true,'id',m.id);
end $$;

create or replace function public.dismiss_member(p_member_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare m members;
begin
 if not public.is_admin() and not public.has_role('lideranca') then raise exception 'Apenas a liderança pode exonerar.'; end if;
 update members set status='dismissed',dismissed_at=now(),dismissal_reason=nullif(trim(coalesce(p_reason,'')),''),dismissed_by=auth.uid(),updated_at=now()
 where id=p_member_id returning * into m;
 if not found then raise exception 'Membro não encontrado.'; end if;
 if m.profile_id is not null then update profiles set is_active=false where id=m.profile_id; end if;
 update weekly_goal_members set status='excused',notes='Dispensado por exoneração',updated_by=auth.uid(),updated_at=now()
 where member_record_id=m.id and goal_id in(select id from weekly_goals where status='active');
 insert into activity_logs(user_id,action,entity_type,entity_id,description,new_data)
 values(auth.uid(),'update','member',m.id,'Membro exonerado.',jsonb_build_object('reason',p_reason,'status','dismissed'));
 return jsonb_build_object('success',true);
end $$;

alter table public.member_absences enable row level security;
alter table public.members enable row level security;
alter table public.weekly_goal_requirements enable row level security;
alter table public.weekly_goal_submissions enable row level security;
alter table public.weekly_goal_submission_items enable row level security;
alter table public.weekly_goal_ledger enable row level security;
alter table public.weekly_goal_notifications enable row level security;
create policy "Equipe gerencia ausencias" on public.member_absences for all to authenticated using(public.is_staff()) with check(public.is_staff());
create policy "Equipe consulta membros" on public.members for select to authenticated using(public.is_staff());
create policy "Equipe consulta requisitos" on public.weekly_goal_requirements for select to authenticated using(public.is_staff());
create policy "Equipe consulta entregas" on public.weekly_goal_submissions for select to authenticated using(public.is_staff());
create policy "Equipe consulta itens entregues" on public.weekly_goal_submission_items for select to authenticated using(public.is_staff());
create policy "Equipe consulta ledger" on public.weekly_goal_ledger for select to authenticated using(public.is_staff());
create policy "Equipe consulta notificacoes" on public.weekly_goal_notifications for select to authenticated using(public.is_staff());
grant select,insert,update,delete on public.member_absences to authenticated;
grant select on public.members to authenticated;
grant select on public.weekly_goal_requirements,public.weekly_goal_submissions,public.weekly_goal_submission_items,public.weekly_goal_ledger,public.weekly_goal_notifications to authenticated;
grant execute on function public.register_weekly_goal_submission(text,text,text,text,text,text,jsonb) to service_role;
grant execute on function public.set_weekly_goal_member_status(uuid,text,text) to authenticated;
grant execute on function public.create_weekly_goal_v2(date,date,text,numeric,text,jsonb) to authenticated;
grant execute on function public.register_member_absence(uuid,date,date,text) to authenticated;
grant execute on function public.save_member(uuid,text,text,text,text,text,text,text) to authenticated;
grant execute on function public.dismiss_member(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
