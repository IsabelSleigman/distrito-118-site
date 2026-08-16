begin;

-- Guarda quanto de cada material de primeiro nível já foi efetivamente coberto
-- pela baixa da encomenda. O valor nunca diminui automaticamente: se o pedido
-- for reduzido, o excedente continua registrado como já baixado até existir
-- uma devolução explícita no futuro.
create table if not exists public.order_production_requirements (
  order_id uuid not null references public.orders(id) on delete cascade,
  material_id uuid not null references public.materials(id),
  consumed_required_quantity numeric not null default 0 check (consumed_required_quantity >= 0),
  updated_at timestamptz not null default now(),
  primary key (order_id, material_id)
);

grant select on public.order_production_requirements to authenticated;

-- Pedidos que já tiveram baixa antes desta migration recebem como baseline
-- a receita correspondente ao pedido atual. Nenhum estoque é movimentado aqui.
insert into public.order_production_requirements(order_id, material_id, consumed_required_quantity)
select
  oi.order_id,
  pm.material_id,
  sum(
    ceil(oi.quantity::numeric / greatest(coalesce(p.output_quantity,1),0.000001))
    * pm.quantity_required
  )::numeric
from public.order_items oi
join public.order_inventory_consumptions oic on oic.order_id=oi.order_id
join public.products p on p.id=oi.product_id
join public.product_materials pm on pm.product_id=oi.product_id
group by oi.order_id, pm.material_id
on conflict(order_id,material_id) do nothing;

-- A baixa inicial passa a registrar também o baseline usado para ajustes futuros.
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
    select
      pm.material_id,
      sum(
        ceil(oi.quantity::numeric / greatest(coalesce(p.output_quantity,1),0.000001))
        * pm.quantity_required
      )::numeric as required_quantity
    from public.order_items oi
    join public.products p on p.id=oi.product_id
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

    insert into public.order_production_requirements(order_id,material_id,consumed_required_quantity,updated_at)
    values(p_order_id,v_recipe.material_id,v_recipe.required_quantity,now())
    on conflict(order_id,material_id) do update
      set consumed_required_quantity=greatest(public.order_production_requirements.consumed_required_quantity,excluded.consumed_required_quantity),
          updated_at=now();
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

