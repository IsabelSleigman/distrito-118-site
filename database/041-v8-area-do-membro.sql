begin;

create or replace function public.get_my_member_dashboard()
returns jsonb language plpgsql security definer set search_path=public as $$
declare m members;g weekly_goals;gm weekly_goal_members;req jsonb;subs jsonb;
begin
 select * into m from members where profile_id=auth.uid();
 if not found then raise exception 'Cadastro de membro não vinculado.'; end if;
 select * into g from weekly_goals where status='active' order by start_date desc limit 1;
 if g.id is not null then select * into gm from weekly_goal_members where goal_id=g.id and member_record_id=m.id limit 1; end if;
 select coalesce(jsonb_agg(jsonb_build_object('item_name',p.item_name,'required',p.required_quantity,'credited',p.credited_quantity,'remaining',p.remaining_quantity,'extra',p.extra_quantity) order by p.item_name),'[]') into req from weekly_goal_member_progress p where p.member_id=gm.id;
 select coalesce(jsonb_agg(x),'[]') into subs from(select jsonb_build_object('id',s.id,'submitted_at',s.submitted_at,'status',s.status,'evidence_url',s.evidence_url,'items',coalesce(jsonb_agg(jsonb_build_object('name',i.name,'quantity',si.quantity,'classification',si.classification)) filter(where si.id is not null),'[]')) x from weekly_goal_submissions s left join weekly_goal_submission_items si on si.submission_id=s.id left join inventory_items i on i.id=si.inventory_item_id where s.member_id=gm.id group by s.id order by s.submitted_at desc limit 5)q;
 return jsonb_build_object('member',jsonb_build_object('name',m.name,'code',m.member_code,'status',m.status),'goal',case when g.id is null then null else jsonb_build_object('id',g.id,'title',g.title,'start_date',g.start_date,'end_date',g.end_date,'reward_name',g.reward_name,'member_status',gm.status,'requirements',req,'submissions',subs) end);
end $$;

create or replace function public.get_member_craft_data()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from members where profile_id=auth.uid() and status='active') then raise exception 'Acesso negado.'; end if;
 return jsonb_build_object(
 'catalog',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select item_id,name,unit,is_product,is_material,is_craftable from inventory_catalog where is_active order by name)x),
 'products',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select id,name,inventory_item_id from products where is_active and allows_order and inventory_item_id is not null order by name)x),
 'recipes',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select production_item_id,component_item_id,quantity_required,output_quantity from inventory_craft_recipes)x));
end $$;
grant execute on function public.get_my_member_dashboard() to authenticated;
grant execute on function public.get_member_craft_data() to authenticated;
notify pgrst,'reload schema';commit;
