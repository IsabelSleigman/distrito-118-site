begin;

-- V7.7 — materiais e produtos prontos compartilham os dois estoques.
-- As tabelas atuais de materiais permanecem intactas para preservar todos os saldos.

create table if not exists public.inventory_product_balances (
  stock_id uuid not null references public.inventory_stocks(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  quantity numeric not null default 0 check (quantity >= 0),
  reserved_quantity numeric not null default 0 check (reserved_quantity >= 0),
  updated_at timestamptz not null default now(),
  primary key (stock_id, product_id)
);

create table if not exists public.inventory_product_movements (
  id uuid primary key default gen_random_uuid(),
  stock_id uuid not null references public.inventory_stocks(id),
  product_id uuid not null references public.products(id),
  movement_type text not null check (movement_type in ('entry','exit','adjustment_entry','adjustment_exit','order_consumption','production_surplus')),
  quantity numeric not null check (quantity > 0),
  balance_before numeric not null,
  balance_after numeric not null,
  source text not null default 'manual' check (source in ('discord','site','order','manual')),
  reason text,
  order_id uuid references public.orders(id),
  operation_key text,
  discord_user_id text,
  discord_user_name text,
  registered_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create unique index if not exists inventory_product_movements_operation_key_uq
  on public.inventory_product_movements(operation_key) where operation_key is not null;

create table if not exists public.inventory_item_aliases (
  id uuid primary key default gen_random_uuid(),
  alias text not null,
  normalized_alias text not null unique,
  item_type text not null check (item_type in ('material','product')),
  material_id uuid references public.materials(id) on delete cascade,
  product_id uuid references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  check (
    (item_type='material' and material_id is not null and product_id is null) or
    (item_type='product' and product_id is not null and material_id is null)
  )
);

create or replace function public.normalize_inventory_name(p_name text)
returns text language sql immutable parallel safe as $$
  select trim(regexp_replace(
    translate(lower(coalesce(p_name,'')),
      'áàâãäéèêëíìîïóòôõöúùûüç',
      'aaaaaeeeeiiiiooooouuuuc'),
    '\s+',' ','g'));
$$;

insert into public.inventory_item_aliases(alias,normalized_alias,item_type,product_id)
select 'Meta',public.normalize_inventory_name('Meta'),'product',p.id
from public.products p
where public.normalize_inventory_name(p.name)=public.normalize_inventory_name('Metanfetamina')
on conflict(normalized_alias) do update set
  alias=excluded.alias,item_type='product',material_id=null,product_id=excluded.product_id;

insert into public.inventory_product_balances(stock_id,product_id,quantity,reserved_quantity)
select s.id,p.id,0,0
from public.inventory_stocks s cross join public.products p
where s.scope in ('geral','gerencia')
on conflict(stock_id,product_id) do nothing;

create or replace view public.inventory_catalog with (security_invoker=true) as
select 'product'::text item_type,p.id item_id,p.name,p.is_active,'unidade'::text unit
from public.products p
union all
select 'material'::text,m.id,m.name,m.is_active,m.unit
from public.materials m;

create or replace view public.inventory_all_balances with (security_invoker=true) as
select b.stock_id,'product'::text item_type,b.product_id item_id,b.quantity,b.reserved_quantity,b.updated_at
from public.inventory_product_balances b
union all
select b.stock_id,'material'::text,b.material_id,b.quantity,b.reserved_quantity,b.updated_at
from public.inventory_balances b;

create or replace function public.resolve_inventory_item(p_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_normalized text; v_item record;
begin
  v_normalized := public.normalize_inventory_name(p_name);
  if v_normalized='' then raise exception 'Informe o nome do item.'; end if;

  select a.item_type,coalesce(a.product_id,a.material_id) item_id,
         coalesce(p.name,m.name) name,coalesce(m.unit,'unidade') unit
  into v_item
  from public.inventory_item_aliases a
  left join public.products p on a.item_type='product' and p.id=a.product_id and p.is_active=true
  left join public.materials m on a.item_type='material' and m.id=a.material_id and m.is_active=true
  where a.normalized_alias=v_normalized and (p.id is not null or m.id is not null)
  limit 1;
  if found then return jsonb_build_object('item_type',v_item.item_type,'item_id',v_item.item_id,'name',v_item.name,'unit',v_item.unit); end if;

  -- Produto explícito tem precedência sobre material com o mesmo nome.
  select 'product'::text,p.id,p.name,'unidade'::text into v_item
  from public.products p where p.is_active=true and public.normalize_inventory_name(p.name)=v_normalized limit 1;
  if found then return jsonb_build_object('item_type','product','item_id',v_item.id,'name',v_item.name,'unit','unidade'); end if;

  select 'material'::text,m.id,m.name,m.unit into v_item
  from public.materials m where m.is_active=true and public.normalize_inventory_name(m.name)=v_normalized limit 1;
  if found then return jsonb_build_object('item_type','material','item_id',v_item.id,'name',v_item.name,'unit',v_item.unit); end if;
  raise exception 'O item "%" não está cadastrado no site.',p_name;
end;
$$;

create or replace function public.set_inventory_item_balance(
  p_scope text,p_item_type text,p_item_id uuid,p_quantity numeric,
  p_reason text default 'Conferência física',p_source text default 'discord',
  p_operation_key text default null,p_discord_user_id text default null,p_discord_user_name text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_stock_id uuid; v_before numeric; v_type text;
begin
  if p_quantity<0 then raise exception 'Quantidade inválida.'; end if;
  select id into v_stock_id from public.inventory_stocks where scope=p_scope and is_active=true;
  if v_stock_id is null then raise exception 'Estoque inválido.'; end if;
  if p_item_type='material' then
    return public.set_inventory_balance(p_scope,p_item_id,p_quantity,p_reason,p_source,p_operation_key,p_discord_user_id,p_discord_user_name);
  elsif p_item_type<>'product' or not exists(select 1 from public.products where id=p_item_id and is_active=true) then
    raise exception 'Produto inválido ou inativo.';
  end if;
  insert into public.inventory_product_balances(stock_id,product_id,quantity) values(v_stock_id,p_item_id,0) on conflict do nothing;
  select quantity into v_before from public.inventory_product_balances where stock_id=v_stock_id and product_id=p_item_id for update;
  update public.inventory_product_balances set quantity=p_quantity,updated_at=clock_timestamp() where stock_id=v_stock_id and product_id=p_item_id;
  if p_quantity<>v_before then
    v_type:=case when p_quantity>v_before then 'adjustment_entry' else 'adjustment_exit' end;
    insert into public.inventory_product_movements(stock_id,product_id,movement_type,quantity,balance_before,balance_after,source,reason,operation_key,discord_user_id,discord_user_name,registered_by)
    values(v_stock_id,p_item_id,v_type,abs(p_quantity-v_before),v_before,p_quantity,p_source,p_reason,p_operation_key,p_discord_user_id,p_discord_user_name,auth.uid())
    on conflict(operation_key) where operation_key is not null do nothing;
  end if;
  return jsonb_build_object('success',true,'item_type','product','before',v_before,'after',p_quantity);
end;
$$;

create or replace function public.apply_inventory_item_batch(
  p_scope text,p_movement_type text,p_items jsonb,p_source text default 'discord',p_reason text default null,
  p_operation_key text default null,p_discord_user_id text default null,p_discord_user_name text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_stock_id uuid; v_item jsonb; v_type text; v_id uuid; v_qty numeric; v_before numeric; v_after numeric; v_results jsonb:='[]';
begin
  if p_scope not in ('geral','gerencia') then raise exception 'Estoque inválido.'; end if;
  if p_movement_type not in ('entry','exit') then raise exception 'Movimentação inválida.'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Informe ao menos um item.'; end if;
  select id into v_stock_id from public.inventory_stocks where scope=p_scope and is_active=true;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_type:=v_item->>'item_type'; v_id:=(v_item->>'item_id')::uuid; v_qty:=(v_item->>'quantity')::numeric;
    if v_qty<=0 or v_type not in ('material','product') then raise exception 'Item ou quantidade inválida.'; end if;
    if v_type='material' then
      insert into public.inventory_balances(stock_id,material_id,quantity) values(v_stock_id,v_id,0) on conflict do nothing;
      select quantity into v_before from public.inventory_balances where stock_id=v_stock_id and material_id=v_id for update;
      v_after:=case when p_movement_type='entry' then v_before+v_qty else v_before-v_qty end;
      if v_after<0 then raise exception 'Estoque insuficiente para o material %.',v_id; end if;
      update public.inventory_balances set quantity=v_after,updated_at=clock_timestamp() where stock_id=v_stock_id and material_id=v_id;
      insert into public.inventory_movements(stock_id,material_id,movement_type,quantity,balance_before,balance_after,source,reason,operation_key,discord_user_id,discord_user_name,registered_by)
      values(v_stock_id,v_id,p_movement_type,v_qty,v_before,v_after,p_source,p_reason,case when p_operation_key is null then null else p_operation_key||':material:'||v_id end,p_discord_user_id,p_discord_user_name,auth.uid());
    else
      insert into public.inventory_product_balances(stock_id,product_id,quantity) values(v_stock_id,v_id,0) on conflict do nothing;
      select quantity into v_before from public.inventory_product_balances where stock_id=v_stock_id and product_id=v_id for update;
      v_after:=case when p_movement_type='entry' then v_before+v_qty else v_before-v_qty end;
      if v_after<0 then raise exception 'Estoque insuficiente para o produto %.',v_id; end if;
      update public.inventory_product_balances set quantity=v_after,updated_at=clock_timestamp() where stock_id=v_stock_id and product_id=v_id;
      insert into public.inventory_product_movements(stock_id,product_id,movement_type,quantity,balance_before,balance_after,source,reason,operation_key,discord_user_id,discord_user_name,registered_by)
      values(v_stock_id,v_id,p_movement_type,v_qty,v_before,v_after,p_source,p_reason,case when p_operation_key is null then null else p_operation_key||':product:'||v_id end,p_discord_user_id,p_discord_user_name,auth.uid());
    end if;
    v_results:=v_results||jsonb_build_array(jsonb_build_object('item_type',v_type,'item_id',v_id,'quantity',v_qty,'before',v_before,'after',v_after));
  end loop;
  return jsonb_build_object('success',true,'scope',p_scope,'items',v_results);
end;
$$;

create table if not exists public.order_product_fulfillments (
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid not null references public.products(id),
  covered_quantity numeric not null default 0 check(covered_quantity>=0),
  updated_at timestamptz not null default now(),
  primary key(order_id,product_id)
);

alter table public.inventory_movements alter column created_at set default clock_timestamp();

-- Pedidos baixados antes desta versão são considerados cobertos no estado atual.
insert into public.order_product_fulfillments(order_id,product_id,covered_quantity)
select oi.order_id,oi.product_id,sum(oi.quantity)::numeric
from public.order_items oi join public.order_inventory_consumptions c on c.order_id=oi.order_id
group by oi.order_id,oi.product_id on conflict(order_id,product_id) do nothing;

create or replace function public.consume_ready_product_combined(p_product_id uuid,p_quantity numeric,p_order_id uuid)
returns numeric language plpgsql security definer set search_path=public as $$
declare v_stock record; v_available numeric; v_use numeric; v_remaining numeric:=p_quantity; v_used numeric:=0; v_code text;
begin
  select code into v_code from public.orders where id=p_order_id;
  for v_stock in select id,scope from public.inventory_stocks where is_active=true and scope in ('geral','gerencia') order by case scope when 'geral' then 1 else 2 end loop
    exit when v_remaining<=0;
    insert into public.inventory_product_balances(stock_id,product_id,quantity) values(v_stock.id,p_product_id,0) on conflict do nothing;
    select quantity into v_available from public.inventory_product_balances where stock_id=v_stock.id and product_id=p_product_id for update;
    v_use:=least(v_available,v_remaining);
    if v_use>0 then
      update public.inventory_product_balances set quantity=quantity-v_use,updated_at=clock_timestamp() where stock_id=v_stock.id and product_id=p_product_id;
      insert into public.inventory_product_movements(stock_id,product_id,movement_type,quantity,balance_before,balance_after,source,reason,order_id,registered_by)
      values(v_stock.id,p_product_id,'order_consumption',v_use,v_available,v_available-v_use,'order','Encomenda '||coalesce(v_code,p_order_id::text),p_order_id,auth.uid());
      v_remaining:=v_remaining-v_use; v_used:=v_used+v_use;
    end if;
  end loop;
  return v_used;
end;
$$;

create or replace function public.fulfill_order_product_delta(p_order_id uuid,p_product_id uuid,p_quantity numeric)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_ready numeric; v_remaining numeric; v_output numeric; v_batches numeric; v_produced numeric; v_surplus numeric; v_recipe record; v_general uuid; v_before numeric; v_name text;
begin
  if p_quantity<=0 then return jsonb_build_object('ready',0,'produced',0,'surplus',0); end if;
  select name,greatest(coalesce(output_quantity,1),0.000001) into v_name,v_output from public.products where id=p_product_id;
  if v_name is null then raise exception 'Produto inválido.'; end if;
  v_ready:=public.consume_ready_product_combined(p_product_id,p_quantity,p_order_id);
  v_remaining:=p_quantity-v_ready;
  if v_remaining<=0 then return jsonb_build_object('ready',v_ready,'produced',0,'surplus',0); end if;
  if not exists(select 1 from public.product_materials where product_id=p_product_id) then raise exception 'Produto pronto insuficiente e produto sem receita: %.',v_name; end if;
  v_batches:=ceil(v_remaining/v_output); v_produced:=v_batches*v_output; v_surplus:=v_produced-v_remaining;
  for v_recipe in select material_id,quantity_required from public.product_materials where product_id=p_product_id loop
    perform public.consume_inventory_material_combined(v_recipe.material_id,v_batches*v_recipe.quantity_required,p_order_id,'{}');
  end loop;
  if v_surplus>0 then
    select id into v_general from public.inventory_stocks where scope='geral' and is_active=true limit 1;
    insert into public.inventory_product_balances(stock_id,product_id,quantity) values(v_general,p_product_id,0) on conflict do nothing;
    select quantity into v_before from public.inventory_product_balances where stock_id=v_general and product_id=p_product_id for update;
    update public.inventory_product_balances set quantity=quantity+v_surplus,updated_at=clock_timestamp() where stock_id=v_general and product_id=p_product_id;
    insert into public.inventory_product_movements(stock_id,product_id,movement_type,quantity,balance_before,balance_after,source,reason,order_id,registered_by)
    values(v_general,p_product_id,'production_surplus',v_surplus,v_before,v_before+v_surplus,'order','Sobra da fabricação da encomenda',p_order_id,auth.uid());
  end if;
  return jsonb_build_object('ready',v_ready,'produced',v_produced,'surplus',v_surplus);
end;
$$;

create or replace function public.consume_order_inventory(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item record; v_general uuid; v_result jsonb;
begin
  if exists(select 1 from public.order_inventory_consumptions where order_id=p_order_id) then return jsonb_build_object('success',true,'already_consumed',true); end if;
  if not exists(select 1 from public.orders where id=p_order_id and deleted_at is null) then raise exception 'Encomenda não encontrada.'; end if;
  for v_item in select oi.product_id,sum(oi.quantity)::numeric quantity from public.order_items oi where oi.order_id=p_order_id group by oi.product_id loop
    v_result:=public.fulfill_order_product_delta(p_order_id,v_item.product_id,v_item.quantity);
    insert into public.order_product_fulfillments(order_id,product_id,covered_quantity,updated_at) values(p_order_id,v_item.product_id,v_item.quantity,clock_timestamp())
    on conflict(order_id,product_id) do update set covered_quantity=greatest(public.order_product_fulfillments.covered_quantity,excluded.covered_quantity),updated_at=clock_timestamp();
  end loop;
  select id into v_general from public.inventory_stocks where scope='geral' limit 1;
  insert into public.order_inventory_consumptions(order_id,stock_id) values(p_order_id,v_general);
  return jsonb_build_object('success',true,'priority',jsonb_build_array('geral','gerencia'),'already_consumed',false);
end;
$$;

create or replace function public.adjust_order_production_inventory(p_order_id uuid,p_responsible_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item record; v_name text:=regexp_replace(trim(coalesce(p_responsible_name,'')),'\s+',' ','g'); v_status text; v_code text; v_customer text; v_delta numeric; v_additions jsonb:='[]'; v_excess jsonb:='[]'; v_before timestamptz:=clock_timestamp(); v_movements jsonb; v_result jsonb;
begin
  if length(v_name)<3 then raise exception 'Informe o nome RP do responsável pela baixa.'; end if;
  select status,code,coalesce(cnpj_name,customer_name) into v_status,v_code,v_customer from public.orders where id=p_order_id and deleted_at is null for update;
  if v_status is null then raise exception 'Encomenda não encontrada.'; end if;
  if v_status in ('delivered','cancelled','rejected') then raise exception 'Não é possível ajustar uma encomenda finalizada.'; end if;
  if not exists(select 1 from public.order_inventory_consumptions where order_id=p_order_id) then raise exception 'A encomenda ainda não teve a baixa inicial.'; end if;
  for v_item in
    with current_items as (select product_id,sum(quantity)::numeric quantity from public.order_items where order_id=p_order_id group by product_id), all_items as (
      select product_id from current_items union select product_id from public.order_product_fulfillments where order_id=p_order_id)
    select a.product_id,p.name,coalesce(c.quantity,0) required_quantity,coalesce(f.covered_quantity,0) covered_quantity
    from all_items a join public.products p on p.id=a.product_id left join current_items c on c.product_id=a.product_id
    left join public.order_product_fulfillments f on f.order_id=p_order_id and f.product_id=a.product_id
  loop
    v_delta:=v_item.required_quantity-v_item.covered_quantity;
    if v_delta>0 then
      v_result:=public.fulfill_order_product_delta(p_order_id,v_item.product_id,v_delta);
      insert into public.order_product_fulfillments(order_id,product_id,covered_quantity,updated_at) values(p_order_id,v_item.product_id,v_item.required_quantity,clock_timestamp())
      on conflict(order_id,product_id) do update set covered_quantity=greatest(public.order_product_fulfillments.covered_quantity,excluded.covered_quantity),updated_at=clock_timestamp();
      v_additions:=v_additions||jsonb_build_array(jsonb_build_object('product_id',v_item.product_id,'product',v_item.name,'quantity',v_delta,'fulfillment',v_result));
    elsif v_delta<0 then v_excess:=v_excess||jsonb_build_array(jsonb_build_object('product_id',v_item.product_id,'product',v_item.name,'quantity',abs(v_delta))); end if;
  end loop;
  if jsonb_array_length(v_additions)=0 then return jsonb_build_object('success',true,'adjusted',false,'additions',v_additions,'excess',v_excess); end if;
  select coalesce(jsonb_agg(x),'[]') into v_movements from (
    select pm.id movement_id,p.name item,pm.quantity,pm.movement_type,s.scope,s.name stock_name,'product' item_type
    from public.inventory_product_movements pm join public.products p on p.id=pm.product_id join public.inventory_stocks s on s.id=pm.stock_id
    where pm.order_id=p_order_id and pm.created_at>=v_before
    union all
    select mm.id,m.name,mm.quantity,mm.movement_type,s.scope,s.name,'material'
    from public.inventory_movements mm join public.materials m on m.id=mm.material_id join public.inventory_stocks s on s.id=mm.stock_id
    where mm.order_id=p_order_id and mm.created_at>=v_before
  ) x;
  insert into public.order_status_history(order_id,previous_status,new_status,changed_by,notes,status,note,old_status)
  values(p_order_id,v_status,v_status,auth.uid(),'Baixa adicional confirmada por '||v_name||'.',v_status,'Baixa adicional confirmada por '||v_name||'.',v_status);
  insert into public.integration_outbox(event_type,entity_type,entity_id,payload,status,destination)
  values('order_inventory_adjusted','order',p_order_id,jsonb_build_object('code',v_code,'customer_name',v_customer,'responsible_name',v_name,'status',v_status,'movements',v_movements,'additions',v_additions,'note','Baixa adicional após edição da encomenda.'),'pending','order_history');
  return jsonb_build_object('success',true,'adjusted',true,'additions',v_additions,'excess',v_excess,'movements',v_movements);
end;
$$;

create or replace function public.start_order_production(p_order_id uuid,p_responsible_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result jsonb; v_previous text; v_already boolean; v_code text; v_customer text; v_name text; v_movements jsonb; v_before timestamptz:=clock_timestamp();
begin
  v_name:=regexp_replace(trim(coalesce(p_responsible_name,'')),'\s+',' ','g');
  if length(v_name)<3 then raise exception 'Informe o nome RP do responsável pela baixa.'; end if;
  select status,code,coalesce(cnpj_name,customer_name) into v_previous,v_code,v_customer from public.orders where id=p_order_id and deleted_at is null for update;
  if v_previous is null then raise exception 'Encomenda não encontrada.'; end if;
  if v_previous in ('delivered','cancelled','rejected') then raise exception 'Não é possível iniciar a produção de uma encomenda finalizada.'; end if;
  v_result:=public.consume_order_inventory(p_order_id); v_already:=coalesce((v_result->>'already_consumed')::boolean,false);
  if not v_already then
    update public.orders set status='in_production',production_responsible=v_name,updated_at=clock_timestamp() where id=p_order_id;
    insert into public.productions(order_id,status,responsible_id,started_at,notes) values(p_order_id,'in_progress',auth.uid(),clock_timestamp(),'Produção iniciada por '||v_name||'.')
    on conflict(order_id) do update set status='in_progress',responsible_id=excluded.responsible_id,started_at=coalesce(public.productions.started_at,excluded.started_at),notes=excluded.notes,updated_at=clock_timestamp();
    insert into public.order_status_history(order_id,previous_status,new_status,changed_by,notes,status,note,old_status)
    values(p_order_id,v_previous,'in_production',auth.uid(),'Itens baixados por '||v_name||' e produção iniciada.','in_production','Itens baixados por '||v_name||' e produção iniciada.',v_previous);
    select coalesce(jsonb_agg(x),'[]') into v_movements from (
      select pm.id movement_id,p.name item,pm.quantity,pm.movement_type,s.scope,s.name stock_name,'product' item_type
      from public.inventory_product_movements pm join public.products p on p.id=pm.product_id join public.inventory_stocks s on s.id=pm.stock_id
      where pm.order_id=p_order_id and pm.created_at>=v_before
      union all
      select mm.id,m.name,mm.quantity,mm.movement_type,s.scope,s.name,'material'
      from public.inventory_movements mm join public.materials m on m.id=mm.material_id join public.inventory_stocks s on s.id=mm.stock_id
      where mm.order_id=p_order_id and mm.created_at>=v_before
    ) x;
    insert into public.integration_outbox(event_type,entity_type,entity_id,payload,status,destination)
    values('order_inventory_consumed','order',p_order_id,jsonb_build_object('code',v_code,'customer_name',v_customer,'responsible_name',v_name,'operator_id',auth.uid(),'previous_status',v_previous,'status','in_production','movements',v_movements,'note','Baixa realizada pelo site.'),'pending','order_history') on conflict do nothing;
  end if;
  return v_result||jsonb_build_object('status','in_production','responsible_name',v_name);
end;
$$;

alter table public.inventory_product_balances enable row level security;
alter table public.inventory_product_movements enable row level security;
alter table public.inventory_item_aliases enable row level security;
alter table public.order_product_fulfillments enable row level security;
drop policy if exists "Equipe consulta saldo de produtos" on public.inventory_product_balances;
drop policy if exists "Equipe consulta movimentos de produtos" on public.inventory_product_movements;
drop policy if exists "Equipe consulta aliases" on public.inventory_item_aliases;
drop policy if exists "Equipe consulta cobertura de produtos" on public.order_product_fulfillments;
create policy "Equipe consulta saldo de produtos" on public.inventory_product_balances for select to authenticated using(public.is_staff());
create policy "Equipe consulta movimentos de produtos" on public.inventory_product_movements for select to authenticated using(public.is_staff());
create policy "Equipe consulta aliases" on public.inventory_item_aliases for select to authenticated using(public.is_staff());
create policy "Equipe consulta cobertura de produtos" on public.order_product_fulfillments for select to authenticated using(public.is_staff());

grant select on public.inventory_product_balances,public.inventory_product_movements,public.inventory_item_aliases,public.order_product_fulfillments,public.inventory_catalog,public.inventory_all_balances to authenticated;
revoke all on function public.resolve_inventory_item(text) from public;
revoke all on function public.set_inventory_item_balance(text,text,uuid,numeric,text,text,text,text,text) from public;
revoke all on function public.apply_inventory_item_batch(text,text,jsonb,text,text,text,text,text) from public;
revoke all on function public.consume_ready_product_combined(uuid,numeric,uuid) from public;
revoke all on function public.fulfill_order_product_delta(uuid,uuid,numeric) from public;
revoke all on function public.consume_order_inventory(uuid) from public;
revoke all on function public.adjust_order_production_inventory(uuid,text) from public;
revoke all on function public.start_order_production(uuid,text) from public;
grant execute on function public.resolve_inventory_item(text) to authenticated,service_role;
grant execute on function public.set_inventory_item_balance(text,text,uuid,numeric,text,text,text,text,text) to authenticated,service_role;
grant execute on function public.apply_inventory_item_batch(text,text,jsonb,text,text,text,text,text) to authenticated,service_role;
grant execute on function public.consume_order_inventory(uuid) to authenticated,service_role;
grant execute on function public.adjust_order_production_inventory(uuid,text) to authenticated,service_role;
grant execute on function public.start_order_production(uuid,text) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
