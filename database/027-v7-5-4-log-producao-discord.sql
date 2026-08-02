begin;

alter table public.integration_outbox
  drop constraint if exists integration_outbox_event_type_check;

alter table public.integration_outbox
  add constraint integration_outbox_event_type_check check (
    event_type = any (array[
      'order_created'::text,
      'order_accepted'::text,
      'order_ready'::text,
      'order_delivered'::text,
      'order_rejected'::text,
      'order_status_changed'::text,
      'order_inventory_consumed'::text,
      'low_stock'::text
    ])
  );

create unique index if not exists integration_outbox_order_inventory_consumed_uidx
  on public.integration_outbox(entity_id, event_type)
  where event_type = 'order_inventory_consumed';

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
  v_order_code text;
  v_customer_name text;
  v_operator_name text;
  v_movements jsonb;
begin
  select status, code, coalesce(cnpj_name, customer_name)
    into v_previous_status, v_order_code, v_customer_name
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

    select coalesce(p.name,p.email,'Usuário do site')
      into v_operator_name
    from public.profiles p
    where p.id=auth.uid();

    select coalesce(jsonb_agg(jsonb_build_object(
      'movement_id', im.id,
      'material', m.name,
      'quantity', im.quantity,
      'before', im.balance_before,
      'after', im.balance_after,
      'movement_type', im.movement_type,
      'scope', s.scope,
      'stock_name', s.name,
      'reason', im.reason
    ) order by im.created_at, m.name), '[]'::jsonb)
      into v_movements
    from public.inventory_movements im
    join public.materials m on m.id=im.material_id
    join public.inventory_stocks s on s.id=im.stock_id
    where im.order_id=p_order_id
      and im.source='order'
      and im.movement_type in ('production_consumption','entry');

    insert into public.integration_outbox(
      event_type,entity_type,entity_id,payload,status,destination
    ) values (
      'order_inventory_consumed','order',p_order_id,
      jsonb_build_object(
        'code',v_order_code,
        'customer_name',v_customer_name,
        'operator_id',auth.uid(),
        'operator_name',coalesce(v_operator_name,'Usuário do site'),
        'previous_status',v_previous_status,
        'status','in_production',
        'movements',v_movements,
        'note','Baixa de materiais confirmada no site e produção iniciada.'
      ),
      'pending','order_history'
    ) on conflict do nothing;
  end if;

  return v_result || jsonb_build_object('status','in_production');
end;
$$;

revoke all on function public.start_order_production(uuid) from public;
grant execute on function public.start_order_production(uuid) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
