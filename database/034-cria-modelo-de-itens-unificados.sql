begin;

create or replace function public.normalize_inventory_name(p_name text) returns text
language sql immutable as $$
 select trim(regexp_replace(translate(lower(coalesce(p_name,'')),'áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc'),'\s+',' ','g'))
$$;

create table public.inventory_items(
 id uuid primary key default gen_random_uuid(), name text not null,
 normalized_name text not null unique, unit text not null default 'unidade',
 is_active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.materials add column inventory_item_id uuid references public.inventory_items(id);
alter table public.products add column inventory_item_id uuid references public.inventory_items(id);
create unique index materials_inventory_item_uidx on public.materials(inventory_item_id) where inventory_item_id is not null;
create unique index products_inventory_item_uidx on public.products(inventory_item_id) where inventory_item_id is not null;

insert into public.inventory_items(name,normalized_name,unit,is_active)
select name,public.normalize_inventory_name(name),coalesce(nullif(unit,''),'unidade'),is_active from public.materials
on conflict(normalized_name) do nothing;
update public.materials m set inventory_item_id=i.id from public.inventory_items i where i.normalized_name=public.normalize_inventory_name(m.name);
update public.products p set inventory_item_id=i.id from public.inventory_items i
where i.normalized_name=public.normalize_inventory_name(p.name);
update public.products p set inventory_item_id=i.id from public.inventory_items i
where p.inventory_item_id is null and public.normalize_inventory_name(p.name)='metanfetamina' and i.normalized_name='meta';
insert into public.inventory_items(name,normalized_name,is_active)
select p.name,public.normalize_inventory_name(p.name),p.is_active from public.products p where p.inventory_item_id is null
on conflict(normalized_name) do nothing;
update public.products p set inventory_item_id=i.id from public.inventory_items i
where p.inventory_item_id is null and i.normalized_name=public.normalize_inventory_name(p.name);
update public.inventory_items i set name=p.name,normalized_name=public.normalize_inventory_name(p.name)
from public.products p where p.inventory_item_id=i.id and public.normalize_inventory_name(p.name)='metanfetamina';

create or replace function public.ensure_product_inventory_item() returns trigger language plpgsql security definer set search_path=public as $$
declare iid uuid;
begin
 if new.inventory_item_id is not null then return new; end if;
 select id into iid from public.inventory_items where normalized_name=public.normalize_inventory_name(new.name);
 if iid is null then insert into public.inventory_items(name,normalized_name,unit,is_active) values(new.name,public.normalize_inventory_name(new.name),'unidade',new.is_active) returning id into iid; end if;
 new.inventory_item_id:=iid; return new;
end $$;
drop trigger if exists products_ensure_inventory_item on public.products;
create trigger products_ensure_inventory_item before insert or update of name,inventory_item_id on public.products for each row execute function public.ensure_product_inventory_item();

create or replace function public.ensure_material_inventory_item() returns trigger language plpgsql security definer set search_path=public as $$
declare iid uuid;
begin
 if new.inventory_item_id is not null then return new; end if;
 select id into iid from public.inventory_items where normalized_name=public.normalize_inventory_name(new.name);
 if iid is null then insert into public.inventory_items(name,normalized_name,unit,is_active) values(new.name,public.normalize_inventory_name(new.name),coalesce(new.unit,'unidade'),new.is_active) returning id into iid; end if;
 new.inventory_item_id:=iid; return new;
end $$;
drop trigger if exists materials_ensure_inventory_item on public.materials;
create trigger materials_ensure_inventory_item before insert or update of name,inventory_item_id on public.materials for each row execute function public.ensure_material_inventory_item();

create table public.inventory_item_aliases(
 id uuid primary key default gen_random_uuid(), inventory_item_id uuid not null references public.inventory_items(id) on delete cascade,
 alias text not null, normalized_alias text not null unique
);
insert into public.inventory_item_aliases(inventory_item_id,alias,normalized_alias)
select inventory_item_id,'Meta','meta' from public.products where public.normalize_inventory_name(name)='metanfetamina';

create table public.inventory_item_balances(
 stock_id uuid not null references public.inventory_stocks(id) on delete cascade,
 inventory_item_id uuid not null references public.inventory_items(id) on delete cascade,
 quantity numeric not null default 0 check(quantity>=0), reserved_quantity numeric not null default 0 check(reserved_quantity>=0),
 updated_at timestamptz not null default now(), primary key(stock_id,inventory_item_id)
);
insert into public.inventory_item_balances(stock_id,inventory_item_id,quantity,reserved_quantity,updated_at)
select b.stock_id,m.inventory_item_id,b.quantity,b.reserved_quantity,b.updated_at
from public.inventory_balances b join public.materials m on m.id=b.material_id;
insert into public.inventory_item_balances(stock_id,inventory_item_id)
select s.id,i.id from public.inventory_stocks s cross join public.inventory_items i on conflict do nothing;

create or replace function public.initialize_inventory_item_balances() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.inventory_item_balances(stock_id,inventory_item_id) select id,new.id from public.inventory_stocks where scope in('geral','gerencia') on conflict do nothing;
 return new;
end $$;
create trigger inventory_items_initialize_balances after insert on public.inventory_items for each row execute function public.initialize_inventory_item_balances();

create table public.inventory_item_movements(
 id uuid primary key default gen_random_uuid(), stock_id uuid not null references public.inventory_stocks(id),
 inventory_item_id uuid not null references public.inventory_items(id),
 movement_type text not null check(movement_type in ('entry','exit','adjustment_entry','adjustment_exit','order_consumption','production_consumption','production_surplus')),
 quantity numeric not null check(quantity>0), balance_before numeric not null,balance_after numeric not null,
 source text not null default 'manual',reason text,order_id uuid references public.orders(id),operation_key text,
 discord_user_id text,discord_user_name text,registered_by uuid references public.profiles(id),created_at timestamptz not null default clock_timestamp()
);
create unique index inventory_item_movements_operation_uidx on public.inventory_item_movements(operation_key) where operation_key is not null;

create view public.inventory_craft_recipes with(security_invoker=true) as
select p.inventory_item_id production_item_id,m.inventory_item_id component_item_id,pm.quantity_required,
 greatest(coalesce(p.output_quantity,1),0.000001) output_quantity
from public.products p join public.product_materials pm on pm.product_id=p.id join public.materials m on m.id=pm.material_id
union all
select m.inventory_item_id,c.inventory_item_id,mc.quantity_required,greatest(coalesce(m.output_quantity,1),0.000001)
from public.materials m join public.material_components mc on mc.material_id=m.id join public.materials c on c.id=mc.component_material_id
where not exists(select 1 from public.products p join public.product_materials pm on pm.product_id=p.id where p.inventory_item_id=m.inventory_item_id);

create view public.inventory_catalog with(security_invoker=true) as
select i.id item_id,i.name,i.unit,i.is_active,
 exists(select 1 from public.products p where p.inventory_item_id=i.id and p.is_active) is_product,
 exists(select 1 from public.materials m where m.inventory_item_id=i.id and m.is_active) is_material,
 exists(select 1 from public.inventory_craft_recipes r where r.production_item_id=i.id) is_craftable,
 coalesce((select min(minimum_stock) from public.materials m where m.inventory_item_id=i.id),0) minimum_stock
from public.inventory_items i;
create view public.inventory_all_balances with(security_invoker=true) as
select stock_id,inventory_item_id item_id,quantity,reserved_quantity,updated_at from public.inventory_item_balances;

create or replace function public.resolve_inventory_item(p_name text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v record;
begin
 select i.id,i.name,i.unit into v from public.inventory_item_aliases a join public.inventory_items i on i.id=a.inventory_item_id
 where a.normalized_alias=public.normalize_inventory_name(p_name) and i.is_active limit 1;
 if not found then select id,name,unit into v from public.inventory_items where normalized_name=public.normalize_inventory_name(p_name) and is_active limit 1; end if;
 if v.id is null then raise exception 'Item não cadastrado: %.',p_name; end if;
 return jsonb_build_object('item_id',v.id,'name',v.name,'unit',v.unit);
end $$;

create or replace function public.set_inventory_item_balance(p_scope text,p_item_id uuid,p_quantity numeric,p_reason text default 'Conferência física',p_source text default 'discord',p_operation_key text default null,p_discord_user_id text default null,p_discord_user_name text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare sid uuid; oldq numeric; kind text;
begin
 if p_quantity<0 then raise exception 'Quantidade inválida.'; end if;
 select id into sid from public.inventory_stocks where scope=p_scope and is_active;
 select quantity into oldq from public.inventory_item_balances where stock_id=sid and inventory_item_id=p_item_id for update;
 if oldq is null then raise exception 'Estoque ou item inválido.'; end if;
 update public.inventory_item_balances set quantity=p_quantity,updated_at=clock_timestamp() where stock_id=sid and inventory_item_id=p_item_id;
 if oldq<>p_quantity then
  kind:=case when p_quantity>oldq then 'adjustment_entry' else 'adjustment_exit' end;
  insert into public.inventory_item_movements(stock_id,inventory_item_id,movement_type,quantity,balance_before,balance_after,source,reason,operation_key,discord_user_id,discord_user_name,registered_by)
  values(sid,p_item_id,kind,abs(p_quantity-oldq),oldq,p_quantity,p_source,p_reason,p_operation_key,p_discord_user_id,p_discord_user_name,auth.uid());
 end if;
 return jsonb_build_object('success',true,'before',oldq,'after',p_quantity);
end $$;

create or replace function public.apply_inventory_item_batch(p_scope text,p_movement_type text,p_items jsonb,p_source text default 'discord',p_reason text default null,p_operation_key text default null,p_discord_user_id text default null,p_discord_user_name text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare sid uuid; x jsonb; iid uuid;q numeric;oldq numeric;newq numeric; result jsonb:='[]';
begin
 if p_movement_type not in('entry','exit') then raise exception 'Movimentação inválida.'; end if;
 select id into sid from public.inventory_stocks where scope=p_scope and is_active;
 for x in select value from jsonb_array_elements(p_items) loop
  iid:=(x->>'item_id')::uuid;q:=(x->>'quantity')::numeric;
  select quantity into oldq from public.inventory_item_balances where stock_id=sid and inventory_item_id=iid for update;
  newq:=case when p_movement_type='entry' then oldq+q else oldq-q end;
  if q<=0 or newq<0 then raise exception 'Quantidade ou saldo inválido.'; end if;
  update public.inventory_item_balances set quantity=newq,updated_at=clock_timestamp() where stock_id=sid and inventory_item_id=iid;
  insert into public.inventory_item_movements(stock_id,inventory_item_id,movement_type,quantity,balance_before,balance_after,source,reason,operation_key,discord_user_id,discord_user_name,registered_by)
  values(sid,iid,p_movement_type,q,oldq,newq,p_source,p_reason,case when p_operation_key is null then null else p_operation_key||':'||iid end,p_discord_user_id,p_discord_user_name,auth.uid());
  result:=result||jsonb_build_array(jsonb_build_object('item_id',iid,'quantity',q,'before',oldq,'after',newq));
 end loop;
 return jsonb_build_object('success',true,'scope',p_scope,'items',result);
end $$;

create or replace function public.consume_inventory_item_combined(p_item_id uuid,p_quantity numeric,p_order_id uuid,p_path uuid[] default '{}') returns jsonb
language plpgsql security definer set search_path=public as $$
declare st record;available numeric;used numeric;remaining numeric:=p_quantity;ready numeric:=0;r record;outq numeric;batches numeric;produced numeric;surplus numeric;general_id uuid;beforeq numeric;item_name text;
begin
 if p_quantity<=0 then return jsonb_build_object('ready',0,'produced',0,'surplus',0); end if;
 if p_item_id=any(p_path) then raise exception 'Receita circular.'; end if;
 select name into item_name from public.inventory_items where id=p_item_id;
 for st in select id,scope from public.inventory_stocks where is_active order by case scope when 'geral' then 1 else 2 end loop
  exit when remaining<=0;
  select quantity into available from public.inventory_item_balances where stock_id=st.id and inventory_item_id=p_item_id for update;
  used:=least(available,remaining);
  if used>0 then
   update public.inventory_item_balances set quantity=quantity-used,updated_at=clock_timestamp() where stock_id=st.id and inventory_item_id=p_item_id;
   insert into public.inventory_item_movements(stock_id,inventory_item_id,movement_type,quantity,balance_before,balance_after,source,order_id,registered_by)
   values(st.id,p_item_id,case when cardinality(p_path)=0 then 'order_consumption' else 'production_consumption' end,used,available,available-used,'order',p_order_id,auth.uid());
   remaining:=remaining-used;ready:=ready+used;
  end if;
 end loop;
 if remaining<=0 then return jsonb_build_object('ready',ready,'produced',0,'surplus',0); end if;
 select max(output_quantity) into outq from public.inventory_craft_recipes where production_item_id=p_item_id;
 if outq is null then raise exception 'Item insuficiente e sem receita: %.',item_name; end if;
 batches:=ceil(remaining/outq);produced:=batches*outq;surplus:=produced-remaining;
 for r in select component_item_id,quantity_required from public.inventory_craft_recipes where production_item_id=p_item_id loop
  perform public.consume_inventory_item_combined(r.component_item_id,batches*r.quantity_required,p_order_id,p_path||p_item_id);
 end loop;
 if surplus>0 then
  select id into general_id from public.inventory_stocks where scope='geral';
  select quantity into beforeq from public.inventory_item_balances where stock_id=general_id and inventory_item_id=p_item_id for update;
  update public.inventory_item_balances set quantity=quantity+surplus where stock_id=general_id and inventory_item_id=p_item_id;
  insert into public.inventory_item_movements(stock_id,inventory_item_id,movement_type,quantity,balance_before,balance_after,source,order_id)
  values(general_id,p_item_id,'production_surplus',surplus,beforeq,beforeq+surplus,'order',p_order_id);
 end if;
 return jsonb_build_object('ready',ready,'produced',produced,'surplus',surplus);
end $$;

create table public.order_item_fulfillments(order_id uuid not null references public.orders(id) on delete cascade,inventory_item_id uuid not null references public.inventory_items(id),covered_quantity numeric not null default 0,updated_at timestamptz not null default now(),primary key(order_id,inventory_item_id));
insert into public.order_item_fulfillments select oi.order_id,p.inventory_item_id,sum(oi.quantity),now() from public.order_items oi join public.order_inventory_consumptions c on c.order_id=oi.order_id join public.products p on p.id=oi.product_id group by oi.order_id,p.inventory_item_id;

create or replace function public.consume_order_inventory(p_order_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare x record;gid uuid;
begin
 if exists(select 1 from public.order_inventory_consumptions where order_id=p_order_id) then return jsonb_build_object('success',true,'already_consumed',true); end if;
 for x in select p.inventory_item_id,sum(oi.quantity)::numeric q from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=p_order_id group by p.inventory_item_id loop
  perform public.consume_inventory_item_combined(x.inventory_item_id,x.q,p_order_id,'{}');
  insert into public.order_item_fulfillments values(p_order_id,x.inventory_item_id,x.q,clock_timestamp());
 end loop;
 select id into gid from public.inventory_stocks where scope='geral';insert into public.order_inventory_consumptions values(p_order_id,gid,clock_timestamp());
 return jsonb_build_object('success',true,'already_consumed',false);
end $$;

-- O ajuste compara itens finais cobertos; reduções não devolvem saldo.
create or replace function public.adjust_order_production_inventory(p_order_id uuid,p_responsible_name text) returns jsonb language plpgsql security definer set search_path=public as $$
declare x record;delta numeric;adds jsonb:='[]';excess jsonb:='[]';status_now text;since timestamptz:=clock_timestamp();moves jsonb;person text:=trim(p_responsible_name);
begin
 if length(person)<3 then raise exception 'Informe o nome RP.'; end if;
 select status into status_now from public.orders where id=p_order_id for update;
 if status_now is null or status_now in('delivered','cancelled','rejected') then raise exception 'Encomenda finalizada ou inexistente.'; end if;
 if not exists(select 1 from public.order_inventory_consumptions where order_id=p_order_id) then raise exception 'A encomenda ainda não teve a baixa inicial.'; end if;
 for x in with cur as(select p.inventory_item_id,sum(oi.quantity)::numeric q from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=p_order_id group by p.inventory_item_id), ids as(select inventory_item_id from cur union select inventory_item_id from public.order_item_fulfillments where order_id=p_order_id)
  select ids.inventory_item_id,i.name,coalesce(cur.q,0) required,coalesce(f.covered_quantity,0) covered from ids join public.inventory_items i on i.id=ids.inventory_item_id left join cur on cur.inventory_item_id=ids.inventory_item_id left join public.order_item_fulfillments f on f.order_id=p_order_id and f.inventory_item_id=ids.inventory_item_id
 loop
  delta:=x.required-x.covered;
  if delta>0 then
   perform public.consume_inventory_item_combined(x.inventory_item_id,delta,p_order_id,'{}');
   insert into public.order_item_fulfillments values(p_order_id,x.inventory_item_id,x.required,clock_timestamp()) on conflict(order_id,inventory_item_id) do update set covered_quantity=greatest(public.order_item_fulfillments.covered_quantity,excluded.covered_quantity),updated_at=clock_timestamp();
   adds:=adds||jsonb_build_array(jsonb_build_object('item',x.name,'quantity',delta));
  elsif delta<0 then excess:=excess||jsonb_build_array(jsonb_build_object('item',x.name,'quantity',abs(delta))); end if;
 end loop;
 if jsonb_array_length(adds)=0 then return jsonb_build_object('success',true,'adjusted',false,'additions',adds,'excess',excess); end if;
 select coalesce(jsonb_agg(jsonb_build_object('item',i.name,'quantity',m.quantity,'movement_type',m.movement_type,'scope',s.scope)),'[]') into moves from public.inventory_item_movements m join public.inventory_items i on i.id=m.inventory_item_id join public.inventory_stocks s on s.id=m.stock_id where m.order_id=p_order_id and m.created_at>=since;
 insert into public.integration_outbox(event_type,entity_type,entity_id,payload,status,destination) values('order_inventory_adjusted','order',p_order_id,jsonb_build_object('responsible_name',person,'movements',moves,'additions',adds),'pending','order_history');
 return jsonb_build_object('success',true,'adjusted',true,'additions',adds,'excess',excess);
end $$;

create or replace function public.start_order_production(p_order_id uuid,p_responsible_name text) returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;old_status text;person text:=trim(p_responsible_name);since timestamptz:=clock_timestamp();moves jsonb;
begin
 if length(person)<3 then raise exception 'Informe o nome RP.'; end if;
 select status into old_status from public.orders where id=p_order_id and deleted_at is null for update;
 if old_status is null or old_status in('delivered','cancelled','rejected') then raise exception 'Encomenda finalizada ou inexistente.'; end if;
 result:=public.consume_order_inventory(p_order_id);
 if not coalesce((result->>'already_consumed')::boolean,false) then
  update public.orders set status='in_production',production_responsible=person,updated_at=clock_timestamp() where id=p_order_id;
  insert into public.productions(order_id,status,responsible_id,started_at,notes) values(p_order_id,'in_progress',auth.uid(),clock_timestamp(),'Produção iniciada por '||person) on conflict(order_id) do update set status='in_progress',responsible_id=excluded.responsible_id,notes=excluded.notes,updated_at=clock_timestamp();
  insert into public.order_status_history(order_id,previous_status,new_status,changed_by,notes,status,note,old_status) values(p_order_id,old_status,'in_production',auth.uid(),'Itens baixados por '||person,'in_production','Itens baixados por '||person,old_status);
  select coalesce(jsonb_agg(jsonb_build_object('item',i.name,'quantity',m.quantity,'movement_type',m.movement_type,'scope',s.scope)),'[]') into moves from public.inventory_item_movements m join public.inventory_items i on i.id=m.inventory_item_id join public.inventory_stocks s on s.id=m.stock_id where m.order_id=p_order_id and m.created_at>=since;
  insert into public.integration_outbox(event_type,entity_type,entity_id,payload,status,destination) values('order_inventory_consumed','order',p_order_id,jsonb_build_object('responsible_name',person,'movements',moves),'pending','order_history') on conflict do nothing;
 end if;
 return result||jsonb_build_object('status','in_production','responsible_name',person);
end $$;

create or replace function public.register_cash_inventory_movement(p_stock_scope text,p_payment_type text,p_movement_type text,p_amount numeric,p_description text) returns jsonb language plpgsql security definer set search_path=public as $$
declare item_name text:=case when p_payment_type='dirty' then 'Dinheiro Sujo' else 'Dinheiro' end;iid uuid;result jsonb;
begin
 if not public.is_staff() or p_amount<=0 then raise exception 'Movimentação inválida.'; end if;
 iid:=(public.resolve_inventory_item(item_name)->>'item_id')::uuid;
 result:=public.apply_inventory_item_batch(p_stock_scope,p_movement_type,jsonb_build_array(jsonb_build_object('item_id',iid,'quantity',p_amount)),'site',p_description,'cash:'||gen_random_uuid(),null,null);
 insert into public.cash_movements(movement_type,description,amount,registered_by,source,payment_type) values(p_movement_type,trim(p_description)||' · '||p_stock_scope,p_amount,auth.uid(),'site',p_payment_type);
 return (result->'items'->0)||jsonb_build_object('stock_scope',p_stock_scope,'payment_type',p_payment_type,'movement_type',p_movement_type,'amount',p_amount);
end $$;

alter table public.inventory_items enable row level security;alter table public.inventory_item_aliases enable row level security;alter table public.inventory_item_balances enable row level security;alter table public.inventory_item_movements enable row level security;alter table public.order_item_fulfillments enable row level security;
create policy "staff items" on public.inventory_items for select to authenticated using(public.is_staff());create policy "staff aliases" on public.inventory_item_aliases for select to authenticated using(public.is_staff());create policy "staff item balances" on public.inventory_item_balances for select to authenticated using(public.is_staff());create policy "staff item movements" on public.inventory_item_movements for select to authenticated using(public.is_staff());create policy "staff fulfillments" on public.order_item_fulfillments for select to authenticated using(public.is_staff());
grant select on public.inventory_items,public.inventory_item_aliases,public.inventory_item_balances,public.inventory_item_movements,public.order_item_fulfillments,public.inventory_catalog,public.inventory_all_balances,public.inventory_craft_recipes to authenticated;
revoke all on function public.resolve_inventory_item(text),public.set_inventory_item_balance(text,uuid,numeric,text,text,text,text,text),public.apply_inventory_item_batch(text,text,jsonb,text,text,text,text,text),public.consume_inventory_item_combined(uuid,numeric,uuid,uuid[]) from public;
revoke all on function public.consume_order_inventory(uuid),public.adjust_order_production_inventory(uuid,text),public.start_order_production(uuid,text) from public;
grant execute on function public.resolve_inventory_item(text),public.set_inventory_item_balance(text,uuid,numeric,text,text,text,text,text),public.apply_inventory_item_batch(text,text,jsonb,text,text,text,text,text) to authenticated,service_role;
grant execute on function public.consume_order_inventory(uuid),public.adjust_order_production_inventory(uuid,text) to authenticated,service_role;
grant execute on function public.start_order_production(uuid,text) to authenticated,service_role;
revoke all on function public.register_cash_inventory_movement(text,text,text,numeric,text) from public;
grant execute on function public.register_cash_inventory_movement(text,text,text,numeric,text) to authenticated;
notify pgrst,'reload schema';
commit;
