begin;

alter table public.product_prices drop constraint if exists product_prices_customer_type_check;
alter table public.product_prices add constraint product_prices_customer_type_check check (customer_type in ('cpf','cnpj','alianca','parceria'));

alter table public.orders add column if not exists pricing_tier text;
alter table public.orders drop constraint if exists orders_pricing_tier_check;
alter table public.orders add constraint orders_pricing_tier_check check (pricing_tier is null or pricing_tier in ('cpf','cnpj','alianca','parceria'));
update public.orders set pricing_tier=customer_type where pricing_tier is null;

create or replace function public.set_default_order_pricing_tier() returns trigger language plpgsql set search_path=public as $$
begin if new.pricing_tier is null then new.pricing_tier:=new.customer_type; end if; return new; end; $$;
drop trigger if exists orders_set_default_pricing_tier on public.orders;
create trigger orders_set_default_pricing_tier before insert on public.orders for each row execute function public.set_default_order_pricing_tier();

insert into public.product_categories(name,description,is_active) values ('Geral','Produtos importados do sistema anterior da Distrito.',true)
on conflict(name) do update set description=excluded.description,is_active=true;

insert into public.materials(name,stock_quantity,reserved_quantity,minimum_stock,unit,is_active) values
('Alumínio',0,0,0,'unidade',true),('Plástico',0,0,0,'unidade',true),('Cobre',0,0,0,'unidade',true),('Vidro',0,0,0,'unidade',true),('Placa Blindada',0,0,0,'unidade',true),('Lona',0,0,0,'unidade',true),('Soro',0,0,0,'unidade',true),('Chapa de Metal',0,0,0,'unidade',true),('Corpo de Sub',0,0,0,'unidade',true),('Peça de Arma',0,0,0,'unidade',true),('Fita Adesiva',0,0,0,'unidade',true)
on conflict(name) do update set is_active=true;

insert into public.products(category_id,name,description,ready_stock,minimum_stock,is_active,is_public,allows_order)
select c.id,p.name,p.description,0,0,true,true,true from public.product_categories c cross join (values
('Colete','Colete disponível para encomenda.'),('TEC-9','Produto disponível para encomenda.'),('AUG','Produto disponível para encomenda.'),('Pente Estendido','Acessório disponível para encomenda.'),('Mira Holográfica','Acessório disponível para encomenda.'),('Silenciador','Acessório disponível para encomenda.'),('Empunhadura','Acessório disponível para encomenda.'),('Lanterna','Acessório disponível para encomenda.'),('Coca','Produto disponível para encomenda.'),('Meth','Produto disponível para encomenda.'),('Baseado','Produto disponível para encomenda.')) p(name,description)
where c.name='Geral' on conflict(name) do update set category_id=excluded.category_id,description=excluded.description,is_active=true,is_public=true,allows_order=true;

insert into public.product_prices(product_id,customer_type,unit_price,wholesale_minimum,wholesale_price)
select p.id,x.tier,x.price,null,null from public.products p cross join (values ('alianca',1000::numeric),('parceria',1200::numeric),('cnpj',1500::numeric),('cpf',2000::numeric)) x(tier,price)
where p.name<>'Colete' on conflict(product_id,customer_type) do update set unit_price=excluded.unit_price,wholesale_minimum=null,wholesale_price=null,updated_at=now();

insert into public.product_prices(product_id,customer_type,unit_price,wholesale_minimum,wholesale_price)
select p.id,x.tier,x.price,20,x.wholesale from public.products p cross join (values ('alianca',6000::numeric,5000::numeric),('parceria',7000::numeric,5500::numeric),('cnpj',8000::numeric,6500::numeric),('cpf',10000::numeric,8500::numeric)) x(tier,price,wholesale)
where p.name='Colete' on conflict(product_id,customer_type) do update set unit_price=excluded.unit_price,wholesale_minimum=20,wholesale_price=excluded.wholesale_price,updated_at=now();

insert into public.product_materials(product_id,material_id,quantity_required)
select p.id,m.id,r.qty from public.products p join (values ('Placa Blindada',5::numeric),('Lona',2::numeric)) r(name,qty) on true join public.materials m on m.name=r.name where p.name='Colete'
on conflict(product_id,material_id) do update set quantity_required=excluded.quantity_required,updated_at=now();
insert into public.product_materials(product_id,material_id,quantity_required)
select p.id,m.id,r.qty from public.products p join (values ('Chapa de Metal',50::numeric),('Peça de Arma',1::numeric)) r(name,qty) on true join public.materials m on m.name=r.name where p.name='TEC-9'
on conflict(product_id,material_id) do update set quantity_required=excluded.quantity_required,updated_at=now();
insert into public.product_materials(product_id,material_id,quantity_required)
select p.id,m.id,r.qty from public.products p join (values ('Plástico',10::numeric),('Fita Adesiva',1::numeric)) r(name,qty) on true join public.materials m on m.name=r.name where p.name='Empunhadura'
on conflict(product_id,material_id) do update set quantity_required=excluded.quantity_required,updated_at=now();

create or replace function public.recalculate_order_pricing(input_order_id uuid,input_pricing_tier text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare item record; price_row public.product_prices; applied numeric(14,2); new_total numeric(14,2):=0;
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
   new_total:=new_total+(applied*item.quantity);
 end loop;
 update public.orders set pricing_tier=input_pricing_tier,total_amount=new_total where id=input_order_id;
 return jsonb_build_object('order_id',input_order_id,'pricing_tier',input_pricing_tier,'total_amount',new_total);
end; $$;
grant execute on function public.recalculate_order_pricing(uuid,text) to authenticated;

commit;
