begin;

-- Fotografia permanente para conferência da conversão.
create table if not exists public.inventory_unification_audit (
  id uuid primary key default gen_random_uuid(),
  stock_id uuid not null,
  inventory_item_id uuid not null,
  product_id uuid,
  material_id uuid,
  material_quantity numeric not null default 0,
  product_quantity numeric not null default 0,
  chosen_quantity numeric not null default 0,
  rule text not null,
  created_at timestamptz not null default now()
);

insert into public.inventory_unification_audit(
  stock_id,inventory_item_id,product_id,material_id,
  material_quantity,product_quantity,chosen_quantity,rule
)
select
  s.id,p.inventory_item_id,p.id,m.id,
  coalesce(mb.quantity,0),coalesce(pb.quantity,0),
  case when coalesce(pb.quantity,0)>0 then pb.quantity else coalesce(mb.quantity,0) end,
  case when coalesce(pb.quantity,0)>0 then 'produto_positivo_priorizado' else 'material_existente_preservado' end
from public.products p
join public.materials m on m.inventory_item_id=p.inventory_item_id
cross join public.inventory_stocks s
left join public.inventory_balances mb on mb.stock_id=s.id and mb.material_id=m.id
left join public.inventory_product_balances pb on pb.stock_id=s.id and pb.product_id=p.id
where not exists(
  select 1 from public.inventory_unification_audit a
  where a.stock_id=s.id and a.inventory_item_id=p.inventory_item_id
);

-- Produtos sem material correspondente recebem seus saldos antigos.
-- Quando ambos existiam, saldo de produto positivo é considerado a conferência mais nova;
-- produto zerado nunca apaga o saldo material existente (Meta 313 permanece 313).
insert into public.inventory_item_balances(stock_id,inventory_item_id,quantity,reserved_quantity,updated_at)
select pb.stock_id,p.inventory_item_id,pb.quantity,pb.reserved_quantity,pb.updated_at
from public.inventory_product_balances pb
join public.products p on p.id=pb.product_id
where p.inventory_item_id is not null
on conflict(stock_id,inventory_item_id) do update set
  quantity=case when excluded.quantity>0 then excluded.quantity else public.inventory_item_balances.quantity end,
  reserved_quantity=greatest(public.inventory_item_balances.reserved_quantity,excluded.reserved_quantity),
  updated_at=greatest(public.inventory_item_balances.updated_at,excluded.updated_at);

-- Preserva aliases adicionais cadastrados na versão anterior.
insert into public.inventory_item_aliases(inventory_item_id,alias,normalized_alias)
select
  coalesce(p.inventory_item_id,m.inventory_item_id),
  a.alias,a.normalized_alias
from public.inventory_item_aliases_legacy_v76 a
left join public.products p on a.item_type='product' and p.id=a.product_id
left join public.materials m on a.item_type='material' and m.id=a.material_id
where coalesce(p.inventory_item_id,m.inventory_item_id) is not null
on conflict(normalized_alias) do update set
  inventory_item_id=excluded.inventory_item_id,alias=excluded.alias;

-- Mantém o maior baseline já coberto para a edição pós-baixa.
insert into public.order_item_fulfillments(order_id,inventory_item_id,covered_quantity,updated_at)
select f.order_id,p.inventory_item_id,f.covered_quantity,f.updated_at
from public.order_product_fulfillments f
join public.products p on p.id=f.product_id
where p.inventory_item_id is not null
on conflict(order_id,inventory_item_id) do update set
  covered_quantity=greatest(public.order_item_fulfillments.covered_quantity,excluded.covered_quantity),
  updated_at=greatest(public.order_item_fulfillments.updated_at,excluded.updated_at);

-- Importa o histórico anterior sem alterar novamente os saldos.
insert into public.inventory_item_movements(
  stock_id,inventory_item_id,movement_type,quantity,balance_before,balance_after,
  source,reason,order_id,operation_key,discord_user_id,discord_user_name,registered_by,created_at
)
select im.stock_id,m.inventory_item_id,im.movement_type,im.quantity,im.balance_before,im.balance_after,
  im.source,im.reason,im.order_id,'legacy-material:'||im.id,im.discord_user_id,im.discord_user_name,im.registered_by,im.created_at
from public.inventory_movements im join public.materials m on m.id=im.material_id
where m.inventory_item_id is not null
on conflict(operation_key) where operation_key is not null do nothing;

insert into public.inventory_item_movements(
  stock_id,inventory_item_id,movement_type,quantity,balance_before,balance_after,
  source,reason,order_id,operation_key,discord_user_id,discord_user_name,registered_by,created_at
)
select pm.stock_id,p.inventory_item_id,pm.movement_type,pm.quantity,pm.balance_before,pm.balance_after,
  pm.source,pm.reason,pm.order_id,'legacy-product:'||pm.id,pm.discord_user_id,pm.discord_user_name,pm.registered_by,pm.created_at
from public.inventory_product_movements pm join public.products p on p.id=pm.product_id
where p.inventory_item_id is not null
on conflict(operation_key) where operation_key is not null do nothing;

notify pgrst,'reload schema';
commit;
