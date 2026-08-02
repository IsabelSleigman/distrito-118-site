begin;

-- Garante que o evento usado pela baixa de materiais da encomenda seja aceito
-- mesmo em bancos que não executaram a migration 027 anteriormente.
alter table public.integration_outbox
  drop constraint if exists integration_outbox_event_type_check;

alter table public.integration_outbox
  add constraint integration_outbox_event_type_check check (
    event_type = any (array[
      'order_created'::text,
      'order_accepted'::text,
      'order_ready'::text,
      'order_delivered'::text,
      'order_rejected'::text,
      'order_status_changed'::text,
      'order_inventory_consumed'::text,
      'low_stock'::text
    ])
  );

create unique index if not exists integration_outbox_order_inventory_consumed_uidx
  on public.integration_outbox(entity_id, event_type)
  where event_type = 'order_inventory_consumed';

notify pgrst,'reload schema';
commit;
