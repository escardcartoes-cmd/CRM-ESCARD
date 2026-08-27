# Especificação — Meta única (Ligações) e revisão dos dados dos gráficos

Projeto: CRM Funil de Vendas (Escard)
Frontend: `index.html` (somente frontend — nenhuma migration, nenhuma RPC alterada)
Data: 27/08/2026

---

## Decisões tomadas

| Questão | Decisão |
|---|---|
| Indicadores de meta | **Somente `ligacoes`.** Todos os outros saem do painel e da edição |
| Metas já gravadas dos indicadores removidos | Ficam no banco, deixam de ser exibidas (filtro no frontend) |
| Movimentação de etapa | Sai do gráfico "Composição do trabalho" e da lista de metas |
| `trabalhados` / `movimentados` no backend | **Não mudam.** Continuam sendo calculados e retornados |

---

## 1. Metas — só Ligações

`METAS_IND` passa a ter uma única entrada. Como toda a UI de metas deriva dessa
lista (grade de Administração, editor inline do Relatório, rótulos do gráfico de
colunas, ordem das barras), a redução se propaga sozinha — nenhum outro ponto
precisou ser tocado.

O que **não** se propaga sozinho é o retorno da RPC: `metas_progresso()` devolve
toda linha com `valor > 0`, inclusive de indicadores que saíram. Sem filtro, o
painel continuaria mostrando "Contatos registrados", "Leads trabalhados" etc.
com rótulo cru. Daí `metasFiltradas()`, aplicada na entrada de
`renderMetasProgresso`.

`metaRotuloCurto()` era um segundo mapa de rótulos, paralelo a `METAS_IND` e
livre para divergir dele. Virou um alias de `rotuloIndicador()` — fonte única.

### Limpeza opcional no banco

As metas antigas continuam gravadas. Elas são inertes (nada as lê mais), mas se
quiser zerar de fato:

```sql
update public.metas
   set valor = 0
 where indicador <> 'ligacoes';
```

Reativar um indicador é devolvê-lo a `METAS_IND` — o valor gravado volta a
aparecer.

---

## 2. Movimentação fora dos gráficos

- "Composição do trabalho" passa a mostrar **Contatados** e **Enriquecidos**.
- A legenda do painel dizia que "Leads trabalhados" era a união das três barras.
  Com duas barras isso ficaria falso, então o texto passa a dizer que o KPI é
  mais amplo e soma também quem só mudou de etapa.
- `movimentacoes` sai de `METAS_IND` junto com os demais.

O backend não muda: `movimentados` continua vindo em `relatorio_produtividade` e
`trabalhados` continua contando movimentação. É decisão de exibição, não de conta.

---

## 3. Revisão dos dados dos gráficos

Cinco correções, todas de leitura errada do próprio dado:

| Onde | O que estava errado | Correção |
|---|---|---|
| Série diária — eixo X | Rótulo `D-N` errava por um (o primeiro ponto é D-(n-1), não D-n), nunca marcava o último dia e não significa nada num período personalizado terminado no passado | Rótulo passa a ser a **data real** do ponto (dd/mm), com o último dia sempre marcado |
| Série multi-vendedor | As linhas eram casadas por **posição** no array. Séries de tamanhos diferentes deslocariam a linha inteira | Casamento por **data** (`diasUniao` + `serieNosDias`); dia sem registro vale 0 |
| Export XLSX da série | `agregarSeries` somava por posição e herdava as datas do primeiro vendedor | Soma por data, sobre a união dos dias |
| Barras (canal, desfecho, perda, municípios, composição, aging) | Piso de 3% pintava barra visível para valor **0** | Valor 0 desenha barra 0 |
| Funil — conversão entre etapas | `entradas(n+1) ÷ entradas(n)` sem teto exibia "180% avançam" quando a etapa seguinte recebe lead que não veio da anterior (importação, salto de etapa). Etapa sem entradas exibia "0% avançam", que soa como fracasso | Teto de 100%; sem entradas exibe "sem entradas nesta etapa no período" |

Correção adjacente: o mapa de rótulos de "Atividades por canal" não tinha
`presencial`. Desde a agenda de reuniões (migration 0008) reunião grava
`channel='presencial'` — a barra aparecia com a chave crua.

---

## 4. Deploy

Só `index.html` → Cloudflare Pages. Nenhuma migration, nenhuma assinatura de RPC
alterada, nada a aplicar no banco antes ou depois. Rollback é o commit anterior.

---

## 5. Checklist

- [x] **Segurança** — nenhuma policy, nenhum segredo, nenhuma RPC nova; filtro de metas é de exibição, a RLS de `metas_progresso` não muda
- [x] **Arquitetura** — single-file preservado; `METAS_IND` volta a ser fonte única de rótulos
- [x] **Backend** — nada alterado
- [x] **Frontend** — ES5 mantido; light mode; legendas revistas para não mentir
- [x] **Dados** — séries casadas por data; conversão do funil com teto
- [x] **DevOps** — deploy de um arquivo, sem ordem de dependência
- [x] **QA** — `node --check` nos 4 blocos `<script>`; testes unitários nas funções novas (rótulo de data, união de dias, agregação, barra zero, filtro de metas); CRLF preservado; nenhum `console.log` novo
- [ ] **Teste manual** — abrir Relatórios → Visão geral e conferir: painel de metas só com "Ligações", "Composição do trabalho" com duas barras, eixo da série com datas, e Funil sem percentual acima de 100%

### Fora do escopo, anotado

`index.html` tem 3 `console.log` de diagnóstico do boot (linhas ~1519, ~1530,
~1639), anteriores a esta mudança. Não foram tocados.
