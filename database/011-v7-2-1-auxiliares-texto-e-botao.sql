begin;

-- V7.2.1 — auxiliares em texto livre.
-- Nem todo membro que ajuda na produção precisa possuir acesso ao sistema.

alter table public.orders
  add column if not exists production_helpers text;

-- Substitui a assinatura anterior da RPC por uma versão com texto livre.
drop function if exists public.create_internal_order(text,text,text,text,text,text,text,text,uuid,jsonb);
drop function if exists public.create_internal_order(text,text,text,text,text,text,text,text,text,jsonb);

create function public.create_internal_order(
  input_customer_type text,
  input_customer_name text,
  input_cnpj_name text,
  input_passport text,
  input_phone text,
  input_notes text,
  input_payment_type text,
  input_pricing_tier text,
  input_production_helpers text,
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

  insert into public.orders(
    customer_type,customer_name,cnpj_name,passport,phone,notes,payment_type,pricing_tier,
    received_by,production_helpers,total_amount,clean_amount,dirty_amount,final_amount
  ) values (
    input_customer_type,trim(input_customer_name),case when input_customer_type='cnpj' then nullif(trim(input_cnpj_name),'') else null end,
    trim(input_passport),nullif(trim(input_phone),''),nullif(trim(input_notes),''),input_payment_type,input_pricing_tier,
    auth.uid(),nullif(trim(input_production_helpers),''),0,0,0,0
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

revoke all on function public.create_internal_order(text,text,text,text,text,text,text,text,text,jsonb) from public;
grant execute on function public.create_internal_order(text,text,text,text,text,text,text,text,text,jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;
