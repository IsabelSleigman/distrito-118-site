begin;

-- V8.1 — metas gerais/individuais, histórico e bonificações auditáveis.
alter table public.weekly_goals drop constraint if exists weekly_goals_status_check;
alter table public.weekly_goals add constraint weekly_goals_status_check check(status in('draft','active','closed'));
alter table public.weekly_goals add column if not exists audience_type text not null default 'general'
  check(audience_type in('general','individual','custom'));
alter table public.weekly_goals add column if not exists bonus_inventory_item_id uuid references public.inventory_items(id) on delete set null;
alter table public.weekly_goals add column if not exists bonus_quantity numeric not null default 0 check(bonus_quantity>=0);
alter table public.weekly_goals add column if not exists bonus_notes text;

-- Períodos iguais são válidos: uma meta geral e outras individuais podem coexistir.
drop index if exists public.weekly_goals_period_unique;
create index if not exists weekly_goals_period_idx on public.weekly_goals(start_date,end_date,status);

create table if not exists public.weekly_goal_bonuses(
 id uuid primary key default gen_random_uuid(),
 goal_id uuid not null references public.weekly_goals(id) on delete cascade,
 goal_member_id uuid not null references public.weekly_goal_members(id) on delete cascade,
 inventory_item_id uuid references public.inventory_items(id) on delete set null,
 description text not null,
 quantity numeric not null default 1 check(quantity>0),
 status text not null default 'pending' check(status in('pending','delivered','cancelled')),
 delivered_at timestamptz,
 delivered_by uuid references public.profiles(id) on delete set null,
 notes text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(goal_id,goal_member_id)
);
alter table public.weekly_goal_bonuses enable row level security;
drop policy if exists "Equipe consulta bonificacoes" on public.weekly_goal_bonuses;
create policy "Equipe consulta bonificacoes" on public.weekly_goal_bonuses for select to authenticated using(public.is_staff());
grant select on public.weekly_goal_bonuses to authenticated;

