# Distrito Control Center — V7

Esta versão continua a base operacional da V6 e conclui o fluxo principal de encomendas.

## V7 — Encomendas
- catálogo real carregado pelo Supabase;
- solicitação pública com múltiplos produtos;
- preços por CPF, CNPJ, Aliança e Parceria;
- aplicação automática de preço de atacado;
- status completamente apresentados em português;
- detalhes da encomenda no painel administrativo;
- linha do tempo pública e administrativa;
- exclusão lógica de encomendas, preservando o histórico;
- código de exemplo corrigido para o padrão `DT-00001`;
- nenhuma alteração no logo.

## Atualização do banco
Execute no Supabase, na ordem:

1. `database/002-pricing-tiers-and-initial-data.sql`;
2. `database/003-v6-base-operacional.sql`;
3. `database/004-v7-encomendas.sql`.

Depois abra o projeto pelo Live Server.

## Próxima etapa — V8
- estoque automático;
- reserva e baixa de materiais;
- cálculo de materiais necessários;
- dashboard operacional real;
- caixa real.


## V7.1
Depois da migration 004, execute `database/005-v7-1-codigo-e-status.sql`. Ela cria códigos no formato `DT-505-ISA-7GQ2`, migra códigos sequenciais antigos, libera a consulta apenas pelo código e move a alteração de status para a tela de detalhes.


## Correção V7.1.1
- Corrigida a abertura do modal de detalhes das encomendas.
- O elemento agora utiliza a classe `modal-backdrop`, compatível com o CSS existente.


## Correção V7.1.2

Execute também `database/006-v7-1-2-atualizacao-status.sql` para habilitar a atualização segura de status e observações pelo painel.

## Correção V7.1.3
Execute `database/007-v7-1-3-status-fix.sql` no Supabase após as migrations anteriores.
Depois publique os arquivos e recarregue o painel com Ctrl+F5.


## V7.1.4-beta
- Tema atualizado para preto, branco e tons de cinza.
- Estoque administrativo conectado aos dados reais da tabela `materials`.
- Dashboard e tela de estoque usam o mesmo cálculo: total - reservado.
- Identificação visual de versão beta para testes internos.


## V7.1.6-beta
- Tema cinza com contraste reforçado.
- Status inativo voltou a usar vermelho.
- Estoque de produto removido da interface; apenas materiais são controlados.
- Catálogo identifica itens como produzidos sob encomenda.


## V7.1.6-beta

- Status das encomendas com cores semânticas no dashboard e painel.
- Linha do tempo usa a mesma cor do status correspondente.
- Vermelho reservado para recusadas; canceladas usam cinza.


## Correção de rotas Vercel
- Links administrativos agora usam rotas absolutas `/admin/...`.
- Links públicos e redirecionamentos de login/logout usam rotas absolutas com `cleanUrls`.
"# distrito-118-site" 


## V7.1.8 — Pagamento e caixa
- cliente escolhe dinheiro limpo ou sujo;
- dinheiro sujo custa 30% a mais;
- comissão de 20% calculada sobre o valor final;
- ao marcar a encomenda como entregue, a entrada da venda e a saída da comissão são lançadas no caixa sem duplicidade;
- caixa administrativo conectado ao Supabase.

Execute `database/008-v7-1-8-pagamento-caixa.sql` no Supabase antes de publicar esta versão.


## V7.1.9-beta
- encomendas passam a ser registradas apenas no painel interno;
- catálogo público orienta o cliente a procurar a gerência;
- perfil `gerente` acessa Dashboard, Encomendas e Caixa;
- produtos, materiais, categorias e estoque ficam restritos aos administradores;
- status “Separação de materiais” renomeado para “Separação de materiais”;
- detalhes da encomenda mostram materiais necessários, disponíveis e faltantes;
- correção da duplicação de eventos na linha do tempo;
- execute `database/009-v7-1-9-gerentes-materiais-status.sql`.
