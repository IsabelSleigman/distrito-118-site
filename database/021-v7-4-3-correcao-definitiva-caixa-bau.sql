begin;

-- V7.4.3 — correção definitiva do caixa/baú.
-- O baú é apenas localização física do dinheiro da família.
-- Confirmar depósito NÃO é entrada nem saída financeira.

-- Remove somente pseudo-movimentações de baú criadas pelas versões 7.4/7.4.2.
-- A informação de quais pedidos já estão no baú permanece em orders.vault_deposited_at.
delete from public.cash_movements
where source = 'vault';

-- O índice não é mais necessário porque depósitos não criam cash_movements.
drop index if exists public.cash_movements_order_vault_unique;

create or replace function public.mark_orders_vault_deposited(p_order_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_id uuid;
  v_order public.orders;
  v_count integer:=0;
  v_total numeric(14,2):=0;
begin
  if auth.uid() is null then raise exception 'Sessão expirada. Entre novamente no painel.'; end if;
  if not public.is_staff() then raise exception 'Usuário sem permissão para movimentar o caixa.'; end if;
  if p_order_ids is null or array_length(p_order_ids,1) is null then raise exception 'Selecione pelo menos uma encomenda.'; end if;

  foreach v_id in array p_order_ids loop
    select * into v_order
    from public.orders
    where id=v_id and deleted_at is null
    for update;

    if not found then raise exception 'Encomenda não encontrada.'; end if;
    if v_order.status <> 'delivered' or v_order.cash_posted_at is null then
      raise exception 'A encomenda % ainda não foi finalizada no caixa.',v_order.code;
    end if;
    if v_order.vault_deposited_at is not null then continue; end if;

    update public.orders
    set vault_deposited_at=now(),
        vault_deposited_by=auth.uid(),
        updated_at=now()
    where id=v_order.id;

    insert into public.activity_logs(user_id,action,entity_type,entity_id,description,new_data)
    values(
      auth.uid(),
      'update',
      'order',
      v_order.id,
      'Valor líquido da encomenda confirmado no baú da família.',
      jsonb_build_object(
        'order_code',v_order.code,
        'net_amount',v_order.net_amount,
        'payment_type',v_order.payment_type,
        'vault_deposited',true
      )
    );

    v_count:=v_count+1;
    v_total:=v_total+coalesce(v_order.net_amount,0);
  end loop;

  return jsonb_build_object('success',true,'orders_count',v_count,'total',v_total);
end;
$$;

revoke all on function public.mark_orders_vault_deposited(uuid[]) from public;
grant execute on function public.mark_orders_vault_deposited(uuid[]) to authenticated;

create or replace function public.undo_order_vault_deposit(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_order public.orders;
begin
  if not public.is_admin() then raise exception 'Apenas administradores podem desfazer um depósito no baú.'; end if;

  select * into v_order
  from public.orders
  where id=p_order_id and deleted_at is null
  for update;

  if not found then raise exception 'Encomenda não encontrada.'; end if;
  if v_order.vault_deposited_at is null then raise exception 'Esta encomenda não está marcada como depositada.'; end if;

  update public.orders
  set vault_deposited_at=null,
      vault_deposited_by=null,
      updated_at=now()
  where id=p_order_id;

  insert into public.activity_logs(user_id,action,entity_type,entity_id,description,new_data)
  values(
    auth.uid(),
    'update',
    'order',
    p_order_id,
    'Confirmação de baú desfeita; valor voltou para aguardando depósito.',
    jsonb_build_object('vault_deposited',false)
  );

  return jsonb_build_object('success',true,'order_id',p_order_id);
end;
$$;

revoke all on function public.undo_order_vault_deposit(uuid) from public;
grant execute on function public.undo_order_vault_deposit(uuid) to authenticated;

-- Ao mudar Limpo/Sujo de um pedido já guardado, apenas reabre a conferência
-- física. Não existe movimentação financeira de baú para excluir.
create or replace function public.update_order_payment_type(
  p_order_id uuid,
  p_payment_type text
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order public.orders;
  v_previous_type text;
  v_clean numeric(14,2);
  v_dirty numeric(14,2);
  v_final numeric(14,2);
  v_commission numeric(14,2);
  v_net numeric(14,2);
  v_reopened_vault boolean:=false;
begin
  if auth.uid() is null then raise exception 'Sessão expirada. Entre novamente no painel.'; end if;
  if not public.is_staff() then raise exception 'Usuário sem permissão para alterar encomendas.'; end if;
  if p_payment_type not in ('clean','dirty') then raise exception 'Forma de pagamento inválida.'; end if;

  select * into v_order
  from public.orders
  where id=p_order_id and deleted_at is null
  for update;
  if not found then raise exception 'Encomenda não encontrada.'; end if;

  v_previous_type:=v_order.payment_type;
  if v_previous_type=p_payment_type then
    return jsonb_build_object('success',true,'changed',false,'order_id',p_order_id,'payment_type',p_payment_type);
  end if;

  select coalesce(sum(subtotal),v_order.clean_amount,v_order.total_amount,0)
  into v_clean
  from public.order_items
  where order_id=p_order_id;

  v_dirty:=round(v_clean*1.30,2);
  v_final:=case when p_payment_type='dirty' then v_dirty else v_clean end;
  v_commission:=round(v_final*v_order.commission_rate,2);
  v_net:=round(v_final-v_commission,2);

  if v_order.vault_deposited_at is not null then
    v_reopened_vault:=true;
  end if;

  update public.orders
  set payment_type=p_payment_type,
      total_amount=v_clean,
      clean_amount=v_clean,
      dirty_amount=v_dirty,
      final_amount=v_final,
      commission_amount=v_commission,
      net_amount=v_net,
      vault_deposited_at=case when v_reopened_vault then null else vault_deposited_at end,
      vault_deposited_by=case when v_reopened_vault then null else vault_deposited_by end,
      updated_at=now()
  where id=p_order_id
  returning * into v_order;

  if v_order.cash_posted_at is not null then
    update public.cash_movements
    set amount=v_final,
        description='Venda da encomenda '||v_order.code,
        payment_type=p_payment_type
    where order_id=p_order_id and source='order' and movement_type='entry';

    update public.cash_movements
    set amount=v_commission,
        description='Comissão de 20% da encomenda '||v_order.code,
        payment_type=p_payment_type
    where order_id=p_order_id and source='order' and movement_type='exit';
  end if;

  insert into public.activity_logs(user_id,action,entity_type,entity_id,description,new_data)
  values(auth.uid(),'update','order',p_order_id,
    'Forma de pagamento alterada de '||case when v_previous_type='dirty' then 'dinheiro sujo' else 'dinheiro limpo' end||
    ' para '||case when p_payment_type='dirty' then 'dinheiro sujo' else 'dinheiro limpo' end||'.',
    jsonb_build_object(
      'previous_payment_type',v_previous_type,
      'payment_type',p_payment_type,
      'final_amount',v_final,
      'commission_amount',v_commission,
      'net_amount',v_net,
      'vault_reopened',v_reopened_vault
    ));

  return jsonb_build_object(
    'success',true,
    'changed',true,
    'order_id',p_order_id,
    'previous_payment_type',v_previous_type,
    'payment_type',p_payment_type,
    'final_amount',v_final,
    'commission_amount',v_commission,
    'net_amount',v_net,
    'vault_reopened',v_reopened_vault
  );
end;
$$;

revoke all on function public.update_order_payment_type(uuid,text) from public;
grant execute on function public.update_order_payment_type(uuid,text) to authenticated;

commit;
