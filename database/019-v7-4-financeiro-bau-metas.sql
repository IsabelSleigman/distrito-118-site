begin;

-- V7.4 — pagamento editável, controle de repasse ao baú e metas semanais.

-- ---------------------------------------------------------------------------
-- Caixa / baú
-- ---------------------------------------------------------------------------

alter table public.orders add column if not exists vault_deposited_at timestamptz;
alter table public.orders add column if not exists vault_deposited_by uuid references public.profiles(id) on delete set null;

alter table public.cash_movements add column if not exists payment_type text;

-- A V7.4 cria movimentações com source='vault'. Versões anteriores do banco
-- restringiam source e não conheciam esse novo valor.
alter table public.cash_movements drop constraint if exists cash_movements_source_check;
alter table public.cash_movements add constraint cash_movements_source_check
  check (source in ('manual','order','site','discord','vault'));
alter table public.cash_movements drop constraint if exists cash_movements_payment_type_check;
alter table public.cash_movements add constraint cash_movements_payment_type_check
  check (payment_type is null or payment_type in ('clean','dirty'));

update public.cash_movements cm
set payment_type=o.payment_type
from public.orders o
where cm.order_id=o.id
  and cm.source in ('order','vault')
  and cm.payment_type is null;

create unique index if not exists cash_movements_order_vault_unique
on public.cash_movements(order_id,source)
where order_id is not null and source='vault';

-- Troca apenas a forma de pagamento. Funciona mesmo depois da entrega.
-- Caso o valor já tenha sido marcado como depositado no baú, o repasse é
-- reaberto como pendente para obrigar uma nova conferência física.
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

  -- Se já houve depósito físico, removemos a baixa de baú e reabrimos a
  -- pendência. Assim o painel nunca diz que um valor corrigido já foi guardado.
  if v_order.vault_deposited_at is not null then
    delete from public.cash_movements where order_id=p_order_id and source='vault';
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

