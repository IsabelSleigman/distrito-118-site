begin;

-- V7.1.8 — pagamento limpo/sujo, comissão e caixa automático.
alter table public.orders add column if not exists payment_type text not null default 'clean';
alter table public.orders drop constraint if exists orders_payment_type_check;
alter table public.orders add constraint orders_payment_type_check check (payment_type in ('clean','dirty'));
alter table public.orders add column if not exists clean_amount numeric(14,2) not null default 0;
alter table public.orders add column if not exists dirty_amount numeric(14,2) not null default 0;
alter table public.orders add column if not exists final_amount numeric(14,2) not null default 0;
alter table public.orders add column if not exists commission_rate numeric(6,4) not null default 0.20;
alter table public.orders add column if not exists commission_amount numeric(14,2) not null default 0;
alter table public.orders add column if not exists net_amount numeric(14,2) not null default 0;
alter table public.orders add column if not exists cash_posted_at timestamptz;

update public.orders
set payment_type=coalesce(payment_type,'clean'),
    clean_amount=case when clean_amount=0 then total_amount else clean_amount end,
    dirty_amount=case when dirty_amount=0 then round(total_amount*1.30,2) else dirty_amount end,
    final_amount=case when final_amount=0 then total_amount else final_amount end,
    commission_amount=case when commission_amount=0 then round(total_amount*commission_rate,2) else commission_amount end,
    net_amount=case when net_amount=0 then round(total_amount-(total_amount*commission_rate),2) else net_amount end;

create unique index if not exists cash_movements_order_type_source_unique
on public.cash_movements(order_id,movement_type,source)
where order_id is not null and source='order';

create or replace function public.refresh_order_financials(p_order_id uuid)
returns public.orders
language plpgsql
security definer
set search_path=public
as $$
declare v_order public.orders; v_clean numeric(14,2); v_dirty numeric(14,2); v_final numeric(14,2);
begin
  select coalesce(sum(subtotal),0) into v_clean from public.order_items where order_id=p_order_id;
  select * into v_order from public.orders where id=p_order_id for update;
  if not found then raise exception 'Encomenda não encontrada.'; end if;
  v_dirty:=round(v_clean*1.30,2);
  v_final:=case when v_order.payment_type='dirty' then v_dirty else v_clean end;
  update public.orders set total_amount=v_clean,clean_amount=v_clean,dirty_amount=v_dirty,final_amount=v_final,
    commission_amount=round(v_final*commission_rate,2),net_amount=round(v_final-(v_final*commission_rate),2)
  where id=p_order_id returning * into v_order;
  return v_order;
end; $$;

