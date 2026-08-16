begin;

-- Isola somente os objetos com nomes reutilizados pelo modelo unificado.
-- Nenhum saldo ou movimento é apagado.
do $$
begin
  if to_regclass('public.inventory_catalog') is not null
     and to_regclass('public.inventory_catalog_legacy_v76') is null then
    alter view public.inventory_catalog rename to inventory_catalog_legacy_v76;
  end if;
  if to_regclass('public.inventory_all_balances') is not null
     and to_regclass('public.inventory_all_balances_legacy_v76') is null then
    alter view public.inventory_all_balances rename to inventory_all_balances_legacy_v76;
  end if;
  if to_regclass('public.inventory_item_aliases') is not null
     and to_regclass('public.inventory_item_aliases_legacy_v76') is null then
    alter table public.inventory_item_aliases rename to inventory_item_aliases_legacy_v76;
  end if;
end $$;

notify pgrst,'reload schema';
commit;
