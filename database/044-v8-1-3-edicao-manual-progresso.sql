begin;

create or replace function public.set_weekly_goal_member_item_totals(
 p_member_id uuid,p_items jsonb,p_note text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare gm weekly_goal_members;x jsonb;iid uuid;desired numeric;current_total numeric;delta numeric;n integer:=0;later_goal uuid;
begin
 if not public.is_staff() then raise exception 'Sem permissão.'; end if;
 select * into gm from weekly_goal_members where id=p_member_id;
 if not found then raise exception 'Participante não encontrado.'; end if;
 for x in select * from jsonb_array_elements(coalesce(p_items,'[]')) loop
  iid:=(x->>'item_id')::uuid; desired:=greatest(coalesce((x->>'quantity')::numeric,0),0);
  if not exists(select 1 from weekly_goal_requirements where goal_id=gm.goal_id and inventory_item_id=iid) then
   raise exception 'O item informado não pertence a esta meta.';
  end if;
  select coalesce(sum(quantity),0) into current_total from weekly_goal_ledger
  where member_id=p_member_id and inventory_item_id=iid and entry_type in('submission','correction','carry_in');
  delta:=desired-current_total;
  if delta<>0 then
   insert into weekly_goal_ledger(goal_id,member_id,inventory_item_id,entry_type,quantity,operation_key,reason,created_by)
   values(gm.goal_id,p_member_id,iid,'correction',delta,'manual-goal:'||gen_random_uuid(),
    coalesce(nullif(trim(coalesce(p_note,'')),''),'Correção manual pela gestão'),auth.uid());
   n:=n+1;
  end if;
 end loop;
 -- Recalcula todos os destinos posteriores dessa pessoa, sem duplicar créditos.
 for later_goal in
  select distinct g.id from weekly_goals g join weekly_goal_members next_gm on next_gm.goal_id=g.id
  join weekly_goals source_g on source_g.id=gm.goal_id
  where next_gm.member_record_id=gm.member_record_id and g.start_date>=source_g.end_date
  order by g.id
 loop perform public.apply_weekly_goal_carryover(later_goal); end loop;
 insert into activity_logs(user_id,action,entity_type,entity_id,description,new_data)
 values(auth.uid(),'update','weekly_goal_member',p_member_id,'Progresso de itens corrigido manualmente.',
  jsonb_build_object('items',p_items,'note',p_note));
 return jsonb_build_object('success',true,'corrections',n);
end $$;

grant execute on function public.set_weekly_goal_member_item_totals(uuid,jsonb,text) to authenticated;
notify pgrst,'reload schema';
commit;
