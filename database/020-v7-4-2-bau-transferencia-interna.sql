begin;

-- V7.4.2 — Depósito no baú é transferência interna, não despesa.
-- Os registros source='vault' permanecem rastreáveis no histórico,
-- mas devem ser tratados como transferência interna nas telas e relatórios,
-- nunca como redução do patrimônio da família.

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
    select * into v_order from public.orders where id=v_id and deleted_at is null for update;
    if not found then raise exception 'Encomenda não encontrada.'; end if;
    if v_order.status<>'delivered' or v_order.cash_posted_at is null then
      raise exception 'A encomenda % ainda não foi finalizada no caixa.',v_order.code;
    end if;
    if v_order.vault_deposited_at is not null then continue; end if;

    -- source='vault' identifica uma transferência interna. O movement_type
    -- continua 'exit' por compatibilidade com o schema legado, mas NÃO deve
    -- ser somado como despesa no saldo financeiro da família.
    insert into public.cash_movements(movement_type,description,amount,order_id,registered_by,source,payment_type)
    values('exit','Transferência para o baú da família — '||v_order.code,v_order.net_amount,v_order.id,auth.uid(),'vault',v_order.payment_type)
    on conflict do nothing;

    update public.orders
    set vault_deposited_at=now(),vault_deposited_by=auth.uid(),updated_at=now()
    where id=v_order.id;

    v_count:=v_count+1;
    v_total:=v_total+v_order.net_amount;
  end loop;

  insert into public.activity_logs(user_id,action,entity_type,description,new_data)
  values(auth.uid(),'update','cash','Transferência interna para o baú confirmada.',jsonb_build_object('orders_count',v_count,'total',v_total));

  return jsonb_build_object('success',true,'orders_count',v_count,'total',v_total);
end;
$$;

revoke all on function public.mark_orders_vault_deposited(uuid[]) from public;
grant execute on function public.mark_orders_vault_deposited(uuid[]) to authenticated;

-- Ajusta a descrição dos registros já criados, sem alterar valores.
update public.cash_movements
set description = regexp_replace(description, '^Depósito no baú da família', 'Transferência para o baú da família')
where source='vault' and description like 'Depósito no baú da família%';

commit;
