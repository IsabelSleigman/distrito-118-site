begin;

-- V7.1.3 — correção definitiva da atualização de status.
-- Usa um novo nome de RPC para evitar cache de schema/assinaturas antigas no Supabase.

-- Compatibilidade com estruturas legadas da tabela de histórico.
alter table public.order_status_history
  add column if not exists status text;
alter table public.order_status_history
  add column if not exists note text;
alter table public.order_status_history
  add column if not exists changed_by uuid;
alter table public.order_status_history
  add column if not exists created_at timestamptz default now();

-- Colunas antigas não podem impedir novos registros.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='order_status_history' and column_name='new_status'
  ) then
    execute 'alter table public.order_status_history alter column new_status drop not null';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='order_status_history' and column_name='old_status'
  ) then
    execute 'alter table public.order_status_history alter column old_status drop not null';
  end if;
end $$;

create or replace function public.update_order_status_v2(
  p_order_id uuid,
  p_status text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_status text;
  v_history_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sessão expirada. Entre novamente no painel.';
  end if;

  if not public.is_staff() then
    raise exception 'Usuário sem permissão para alterar encomendas.';
  end if;

  if p_status not in (
    'pending','under_review','accepted','waiting_materials','in_production',
    'ready','awaiting_delivery','delivered','rejected','cancelled'
  ) then
    raise exception 'Status inválido: %', p_status;
  end if;

  select status into v_current_status
  from public.orders
  where id = p_order_id and deleted_at is null
  for update;

  if not found then
    raise exception 'Encomenda não encontrada.';
  end if;

  update public.orders
  set status = p_status
  where id = p_order_id;

  -- O trigger normalmente cria o histórico. Recupera o evento recém-criado.
  select id into v_history_id
  from public.order_status_history
  where order_id = p_order_id and status = p_status
  order by created_at desc
  limit 1;

  -- Se o status era o mesmo, o trigger não cria evento; cria aqui.
  if v_history_id is null or v_current_status is not distinct from p_status then
    insert into public.order_status_history(order_id,status,note,changed_by,created_at)
    values (p_order_id,p_status,nullif(trim(p_note),''),auth.uid(),now())
    returning id into v_history_id;
  elsif nullif(trim(p_note),'') is not null then
    update public.order_status_history
    set note = nullif(trim(p_note),'')
    where id = v_history_id;
  end if;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'previous_status', v_current_status,
    'status', p_status,
    'history_id', v_history_id
  );
end;
$$;

revoke all on function public.update_order_status_v2(uuid,text,text) from public;
grant execute on function public.update_order_status_v2(uuid,text,text) to authenticated;

-- Atualiza imediatamente o cache de schema do PostgREST.
notify pgrst, 'reload schema';

commit;
