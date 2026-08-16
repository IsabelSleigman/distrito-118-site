begin;

alter table public.weekly_goal_members add column if not exists target_multiplier numeric not null default 1
 check(target_multiplier in(1,2));

create or replace view public.weekly_goal_member_progress with(security_invoker=true) as
select gm.id member_id,gm.goal_id,gm.member_name,gm.discord_user_id,gm.discord_channel_id,gm.status,gm.reward_eligible,
 r.inventory_item_id,i.name item_name,(r.required_quantity*gm.target_multiplier) required_quantity,
 coalesce(sum(case when l.entry_type='carry_out' then -l.quantity when l.entry_type in('submission','correction','carry_in') then l.quantity else 0 end),0) credited_quantity,
 greatest((r.required_quantity*gm.target_multiplier)-coalesce(sum(case when l.entry_type='carry_out' then -l.quantity when l.entry_type in('submission','correction','carry_in') then l.quantity else 0 end),0),0) remaining_quantity,
 greatest(coalesce(sum(case when l.entry_type='carry_out' then -l.quantity when l.entry_type in('submission','correction','carry_in') then l.quantity else 0 end),0)-(r.required_quantity*gm.target_multiplier),0) extra_quantity,
 gm.target_multiplier
from weekly_goal_members gm join weekly_goal_requirements r on r.goal_id=gm.goal_id
join inventory_items i on i.id=r.inventory_item_id
left join weekly_goal_ledger l on l.member_id=gm.id and l.inventory_item_id=r.inventory_item_id
group by gm.id,r.inventory_item_id,i.name,r.required_quantity;

create or replace function public.apply_weekly_goal_carryover(p_goal_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t record;src record;base_credit numeric;other_out numeric;desired numeric;op_base text;n integer:=0;
begin
 if not public.is_staff() and coalesce(auth.role(),'')<>'service_role' then raise exception 'Sem permissão.'; end if;
 for t in select gm.id target_member_id,gm.member_record_id,r.inventory_item_id,g.start_date
  from weekly_goal_members gm join weekly_goals g on g.id=gm.goal_id join weekly_goal_requirements r on r.goal_id=g.id
  where g.id=p_goal_id and gm.member_record_id is not null loop
  select pgm.id source_member_id,(pr.required_quantity*coalesce(pgm.target_multiplier,1)) required_quantity into src
  from weekly_goal_members pgm join weekly_goals pg on pg.id=pgm.goal_id
  join weekly_goal_requirements pr on pr.goal_id=pg.id and pr.inventory_item_id=t.inventory_item_id
  where pgm.member_record_id=t.member_record_id and pg.id<>p_goal_id and pg.end_date<=t.start_date
  order by pg.end_date desc,pg.created_at desc limit 1;
  if src.source_member_id is null then continue; end if;
  op_base:='carry:'||src.source_member_id||':'||t.target_member_id||':'||t.inventory_item_id;
  select coalesce(sum(quantity) filter(where entry_type in('submission','correction','carry_in')),0) into base_credit
  from weekly_goal_ledger where member_id=src.source_member_id and inventory_item_id=t.inventory_item_id;
  select coalesce(sum(quantity),0) into other_out from weekly_goal_ledger
  where member_id=src.source_member_id and inventory_item_id=t.inventory_item_id and entry_type='carry_out' and operation_key<>op_base||':out';
  desired:=greatest(base_credit-src.required_quantity-other_out,0);
  if desired>0 then
   insert into weekly_goal_ledger(goal_id,member_id,inventory_item_id,entry_type,quantity,operation_key,reason,created_by)
   select goal_id,src.source_member_id,t.inventory_item_id,'carry_out',desired,op_base||':out','Excedente transferido para a meta seguinte',auth.uid()
   from weekly_goal_members where id=src.source_member_id
   on conflict(operation_key) where operation_key is not null do update set quantity=excluded.quantity,reason=excluded.reason;
   insert into weekly_goal_ledger(goal_id,member_id,inventory_item_id,entry_type,quantity,operation_key,reason,created_by)
   values(p_goal_id,t.target_member_id,t.inventory_item_id,'carry_in',desired,op_base||':in','Crédito excedente da meta anterior',auth.uid())
   on conflict(operation_key) where operation_key is not null do update set quantity=excluded.quantity,reason=excluded.reason;
   n:=n+1;
  else delete from weekly_goal_ledger where operation_key in(op_base||':out',op_base||':in'); end if;
 end loop;
 return jsonb_build_object('success',true,'credits_applied',n);
end $$;

create or replace function public.set_weekly_goal_member_multiplier(p_member_id uuid,p_multiplier numeric)
returns jsonb language plpgsql security definer set search_path=public as $$
declare gm weekly_goal_members;later_goal uuid;
begin
 if not public.is_staff() then raise exception 'Sem permissão.'; end if;
 if p_multiplier not in(1,2) then raise exception 'Multiplicador inválido.'; end if;
 update weekly_goal_members set target_multiplier=p_multiplier,updated_by=auth.uid(),updated_at=now()
 where id=p_member_id returning * into gm;
 if not found then raise exception 'Participante não encontrado.'; end if;
 perform public.apply_weekly_goal_carryover(gm.goal_id);
 for later_goal in select distinct g.id from weekly_goals g join weekly_goal_members ngm on ngm.goal_id=g.id
  join weekly_goals source_g on source_g.id=gm.goal_id where ngm.member_record_id=gm.member_record_id and g.start_date>=source_g.end_date
 loop perform public.apply_weekly_goal_carryover(later_goal);end loop;
 insert into activity_logs(user_id,action,entity_type,entity_id,description,new_data)
 values(auth.uid(),'update','weekly_goal_member',gm.id,'Multiplicador individual da meta alterado.',jsonb_build_object('multiplier',p_multiplier));
 return jsonb_build_object('success',true,'member_id',gm.id,'multiplier',gm.target_multiplier);
end $$;

grant execute on function public.set_weekly_goal_member_multiplier(uuid,numeric) to authenticated;
notify pgrst,'reload schema';
commit;
