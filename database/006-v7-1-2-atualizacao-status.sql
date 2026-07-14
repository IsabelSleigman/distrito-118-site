begin;

-- V7.1.2 — atualização de status por RPC.
-- Evita bloqueios de RLS no navegador e salva a observação de forma atômica.

create or replace function public.update_order_status(
  input_order_id uuid,
  input_status text,
  input_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_status text;
  history_id uuid;
begin
  if not public.is_staff() then
    raise exception 'Acesso negado.';
  end if;

  if input_status not in (
    'pending',
    'under_review',
    'accepted',
    'waiting_materials',
    'in_production',
    'ready',
    'awaiting_delivery',
    'delivered',
    'rejected',
    'cancelled'
  ) then
    raise exception 'Status inválido.';
  end if;

  select status
    into current_status
  from public.orders
  where id = input_order_id
    and deleted_at is null
  for update;

  if not found then
    raise exception 'Encomenda não encontrada.';
  end if;

  if current_status is distinct from input_status then
    -- O trigger orders_register_status_history cria o evento da timeline.
    update public.orders
    set status = input_status
    where id = input_order_id;
  end if;

  select id
    into history_id
  from public.order_status_history
  where order_id = input_order_id
    and status = input_status
  order by created_at desc
  limit 1;

  -- Caso não exista evento (por exemplo, status igual ao atual em banco legado), cria um.
  if history_id is null then
    insert into public.order_status_history (
      order_id,
      status,
      note,
      changed_by,
      created_at
    ) values (
      input_order_id,
      input_status,
      nullif(trim(input_note), ''),
      auth.uid(),
      now()
    )
    returning id into history_id;
  elsif nullif(trim(input_note), '') is not null then
    update public.order_status_history
    set note = nullif(trim(input_note), '')
    where id = history_id;
  end if;

  return jsonb_build_object(
    'order_id', input_order_id,
    'status', input_status,
    'history_id', history_id
  );
end;
$$;

revoke all on function public.update_order_status(uuid,text,text) from public;
grant execute on function public.update_order_status(uuid,text,text) to authenticated;

commit;
