begin;

-- V7.1 — código público DT-PASSAPORTE-NOME-ALEATÓRIO e consulta somente pelo código.

create or replace function public.normalize_order_name(input_name text)
returns text
language sql
immutable
as $$
  select upper(substr(
    regexp_replace(
      translate(coalesce(input_name,''),
        'ÁÀÃÂÄÉÈÊËÍÌÎÏÓÒÕÔÖÚÙÛÜÇáàãâäéèêëíìîïóòõôöúùûüç',
        'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc'),
      '[^A-Za-z0-9]', '', 'g'),
    1, 3));
$$;

create or replace function public.random_order_suffix(input_length integer default 4)
returns text
language plpgsql
volatile
as $$
declare
  chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  result text := '';
  i integer;
begin
  for i in 1..input_length loop
    result := result || substr(chars, 1 + floor(random() * length(chars))::integer, 1);
  end loop;
  return result;
end;
$$;

create or replace function public.assign_public_order_code()
returns trigger
language plpgsql
set search_path=public
as $$
declare
  name_part text;
  passport_part text;
  candidate text;
begin
  -- Substitui também o formato sequencial antigo criado pela função anterior.
  if new.code is null or new.code = '' or new.code ~* '^(DST|DT)-[0-9]+$' then
    name_part := public.normalize_order_name(coalesce(new.cnpj_name,new.customer_name));
    if length(name_part) < 3 then name_part := rpad(name_part,3,'X'); end if;
    passport_part := upper(regexp_replace(coalesce(new.passport,'SEM'),'[^A-Za-z0-9]','','g'));
    if passport_part = '' then passport_part := 'SEM'; end if;

    loop
      candidate := 'DT-' || passport_part || '-' || name_part || '-' || public.random_order_suffix(4);
      exit when not exists(select 1 from public.orders where upper(code)=upper(candidate) and id is distinct from new.id);
    end loop;
    new.code := candidate;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_assign_public_code on public.orders;
create trigger orders_assign_public_code
before insert or update of code,passport,customer_name,cnpj_name on public.orders
for each row execute function public.assign_public_order_code();

-- Atualiza pedidos antigos previsíveis. O UUID interno e todo o histórico permanecem iguais.
update public.orders
set code = null
where code is null or code ~* '^(DST|DT)-[0-9]+$';

-- O UPDATE acima chama o trigger apenas quando "code" está no SET.
update public.orders set code=code where code is null;

create or replace function public.get_public_order_by_code(input_code text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  target_order public.orders;
begin
  select * into target_order
  from public.orders
  where upper(code)=upper(trim(input_code))
    and deleted_at is null;

  if not found then return null; end if;

  return jsonb_build_object(
    'code', target_order.code,
    'customer_display', coalesce(target_order.cnpj_name,target_order.customer_name),
    'total_amount', target_order.total_amount,
    'status', target_order.status,
    'created_at', target_order.created_at,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'quantity',i.quantity,
        'product_name',i.product_name,
        'subtotal',i.subtotal
      ) order by i.created_at)
      from public.order_items i
      where i.order_id=target_order.id
    ),'[]'::jsonb)
  );
end;
$$;

create or replace function public.get_public_order_timeline_by_code(input_code text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  target_id uuid;
begin
  select id into target_id
  from public.orders
  where upper(code)=upper(trim(input_code))
    and deleted_at is null;

  if not found then return null; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'status',h.status,
      'note',h.note,
      'created_at',h.created_at
    ) order by h.created_at)
    from public.order_status_history h
    where h.order_id=target_id
  ),'[]'::jsonb);
end;
$$;

grant execute on function public.get_public_order_by_code(text) to anon,authenticated;
grant execute on function public.get_public_order_timeline_by_code(text) to anon,authenticated;

commit;