-- Substitui a RPC pública pela versão com forma de pagamento.
drop function if exists public.create_public_order(text,text,text,text,text,text,jsonb);
drop function if exists public.create_public_order(text,text,text,text,text,text,text,jsonb);
create or replace function public.create_public_order(
  input_customer_type text,
  input_customer_name text,
  input_cnpj_name text,
  input_passport text,
  input_phone text,
  input_notes text,
  input_payment_type text,
  input_items jsonb
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  v_order public.orders; v_item jsonb; v_product public.products; v_price public.product_prices;
  v_qty integer; v_applied numeric(14,2); v_clean numeric(14,2):=0; v_dirty numeric(14,2); v_final numeric(14,2);
begin
  if input_customer_type not in ('cpf','cnpj') then raise exception 'Tipo de cliente inválido.'; end if;
  if input_payment_type not in ('clean','dirty') then raise exception 'Forma de pagamento inválida.'; end if;
  if nullif(trim(input_customer_name),'') is null then raise exception 'O nome do responsável é obrigatório.'; end if;
  if nullif(trim(input_passport),'') is null then raise exception 'O passaporte é obrigatório.'; end if;
  if input_customer_type='cnpj' and nullif(trim(input_cnpj_name),'') is null then raise exception 'O nome do CNPJ é obrigatório.'; end if;
  if input_items is null or jsonb_typeof(input_items)<>'array' or jsonb_array_length(input_items)=0 then raise exception 'Adicione pelo menos um produto.'; end if;

  insert into public.orders(customer_type,customer_name,cnpj_name,passport,phone,notes,payment_type,total_amount,clean_amount,dirty_amount,final_amount)
  values(input_customer_type,trim(input_customer_name),case when input_customer_type='cnpj' then nullif(trim(input_cnpj_name),'') else null end,trim(input_passport),nullif(trim(input_phone),''),nullif(trim(input_notes),''),input_payment_type,0,0,0,0)
  returning * into v_order;

  for v_item in select value from jsonb_array_elements(input_items) loop
    v_qty:=greatest(1,coalesce((v_item->>'quantity')::integer,1));
    select * into v_product from public.products where id=(v_item->>'product_id')::uuid and is_active=true and is_public=true and allows_order=true;
    if not found then raise exception 'Produto inválido ou indisponível.'; end if;
    select * into v_price from public.product_prices where product_id=v_product.id and customer_type=input_customer_type;
    if not found then raise exception 'O produto % não possui preço para %.',v_product.name,upper(input_customer_type); end if;
    v_applied:=v_price.unit_price;
    if v_price.wholesale_minimum is not null and v_price.wholesale_price is not null and v_qty>=v_price.wholesale_minimum then v_applied:=v_price.wholesale_price; end if;
    insert into public.order_items(order_id,product_id,product_name,quantity,quantity_from_stock,quantity_to_produce,unit_price,subtotal)
    values(v_order.id,v_product.id,v_product.name,v_qty,0,v_qty,v_applied,v_applied*v_qty);
    v_clean:=v_clean+(v_applied*v_qty);
  end loop;

  v_dirty:=round(v_clean*1.30,2); v_final:=case when input_payment_type='dirty' then v_dirty else v_clean end;
  update public.orders set total_amount=v_clean,clean_amount=v_clean,dirty_amount=v_dirty,final_amount=v_final,
    commission_amount=round(v_final*commission_rate,2),net_amount=round(v_final-(v_final*commission_rate),2)
  where id=v_order.id returning * into v_order;

  return jsonb_build_object('id',v_order.id,'code',v_order.code,'total_amount',v_order.total_amount,'clean_amount',v_order.clean_amount,
    'dirty_amount',v_order.dirty_amount,'final_amount',v_order.final_amount,'payment_type',v_order.payment_type,'status',v_order.status);
end; $$;
grant execute on function public.create_public_order(text,text,text,text,text,text,text,jsonb) to anon,authenticated;

create or replace function public.recalculate_order_pricing(input_order_id uuid,input_pricing_tier text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare item record; price_row public.product_prices; applied numeric(14,2); refreshed public.orders;
begin
 if not public.is_staff() then raise exception 'Acesso negado.'; end if;
 if input_pricing_tier not in ('cpf','cnpj','alianca','parceria') then raise exception 'Tabela de preço inválida.'; end if;
 for item in select * from public.order_items where order_id=input_order_id loop
   if item.product_id is null then raise exception 'Item sem produto vinculado: %',item.product_name; end if;
   select * into price_row from public.product_prices where product_id=item.product_id and customer_type=input_pricing_tier;
   if not found then raise exception 'Produto % sem preço para %.',item.product_name,input_pricing_tier; end if;
   applied:=price_row.unit_price;
   if price_row.wholesale_minimum is not null and price_row.wholesale_price is not null and item.quantity>=price_row.wholesale_minimum then applied:=price_row.wholesale_price; end if;
   update public.order_items set unit_price=applied,subtotal=applied*item.quantity where id=item.id;
 end loop;
 update public.orders set pricing_tier=input_pricing_tier where id=input_order_id;
 refreshed:=public.refresh_order_financials(input_order_id);
 return jsonb_build_object('order_id',input_order_id,'pricing_tier',input_pricing_tier,'total_amount',refreshed.total_amount,'final_amount',refreshed.final_amount);
end; $$;
grant execute on function public.recalculate_order_pricing(uuid,text) to authenticated;

create or replace function public.get_public_order_by_code(input_code text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare target_order public.orders;
begin
 select * into target_order from public.orders where upper(code)=upper(trim(input_code)) and deleted_at is null;
 if not found then return null; end if;
 return jsonb_build_object('code',target_order.code,'customer_display',coalesce(target_order.cnpj_name,target_order.customer_name),
   'total_amount',target_order.total_amount,'clean_amount',target_order.clean_amount,'dirty_amount',target_order.dirty_amount,
   'final_amount',target_order.final_amount,'payment_type',target_order.payment_type,'status',target_order.status,'created_at',target_order.created_at,
   'items',coalesce((select jsonb_agg(jsonb_build_object('quantity',i.quantity,'product_name',i.product_name,'subtotal',i.subtotal) order by i.created_at) from public.order_items i where i.order_id=target_order.id),'[]'::jsonb));
end; $$;
grant execute on function public.get_public_order_by_code(text) to anon,authenticated;

-- Finalização financeira automática e idempotente.
create or replace function public.update_order_status_v2(p_order_id uuid,p_status text,p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_current_status text; v_history_id uuid; v_order public.orders;
begin
 if auth.uid() is null then raise exception 'Sessão expirada. Entre novamente no painel.'; end if;
 if not public.is_staff() then raise exception 'Usuário sem permissão para alterar encomendas.'; end if;
 if p_status not in ('pending','under_review','accepted','waiting_materials','in_production','ready','awaiting_delivery','delivered','rejected','cancelled') then raise exception 'Status inválido: %',p_status; end if;
 select status into v_current_status from public.orders where id=p_order_id and deleted_at is null for update;
 if not found then raise exception 'Encomenda não encontrada.'; end if;
 update public.orders set status=p_status,delivered_at=case when p_status='delivered' then coalesce(delivered_at,now()) else delivered_at end,
   delivered_by=case when p_status='delivered' then coalesce(delivered_by,auth.uid()) else delivered_by end where id=p_order_id;
 select id into v_history_id from public.order_status_history where order_id=p_order_id and status=p_status order by created_at desc limit 1;
 if v_history_id is null or v_current_status is not distinct from p_status then
   insert into public.order_status_history(order_id,status,note,changed_by,created_at) values(p_order_id,p_status,nullif(trim(p_note),''),auth.uid(),now()) returning id into v_history_id;
 elsif nullif(trim(p_note),'') is not null then update public.order_status_history set note=nullif(trim(p_note),'') where id=v_history_id; end if;
 if p_status='delivered' then
   select * into v_order from public.orders where id=p_order_id;
   insert into public.cash_movements(movement_type,description,amount,order_id,registered_by,source)
   values('entry','Venda da encomenda '||v_order.code,v_order.final_amount,p_order_id,auth.uid(),'order') on conflict do nothing;
   insert into public.cash_movements(movement_type,description,amount,order_id,registered_by,source)
   values('exit','Comissão de 20% da encomenda '||v_order.code,v_order.commission_amount,p_order_id,auth.uid(),'order') on conflict do nothing;
   update public.orders set cash_posted_at=coalesce(cash_posted_at,now()) where id=p_order_id;
 end if;
 return jsonb_build_object('success',true,'order_id',p_order_id,'previous_status',v_current_status,'status',p_status,'history_id',v_history_id);
end; $$;
revoke all on function public.update_order_status_v2(uuid,text,text) from public;
grant execute on function public.update_order_status_v2(uuid,text,text) to authenticated;

notify pgrst, 'reload schema';
commit;