-- O excedente é consumido somente uma vez e mantém rastreabilidade entre as duas metas.
create or replace function public.apply_weekly_goal_carryover(p_goal_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t record;src record;base_credit numeric;other_out numeric;desired numeric;op_base text;n integer:=0;
begin
 if not public.is_staff() and coalesce(auth.role(),'')<>'service_role' then raise exception 'Sem permissão.'; end if;
 for t in
  select gm.id target_member_id,gm.member_record_id,r.inventory_item_id,r.required_quantity,g.start_date
  from weekly_goal_members gm join weekly_goals g on g.id=gm.goal_id
  join weekly_goal_requirements r on r.goal_id=g.id
  where g.id=p_goal_id and gm.member_record_id is not null
 loop
  select pgm.id source_member_id,pr.required_quantity
  into src
  from weekly_goal_members pgm join weekly_goals pg on pg.id=pgm.goal_id
  join weekly_goal_requirements pr on pr.goal_id=pg.id and pr.inventory_item_id=t.inventory_item_id
  where pgm.member_record_id=t.member_record_id and pg.id<>p_goal_id and pg.end_date<=t.start_date
  order by pg.end_date desc,pg.created_at desc limit 1;
  if src.source_member_id is null then continue; end if;
  op_base:='carry:'||src.source_member_id||':'||t.target_member_id||':'||t.inventory_item_id;
  select coalesce(sum(quantity) filter(where entry_type in('submission','correction','carry_in')),0)
  into base_credit from weekly_goal_ledger where member_id=src.source_member_id and inventory_item_id=t.inventory_item_id;
  select coalesce(sum(quantity),0) into other_out from weekly_goal_ledger
  where member_id=src.source_member_id and inventory_item_id=t.inventory_item_id and entry_type='carry_out'
   and operation_key<>op_base||':out';
  desired:=greatest(base_credit-src.required_quantity-other_out,0);
  if desired>0 then
   insert into weekly_goal_ledger(goal_id,member_id,inventory_item_id,entry_type,quantity,operation_key,reason,created_by)
   select goal_id,src.source_member_id,t.inventory_item_id,'carry_out',desired,op_base||':out','Excedente transferido para a meta seguinte',auth.uid()
   from weekly_goal_members where id=src.source_member_id
   on conflict(operation_key) do update set quantity=excluded.quantity,reason=excluded.reason;
   insert into weekly_goal_ledger(goal_id,member_id,inventory_item_id,entry_type,quantity,operation_key,reason,created_by)
   values(p_goal_id,t.target_member_id,t.inventory_item_id,'carry_in',desired,op_base||':in','Crédito excedente da meta anterior',auth.uid())
   on conflict(operation_key) do update set quantity=excluded.quantity,reason=excluded.reason;
   n:=n+1;
  else
   delete from weekly_goal_ledger where operation_key in(op_base||':out',op_base||':in');
  end if;
 end loop;
 return jsonb_build_object('success',true,'credits_applied',n);
end $$;

create or replace view public.weekly_goal_member_progress with(security_invoker=true) as
select gm.id member_id,gm.goal_id,gm.member_name,gm.discord_user_id,gm.discord_channel_id,gm.status,gm.reward_eligible,
 r.inventory_item_id,i.name item_name,r.required_quantity,
 coalesce(sum(case when l.entry_type='carry_out' then -l.quantity when l.entry_type in('submission','correction','carry_in') then l.quantity else 0 end),0) credited_quantity,
 greatest(r.required_quantity-coalesce(sum(case when l.entry_type='carry_out' then -l.quantity when l.entry_type in('submission','correction','carry_in') then l.quantity else 0 end),0),0) remaining_quantity,
 greatest(coalesce(sum(case when l.entry_type='carry_out' then -l.quantity when l.entry_type in('submission','correction','carry_in') then l.quantity else 0 end),0)-r.required_quantity,0) extra_quantity
from weekly_goal_members gm join weekly_goal_requirements r on r.goal_id=gm.goal_id
join inventory_items i on i.id=r.inventory_item_id
left join weekly_goal_ledger l on l.member_id=gm.id and l.inventory_item_id=r.inventory_item_id
group by gm.id,r.inventory_item_id,i.name,r.required_quantity;

create or replace function public.save_weekly_goal_v3(
 p_id uuid,p_start_date date,p_end_date date,p_title text,p_target_amount numeric,
 p_status text,p_audience_type text,p_member_ids jsonb,p_requirements jsonb,
 p_bonus_name text,p_bonus_item_id uuid,p_bonus_quantity numeric,p_bonus_notes text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare g weekly_goals;x jsonb;n integer:=0;mid uuid;m members;
begin
 if not public.is_staff() then raise exception 'Sem permissão.'; end if;
 if p_end_date<=p_start_date then raise exception 'A data final deve ser posterior à inicial.'; end if;
 if p_status not in('draft','active','closed') then raise exception 'Situação inválida.'; end if;
 if p_audience_type not in('general','individual','custom') then raise exception 'Tipo de público inválido.'; end if;
 if p_audience_type in('individual','custom') and jsonb_array_length(coalesce(p_member_ids,'[]'))=0 then raise exception 'Selecione ao menos um participante.'; end if;

 if p_id is null then
  insert into weekly_goals(title,start_date,end_date,target_amount,status,audience_type,reward_name,bonus_inventory_item_id,bonus_quantity,bonus_notes,reminder_at,closed_at,created_by)
  values(coalesce(nullif(trim(p_title),''),'Meta semanal'),p_start_date,p_end_date,coalesce(p_target_amount,0),p_status,p_audience_type,
   nullif(trim(coalesce(p_bonus_name,'')),''),p_bonus_item_id,coalesce(p_bonus_quantity,0),nullif(trim(coalesce(p_bonus_notes,'')),''),
   (p_end_date::timestamp-interval '1 day') at time zone 'America/Sao_Paulo',case when p_status='closed' then now() end,auth.uid()) returning * into g;
 else
  update weekly_goals set title=coalesce(nullif(trim(p_title),''),'Meta semanal'),start_date=p_start_date,end_date=p_end_date,
   target_amount=coalesce(p_target_amount,0),status=p_status,audience_type=p_audience_type,reward_name=nullif(trim(coalesce(p_bonus_name,'')),''),
   bonus_inventory_item_id=p_bonus_item_id,bonus_quantity=coalesce(p_bonus_quantity,0),bonus_notes=nullif(trim(coalesce(p_bonus_notes,'')),''),
   reminder_at=(p_end_date::timestamp-interval '1 day') at time zone 'America/Sao_Paulo',closed_at=case when p_status='closed' then coalesce(closed_at,now()) else null end,updated_at=now()
  where id=p_id returning * into g;
  if not found then raise exception 'Meta não encontrada.'; end if;
  delete from weekly_goal_requirements where goal_id=g.id;
  -- Mantém resultados, mas refaz somente participantes ainda sem entrega/lançamento.
  delete from weekly_goal_members gm where gm.goal_id=g.id
   and not exists(select 1 from weekly_goal_submissions s where s.member_id=gm.id)
   and not exists(select 1 from weekly_goal_ledger l where l.member_id=gm.id);
 end if;

 for x in select * from jsonb_array_elements(coalesce(p_requirements,'[]')) loop
  insert into weekly_goal_requirements(goal_id,inventory_item_id,required_quantity)
  values(g.id,(x->>'item_id')::uuid,(x->>'quantity')::numeric)
  on conflict(goal_id,inventory_item_id) do update set required_quantity=excluded.required_quantity;
 end loop;

 if p_audience_type='general' and jsonb_array_length(coalesce(p_member_ids,'[]'))=0 then
  insert into weekly_goal_members(goal_id,profile_id,member_record_id,member_name,discord_user_id,discord_channel_id,updated_by,status)
  select g.id,m.profile_id,m.id,m.name,m.discord_user_id,m.discord_channel_id,auth.uid(),
   case when exists(select 1 from member_absences a where a.member_id=m.id and daterange(a.start_date,a.end_date,'[]') && daterange(g.start_date,g.end_date,'[]')) then 'absent' else 'in_progress' end
  from members m where m.status='active' and not exists(select 1 from weekly_goal_members gm where gm.goal_id=g.id and gm.member_record_id=m.id);
  get diagnostics n=row_count;
 else
  for x in select * from jsonb_array_elements(coalesce(p_member_ids,'[]')) loop
   mid:=(x#>>'{}')::uuid; select * into m from members where id=mid;
   if found and not exists(select 1 from weekly_goal_members gm where gm.goal_id=g.id and gm.member_record_id=m.id) then
    insert into weekly_goal_members(goal_id,profile_id,member_record_id,member_name,discord_user_id,discord_channel_id,updated_by,status)
    values(g.id,m.profile_id,m.id,m.name,m.discord_user_id,m.discord_channel_id,auth.uid(),'in_progress'); n:=n+1;
   end if;
  end loop;
 end if;
 perform public.apply_weekly_goal_carryover(g.id);
 insert into activity_logs(user_id,action,entity_type,entity_id,description,new_data)
 values(auth.uid(),case when p_id is null then 'create' else 'update' end,'weekly_goal',g.id,'Configuração da meta salva.',to_jsonb(g));
 return jsonb_build_object('success',true,'id',g.id,'members_added',n);
end $$;

create or replace function public.set_weekly_goal_bonus_status(p_goal_member_id uuid,p_status text,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare gm weekly_goal_members;g weekly_goals;b weekly_goal_bonuses;
begin
 if not public.is_staff() then raise exception 'Sem permissão.'; end if;
 if p_status not in('pending','delivered','cancelled') then raise exception 'Situação inválida.'; end if;
 select * into gm from weekly_goal_members where id=p_goal_member_id;
 select * into g from weekly_goals where id=gm.goal_id;
 if gm.id is null or nullif(trim(coalesce(g.reward_name,'')),'') is null then raise exception 'Esta meta não possui bonificação.'; end if;
 insert into weekly_goal_bonuses(goal_id,goal_member_id,inventory_item_id,description,quantity,status,delivered_at,delivered_by,notes)
 values(g.id,gm.id,g.bonus_inventory_item_id,g.reward_name,greatest(coalesce(g.bonus_quantity,1),1),p_status,
  case when p_status='delivered' then now() end,case when p_status='delivered' then auth.uid() end,nullif(trim(coalesce(p_notes,'')),''))
 on conflict(goal_id,goal_member_id) do update set status=excluded.status,delivered_at=excluded.delivered_at,
  delivered_by=excluded.delivered_by,notes=excluded.notes,updated_at=now() returning * into b;
 insert into activity_logs(user_id,action,entity_type,entity_id,description,new_data)
 values(auth.uid(),'update','weekly_goal_bonus',b.id,'Situação da bonificação alterada.',to_jsonb(b));
 return jsonb_build_object('success',true,'id',b.id,'status',b.status);
end $$;

create or replace function public.get_my_member_dashboard()
returns jsonb language sql security definer set search_path=public as $$
 with me as(select * from members where profile_id=auth.uid() limit 1),
 my_goals as(
  select g.*,gm.id goal_member_id,gm.status member_status
  from me join weekly_goal_members gm on gm.member_record_id=me.id
  join weekly_goals g on g.id=gm.goal_id where g.status='active'
 ), packed as(
  select jsonb_build_object('id',g.id,'title',g.title,'start_date',g.start_date,'end_date',g.end_date,
   'audience_type',g.audience_type,'target_amount',g.target_amount,'reward_name',g.reward_name,
   'bonus_quantity',g.bonus_quantity,'member_status',g.member_status,
   'requirements',(select coalesce(jsonb_agg(jsonb_build_object('item_name',p.item_name,'required',p.required_quantity,
    'credited',p.credited_quantity,'remaining',p.remaining_quantity,'extra',p.extra_quantity) order by p.item_name),'[]')
    from weekly_goal_member_progress p where p.member_id=g.goal_member_id),
   'bonus_status',(select b.status from weekly_goal_bonuses b where b.goal_member_id=g.goal_member_id limit 1)
  ) obj from my_goals g order by g.start_date desc,g.created_at desc
 )
 select jsonb_build_object('member',(select jsonb_build_object('name',name,'code',member_code,'status',status) from me),
  'goals',coalesce((select jsonb_agg(obj) from packed),'[]'),'goal',(select obj from packed limit 1));
$$;

-- O bot escolhe uma meta ativa da qual o membro realmente participa.
create or replace function public.register_weekly_goal_submission(
 p_discord_user_id text,p_discord_channel_id text,p_discord_message_id text,p_original_text text,
 p_evidence_url text,p_evidence_storage_path text,p_items jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare g weekly_goals;m weekly_goal_members;s weekly_goal_submissions;x jsonb;iid uuid;q numeric;kind text;
begin
 select gm.* into m from weekly_goal_members gm join weekly_goals wg on wg.id=gm.goal_id
 where wg.status='active' and current_date between wg.start_date and wg.end_date
 and (gm.discord_user_id=trim(p_discord_user_id) or gm.discord_channel_id=trim(p_discord_channel_id))
 and gm.status not in('absent','excused') order by case wg.audience_type when 'individual' then 1 when 'custom' then 2 else 3 end limit 1;
 if not found then raise exception 'Seu Discord/canal não está vinculado a uma meta ativa.'; end if;
 select * into g from weekly_goals where id=m.goal_id;
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

grant execute on function public.save_weekly_goal_v3(uuid,date,date,text,numeric,text,text,jsonb,jsonb,text,uuid,numeric,text) to authenticated;
grant execute on function public.apply_weekly_goal_carryover(uuid) to authenticated;
grant execute on function public.set_weekly_goal_bonus_status(uuid,text,text) to authenticated;
grant execute on function public.get_my_member_dashboard() to authenticated;
grant execute on function public.register_weekly_goal_submission(text,text,text,text,text,text,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
