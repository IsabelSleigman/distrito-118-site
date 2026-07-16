begin;

-- V7.3.2 — reparo autossuficiente do estoque unificado.
-- Pode ser executado mesmo quando as migrations 015/016 não foram aplicadas.

-- Estoques separados, compartilhados pelo site e pelo bot.
create table if not exists public.inventory_stocks (
  id uuid primary key default gen_random_uuid(),
  scope text not null unique check (scope in ('geral','gerencia')),
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.inventory_balances (
  stock_id uuid not null references public.inventory_stocks(id) on delete cascade,
  material_id uuid not null references public.materials(id) on delete cascade,
  quantity numeric not null default 0 check (quantity >= 0),
  reserved_quantity numeric not null default 0 check (reserved_quantity >= 0),
  updated_at timestamptz not null default now(),
  primary key (stock_id, material_id)
);

create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  stock_id uuid not null references public.inventory_stocks(id),
  material_id uuid not null references public.materials(id),
  movement_type text not null check (movement_type in ('entry','exit','adjustment_entry','adjustment_exit','production_consumption')),
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

create unique index if not exists inventory_movements_operation_key_uq
  on public.inventory_movements(operation_key)
  where operation_key is not null;

create table if not exists public.order_inventory_consumptions (
  order_id uuid primary key references public.orders(id) on delete cascade,
  stock_id uuid not null references public.inventory_stocks(id),
  consumed_at timestamptz not null default now()
);

insert into public.inventory_stocks(scope,name)
values ('geral','Estoque Geral'),('gerencia','Estoque da Gerência')
on conflict (scope) do update set name=excluded.name,is_active=true,updated_at=now();

-- O estoque que já existia no site passa a representar a Gerência.
insert into public.inventory_balances(stock_id,material_id,quantity,reserved_quantity)
select s.id,m.id,greatest(0,m.stock_quantity),greatest(0,m.reserved_quantity)
from public.inventory_stocks s
cross join public.materials m
where s.scope='gerencia'
on conflict (stock_id,material_id) do nothing;

-- O baú geral começa zerado e pode ser conferido pelo comando do bot.
insert into public.inventory_balances(stock_id,material_id,quantity,reserved_quantity)
select s.id,m.id,0,0
from public.inventory_stocks s
cross join public.materials m
where s.scope='geral'
on conflict (stock_id,material_id) do nothing;

alter table public.orders add column if not exists stock_scope text not null default 'gerencia';
alter table public.orders drop constraint if exists orders_stock_scope_check;
alter table public.orders add constraint orders_stock_scope_check check (stock_scope in ('geral','gerencia'));

create or replace function public.set_order_stock_scope(p_order_id uuid,p_scope text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_staff() then raise exception 'Acesso negado.'; end if;
  if p_scope not in ('geral','gerencia') then raise exception 'Estoque inválido.'; end if;
  update public.orders set stock_scope=p_scope,updated_at=now()
  where id=p_order_id and deleted_at is null and status not in ('ready','delivered','cancelled');
  if not found then raise exception 'Encomenda não encontrada ou já finalizada.'; end if;
  return jsonb_build_object('success',true,'order_id',p_order_id,'stock_scope',p_scope);
end;
$$;
grant execute on function public.set_order_stock_scope(uuid,text) to authenticated;

create or replace function public.apply_inventory_batch(
  p_scope text,
  p_movement_type text,
  p_items jsonb,
  p_source text default 'discord',
  p_reason text default null,
  p_operation_key text default null,
  p_discord_user_id text default null,
  p_discord_user_name text default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_stock_id uuid;
  v_item jsonb;
  v_material_id uuid;
  v_quantity numeric;
  v_before numeric;
  v_after numeric;
  v_results jsonb := '[]'::jsonb;
begin
  if p_scope not in ('geral','gerencia') then raise exception 'Estoque inválido.'; end if;
  if p_movement_type not in ('entry','exit') then raise exception 'Movimentação inválida.'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Informe ao menos um item.'; end if;
  if p_operation_key is not null and exists(select 1 from public.inventory_movements where operation_key like p_operation_key||':%') then
    raise exception 'Esta movimentação já foi processada.';
  end if;

  select id into v_stock_id from public.inventory_stocks where scope=p_scope and is_active=true;
  if v_stock_id is null then raise exception 'Estoque não configurado.'; end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_material_id := (v_item->>'material_id')::uuid;
    v_quantity := (v_item->>'quantity')::numeric;
    if v_quantity <= 0 then raise exception 'Quantidade inválida.'; end if;

    insert into public.inventory_balances(stock_id,material_id,quantity)
    values(v_stock_id,v_material_id,0)
    on conflict do nothing;

    select quantity into v_before from public.inventory_balances
    where stock_id=v_stock_id and material_id=v_material_id for update;
    v_after := case when p_movement_type='entry' then v_before+v_quantity else v_before-v_quantity end;
    if v_after < 0 then raise exception 'Estoque insuficiente para o material %.',v_material_id; end if;

    update public.inventory_balances set quantity=v_after,updated_at=now()
    where stock_id=v_stock_id and material_id=v_material_id;

    insert into public.inventory_movements(
      stock_id,material_id,movement_type,quantity,balance_before,balance_after,source,reason,
      operation_key,discord_user_id,discord_user_name,registered_by
    ) values (
      v_stock_id,v_material_id,case when p_movement_type='entry' then 'entry' else 'exit' end,
      v_quantity,v_before,v_after,coalesce(p_source,'discord'),p_reason,
      case when p_operation_key is null then null else p_operation_key||':'||v_material_id::text end,
      p_discord_user_id,p_discord_user_name,auth.uid()
    );

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'material_id',v_material_id,'quantity',v_quantity,'before',v_before,'after',v_after
    ));
  end loop;
  return jsonb_build_object('success',true,'scope',p_scope,'items',v_results);
end;
$$;
revoke all on function public.apply_inventory_batch(text,text,jsonb,text,text,text,text,text) from public;
grant execute on function public.apply_inventory_batch(text,text,jsonb,text,text,text,text,text) to authenticated,service_role;

create or replace function public.set_inventory_balance(
  p_scope text,p_material_id uuid,p_quantity numeric,p_reason text default 'Conferência física',
  p_source text default 'discord',p_operation_key text default null,p_discord_user_id text default null,p_discord_user_name text default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_stock_id uuid; v_before numeric; v_type text;
begin
  if p_quantity < 0 then raise exception 'Quantidade inválida.'; end if;
  select id into v_stock_id from public.inventory_stocks where scope=p_scope and is_active=true;
  if v_stock_id is null then raise exception 'Estoque inválido.'; end if;
  insert into public.inventory_balances(stock_id,material_id,quantity) values(v_stock_id,p_material_id,0) on conflict do nothing;
  select quantity into v_before from public.inventory_balances where stock_id=v_stock_id and material_id=p_material_id for update;
  update public.inventory_balances set quantity=p_quantity,updated_at=now() where stock_id=v_stock_id and material_id=p_material_id;
  if p_quantity <> v_before then
    v_type := case when p_quantity>v_before then 'adjustment_entry' else 'adjustment_exit' end;
    insert into public.inventory_movements(stock_id,material_id,movement_type,quantity,balance_before,balance_after,source,reason,operation_key,discord_user_id,discord_user_name,registered_by)
    values(v_stock_id,p_material_id,v_type,abs(p_quantity-v_before),v_before,p_quantity,p_source,p_reason,p_operation_key,p_discord_user_id,p_discord_user_name,auth.uid())
    on conflict (operation_key) where operation_key is not null do nothing;
  end if;
  return jsonb_build_object('success',true,'before',v_before,'after',p_quantity);
end;
$$;
revoke all on function public.set_inventory_balance(text,uuid,numeric,text,text,text,text,text) from public;
grant execute on function public.set_inventory_balance(text,uuid,numeric,text,text,text,text,text) to authenticated,service_role;

create or replace function public.consume_inventory_material(
  p_stock_id uuid,p_material_id uuid,p_quantity numeric,p_order_id uuid,p_path uuid[] default '{}'
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_available numeric;
  v_use numeric;
  v_remaining numeric;
  v_component record;
  v_code text;
begin
  if p_quantity <= 0 then return; end if;
  if p_material_id = any(p_path) then raise exception 'Receita circular encontrada no material %.',p_material_id; end if;
  insert into public.inventory_balances(stock_id,material_id,quantity) values(p_stock_id,p_material_id,0) on conflict do nothing;
  select quantity into v_available from public.inventory_balances where stock_id=p_stock_id and material_id=p_material_id for update;
  v_use := least(v_available,p_quantity);
  if v_use > 0 then
    update public.inventory_balances set quantity=quantity-v_use,updated_at=now() where stock_id=p_stock_id and material_id=p_material_id;
    select code into v_code from public.orders where id=p_order_id;
    insert into public.inventory_movements(stock_id,material_id,movement_type,quantity,balance_before,balance_after,source,reason,order_id,operation_key,registered_by)
    values(p_stock_id,p_material_id,'production_consumption',v_use,v_available,v_available-v_use,'order','Produção da encomenda '||coalesce(v_code,p_order_id::text),p_order_id,
      null,auth.uid());
  end if;
  v_remaining := p_quantity-v_use;
  if v_remaining <= 0 then return; end if;

  if not exists(select 1 from public.material_components where material_id=p_material_id) then
    raise exception 'Material insuficiente: % (faltam %).',(select name from public.materials where id=p_material_id),v_remaining;
  end if;

  for v_component in
    select component_material_id,quantity_required from public.material_components where material_id=p_material_id
  loop
    perform public.consume_inventory_material(p_stock_id,v_component.component_material_id,v_remaining*v_component.quantity_required,p_order_id,p_path||p_material_id);
  end loop;
end;
$$;

create or replace function public.consume_order_inventory(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_stock_id uuid; v_scope text; v_recipe record;
begin
  if exists(select 1 from public.order_inventory_consumptions where order_id=p_order_id) then
    return jsonb_build_object('success',true,'already_consumed',true);
  end if;
  select o.stock_scope,s.id into v_scope,v_stock_id
  from public.orders o join public.inventory_stocks s on s.scope=o.stock_scope
  where o.id=p_order_id for update;
  if v_stock_id is null then raise exception 'Estoque da encomenda não encontrado.'; end if;

  for v_recipe in
    select pm.material_id,sum(oi.quantity*pm.quantity_required)::numeric as required_quantity
    from public.order_items oi join public.product_materials pm on pm.product_id=oi.product_id
    where oi.order_id=p_order_id
    group by pm.material_id
  loop
    perform public.consume_inventory_material(v_stock_id,v_recipe.material_id,v_recipe.required_quantity,p_order_id,'{}');
  end loop;
  insert into public.order_inventory_consumptions(order_id,stock_id) values(p_order_id,v_stock_id);
  return jsonb_build_object('success',true,'scope',v_scope,'already_consumed',false);
end;
$$;
revoke all on function public.consume_order_inventory(uuid) from public;
grant execute on function public.consume_order_inventory(uuid) to authenticated,service_role;

create or replace function public.consume_order_when_ready()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.status='ready' and old.status is distinct from new.status then
    perform public.consume_order_inventory(new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists orders_consume_inventory_when_ready on public.orders;
create trigger orders_consume_inventory_when_ready
after update of status on public.orders
for each row execute function public.consume_order_when_ready();

alter table public.inventory_stocks enable row level security;
alter table public.inventory_balances enable row level security;
alter table public.inventory_movements enable row level security;

drop policy if exists "Equipe consulta estoques" on public.inventory_stocks;
create policy "Equipe consulta estoques" on public.inventory_stocks for select to authenticated using (public.is_staff());
drop policy if exists "Equipe consulta saldos" on public.inventory_balances;
create policy "Equipe consulta saldos" on public.inventory_balances for select to authenticated using (public.is_staff());
drop policy if exists "Equipe consulta movimentacoes" on public.inventory_movements;
create policy "Equipe consulta movimentacoes" on public.inventory_movements for select to authenticated using (public.is_staff());

grant select on public.inventory_stocks,public.inventory_balances,public.inventory_movements to authenticated;

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

-- Garante que todos os materiais, inclusive os zerados, existam nos dois baús.
insert into public.inventory_balances(stock_id,material_id,quantity,reserved_quantity)
select s.id,m.id,
       case when s.scope='gerencia' then greatest(0,coalesce(m.stock_quantity,0)) else 0 end,
       case when s.scope='gerencia' then greatest(0,coalesce(m.reserved_quantity,0)) else 0 end
from public.inventory_stocks s
cross join public.materials m
on conflict (stock_id,material_id) do nothing;

notify pgrst, 'reload schema';
commit;