-- Confirma somente a diferença positiva após uma edição do pedido.
-- Reduções nunca devolvem material automaticamente ao estoque.
create or replace function public.adjust_order_production_inventory(
  p_order_id uuid,
  p_responsible_name text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_recipe record;
  v_responsible_name text;
  v_order_code text;
  v_customer_name text;
  v_status text;
  v_before timestamptz := clock_timestamp();
  v_movements jsonb;
  v_additions jsonb := '[]'::jsonb;
  v_excess jsonb := '[]'::jsonb;
  v_delta numeric;
  v_previous numeric;
begin
  v_responsible_name := regexp_replace(trim(coalesce(p_responsible_name,'')), '\s+', ' ', 'g');
  if length(v_responsible_name) < 3 then raise exception 'Informe o nome RP do responsável pela baixa.'; end if;
  if length(v_responsible_name) > 120 then raise exception 'O nome do responsável é muito longo.'; end if;

  select status,code,coalesce(cnpj_name,customer_name)
    into v_status,v_order_code,v_customer_name
  from public.orders
  where id=p_order_id and deleted_at is null
  for update;

  if v_status is null then raise exception 'Encomenda não encontrada.'; end if;
  if v_status in ('delivered','cancelled','rejected') then raise exception 'Não é possível ajustar materiais de uma encomenda finalizada.'; end if;
  if not exists(select 1 from public.order_inventory_consumptions where order_id=p_order_id) then
    raise exception 'A encomenda ainda não teve a baixa inicial de materiais.';
  end if;

  for v_recipe in
    with current_requirements as (
      select pm.material_id,
        sum(ceil(oi.quantity::numeric / greatest(coalesce(p.output_quantity,1),0.000001))*pm.quantity_required)::numeric required_quantity
      from public.order_items oi
      join public.products p on p.id=oi.product_id
      join public.product_materials pm on pm.product_id=oi.product_id
      where oi.order_id=p_order_id
      group by pm.material_id
    ), all_materials as (
      select material_id from current_requirements
      union
      select material_id from public.order_production_requirements where order_id=p_order_id
    )
    select a.material_id,m.name,m.unit,
      coalesce(c.required_quantity,0)::numeric required_quantity,
      coalesce(r.consumed_required_quantity,0)::numeric consumed_quantity
    from all_materials a
    join public.materials m on m.id=a.material_id
    left join current_requirements c on c.material_id=a.material_id
    left join public.order_production_requirements r on r.order_id=p_order_id and r.material_id=a.material_id
  loop
    v_previous := v_recipe.consumed_quantity;
    v_delta := v_recipe.required_quantity-v_previous;

    if v_delta > 0 then
      perform public.consume_inventory_material_combined(v_recipe.material_id,v_delta,p_order_id,'{}');
      insert into public.order_production_requirements(order_id,material_id,consumed_required_quantity,updated_at)
      values(p_order_id,v_recipe.material_id,v_recipe.required_quantity,now())
      on conflict(order_id,material_id) do update
        set consumed_required_quantity=greatest(public.order_production_requirements.consumed_required_quantity,excluded.consumed_required_quantity),updated_at=now();
      v_additions := v_additions || jsonb_build_array(jsonb_build_object('material_id',v_recipe.material_id,'material',v_recipe.name,'unit',v_recipe.unit,'quantity',v_delta));
    elsif v_delta < 0 then
      v_excess := v_excess || jsonb_build_array(jsonb_build_object('material_id',v_recipe.material_id,'material',v_recipe.name,'unit',v_recipe.unit,'quantity',abs(v_delta)));
    end if;
  end loop;

  if jsonb_array_length(v_additions)=0 then
    return jsonb_build_object('success',true,'adjusted',false,'additions',v_additions,'excess',v_excess);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'movement_id',im.id,'material',m.name,'quantity',im.quantity,
    'movement_type',im.movement_type,'scope',s.scope,'stock_name',s.name
  ) order by s.scope,m.name),'[]'::jsonb)
  into v_movements
  from public.inventory_movements im
  join public.materials m on m.id=im.material_id
  join public.inventory_stocks s on s.id=im.stock_id
  where im.order_id=p_order_id and im.source='order'
    and im.movement_type='production_consumption' and im.created_at>=v_before;

  insert into public.order_status_history(order_id,previous_status,new_status,changed_by,notes,status,note,old_status)
  values(p_order_id,v_status,v_status,auth.uid(),
    'Baixa adicional de materiais confirmada por '||v_responsible_name||'.',
    v_status,'Baixa adicional de materiais confirmada por '||v_responsible_name||'.',v_status);

  insert into public.integration_outbox(event_type,entity_type,entity_id,payload,status,destination)
  values('order_inventory_adjusted','order',p_order_id,
    jsonb_build_object('code',v_order_code,'customer_name',v_customer_name,'responsible_name',v_responsible_name,
      'operator_id',auth.uid(),'status',v_status,'movements',v_movements,'additions',v_additions,
      'note','Baixa adicional após edição da encomenda.'),
    'pending','order_history');

  return jsonb_build_object('success',true,'adjusted',true,'additions',v_additions,'excess',v_excess,'movements',v_movements);
end;
$$;

alter table public.integration_outbox drop constraint if exists integration_outbox_event_type_check;
alter table public.integration_outbox add constraint integration_outbox_event_type_check check (
  event_type = any(array[
    'order_created'::text,'order_accepted'::text,'order_ready'::text,'order_delivered'::text,
    'order_rejected'::text,'order_status_changed'::text,'order_inventory_consumed'::text,
    'order_inventory_adjusted'::text,'low_stock'::text
  ])
);

revoke all on function public.adjust_order_production_inventory(uuid,text) from public;
grant execute on function public.adjust_order_production_inventory(uuid,text) to authenticated,service_role;
revoke all on function public.consume_order_inventory(uuid) from public;
grant execute on function public.consume_order_inventory(uuid) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
