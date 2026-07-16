begin;

-- V7.2.4 — evita histórico duplicado e preserva a RPC como única responsável por mudanças de status.
drop trigger if exists orders_register_status_change on public.orders;

-- Limpa registros consecutivos repetidos, mesmo quando notas antigas diferem.
with ordered as (
  select id, order_id, status, created_at,
         lag(status) over(partition by order_id order by created_at,id) as previous_status
  from public.order_status_history
), duplicates as (
  select id from ordered where status=previous_status
)
delete from public.order_status_history h
using duplicates d
where h.id=d.id;

-- Proteção adicional: não insere novamente o mesmo status se ele já for o último da encomenda.
create or replace function public.prevent_duplicate_order_status_history()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_last_status text;
begin
  select status into v_last_status
  from public.order_status_history
  where order_id=new.order_id
  order by created_at desc,id desc
  limit 1;
  if v_last_status is not distinct from new.status then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists order_status_history_prevent_duplicate on public.order_status_history;
create trigger order_status_history_prevent_duplicate
before insert on public.order_status_history
for each row execute function public.prevent_duplicate_order_status_history();

notify pgrst,'reload schema';
commit;
