# V7.3 — Estoque único entre Site e Discord

## 1. Banco

Execute no Supabase:

```text
database/015-v7-3-estoque-unificado-discord-site.sql
```

A migration cria dois estoques independentes:

- `geral`
- `gerencia`

Os valores antigos de `materials.stock_quantity` são copiados inicialmente para o estoque da Gerência. O estoque Geral começa zerado para ser conferido pelo bot.

## 2. Regra da encomenda

Cada encomenda escolhe qual baú será usado. Ao mudar o status para **Pronta**, os materiais são consumidos automaticamente desse estoque.

- intermediários prontos são usados primeiro;
- o restante abre a receita do intermediário;
- materiais básicos insuficientes bloqueiam a mudança para Pronta;
- a mesma encomenda não pode consumir duas vezes.

## 3. Bot

Use o pacote do bot V3 e configure:

```env
SUPABASE_URL=https://zxapsoxexpykpqkapdgj.supabase.co
SUPABASE_SERVICE_ROLE_KEY=sb_secret_...
DISCORD_ORDER_REGISTRATION_CHANNEL_ID=...
DISCORD_ORDER_HISTORY_CHANNEL_ID=...
```

O bot passa a gravar entradas e saídas no Supabase. O SQLite permanece somente para guardar a configuração dos canais de cada baú.

## 4. Conferência inicial

Depois da migration e do bot novo, confira fisicamente os baús e rode:

```text
/definir_saldo chave:geral item:Aluminio quantidade:3809
/definir_saldo chave:gerencia item:Placa Blindada quantidade:164
```

Isso alinha o sistema com o jogo antes das novas movimentações.
