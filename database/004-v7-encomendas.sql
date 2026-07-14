begin;

-- V7 — encomendas, timeline e exclusão lógica.

alter table public.orders add column if not exists deleted_at timestamptz;
alter table public.orders add column if not exists deleted_by uuid;

create table if not exists public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  status text not null,
  note text,
  changed_by uuid,
  created_at timestamptz not null default now()
);

create index if not exists order_status_history_order_created_idx
  on public.order_status_history(order_id, created_at);

alter table public.order_status_history enable row level security;

drop policy if exists "Staff pode consultar histórico de encomendas" on public.order_status_history;
create policy "Staff pode consultar histórico de encomendas"
  on public.order_status_history for select to authenticated
  using (public.is_staff());

drop policy if exists "Staff pode inserir histórico de encomendas" on public.order_status_history;
create policy "Staff pode inserir histórico de encomendas"
  on public.order_status_history for insert to authenticated
  with check (public.is_staff());

create or replace function public.register_order_status_history()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.order_status_history(order_id,status,note,changed_by)
    values (new.id,new.status,'Encomenda criada.',auth.uid());
  elsif new.status is distinct from old.status then
    insert into public.order_status_history(order_id,status,note,changed_by)
    values (new.id,new.status,null,auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists orders_register_status_history on public.orders;
create trigger orders_register_status_history
after insert or update of status on public.orders
for each row execute function public.register_order_status_history();

-- Garante um primeiro evento para encomendas antigas.
insert into public.order_status_history(order_id,status,note,created_at)
select o.id,o.status,'Histórico iniciado na atualização V7.',coalesce(o.created_at,now())
from public.orders o
where not exists (
  select 1 from public.order_status_history h where h.order_id=o.id
);

create or replace function public.soft_delete_order(input_order_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_staff() then
    raise exception 'Acesso negado.';
  end if;

  update public.orders
  set deleted_at=now(), deleted_by=auth.uid()
  where id=input_order_id and deleted_at is null;

  if not found then
    raise exception 'Encomenda não encontrada ou já excluída.';
  end if;
end;
$$;

grant execute on function public.soft_delete_order(uuid) to authenticated;

create or replace function public.get_public_order_timeline(input_code text,input_public_token uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  target_order public.orders;
begin
  select * into target_order
  from public.orders
  where upper(code)=upper(trim(input_code))
    and public_token=input_public_token
    and deleted_at is null;

  if not found then return null; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'status',h.status,
      'note',h.note,
      'created_at',h.created_at
    ) order by h.created_at)
    from public.order_status_history h
    where h.order_id=target_order.id
  ),'[]'::jsonb);
end;
$$;

grant execute on function public.get_public_order_timeline(text,uuid) to anon,authenticated;

commit;