-- Finalização financeira: entra a venda, sai a comissão e o líquido fica
-- pendente de saque/depósito no baú até a equipe confirmar o repasse.
create or replace function public.update_order_status_v2(p_order_id uuid,p_status text,p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_current_status text;
  v_history_id uuid;
  v_order public.orders;
  v_note text:=nullif(trim(coalesce(p_note,'')),'');
begin
  if auth.uid() is null then raise exception 'Sessão expirada. Entre novamente no painel.'; end if;
  if not public.is_staff() then raise exception 'Usuário sem permissão para alterar encomendas.'; end if;
  if p_status not in ('pending','under_review','accepted','waiting_materials','in_production','ready','awaiting_delivery','delivered','rejected','cancelled') then
    raise exception 'Status inválido: %',p_status;
  end if;

  select status into v_current_status from public.orders where id=p_order_id and deleted_at is null for update;
  if not found then raise exception 'Encomenda não encontrada.'; end if;

  if v_current_status is distinct from p_status then
    update public.orders
    set status=p_status,
        delivered_at=case when p_status='delivered' then coalesce(delivered_at,now()) else delivered_at end,
        delivered_by=case when p_status='delivered' then coalesce(delivered_by,auth.uid()) else delivered_by end,
        updated_at=now()
    where id=p_order_id;

    insert into public.order_status_history(order_id,status,note,changed_by,created_at)
    values(p_order_id,p_status,v_note,auth.uid(),now())
    returning id into v_history_id;
  elsif v_note is not null then
    select id into v_history_id
    from public.order_status_history
    where order_id=p_order_id and status=p_status
    order by created_at desc limit 1;

    if v_history_id is not null then
      update public.order_status_history set note=v_note where id=v_history_id;
    end if;
  end if;

  if p_status='delivered' then
    select * into v_order from public.orders where id=p_order_id;

    insert into public.cash_movements(movement_type,description,amount,order_id,registered_by,source,payment_type)
    values('entry','Venda da encomenda '||v_order.code,v_order.final_amount,p_order_id,auth.uid(),'order',v_order.payment_type)
    on conflict do nothing;

    insert into public.cash_movements(movement_type,description,amount,order_id,registered_by,source,payment_type)
    values('exit','Comissão de 20% da encomenda '||v_order.code,v_order.commission_amount,p_order_id,auth.uid(),'order',v_order.payment_type)
    on conflict do nothing;

    -- Corrige registros criados por versões anteriores sem tipo de pagamento.
    update public.cash_movements
    set payment_type=v_order.payment_type
    where order_id=p_order_id and source='order';

    update public.orders set cash_posted_at=coalesce(cash_posted_at,now()) where id=p_order_id;
  end if;

  return jsonb_build_object('success',true,'order_id',p_order_id,'previous_status',v_current_status,'status',p_status,'history_id',v_history_id);
end;
$$;
revoke all on function public.update_order_status_v2(uuid,text,text) from public;
grant execute on function public.update_order_status_v2(uuid,text,text) to authenticated;

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
    if v_order.vault_deposited_at is not null then
      continue;
    end if;

    insert into public.cash_movements(movement_type,description,amount,order_id,registered_by,source,payment_type)
    values('exit','Depósito no baú da família — '||v_order.code,v_order.net_amount,v_order.id,auth.uid(),'vault',v_order.payment_type)
    on conflict do nothing;

    update public.orders
    set vault_deposited_at=now(),vault_deposited_by=auth.uid(),updated_at=now()
    where id=v_order.id;

    v_count:=v_count+1;
    v_total:=v_total+v_order.net_amount;
  end loop;

  insert into public.activity_logs(user_id,action,entity_type,description,new_data)
  values(auth.uid(),'update','cash','Repasse ao baú confirmado.',jsonb_build_object('orders_count',v_count,'total',v_total));

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
  select * into v_order from public.orders where id=p_order_id and deleted_at is null for update;
  if not found then raise exception 'Encomenda não encontrada.'; end if;
  if v_order.vault_deposited_at is null then raise exception 'Esta encomenda não está marcada como depositada.'; end if;

  delete from public.cash_movements where order_id=p_order_id and source='vault';
  update public.orders set vault_deposited_at=null,vault_deposited_by=null,updated_at=now() where id=p_order_id;

  insert into public.activity_logs(user_id,action,entity_type,entity_id,description)
  values(auth.uid(),'update','order',p_order_id,'Depósito no baú desfeito; valor voltou para pendente.');

  return jsonb_build_object('success',true,'order_id',p_order_id);
end;
$$;
revoke all on function public.undo_order_vault_deposit(uuid) from public;
grant execute on function public.undo_order_vault_deposit(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Metas semanais
-- ---------------------------------------------------------------------------

create table if not exists public.weekly_goals (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Meta semanal',
  start_date date not null,
  end_date date not null,
  target_amount numeric(14,2) not null check (target_amount>0),
  status text not null default 'active' check (status in ('active','closed')),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint weekly_goals_period_check check (end_date>start_date)
);

create unique index if not exists weekly_goals_period_unique on public.weekly_goals(start_date,end_date);

create table if not exists public.weekly_goal_members (
  id uuid primary key default gen_random_uuid(),
  goal_id uuid not null references public.weekly_goals(id) on delete cascade,
  profile_id uuid references public.profiles(id) on delete set null,
  member_name text not null,
  discord_user_id text,
  amount_paid numeric(14,2) not null default 0 check (amount_paid>=0),
  paid_at timestamptz,
  notes text,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists weekly_goal_members_profile_unique
on public.weekly_goal_members(goal_id,profile_id)
where profile_id is not null;

create unique index if not exists weekly_goal_members_discord_unique
on public.weekly_goal_members(goal_id,discord_user_id)
where discord_user_id is not null;

alter table public.weekly_goals enable row level security;
alter table public.weekly_goal_members enable row level security;

drop policy if exists "Equipe consulta metas" on public.weekly_goals;
create policy "Equipe consulta metas" on public.weekly_goals for select to authenticated using (public.is_staff());
drop policy if exists "Equipe consulta membros das metas" on public.weekly_goal_members;
create policy "Equipe consulta membros das metas" on public.weekly_goal_members for select to authenticated using (public.is_staff());

grant select on public.weekly_goals, public.weekly_goal_members to authenticated;

create or replace function public.create_weekly_goal(
  p_start_date date,
  p_end_date date,
  p_target_amount numeric,
  p_title text default 'Meta semanal'
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_goal public.weekly_goals; v_profiles integer:=0;
begin
  if not public.is_staff() then raise exception 'Usuário sem permissão para criar metas.'; end if;
  if p_end_date<=p_start_date then raise exception 'A data final precisa ser posterior à inicial.'; end if;
  if (p_end_date-p_start_date)<>7 then raise exception 'A meta semanal deve ter exatamente 7 dias.'; end if;
  if p_target_amount is null or p_target_amount<=0 then raise exception 'Informe um valor de meta maior que zero.'; end if;

  update public.weekly_goals set status='closed',updated_at=now() where status='active';

  insert into public.weekly_goals(title,start_date,end_date,target_amount,status,created_by)
  values(coalesce(nullif(trim(p_title),''),'Meta semanal'),p_start_date,p_end_date,round(p_target_amount,2),'active',auth.uid())
  returning * into v_goal;

  insert into public.weekly_goal_members(goal_id,profile_id,member_name,updated_by)
  select v_goal.id,p.id,coalesce(nullif(trim(p.name),''),p.email,'Membro'),auth.uid()
  from public.profiles p
  where coalesce(p.is_active,true)=true
  on conflict do nothing;
  get diagnostics v_profiles=row_count;

  return jsonb_build_object('success',true,'id',v_goal.id,'members_added',v_profiles);
end;
$$;
revoke all on function public.create_weekly_goal(date,date,numeric,text) from public;
grant execute on function public.create_weekly_goal(date,date,numeric,text) to authenticated;

create or replace function public.sync_weekly_goal_members(p_goal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_count integer:=0;
begin
  if not public.is_staff() then raise exception 'Usuário sem permissão para alterar metas.'; end if;
  if not exists(select 1 from public.weekly_goals where id=p_goal_id) then raise exception 'Meta não encontrada.'; end if;

  insert into public.weekly_goal_members(goal_id,profile_id,member_name,updated_by)
  select p_goal_id,p.id,coalesce(nullif(trim(p.name),''),p.email,'Membro'),auth.uid()
  from public.profiles p
  where coalesce(p.is_active,true)=true
  on conflict do nothing;
  get diagnostics v_count=row_count;

  return jsonb_build_object('success',true,'members_added',v_count);
end;
$$;
revoke all on function public.sync_weekly_goal_members(uuid) from public;
grant execute on function public.sync_weekly_goal_members(uuid) to authenticated;

create or replace function public.add_weekly_goal_member(p_goal_id uuid,p_member_name text,p_discord_user_id text default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_member public.weekly_goal_members;
begin
  if not public.is_staff() then raise exception 'Usuário sem permissão para alterar metas.'; end if;
  if nullif(trim(p_member_name),'') is null then raise exception 'Informe o nome do membro.'; end if;
  insert into public.weekly_goal_members(goal_id,member_name,discord_user_id,updated_by)
  values(p_goal_id,trim(p_member_name),nullif(trim(coalesce(p_discord_user_id,'')),''),auth.uid())
  returning * into v_member;
  return jsonb_build_object('success',true,'id',v_member.id);
end;
$$;
revoke all on function public.add_weekly_goal_member(uuid,text,text) from public;
grant execute on function public.add_weekly_goal_member(uuid,text,text) to authenticated;

create or replace function public.set_weekly_goal_payment(p_member_id uuid,p_amount numeric,p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_member public.weekly_goal_members; v_goal public.weekly_goals; v_paid boolean;
begin
  if not public.is_staff() then raise exception 'Usuário sem permissão para registrar metas.'; end if;
  if p_amount is null or p_amount<0 then raise exception 'O valor pago não pode ser negativo.'; end if;

  select * into v_member from public.weekly_goal_members where id=p_member_id for update;
  if not found then raise exception 'Membro da meta não encontrado.'; end if;
  select * into v_goal from public.weekly_goals where id=v_member.goal_id;
  if not found then raise exception 'Meta não encontrada.'; end if;

  v_paid:=round(p_amount,2)>=v_goal.target_amount;
  update public.weekly_goal_members
  set amount_paid=round(p_amount,2),
      paid_at=case when v_paid then coalesce(paid_at,now()) else null end,
      notes=nullif(trim(coalesce(p_note,'')),''),
      updated_by=auth.uid(),
      updated_at=now()
  where id=p_member_id
  returning * into v_member;

  return jsonb_build_object('success',true,'id',v_member.id,'amount_paid',v_member.amount_paid,'paid',v_paid);
end;
$$;
revoke all on function public.set_weekly_goal_payment(uuid,numeric,text) from public;
grant execute on function public.set_weekly_goal_payment(uuid,numeric,text) to authenticated;

create or replace function public.remove_weekly_goal_member(p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_staff() then raise exception 'Usuário sem permissão para alterar metas.'; end if;
  delete from public.weekly_goal_members where id=p_member_id;
  if not found then raise exception 'Membro da meta não encontrado.'; end if;
  return jsonb_build_object('success',true);
end;
$$;
revoke all on function public.remove_weekly_goal_member(uuid) from public;
grant execute on function public.remove_weekly_goal_member(uuid) to authenticated;

-- Ponto de integração futura com o bot: atualiza pelo Discord sem depender da UI.
create or replace function public.set_weekly_goal_payment_by_discord(
  p_goal_id uuid,
  p_discord_user_id text,
  p_member_name text,
  p_amount numeric,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_member_id uuid;
begin
  if not public.is_staff() then raise exception 'Usuário sem permissão para registrar metas.'; end if;
  if nullif(trim(p_discord_user_id),'') is null then raise exception 'Discord ID obrigatório.'; end if;

  select id into v_member_id
  from public.weekly_goal_members
  where goal_id=p_goal_id and discord_user_id=trim(p_discord_user_id)
  limit 1;

  if v_member_id is null then
    insert into public.weekly_goal_members(goal_id,member_name,discord_user_id,updated_by)
    values(p_goal_id,coalesce(nullif(trim(p_member_name),''),'Membro'),trim(p_discord_user_id),auth.uid())
    returning id into v_member_id;
  end if;

  return public.set_weekly_goal_payment(v_member_id,p_amount,p_note);
end;
$$;
revoke all on function public.set_weekly_goal_payment_by_discord(uuid,text,text,numeric,text) from public;
grant execute on function public.set_weekly_goal_payment_by_discord(uuid,text,text,numeric,text) to authenticated;

notify pgrst, 'reload schema';
commit;
