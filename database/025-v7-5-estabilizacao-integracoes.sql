begin;

-- V7.5 — estabilização da integração de encomendas.
-- Não altera saldos de estoque ou caixa existentes.

-- Remove somente eventos de criação repetidos ainda não processados,
-- preservando o registro mais antigo de cada encomenda.
with repetidos as (
  select id,
         row_number() over (
           partition by order_id, event_type
           order by created_at asc, id asc
         ) as ordem
  from public.order_integration_events
  where event_type = 'created'
    and processed_at is null
)
delete from public.order_integration_events evento
using repetidos
where evento.id = repetidos.id
  and repetidos.ordem > 1;

-- Uma encomenda só pode possuir um evento de criação na fila exclusiva.
create unique index if not exists order_integration_events_created_order_uidx
  on public.order_integration_events(order_id, event_type)
  where event_type = 'created';

-- A outbox não é mais responsável por NOVA ENCOMENDA. Eventos antigos
-- pendentes são encerrados sem enviar outra mensagem ao Discord.
update public.integration_outbox
set status = 'completed',
    processed_at = coalesce(processed_at, now()),
    last_error = null
where event_type = 'order_created'
  and status in ('pending', 'processing', 'failed');

create index if not exists order_integration_events_pending_idx
  on public.order_integration_events(created_at)
  where event_type = 'created'
    and status = 'pending'
    and processed_at is null;

notify pgrst, 'reload schema';
commit;
