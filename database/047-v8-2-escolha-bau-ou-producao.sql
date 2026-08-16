begin;

alter table public.order_items add column if not exists acquisition_mode text not null default 'auto'
 check(acquisition_mode in('auto','stock','produce'));

create or replace function public.consume_inventory_item_planned(p_item_id uuid,p_quantity numeric,p_order_id uuid,p_path uuid[],p_mode text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare st record;available numeric;used numeric;remaining numeric:=p_quantity;ready numeric:=0;r record;outq numeric;batches numeric;produced numeric:=0;surplus numeric:=0;gid uuid;beforeq numeric;item_name text;
begin
 if p_quantity<=0 then return jsonb_build_object('ready',0,'produced',0,'surplus',0,'mode',p_mode);end if;
 if p_mode not in('auto','stock','produce') then raise exception 'Estratégia de produção inválida.';end if;
 if p_item_id=any(p_path) then raise exception 'Receita circular.';end if;
 select name into item_name from inventory_items where id=p_item_id;
 if p_mode<>'produce' then
  for st in select id,scope from inventory_stocks where is_active and scope in('geral','gerencia') order by case scope when 'geral' then 1 else 2 end loop
   exit when remaining<=0;select coalesce(quantity,0) into available from inventory_item_balances where stock_id=st.id and inventory_item_id=p_item_id for update;
   used:=least(coalesce(available,0),remaining);
   if used>0 then update inventory_item_balances set quantity=quantity-used,updated_at=clock_timestamp() where stock_id=st.id and inventory_item_id=p_item_id;
    insert into inventory_item_movements(stock_id,inventory_item_id,movement_type,quantity,balance_before,balance_after,source,order_id,registered_by,reason)
    values(st.id,p_item_id,case when cardinality(p_path)=0 then 'order_consumption' else 'production_consumption' end,used,available,available-used,'order',p_order_id,auth.uid(),'Estratégia: '||p_mode);
    remaining:=remaining-used;ready:=ready+used;end if;
  end loop;
 end if;
 if remaining<=0 then return jsonb_build_object('ready',ready,'produced',0,'surplus',0,'mode',p_mode);end if;
 if p_mode='stock' then raise exception 'Estoque pronto insuficiente para %: faltam %.',item_name,remaining;end if;
 select max(output_quantity) into outq from inventory_craft_recipes where production_item_id=p_item_id;
 if outq is null then raise exception 'Item insuficiente e sem receita: %.',item_name;end if;
 batches:=ceil(remaining/outq);produced:=batches*outq;surplus:=produced-remaining;
 for r in select component_item_id,quantity_required from inventory_craft_recipes where production_item_id=p_item_id loop
  perform public.consume_inventory_item_planned(r.component_item_id,batches*r.quantity_required,p_order_id,p_path||p_item_id,'auto');
 end loop;
 if surplus>0 then select id into gid from inventory_stocks where scope='geral' and is_active limit 1;
  insert into inventory_item_balances(stock_id,inventory_item_id,quantity) values(gid,p_item_id,0) on conflict do nothing;
  select quantity into beforeq from inventory_item_balances where stock_id=gid and inventory_item_id=p_item_id for update;
  update inventory_item_balances set quantity=quantity+surplus,updated_at=clock_timestamp() where stock_id=gid and inventory_item_id=p_item_id;
  insert into inventory_item_movements(stock_id,inventory_item_id,movement_type,quantity,balance_before,balance_after,source,order_id,registered_by,reason)
  values(gid,p_item_id,'production_surplus',surplus,beforeq,beforeq+surplus,'order',p_order_id,auth.uid(),'Sobra da produção planejada');end if;
 return jsonb_build_object('ready',ready,'produced',produced,'surplus',surplus,'mode',p_mode);
end $$;

create or replace function public.consume_order_inventory(p_order_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare x record;gid uuid;
begin
 if exists(select 1 from order_inventory_consumptions where order_id=p_order_id) then return jsonb_build_object('success',true,'already_consumed',true);end if;
 for x in select p.inventory_item_id,oi.quantity::numeric q,oi.acquisition_mode from order_items oi join products p on p.id=oi.product_id where oi.order_id=p_order_id loop
  perform public.consume_inventory_item_planned(x.inventory_item_id,x.q,p_order_id,'{}',x.acquisition_mode);
 end loop;
 insert into order_item_fulfillments(order_id,inventory_item_id,covered_quantity,updated_at)
 select p_order_id,p.inventory_item_id,sum(oi.quantity),clock_timestamp() from order_items oi join products p on p.id=oi.product_id where oi.order_id=p_order_id group by p.inventory_item_id
 on conflict(order_id,inventory_item_id) do update set covered_quantity=excluded.covered_quantity,updated_at=clock_timestamp();
 select id into gid from inventory_stocks where scope='geral' and is_active limit 1;insert into order_inventory_consumptions(order_id,stock_id) values(p_order_id,gid);
 return jsonb_build_object('success',true,'already_consumed',false);
end $$;

create or replace function public.adjust_order_production_inventory(p_order_id uuid,p_responsible_name text) returns jsonb language plpgsql security definer set search_path=public as $$
declare x record;delta numeric;adds jsonb:='[]';excess jsonb:='[]';status_now text;since timestamptz:=clock_timestamp();moves jsonb;person text:=trim(p_responsible_name);
begin
 if length(person)<3 then raise exception 'Informe o nome RP.';end if;select status into status_now from orders where id=p_order_id for update;
 if status_now is null or status_now in('delivered','cancelled','rejected') then raise exception 'Encomenda finalizada ou inexistente.';end if;
 if not exists(select 1 from order_inventory_consumptions where order_id=p_order_id) then raise exception 'A encomenda ainda não teve a baixa inicial.';end if;
 for x in with cur as(select p.inventory_item_id,sum(oi.quantity)::numeric q,case when bool_or(oi.acquisition_mode='produce') then 'produce' when bool_and(oi.acquisition_mode='stock') then 'stock' else 'auto' end mode from order_items oi join products p on p.id=oi.product_id where oi.order_id=p_order_id group by p.inventory_item_id),ids as(select inventory_item_id from cur union select inventory_item_id from order_item_fulfillments where order_id=p_order_id)
  select ids.inventory_item_id,i.name,coalesce(cur.q,0) required,coalesce(f.covered_quantity,0) covered,coalesce(cur.mode,'auto') mode from ids join inventory_items i on i.id=ids.inventory_item_id left join cur on cur.inventory_item_id=ids.inventory_item_id left join order_item_fulfillments f on f.order_id=p_order_id and f.inventory_item_id=ids.inventory_item_id loop
  delta:=x.required-x.covered;if delta>0 then perform public.consume_inventory_item_planned(x.inventory_item_id,delta,p_order_id,'{}',x.mode);
   insert into order_item_fulfillments values(p_order_id,x.inventory_item_id,x.required,clock_timestamp()) on conflict(order_id,inventory_item_id) do update set covered_quantity=greatest(order_item_fulfillments.covered_quantity,excluded.covered_quantity),updated_at=clock_timestamp();adds:=adds||jsonb_build_array(jsonb_build_object('item',x.name,'quantity',delta,'mode',x.mode));
  elsif delta<0 then excess:=excess||jsonb_build_array(jsonb_build_object('item',x.name,'quantity',abs(delta)));end if;end loop;
 if jsonb_array_length(adds)=0 then return jsonb_build_object('success',true,'adjusted',false,'additions',adds,'excess',excess);end if;
 select coalesce(jsonb_agg(jsonb_build_object('item',i.name,'quantity',m.quantity,'movement_type',m.movement_type,'scope',s.scope)),'[]') into moves from inventory_item_movements m join inventory_items i on i.id=m.inventory_item_id join inventory_stocks s on s.id=m.stock_id where m.order_id=p_order_id and m.created_at>=since;
 insert into integration_outbox(event_type,entity_type,entity_id,payload,status,destination) values('order_inventory_adjusted','order',p_order_id,jsonb_build_object('responsible_name',person,'movements',moves,'additions',adds),'pending','order_history');
 return jsonb_build_object('success',true,'adjusted',true,'additions',adds,'excess',excess);
end $$;

-- As RPCs continuam com a mesma assinatura; o modo vem dentro de input_items.
create or replace function public.create_internal_order(input_customer_type text,input_customer_name text,input_cnpj_name text,input_passport text,input_phone text,input_notes text,input_payment_type text,input_pricing_tier text,input_production_helpers text,input_items jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare o orders;x jsonb;p products;pr product_prices;q integer;price numeric;clean numeric:=0;dirty numeric;final numeric;mode text;
begin
 if not public.is_staff() then raise exception 'Acesso negado.';end if;
 if input_customer_type not in('cpf','cnpj') or input_pricing_tier not in('cpf','cnpj','alianca','parceria') or input_payment_type not in('clean','dirty') then raise exception 'Dados comerciais inválidos.';end if;
 if nullif(trim(input_customer_name),'') is null or nullif(trim(input_passport),'') is null then raise exception 'Informe responsável e passaporte.';end if;
 if input_customer_type='cnpj' and nullif(trim(input_cnpj_name),'') is null then raise exception 'Informe o nome do CNPJ.';end if;
 if input_items is null or jsonb_typeof(input_items)<>'array' or jsonb_array_length(input_items)=0 then raise exception 'Adicione pelo menos um produto.';end if;
 insert into orders(customer_type,customer_name,cnpj_name,passport,phone,notes,payment_type,pricing_tier,received_by,production_helpers,total_amount,clean_amount,dirty_amount,final_amount)
 values(input_customer_type,trim(input_customer_name),case when input_customer_type='cnpj' then nullif(trim(input_cnpj_name),'') end,trim(input_passport),nullif(trim(input_phone),''),nullif(trim(input_notes),''),input_payment_type,input_pricing_tier,auth.uid(),nullif(trim(input_production_helpers),''),0,0,0,0) returning * into o;
 for x in select value from jsonb_array_elements(input_items) loop q:=greatest(1,coalesce((x->>'quantity')::integer,1));mode:=coalesce(nullif(x->>'acquisition_mode',''),'auto');if mode not in('auto','stock','produce') then raise exception 'Estratégia inválida.';end if;
  select * into p from products where id=(x->>'product_id')::uuid and is_active and allows_order;if not found then raise exception 'Produto inválido ou indisponível.';end if;
  select * into pr from product_prices where product_id=p.id and customer_type=input_pricing_tier;if not found then raise exception 'Preço não cadastrado para o produto %.',p.name;end if;
  price:=case when pr.wholesale_minimum is not null and q>=pr.wholesale_minimum then coalesce(pr.wholesale_price,pr.unit_price) else pr.unit_price end;
  insert into order_items(order_id,product_id,product_name,quantity,quantity_from_stock,quantity_to_produce,unit_price,subtotal,acquisition_mode) values(o.id,p.id,p.name,q,0,q,price,price*q,mode);clean:=clean+price*q;end loop;
 dirty:=round(clean*1.30,2);final:=case when input_payment_type='dirty' then dirty else clean end;update orders set total_amount=clean,clean_amount=clean,dirty_amount=dirty,final_amount=final,commission_amount=round(final*commission_rate,2),net_amount=round(final-(final*commission_rate),2) where id=o.id returning * into o;perform queue_order_created_event(o.id);
 return jsonb_build_object('id',o.id,'code',o.code,'final_amount',o.final_amount,'status',o.status);
end $$;

create or replace function public.update_internal_order(input_order_id uuid,input_customer_type text,input_customer_name text,input_cnpj_name text,input_passport text,input_phone text,input_notes text,input_payment_type text,input_pricing_tier text,input_production_helpers text,input_items jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare o orders;x jsonb;p products;pr product_prices;q integer;price numeric;clean numeric:=0;dirty numeric;final numeric;mode text;
begin
 if not public.is_staff() then raise exception 'Acesso negado.';end if;select * into o from orders where id=input_order_id and deleted_at is null for update;if not found or o.status in('delivered','cancelled') or o.cash_posted_at is not null then raise exception 'Encomenda finalizada ou inexistente.';end if;
 if input_customer_type not in('cpf','cnpj') or input_pricing_tier not in('cpf','cnpj','alianca','parceria') or input_payment_type not in('clean','dirty') then raise exception 'Dados comerciais inválidos.';end if;
 if nullif(trim(input_customer_name),'') is null or nullif(trim(input_passport),'') is null then raise exception 'Informe responsável e passaporte.';end if;
 if input_customer_type='cnpj' and nullif(trim(input_cnpj_name),'') is null then raise exception 'Informe o nome do CNPJ.';end if;
 if input_items is null or jsonb_typeof(input_items)<>'array' or jsonb_array_length(input_items)=0 then raise exception 'Adicione pelo menos um produto.';end if;
 delete from order_items where order_id=input_order_id;
 for x in select value from jsonb_array_elements(input_items) loop q:=greatest(1,coalesce((x->>'quantity')::integer,1));mode:=coalesce(nullif(x->>'acquisition_mode',''),'auto');if mode not in('auto','stock','produce') then raise exception 'Estratégia inválida.';end if;
  select * into p from products where id=(x->>'product_id')::uuid and is_active and allows_order;if not found then raise exception 'Produto inválido ou indisponível.';end if;
  select * into pr from product_prices where product_id=p.id and customer_type=input_pricing_tier;if not found then raise exception 'Preço não cadastrado para o produto %.',p.name;end if;
  price:=case when pr.wholesale_minimum is not null and q>=pr.wholesale_minimum then coalesce(pr.wholesale_price,pr.unit_price) else pr.unit_price end;
  insert into order_items(order_id,product_id,product_name,quantity,quantity_from_stock,quantity_to_produce,unit_price,subtotal,acquisition_mode) values(input_order_id,p.id,p.name,q,0,q,price,price*q,mode);clean:=clean+price*q;end loop;
 dirty:=round(clean*1.30,2);final:=case when input_payment_type='dirty' then dirty else clean end;update orders set customer_type=input_customer_type,customer_name=trim(input_customer_name),cnpj_name=case when input_customer_type='cnpj' then nullif(trim(input_cnpj_name),'') end,passport=trim(input_passport),phone=nullif(trim(input_phone),''),notes=nullif(trim(input_notes),''),payment_type=input_payment_type,pricing_tier=input_pricing_tier,production_helpers=nullif(trim(input_production_helpers),''),total_amount=clean,clean_amount=clean,dirty_amount=dirty,final_amount=final,commission_amount=round(final*commission_rate,2),net_amount=round(final-(final*commission_rate),2),updated_at=now() where id=input_order_id returning * into o;
 insert into activity_logs(user_id,action,entity_type,entity_id,description,new_data) values(auth.uid(),'update','order',o.id,'Encomenda e estratégia de produção alteradas.',jsonb_build_object('code',o.code));return jsonb_build_object('success',true,'id',o.id,'code',o.code,'final_amount',o.final_amount,'status',o.status);
end $$;

grant execute on function public.consume_inventory_item_planned(uuid,numeric,uuid,uuid[],text) to authenticated,service_role;
grant execute on function public.consume_order_inventory(uuid),public.adjust_order_production_inventory(uuid,text) to authenticated,service_role;
grant execute on function public.create_internal_order(text,text,text,text,text,text,text,text,text,jsonb) to authenticated;
grant execute on function public.update_internal_order(uuid,text,text,text,text,text,text,text,text,text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
