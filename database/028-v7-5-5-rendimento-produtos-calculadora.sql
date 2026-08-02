begin;

-- Produtos também podem render mais de uma unidade por fabricação.
-- O padrão 1 preserva todos os produtos e receitas já cadastrados.
alter table public.products
  add column if not exists output_quantity numeric not null default 1;

alter table public.products
  drop constraint if exists products_output_quantity_check;
alter table public.products
  add constraint products_output_quantity_check check (output_quantity > 0);

-- Recalcula os materiais da encomenda por número de fabricações do produto,
-- e não mais diretamente pela quantidade de unidades pedidas.
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

revoke all on function public.consume_order_inventory(uuid) from public;
grant execute on function public.consume_order_inventory(uuid) to authenticated,service_role;
grant select,update on public.products to authenticated;

notify pgrst,'reload schema';
commit;
