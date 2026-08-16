begin;

create or replace function public.apply_weekly_goal_carryover(p_goal_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare t record;src record;base_credit numeric;other_out numeric;desired numeric;op_base text;n integer:=0;
begin
 if not public.is_staff() and coalesce(auth.role(),'')<>'service_role' then raise exception 'Sem permissão.'; end if;
 for t in select gm.id target_member_id,gm.member_record_id,r.inventory_item_id,g.start_date
  from weekly_goal_members gm join weekly_goals g on g.id=gm.goal_id join weekly_goal_requirements r on r.goal_id=g.id
  where g.id=p_goal_id and gm.member_record_id is not null loop
  select pgm.id source_member_id,pr.required_quantity into src
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

create or replace function public.set_weekly_goal_member_item_totals(p_member_id uuid,p_items jsonb,p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare gm weekly_goal_members;x jsonb;iid uuid;desired numeric;current_total numeric;delta numeric;n integer:=0;later_goal uuid;
begin
 if not public.is_staff() then raise exception 'Sem permissão.'; end if;
 select * into gm from weekly_goal_members where id=p_member_id;
 if not found then raise exception 'Participante não encontrado.'; end if;
 for x in select * from jsonb_array_elements(coalesce(p_items,'[]')) loop
  iid:=(x->>'item_id')::uuid;desired:=greatest(coalesce((x->>'quantity')::numeric,0),0);
  if not exists(select 1 from weekly_goal_requirements where goal_id=gm.goal_id and inventory_item_id=iid) then raise exception 'O item informado não pertence a esta meta.'; end if;
  select coalesce(sum(quantity),0) into current_total from weekly_goal_ledger
  where member_id=p_member_id and inventory_item_id=iid and entry_type in('submission','correction');
  delta:=desired-current_total;
  if delta<>0 then insert into weekly_goal_ledger(goal_id,member_id,inventory_item_id,entry_type,quantity,operation_key,reason,created_by)
   values(gm.goal_id,p_member_id,iid,'correction',delta,'manual-goal:'||gen_random_uuid(),coalesce(nullif(trim(coalesce(p_note,'')),''),'Correção manual pela gestão'),auth.uid());n:=n+1;end if;
 end loop;
 for later_goal in select distinct g.id from weekly_goals g join weekly_goal_members ngm on ngm.goal_id=g.id
  join weekly_goals source_g on source_g.id=gm.goal_id where ngm.member_record_id=gm.member_record_id and g.start_date>=source_g.end_date
 loop perform public.apply_weekly_goal_carryover(later_goal);end loop;
 insert into activity_logs(user_id,action,entity_type,entity_id,description,new_data)
 values(auth.uid(),'update','weekly_goal_member',p_member_id,'Progresso de itens corrigido manualmente.',jsonb_build_object('items',p_items,'note',p_note));
 return jsonb_build_object('success',true,'corrections',n);
end $$;

grant execute on function public.apply_weekly_goal_carryover(uuid) to authenticated;
grant execute on function public.set_weekly_goal_member_item_totals(uuid,jsonb,text) to authenticated;
notify pgrst,'reload schema';
commit;
