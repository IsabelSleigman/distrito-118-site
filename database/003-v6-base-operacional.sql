begin;

-- V6: nomes oficiais, categorias e imagens locais do catálogo.

insert into public.product_categories (name,description,is_active)
values
 ('Proteção','Equipamentos de proteção.',true),
 ('Armamentos','Armamentos produzidos pela Distrito.',true),
 ('Acessórios','Acessórios e componentes.',true),
 ('Substâncias','Produtos de substâncias.',true)
on conflict (name) do update set description=excluded.description,is_active=true;

update public.products set
 name='Colete Balístico',
 description='Colete balístico disponível para encomenda.',
 image_url='/assets/images/products/colete-balistico.png',
 category_id=(select id from public.product_categories where name='Proteção')
where lower(name) in ('colete','colete balístico');

update public.products set
 name='Tec-9',
 image_url='/assets/images/products/tec-9.png',
 category_id=(select id from public.product_categories where name='Armamentos')
where lower(name) in ('tec-9','tec9');

update public.products set
 name='Steyr AUG',
 image_url='/assets/images/products/steyr-aug.png',
 category_id=(select id from public.product_categories where name='Armamentos')
where lower(name) in ('aug','steyr aug');

update public.products set name='Pente Estendido',image_url='/assets/images/products/pente-estendido.png',
 category_id=(select id from public.product_categories where name='Acessórios')
where lower(name)='pente estendido';

update public.products set name='Mira Holográfica',image_url='/assets/images/products/mira-holografica.png',
 category_id=(select id from public.product_categories where name='Acessórios')
where lower(name) in ('mira holografica','mira holográfica');

update public.products set name='Silenciador',image_url='/assets/images/products/silenciador.png',
 category_id=(select id from public.product_categories where name='Acessórios')
where lower(name)='silenciador';

update public.products set name='Empunhadura',image_url='/assets/images/products/empunhadura.png',
 category_id=(select id from public.product_categories where name='Acessórios')
where lower(name)='empunhadura';

update public.products set name='Lanterna Tática',image_url='/assets/images/products/lanterna-tatica.png',
 category_id=(select id from public.product_categories where name='Acessórios')
where lower(name) in ('lanterna','lanterna tática');

update public.products set name='Carreira de Cocaína',image_url='/assets/images/products/carreira-cocaina.png',
 category_id=(select id from public.product_categories where name='Substâncias')
where lower(name) in ('coca','carreira de cocaína','carreira de cocaina');

update public.products set name='Cigarro de Cannabis',image_url='/assets/images/products/cigarro-cannabis.png',
 category_id=(select id from public.product_categories where name='Substâncias')
where lower(name) in ('baseado','cigarro de cannabis');

update public.products set name='Metanfetamina',image_url='/assets/images/products/metanfetamina.png',
 category_id=(select id from public.product_categories where name='Substâncias')
where lower(name) in ('meth','meta','metanfetamina');

-- Mantém a categoria Geral apenas se ainda houver produtos nela.
update public.product_categories
set is_active = exists(select 1 from public.products where category_id=product_categories.id)
where name='Geral';

commit;
