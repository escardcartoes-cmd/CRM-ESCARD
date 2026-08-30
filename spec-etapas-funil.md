# Especificação — Reestruturação das etapas do funil

Projeto: CRM Funil de Vendas (Escard)
Migration: `supabase/migrations/20260828_0012_reestrutura_etapas.sql`
Frontend: `index.html`

**Status:** migration aplicada em produção em 28/08/2026. Encerra a série
0009 → 0012, todas aplicadas. Frontend publicado em `crm-72a.pages.dev` e
versionado no commit `007c89a`.

---

## Antes e depois

| # | Antes | Leads | Fila | | # | Depois | Leads | Fila |
|---|---|---|---|---|---|---|---|---|
| 1 | Prospecção | 12.067 | não | → | 1 | **Leads Novos** | 12.890 | não |
| 2 | Novo Lead | 823 | sim | → | 2 | **Sem Contato** | 0 | sim |
| 3 | Contato Feito | 774 | sim | | 3 | Contato Feito | 774 | sim |
| 4 | Reunião | 5 | sim | | 4 | Reunião | 5 | sim |
| 5 | Proposta/Orçamento | 0 | sim | ✗ | 5 | Negociação | 1 | sim |
| 6 | Negociação | 1 | sim | | 6 | Fechado Ganho | 1 | sim |
| 7 | Fechado Ganho | 1 | sim | | 7 | **Perdidos** | 660 | sim |
| 8 | Fechado Perdido | 660 | sim | → | | | | |

---

## Decisões

### "Leads Novos" fica FORA da fila de follow-up

A Prospecção já era `in_followup = false`, e é isso que impede os 12 mil leads
importados de afogarem a esteira do SDR. A etapa unificada herda esse
comportamento: a fila continua com ~1.440 itens trabalháveis em vez de saltar
para ~12.900.

**Efeito colateral assumido:** os 823 leads que hoje aparecem no Follow-up saem
da esteira. Passam a ser garimpados pelo Kanban e pelo filtro de lista.

### O histórico da fusão é preservado, não descartado

A FK `deal_stage_history → pipeline_stages` é `ON DELETE SET NULL`. Apagar a
linha de "Novo Lead" sem mais nada transformaria **1.107 movimentações** em
"etapa desconhecida" nos relatórios. A migration repontá-las para a etapa
unificada antes de apagar.

A exceção são as transições **entre** as duas etapas fundidas (Prospecção →
Novo Lead e vice-versa). Repontadas, virariam "Leads Novos → Leads Novos" e
inflariam a meta `movimentacoes` com um avanço de funil que deixou de existir.
Essas linhas são removidas.

### `stage_changed_at` não é tocado

Os 823 leads mudam de `stage_id`, mas o carimbo de entrada na etapa fica como
está. O lead não avançou no funil — a etapa é que mudou de nome. Atualizar o
carimbo zeraria o "tempo parado" de 823 leads de uma vez e sujaria o selo
"⏱ Nd parado" no Kanban.

### Proposta/Orçamento é apagada

0 leads, então a FK `deals.stage_id` (NO ACTION) não bloqueia. As 8 linhas de
histórico perdem a referência — são 8 movimentações de uma etapa que a operação
nunca usou. Há uma trava: se alguém mover um lead para lá entre a leitura e a
execução, a migration para com mensagem clara em vez de estourar a FK.

### "Sem Contato" entra na fila

Combinada com a migration 0011 (`dias_parado` só zera com contato efetivo), ela
vira a lista de rediscagem: o SDR joga ali quem tentou e não conseguiu falar, o
lead continua visível e o contador de dias continua correndo.

### O que NÃO mudou

"Fechado Ganho" ficou como está — não foi pedido. Fica assimétrico ao lado de
"Perdidos"; se incomodar, é um `update` de uma linha:

```sql
update public.pipeline_stages set name = 'Ganhos' where name = 'Fechado Ganho';
```

---

## Frontend

`etapaProspeccao()` comparava com a string `'Prospecção'` — que deixa de
existir. Passa a procurar `'Leads Novos'`, com o nome antigo no fallback e
`stages[0]` como última defesa. Sem isso, o botão "→ Gerar lead" das telas de
Empresas e Pessoas jogaria o lead na primeira etapa por acidente.

Quatro rótulos que diziam "Prospecção" (dois botões e dois toasts em Empresas /
Pessoas) passam a dizer "Gerar lead" e "Lead criado para X" — apontavam para uma
etapa que deixa de existir.

Nenhum outro ponto do código compara nome de etapa.

---

## Ordem de deploy

1. **Anote o horário** — o rollback desta migration depende de backup
2. Migration no dashboard do Supabase
3. Conferência: 7 etapas, Leads Novos com 12.890, nenhum lead órfão
4. Push do `index.html`

**Rollback é parcial.** Os renomes voltam com um `update`. A fusão e a exclusão
não voltam sozinhas — depois de aplicada, os 823 leads não sabem mais de qual
etapa vieram. Restauração completa só por Database > Backups do Supabase, num
ponto no tempo anterior à execução.

---

## Checklist

- [x] **Segurança** — nenhuma policy nova; nenhum segredo; sem UUID hardcoded
- [x] **Arquitetura** — single-file preservado; nenhuma RPC alterada
- [x] **Backend** — tudo numa transação; trava contra lead em etapa a apagar
- [x] **Frontend** — comparação de nome corrigida com dupla defesa; rótulos coerentes
- [x] **Dados** — histórico repontado em vez de anulado; `stage_changed_at` intacto
- [x] **DevOps** — migration antes do frontend; rollback documentado como parcial
- [x] **QA** — `node --check` nos 4 blocos; SQL validado pelo parser do Postgres;
      CRLF preservado; sem `console.log`
- [ ] **Teste manual** — conferir as 7 colunas no Kanban, mover um lead para
      "Sem Contato" e ver se ele aparece no Follow-up, conferir que a fila não
      saltou para 12 mil
