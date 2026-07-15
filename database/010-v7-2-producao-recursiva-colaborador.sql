begin;

-- V7.2 — colaborador da encomenda, receitas de materiais e produção recursiva.

alter table public.orders
  add column if not exists assistant_id uuid references public.profiles(id);

create table if not exists public.material_components (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.materials(id) on delete cascade,
  component_material_id uuid not null references public.materials(id) on delete restrict,
  quantity_required numeric not null check (quantity_required > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint material_components_unique unique(material_id, component_material_id),
  constraint material_components_not_self check (material_id <> component_material_id)
);

alter table public.material_components enable row level security;
grant select,insert,update,delete on public.material_components to authenticated;

drop policy if exists "Equipe consulta receitas de materiais" on public.material_components;
create policy "Equipe consulta receitas de materiais"
on public.material_components for select to authenticated
using (public.is_staff());

drop policy if exists "Somente admin insere receitas de materiais" on public.material_components;
create policy "Somente admin insere receitas de materiais"
on public.material_components for insert to authenticated
with check (public.is_admin());

drop policy if exists "Somente admin altera receitas de materiais" on public.material_components;
create policy "Somente admin altera receitas de materiais"
on public.material_components for update to authenticated
using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Somente admin exclui receitas de materiais" on public.material_components;
create policy "Somente admin exclui receitas de materiais"
on public.material_components for delete to authenticated
using (public.is_admin());

-- Garante leitura para a equipe nas tabelas necessárias para montar pedidos e planos de produção.
do $$
declare table_name text;
begin
  foreach table_name in array array['products','product_categories','product_prices','materials','material_aliases','product_materials','profiles'] loop
    execute format('alter table public.%I enable row level security', table_name);
    execute format('drop policy if exists "Equipe consulta %s" on public.%I', table_name, table_name);
    execute format('create policy "Equipe consulta %s" on public.%I for select to authenticated using (public.is_staff())', table_name, table_name);
  end loop;
end $$;

-- Mantém o catálogo público visível.
drop policy if exists "Catalogo publico produtos" on public.products;
create policy "Catalogo publico produtos" on public.products for select to anon,authenticated
using (is_active=true and is_public=true);

drop policy if exists "Catalogo publico categorias" on public.product_categories;
create policy "Catalogo publico categorias" on public.product_categories for select to anon,authenticated
using (is_active=true);

drop policy if exists "Catalogo publico precos" on public.product_prices;
create policy "Catalogo publico precos" on public.product_prices for select to anon,authenticated
using (exists (
  select 1 from public.products p
  where p.id=product_prices.product_id and p.is_active=true and p.is_public=true
));

-- Remove a assinatura anterior para evitar ambiguidade no PostgREST.
drop function if exists public.create_internal_order(text,text,text,text,text,text,text,text,jsonb);

create function public.create_internal_order(
  input_customer_type text,
  input_customer_name text,
  input_cnpj_name text,
  input_passport text,
  input_phone text,
  input_notes text,
  input_payment_type text,
  input_pricing_tier text,
  input_assistant_id uuid,
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
  if input_assistant_id is not null and not exists(select 1 from public.profiles where id=input_assistant_id and is_active=true) then
    raise exception 'O colaborador selecionado não está disponível.';
  end if;

  insert into public.orders(
    customer_type,customer_name,cnpj_name,passport,phone,notes,payment_type,pricing_tier,
    received_by,assistant_id,total_amount,clean_amount,dirty_amount,final_amount
  ) values (
    input_customer_type,trim(input_customer_name),case when input_customer_type='cnpj' then nullif(trim(input_cnpj_name),'') else null end,
    trim(input_passport),nullif(trim(input_phone),''),nullif(trim(input_notes),''),input_payment_type,input_pricing_tier,
    auth.uid(),input_assistant_id,0,0,0,0
  ) returning * into v_order;

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

revoke all on function public.create_internal_order(text,text,text,text,text,text,text,text,uuid,jsonb) from public;
grant execute on function public.create_internal_order(text,text,text,text,text,text,text,text,uuid,jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
