begin;

-- V7.1.9 — gerentes, encomenda interna, materiais e histórico sem duplicidade.

insert into public.user_roles(name,description)
values ('gerente','Gerente com acesso ao dashboard, encomendas e caixa.')
on conflict (name) do update set description=excluded.description;

create or replace function public.has_role(required_role text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profile_roles pr
    join public.user_roles ur
      on ur.id = pr.role_id
    where pr.profile_id = auth.uid()
      and lower(ur.name) = lower(required_role)
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path=public
as $$ select public.has_role('admin'); $$;

create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.has_role('admin') or public.has_role('gerente') or public.has_role('management');
$$;

grant execute on function public.has_role(text) to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_staff() to authenticated;

-- O formulário público deixa de criar encomendas; o registro passa a ser exclusivamente interno.
revoke execute on function public.create_public_order(text,text,text,text,text,text,text,jsonb) from anon,authenticated;

-- Histórico: trigger cria somente o primeiro evento. Alterações são registradas pela RPC.
create or replace function public.register_order_status_history()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  insert into public.order_status_history(order_id,status,note,changed_by,created_at)
  values (new.id,new.status,'Encomenda registrada.',auth.uid(),coalesce(new.created_at,now()));
  return new;
end;
$$;

drop trigger if exists orders_register_status_history on public.orders;
create trigger orders_register_status_history
after insert on public.orders
for each row execute function public.register_order_status_history();

-- Remove duplicações consecutivas criadas em poucos segundos pelas versões anteriores.
with ordered as (
  select id,order_id,status,note,created_at,
         lag(status) over(partition by order_id order by created_at,id) as previous_status,
         lag(coalesce(note,'')) over(partition by order_id order by created_at,id) as previous_note,
         lag(created_at) over(partition by order_id order by created_at,id) as previous_created_at
  from public.order_status_history
), duplicates as (
  select id from ordered
  where status=previous_status
    and coalesce(note,'')=previous_note
    and created_at-previous_created_at <= interval '10 seconds'
)
delete from public.order_status_history h using duplicates d where h.id=d.id;

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
    insert into public.cash_movements(movement_type,description,amount,order_id,registered_by,source)
    values('entry','Venda da encomenda '||v_order.code,v_order.final_amount,p_order_id,auth.uid(),'order') on conflict do nothing;
    insert into public.cash_movements(movement_type,description,amount,order_id,registered_by,source)
    values('exit','Comissão de 20% da encomenda '||v_order.code,v_order.commission_amount,p_order_id,auth.uid(),'order') on conflict do nothing;
    update public.orders set cash_posted_at=coalesce(cash_posted_at,now()) where id=p_order_id;
  end if;

  return jsonb_build_object('success',true,'order_id',p_order_id,'previous_status',v_current_status,'status',p_status,'history_id',v_history_id);
end;
$$;
revoke all on function public.update_order_status_v2(uuid,text,text) from public;
grant execute on function public.update_order_status_v2(uuid,text,text) to authenticated;

-- Registro interno de encomendas por administradores e gerentes.
create or replace function public.create_internal_order(
  input_customer_type text,
  input_customer_name text,
  input_cnpj_name text,
  input_passport text,
  input_phone text,
  input_notes text,
  input_payment_type text,
  input_pricing_tier text,
  input_items jsonb
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order public.orders;
  v_item jsonb;
  v_product public.products;
  v_price public.product_prices;
  v_qty integer;
  v_applied numeric(14,2);
  v_clean numeric(14,2):=0;
  v_dirty numeric(14,2);
  v_final numeric(14,2);
begin
  if not public.is_staff() then raise exception 'Acesso negado.'; end if;
  if input_customer_type not in ('cpf','cnpj') then raise exception 'Tipo de cliente inválido.'; end if;
  if input_pricing_tier not in ('cpf','cnpj','alianca','parceria') then raise exception 'Tabela de preço inválida.'; end if;
  if input_payment_type not in ('clean','dirty') then raise exception 'Forma de pagamento inválida.'; end if;
  if nullif(trim(input_customer_name),'') is null then raise exception 'O nome do responsável é obrigatório.'; end if;
  if nullif(trim(input_passport),'') is null then raise exception 'O passaporte é obrigatório.'; end if;
  if input_customer_type='cnpj' and nullif(trim(input_cnpj_name),'') is null then raise exception 'O nome do CNPJ é obrigatório.'; end if;
  if input_items is null or jsonb_typeof(input_items)<>'array' or jsonb_array_length(input_items)=0 then raise exception 'Adicione pelo menos um produto.'; end if;

  insert into public.orders(customer_type,customer_name,cnpj_name,passport,phone,notes,payment_type,pricing_tier,received_by,total_amount,clean_amount,dirty_amount,final_amount)
  values(input_customer_type,trim(input_customer_name),case when input_customer_type='cnpj' then nullif(trim(input_cnpj_name),'') else null end,trim(input_passport),nullif(trim(input_phone),''),nullif(trim(input_notes),''),input_payment_type,input_pricing_tier,auth.uid(),0,0,0,0)
  returning * into v_order;

  for v_item in select value from jsonb_array_elements(input_items) loop
    v_qty:=greatest(1,coalesce((v_item->>'quantity')::integer,1));
    select * into v_product from public.products where id=(v_item->>'product_id')::uuid and is_active=true and allows_order=true;
    if not found then raise exception 'Produto inválido ou indisponível.'; end if;
    select * into v_price from public.product_prices where product_id=v_product.id and customer_type=input_pricing_tier;
    if not found then raise exception 'O produto % não possui preço para %.',v_product.name,upper(input_pricing_tier); end if;
    v_applied:=v_price.unit_price;
    if v_price.wholesale_minimum is not null and v_price.wholesale_price is not null and v_qty>=v_price.wholesale_minimum then
      v_applied:=v_price.wholesale_price;
    end if;
    insert into public.order_items(order_id,product_id,product_name,quantity,quantity_from_stock,quantity_to_produce,unit_price,subtotal)
    values(v_order.id,v_product.id,v_product.name,v_qty,0,v_qty,v_applied,v_applied*v_qty);
    v_clean:=v_clean+(v_applied*v_qty);
  end loop;

  v_dirty:=round(v_clean*1.30,2);
  v_final:=case when input_payment_type='dirty' then v_dirty else v_clean end;
  update public.orders
  set total_amount=v_clean,clean_amount=v_clean,dirty_amount=v_dirty,final_amount=v_final,
      commission_amount=round(v_final*commission_rate,2),net_amount=round(v_final-(v_final*commission_rate),2)
  where id=v_order.id returning * into v_order;

  return jsonb_build_object('id',v_order.id,'code',v_order.code,'final_amount',v_order.final_amount,'status',v_order.status);
end;
$$;
revoke all on function public.create_internal_order(text,text,text,text,text,text,text,text,jsonb) from public;
grant execute on function public.create_internal_order(text,text,text,text,text,text,text,text,jsonb) to authenticated;

-- Gerentes podem consultar produtos para montar pedidos, mas alterações operacionais ficam restritas aos admins.
do $$
declare table_name text;
begin
  foreach table_name in array array['products','product_categories','product_prices','materials','material_aliases','product_materials','stock_movements'] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists "Somente admin insere %s" on public.%I',table_name,table_name);
    execute format('drop policy if exists "Somente admin altera %s" on public.%I',table_name,table_name);
    execute format('drop policy if exists "Somente admin exclui %s" on public.%I',table_name,table_name);
    execute format('create policy "Somente admin insere %s" on public.%I as restrictive for insert to authenticated with check (public.is_admin())',table_name,table_name);
    execute format('create policy "Somente admin altera %s" on public.%I as restrictive for update to authenticated using (public.is_admin()) with check (public.is_admin())',table_name,table_name);
    execute format('create policy "Somente admin exclui %s" on public.%I as restrictive for delete to authenticated using (public.is_admin())',table_name,table_name);
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;
