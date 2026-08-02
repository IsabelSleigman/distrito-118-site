begin;

-- Registra o responsável informado na confirmação e gera um único evento
-- que o bot distribui entre os canais de saída Geral, Gerência e histórico.
drop function if exists public.start_order_production(uuid);

create or replace function public.start_order_production(
  p_order_id uuid,
  p_responsible_name text
)
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
  v_responsible_name text;
  v_movements jsonb;
begin
  v_responsible_name := regexp_replace(trim(coalesce(p_responsible_name,'')), '\s+', ' ', 'g');
  if length(v_responsible_name) < 3 then
    raise exception 'Informe o nome RP do responsável pela baixa.';
  end if;
  if length(v_responsible_name) > 120 then
    raise exception 'O nome do responsável é muito longo.';
  end if;

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

  if not v_already then
    update public.orders
       set status='in_production',
           production_responsible=v_responsible_name,
           updated_at=now()
     where id=p_order_id;

    insert into public.productions(order_id,status,responsible_id,started_at,notes)
    values(p_order_id,'in_progress',auth.uid(),now(),'Produção iniciada por '||v_responsible_name||'.')
    on conflict(order_id) do update
      set status='in_progress',
          responsible_id=excluded.responsible_id,
          started_at=coalesce(public.productions.started_at,excluded.started_at),
          notes=excluded.notes,
          updated_at=now();

    insert into public.order_status_history(order_id,previous_status,new_status,changed_by,notes,status,note,old_status)
    values(
      p_order_id,v_previous_status,'in_production',auth.uid(),
      'Materiais baixados por '||v_responsible_name||' e produção iniciada.',
      'in_production','Materiais baixados por '||v_responsible_name||' e produção iniciada.',v_previous_status
    );

    select coalesce(jsonb_agg(jsonb_build_object(
      'movement_id', im.id,
      'material', m.name,
      'quantity', im.quantity,
      'movement_type', im.movement_type,
      'scope', s.scope,
      'stock_name', s.name
    ) order by s.scope, m.name), '[]'::jsonb)
      into v_movements
    from public.inventory_movements im
    join public.materials m on m.id=im.material_id
    join public.inventory_stocks s on s.id=im.stock_id
    where im.order_id=p_order_id
      and im.source='order'
      and im.movement_type='production_consumption';

    insert into public.integration_outbox(
      event_type,entity_type,entity_id,payload,status,destination
    ) values (
      'order_inventory_consumed','order',p_order_id,
      jsonb_build_object(
        'code',v_order_code,
        'customer_name',v_customer_name,
        'responsible_name',v_responsible_name,
        'operator_id',auth.uid(),
        'previous_status',v_previous_status,
        'status','in_production',
        'movements',v_movements,
        'note','Baixa realizada pelo site.'
      ),
      'pending','order_history'
    ) on conflict do nothing;
  end if;

  return v_result || jsonb_build_object(
    'status','in_production',
    'responsible_name',v_responsible_name
  );
end;
$$;

revoke all on function public.start_order_production(uuid,text) from public;
grant execute on function public.start_order_production(uuid,text) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
