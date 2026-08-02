begin;

-- Mantém todas as receitas atuais com rendimento 1.
alter table public.materials
  add column if not exists output_quantity numeric not null default 1;

alter table public.materials
  drop constraint if exists materials_output_quantity_check;
alter table public.materials
  add constraint materials_output_quantity_check check (output_quantity > 0);

-- A baixa deixa de acontecer automaticamente ao marcar a encomenda como pronta.
drop trigger if exists orders_consume_inventory_when_ready on public.orders;

-- Consome materiais dos dois baús e respeita o rendimento de cada receita.
-- Se uma fabricação gerar sobra, ela é guardada no Estoque Geral.
create or replace function public.consume_inventory_material_combined(
  p_material_id uuid,
  p_quantity numeric,
  p_order_id uuid,
  p_path uuid[] default '{}'
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_stock record;
  v_general_stock_id uuid;
  v_available numeric;
  v_use numeric;
  v_remaining numeric := p_quantity;
  v_component record;
  v_code text;
  v_name text;
  v_output_quantity numeric := 1;
  v_batches numeric;
  v_produced numeric;
  v_surplus numeric;
  v_general_before numeric;
begin
  if p_quantity <= 0 then return; end if;
  if p_material_id = any(p_path) then
    raise exception 'Receita circular encontrada no material %.', p_material_id;
  end if;

  select o.code into v_code from public.orders o where o.id=p_order_id;
  select m.name,coalesce(m.output_quantity,1)
    into v_name,v_output_quantity
  from public.materials m where m.id=p_material_id;

  -- Usa primeiro o que já está pronto no Geral e depois na Gerência.
  for v_stock in
    select id,scope from public.inventory_stocks
    where is_active=true and scope in ('geral','gerencia')
    order by case scope when 'geral' then 1 else 2 end
  loop
    exit when v_remaining <= 0;
    insert into public.inventory_balances(stock_id,material_id,quantity)
    values(v_stock.id,p_material_id,0) on conflict do nothing;

    select quantity into v_available
    from public.inventory_balances
    where stock_id=v_stock.id and material_id=p_material_id
    for update;

    v_use := least(v_available,v_remaining);
    if v_use > 0 then
      update public.inventory_balances
      set quantity=quantity-v_use,updated_at=now()
      where stock_id=v_stock.id and material_id=p_material_id;

      insert into public.inventory_movements(
        stock_id,material_id,movement_type,quantity,balance_before,balance_after,
        source,reason,order_id,registered_by
      ) values(
        v_stock.id,p_material_id,'production_consumption',v_use,v_available,v_available-v_use,
        'order',
        'Produção da encomenda '||coalesce(v_code,p_order_id::text)||' · '||
          case when v_stock.scope='geral' then 'Estoque Geral' else 'Estoque da Gerência' end,
        p_order_id,auth.uid()
      );
      v_remaining := v_remaining-v_use;
    end if;
  end loop;

  if v_remaining <= 0 then return; end if;

  if not exists(select 1 from public.material_components where material_id=p_material_id) then
    raise exception 'Material insuficiente nos dois baús: % (faltam %).',coalesce(v_name,p_material_id::text),v_remaining;
  end if;

  -- Cada linha da receita representa uma fabricação completa.
  v_batches := ceil(v_remaining / greatest(v_output_quantity,0.000001));
  v_produced := v_batches * v_output_quantity;
  v_surplus := v_produced - v_remaining;

  for v_component in
    select component_material_id,quantity_required
    from public.material_components
    where material_id=p_material_id
  loop
    perform public.consume_inventory_material_combined(
      v_component.component_material_id,
      v_batches*v_component.quantity_required,
      p_order_id,
      p_path||p_material_id
    );
  end loop;

  -- O que foi produzido além do necessário não desaparece.
  if v_surplus > 0 then
    select id into v_general_stock_id from public.inventory_stocks where scope='geral' and is_active=true limit 1;
    if v_general_stock_id is null then
      raise exception 'Estoque Geral não encontrado para registrar a sobra da produção.';
    end if;

    insert into public.inventory_balances(stock_id,material_id,quantity)
    values(v_general_stock_id,p_material_id,0) on conflict do nothing;

    select quantity into v_general_before
    from public.inventory_balances
    where stock_id=v_general_stock_id and material_id=p_material_id
    for update;

    update public.inventory_balances
    set quantity=quantity+v_surplus,updated_at=now()
    where stock_id=v_general_stock_id and material_id=p_material_id;

    insert into public.inventory_movements(
      stock_id,material_id,movement_type,quantity,balance_before,balance_after,
      source,reason,order_id,registered_by
    ) values(
      v_general_stock_id,p_material_id,'entry',v_surplus,v_general_before,v_general_before+v_surplus,
      'order','Sobra da produção da encomenda '||coalesce(v_code,p_order_id::text),p_order_id,auth.uid()
    );
  end if;
end;
$$;

create or replace function public.consume_order_inventory(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_recipe record;
  v_general_id uuid;
begin
  if exists(select 1 from public.order_inventory_consumptions where order_id=p_order_id) then
    return jsonb_build_object('success',true,'already_consumed',true);
  end if;

  if not exists(select 1 from public.orders where id=p_order_id and deleted_at is null) then
    raise exception 'Encomenda não encontrada.';
  end if;

  for v_recipe in
    select pm.material_id,sum(oi.quantity*pm.quantity_required)::numeric as required_quantity
    from public.order_items oi
    join public.product_materials pm on pm.product_id=oi.product_id
    where oi.order_id=p_order_id
    group by pm.material_id
  loop
    perform public.consume_inventory_material_combined(
      v_recipe.material_id,
      v_recipe.required_quantity,
      p_order_id,
      '{}'
    );
  end loop;

  select id into v_general_id from public.inventory_stocks where scope='geral' limit 1;
  insert into public.order_inventory_consumptions(order_id,stock_id)
  values(p_order_id,v_general_id);

  return jsonb_build_object(
    'success',true,
    'priority',jsonb_build_array('geral','gerencia'),
    'already_consumed',false
  );
end;
$$;

-- Uma única operação: baixa o estoque, muda o status e grava o histórico.
create or replace function public.start_order_production(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_result jsonb;
  v_previous_status text;
  v_already boolean;
begin
  select status into v_previous_status
  from public.orders
  where id=p_order_id and deleted_at is null
  for update;

  if v_previous_status is null then raise exception 'Encomenda não encontrada.'; end if;
  if v_previous_status in ('delivered','cancelled','rejected') then
    raise exception 'Não é possível iniciar a produção de uma encomenda finalizada.';
  end if;

  v_result := public.consume_order_inventory(p_order_id);
  v_already := coalesce((v_result->>'already_consumed')::boolean,false);

  if not v_already and v_previous_status is distinct from 'in_production' then
    update public.orders set status='in_production',updated_at=now() where id=p_order_id;
    insert into public.order_status_history(order_id,previous_status,new_status,changed_by,notes,status,note,old_status)
    values(
      p_order_id,v_previous_status,'in_production',auth.uid(),
      'Materiais baixados do estoque e produção iniciada.',
      'in_production','Materiais baixados do estoque e produção iniciada.',v_previous_status
    );
  end if;

  return v_result || jsonb_build_object('status','in_production');
end;
$$;

revoke all on function public.consume_inventory_material_combined(uuid,numeric,uuid,uuid[]) from public;
grant execute on function public.consume_inventory_material_combined(uuid,numeric,uuid,uuid[]) to authenticated,service_role;
revoke all on function public.consume_order_inventory(uuid) from public;
grant execute on function public.consume_order_inventory(uuid) to authenticated,service_role;
revoke all on function public.start_order_production(uuid) from public;
grant execute on function public.start_order_production(uuid) to authenticated,service_role;

grant select,update on public.materials to authenticated;

notify pgrst,'reload schema';
commit;
