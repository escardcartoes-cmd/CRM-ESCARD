# Especificação — Timeout do relatório e o `.catch` que não existia

Projeto: CRM Funil de Vendas (Escard)
Migration: `supabase/migrations/20260828_0019_desempenho_relatorio.sql`
Frontend: `index.html`
Data: 28/08/2026

**Status:** migration `0019` aplicada em produção em 30/08/2026. A correção do
`.catch` foi publicada no commit `2d78cef`. Relatório restabelecido.

---

## Os dois erros apareceram porque a mensagem passou a ser exibida

Poucos minutos depois de o bloco de erro começar a mostrar a mensagem real, dois
defeitos distintos se identificaram sozinhos na tela:

```
canceling statement due to statement timeout      ← relatorio_produtividade
db.rpc(...).catch is not a function               ← Ligações por dia
```

Antes disso, os dois apareceriam como o mesmo vermelho mudo.

---

## 1. `db.rpc(...).catch is not a function`

`db.rpc()` do supabase-js devolve um **PostgrestFilterBuilder**: é *thenable*
(tem `.then`), então `await` funciona — mas **não é uma Promise** e não tem
`.catch`.

Eu escrevi, ao buscar a meta para a linha do gráfico:

```js
db.rpc("metas_progresso", { p_owner: owner }).catch(function(){ return { error: true }; })
```

A intenção era boa — falha ao buscar a meta não deve derrubar o gráfico. O efeito
foi o oposto: a chamada estourava antes de sair, e derrubava o bloco inteiro.

Correção: `Promise.resolve(...)` envolve o thenable numa Promise de verdade.

```js
Promise.resolve(db.rpc("metas_progresso", { p_owner: owner }))
       .catch(function(){ return { error: true }; })
```

---

## 2. `canceling statement due to statement timeout`

**A causa foi minha, na 0018.** Ao separar esforço de carteira, criei dois CTEs
independentes — `ativ` (por autor) e `ativ_dono` (por dono) — e **cada um varria
`deal_activities` join `deals` de novo**, na mesma janela. Custo dobrado na
função mais pesada do sistema, e ela passou do `statement_timeout`.

### A correção tem duas partes

**Uma varredura, dois recortes.** `ativ_janela` traz autor e dono na mesma
passada; `ativ` e `ativ_dono` filtram em cima dela.

`as materialized` é **obrigatório**. Desde o Postgres 12 o CTE é inlined por
padrão em cada uso — sem a palavra, o planejador desfaz a otimização e volta a
varrer duas vezes. Verificado no plano:

```
 CTE base
   ->  Seq Scan on deal_activities      ← uma vez só
 InitPlan 2 ... ->  CTE Scan on base
 InitPlan 3 ... ->  CTE Scan on base
```

**Os índices que nunca existiram.** `coalesce(occurred_at, created_at)` é
expressão: sem índice sobre a expressão, toda janela de período é sequential scan
na tabela inteira. Isso já era assim **antes** da 0018 — ela só tornou visível ao
dobrar o trabalho.

| Índice | Para quê |
|---|---|
| `deal_activities_quando_idx` | a janela de período, condição de toda consulta de atividade |
| `deal_activities_author_quando_idx` | esforço por vendedor, desde a 0018 |
| `deal_activities_presencial_idx` | reuniões — parcial, fica pequeno |
| `deal_activities_telefone_idx` | `serie_ligacoes` e os KPIs de ligação — parcial |

Índice não muda resultado, só tempo. A função devolve exatamente as mesmas
chaves — conferido com o cenário Priscila/Micheli antes e depois.

---

## A lição que fica registrada

A separação esforço/carteira estava certa; a implementação duplicou trabalho sem
que ninguém percebesse porque **não há medição de tempo no caminho**. Um
`explain analyze` na 0018 teria mostrado o dobro de varredura antes de ir para
produção.

Para as próximas mudanças em `rel_metricas`, a conferência mínima é:

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"<uuid de um admin>"}';
  explain analyze select public.relatorio_produtividade(current_date - 30, current_date, null);
rollback;
```

---

## Ordem de deploy

As duas correções são independentes. A do `.catch` é frontend puro; a do timeout
é banco. Qualquer ordem serve.

## Checklist

- [x] **Segurança** — nenhuma policy, nenhum grant, nenhuma assinatura alterada
- [x] **Arquitetura** — o CTE materializado deixa explícito que é uma varredura só; comentário no código explica por que a palavra não pode sair
- [x] **Backend** — `create index if not exists`, idempotente; resultado idêntico conferido
- [x] **Frontend** — `Promise.resolve` no thenable; comentário registra a armadilha
- [x] **Dados** — mesmas chaves, mesmos valores, antes e depois
- [x] **DevOps** — índices podem ficar no rollback; só a função volta
- [x] **QA** — plano de execução conferido (`Seq Scan` uma vez, dois `CTE Scan`); cenário Priscila/Micheli reexecutado; `node --check` nos 4 blocos
- [ ] **Teste manual** — abrir Relatórios em 90 dias e conferir que carrega sem timeout
