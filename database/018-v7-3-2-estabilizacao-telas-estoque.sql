begin;

-- Mantém exatamente um baú de cada tipo e garante saldo para todos os materiais.
insert into public.inventory_stocks(name,scope,is_active)
values ('Estoque Geral','geral',true),('Estoque da Gerência','gerencia',true)
on conflict (scope) do update set is_active=true;

insert into public.inventory_balances(stock_id,material_id,quantity,reserved_quantity)
select stock.id,material.id,0,0
from public.inventory_stocks stock
cross join public.materials material
where stock.scope in ('geral','gerencia')
on conflict (stock_id,material_id) do nothing;

-- Usuários da equipe precisam consultar os três recursos para carregar
-- Encomendas, Calculadora e Estoque sem depender de joins embutidos do PostgREST.
grant select on public.inventory_stocks, public.inventory_balances to authenticated;

notify pgrst, 'reload schema';
commit;
