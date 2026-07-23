begin;

-- V7.4.4 — o saldo exibido pelo site passa a vir do estoque real da Gerência.
-- Esta migration não altera saldos de inventário. Ela apenas garante que
-- pseudo-movimentações antigas de depósito no baú não permaneçam no histórico.
delete from public.cash_movements where source = 'vault';

commit;
