begin;

-- V7.4.6 — unifica dinheiro físico dos dois baús com o Caixa e evita
-- notificações duplicadas de novas encomendas.

-- ---------------------------------------------------------------------------
-- 1. Fila de novas encomendas com captura atômica
-- ---------------------------------------------------------------------------
alter table public.order_integration_events
  add column if not exists status text not null default 'pending',
  add column if not exists attempts integer not null default 0,
  add column if not exists last_error text,
  add column if not exists processing_at timestamptz,
  add column if not exists discord_message_id text;

alter table public.order_integration_events
  drop constraint if exists order_integration_events_status_check;
alter table public.order_integration_events
  add constraint order_integration_events_status_check
  check (status in ('pending','processing','completed','failed'));

update public.order_integration_events
set status = case when processed_at is null then 'pending' else 'completed' end
where status is null
   or (processed_at is not null and status <> 'completed');

create index if not exists order_integration_events_status_idx
  on public.order_integration_events(status, created_at);

-- Eventos antigos de criação presentes na outbox são a segunda fonte que
-- causava a mesma encomenda ser enviada duas vezes. A partir desta versão,
-- order_integration_events é a única fila para NOVA ENCOMENDA.
update public.integration_outbox io
set status = 'completed',
    processed_at = coalesce(io.processed_at, now()),
    last_error = null
where io.event_type = 'order_created'
  and io.status in ('pending','processing','failed')
  and exists (
    select 1
    from public.order_integration_events oe
    where oe.order_id = io.entity_id
      and oe.event_type = 'created'
  );

-- ---------------------------------------------------------------------------
-- 2. Dinheiro e Dinheiro Sujo: movimento único no estoque + histórico do caixa
-- ---------------------------------------------------------------------------
create or replace function public.register_cash_inventory_movement(
  p_stock_scope text,
  p_payment_type text,
  p_movement_type text,
  p_amount numeric,
  p_description text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stock public.inventory_stocks;
  v_material public.materials;
  v_before numeric := 0;
  v_after numeric := 0;
  v_inventory_type text;
  v_material_name text;
begin
  if not public.is_staff() then
    raise exception 'Acesso negado.';
  end if;
  if p_stock_scope not in ('geral','gerencia') then
    raise exception 'Baú inválido.';
  end if;
  if p_payment_type not in ('clean','dirty') then
    raise exception 'Tipo de dinheiro inválido.';
  end if;
  if p_movement_type not in ('entry','exit') then
    raise exception 'Tipo de movimentação inválido.';
  end if;
  if coalesce(p_amount,0) <= 0 then
    raise exception 'Informe um valor maior que zero.';
  end if;
  if nullif(trim(p_description),'') is null then
    raise exception 'Informe uma descrição.';
  end if;

  v_material_name := case when p_payment_type = 'dirty' then 'dinheiro sujo' else 'dinheiro' end;

  select * into v_stock
  from public.inventory_stocks
  where scope = p_stock_scope and is_active = true
  limit 1;
  if not found then raise exception 'Baú não encontrado.'; end if;

  select * into v_material
  from public.materials
  where is_active = true
    and lower(trim(name)) = v_material_name
  limit 1;
  if not found then
    raise exception 'Material % não encontrado. Mantenha o cadastro como Dinheiro ou Dinheiro Sujo.', initcap(v_material_name);
  end if;

  insert into public.inventory_balances(stock_id, material_id, quantity, reserved_quantity)
  values(v_stock.id, v_material.id, 0, 0)
  on conflict (stock_id, material_id) do nothing;

  select quantity into v_before
  from public.inventory_balances
  where stock_id = v_stock.id and material_id = v_material.id
  for update;

  if p_movement_type = 'exit' and v_before < p_amount then
    raise exception 'Saldo insuficiente no baú %. Disponível: %.', v_stock.name, v_before;
  end if;

  v_after := case
    when p_movement_type = 'entry' then v_before + p_amount
    else v_before - p_amount
  end;
  v_inventory_type := case when p_movement_type = 'entry' then 'adjustment_entry' else 'adjustment_exit' end;

  update public.inventory_balances
  set quantity = v_after, updated_at = now()
  where stock_id = v_stock.id and material_id = v_material.id;

  insert into public.inventory_movements(
    stock_id, material_id, movement_type, quantity,
    balance_before, balance_after, source, reason, registered_by
  ) values (
    v_stock.id, v_material.id, v_inventory_type, p_amount,
    v_before, v_after, 'site', trim(p_description), auth.uid()
  );

  insert into public.cash_movements(
    movement_type, description, amount, registered_by, source, payment_type
  ) values (
    p_movement_type,
    trim(p_description) || ' · ' || v_stock.name,
    p_amount,
    auth.uid(),
    'site',
    p_payment_type
  );

  insert into public.activity_logs(user_id, action, entity_type, entity_id, description, new_data)
  values(
    auth.uid(),
    'cash_inventory_' || p_movement_type,
    'material',
    v_material.id,
    trim(p_description),
    jsonb_build_object(
      'stock_scope', p_stock_scope,
      'payment_type', p_payment_type,
      'amount', p_amount,
      'balance_before', v_before,
      'balance_after', v_after
    )
  );

  return jsonb_build_object(
    'stock_scope', p_stock_scope,
    'payment_type', p_payment_type,
    'movement_type', p_movement_type,
    'amount', p_amount,
    'balance_before', v_before,
    'balance_after', v_after
  );
end;
$$;

revoke all on function public.register_cash_inventory_movement(text,text,text,numeric,text) from public;
grant execute on function public.register_cash_inventory_movement(text,text,text,numeric,text) to authenticated;

notify pgrst, 'reload schema';
commit;
