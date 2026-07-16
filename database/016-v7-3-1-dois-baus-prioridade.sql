begin;

-- A produção passa a usar os dois baús: Geral primeiro e Gerência para completar.
create or replace function public.consume_inventory_material_combined(
  p_material_id uuid,p_quantity numeric,p_order_id uuid,p_path uuid[] default '{}'
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_stock record;
  v_available numeric;
  v_use numeric;
  v_remaining numeric := p_quantity;
  v_component record;
  v_code text;
begin
  if p_quantity <= 0 then return; end if;
  if p_material_id = any(p_path) then raise exception 'Receita circular encontrada no material %.',p_material_id; end if;
  select code into v_code from public.orders where id=p_order_id;

  -- Prioridade fixa: baú geral e depois baú da gerência.
  for v_stock in
    select id,scope from public.inventory_stocks
    where is_active=true and scope in ('geral','gerencia')
    order by case scope when 'geral' then 1 else 2 end
  loop
    exit when v_remaining <= 0;
    insert into public.inventory_balances(stock_id,material_id,quantity)
    values(v_stock.id,p_material_id,0) on conflict do nothing;
    select quantity into v_available from public.inventory_balances
    where stock_id=v_stock.id and material_id=p_material_id for update;
    v_use := least(v_available,v_remaining);
    if v_use > 0 then
      update public.inventory_balances set quantity=quantity-v_use,updated_at=now()
      where stock_id=v_stock.id and material_id=p_material_id;
      insert into public.inventory_movements(
        stock_id,material_id,movement_type,quantity,balance_before,balance_after,source,reason,order_id,registered_by
      ) values(
        v_stock.id,p_material_id,'production_consumption',v_use,v_available,v_available-v_use,'order',
        'Produção da encomenda '||coalesce(v_code,p_order_id::text)||' · '||case when v_stock.scope='geral' then 'Estoque Geral' else 'Estoque da Gerência' end,
        p_order_id,auth.uid()
      );
      v_remaining := v_remaining-v_use;
    end if;
  end loop;

  if v_remaining <= 0 then return; end if;
  if not exists(select 1 from public.material_components where material_id=p_material_id) then
    raise exception 'Material insuficiente nos dois baús: % (faltam %).',(select name from public.materials where id=p_material_id),v_remaining;
  end if;

  for v_component in
    select component_material_id,quantity_required from public.material_components where material_id=p_material_id
  loop
    perform public.consume_inventory_material_combined(
      v_component.component_material_id,
      v_remaining*v_component.quantity_required,
      p_order_id,
      p_path||p_material_id
    );
  end loop;
end;
$$;

create or replace function public.consume_order_inventory(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_recipe record; v_general_id uuid;
begin
  if exists(select 1 from public.order_inventory_consumptions where order_id=p_order_id) then
    return jsonb_build_object('success',true,'already_consumed',true);
  end if;

  for v_recipe in
    select pm.material_id,sum(oi.quantity*pm.quantity_required)::numeric as required_quantity
    from public.order_items oi
    join public.product_materials pm on pm.product_id=oi.product_id
    where oi.order_id=p_order_id
    group by pm.material_id
  loop
    perform public.consume_inventory_material_combined(v_recipe.material_id,v_recipe.required_quantity,p_order_id,'{}');
  end loop;

  select id into v_general_id from public.inventory_stocks where scope='geral';
  insert into public.order_inventory_consumptions(order_id,stock_id) values(p_order_id,v_general_id);
  return jsonb_build_object('success',true,'priority',jsonb_build_array('geral','gerencia'),'already_consumed',false);
end;
$$;

revoke all on function public.consume_inventory_material_combined(uuid,numeric,uuid,uuid[]) from public;
grant execute on function public.consume_inventory_material_combined(uuid,numeric,uuid,uuid[]) to authenticated,service_role;
revoke all on function public.consume_order_inventory(uuid) from public;
grant execute on function public.consume_order_inventory(uuid) to authenticated,service_role;

notify pgrst, 'reload schema';
commit;
