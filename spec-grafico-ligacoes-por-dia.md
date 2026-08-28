# Especificação — Gráfico de ligações por dia

Projeto: CRM Funil de Vendas (Escard)
Migration: `supabase/migrations/20260828_0015_serie_ligacoes.sql`
Frontend: `index.html`
Data: 28/08/2026

---

## O pedido

> "quero que tenha gráfico com dados de todos os dias para que eu possa fazer
> comparação em sequência de trabalho em coluna"

O painel de metas mostra **hoje**: quatro barrinhas, três em zero. Não dá para
saber se ontem foi igual, se a equipe trabalhou a semana inteira, ou se o zero de
hoje é exceção ou rotina.

---

## Decisões tomadas

| Questão | Decisão |
|---|---|
| O que a coluna mede | **Só ligações** — é a meta única. Atendidas entram como marca, não como série |
| Formato | Coluna **empilhada por dia**, uma cor por vendedora |
| Gráfico de linha antigo | **Substituído**. Dois gráficos da mesma coisa competem pela leitura |
| Dias sem ligação | Aparecem como coluna vazia — é o buraco que interessa ver |
| Fim de semana | Faixa de fundo cinza |

### Por que coluna e não linha

A linha responde "a tendência sobe?". A pergunta do gestor é outra: **"trabalhamos
todo dia, e quem trabalhou em cada dia?"**. Linha interpola entre dois pontos e
esconde o dia parado; coluna mostra o vão.

---

## 1. Backend — `serie_ligacoes(p_de, p_ate, p_owner)`

Devolve `(dia, owner_id, vendedor, ligacoes, atendidas)`, uma linha por dia com
movimento. Canal `telefone`, dia no fuso de São Paulo, escopo por
`rel_owner_efetivo` — vendedor só vê a própria carteira.

**Não devolve dia vazio.** O eixo é montado no frontend a partir do próprio
período: 30 dias × 4 vendedoras seriam 120 linhas, quase todas zeradas, para
transportar informação que o cliente já tem.

Verificado num Postgres 16 com a sessão em UTC: WhatsApp fora da conta, e a
ligação das 22h30 do dia 12 fica **no dia 12**.

---

## 2. Frontend — o desenho

**Empilhamento** por vendedora, ordenado pelo total no período. A cor segue a
pessoa, não a colocação: filtrar um vendedor não repinta os outros.

**Fim de semana** ganha faixa cinza de fundo. Sem isso, um domingo zerado parece
falha de operação.

**Atendidas** não viram um segundo empilhamento — com 4 vendedoras seriam 8
sub-segmentos por coluna, ilegível. Viram um traço horizontal na altura do total
atendido do dia, com halo branco por baixo (sem o halo, o traço escuro some dentro
do azul). Uma marca por dia: volume na altura, eficácia no traço.

**Rodapé do gráfico** diz quantos **dias úteis** ficaram sem nenhuma ligação. O
vazio precisa ser dito, não deduzido contando colunas.

**Eixo Y** com teto sempre divisível por 4, para todo rótulo sair inteiro. A regra
anterior (potência de 10) dava teto 9 para máximo 9 e grade em 2,25 / 4,5 / 6,75.

**Total escrito no topo** de cada coluna quando a largura comporta.

### A paleta

A paleta antiga do CRM (`#2a2f8f`, `#16a34a`, `#dc2626`, `#b45309`) **reprovou**
no validador:

| Check | Resultado |
|---|---|
| Faixa de luminosidade | FAIL — `#2a2f8f` fora da banda |
| Separação para daltonismo | FAIL — `#b45309` ↔ `#dc2626` ΔE **2,8** em deuteranopia |
| Piso de visão normal | FAIL — o mesmo par com ΔE 9,9, abaixo do piso de 15 |

Laranja e vermelho eram indistinguíveis para quem tem deuteranopia — e quase
indistinguíveis para todo mundo. Trocada por uma paleta que passa em todos os
checks: pior par adjacente ΔE **9,1** em protanopia e **22,9** em visão normal.

Os tons claros ficam abaixo de 3:1 contra o branco, o que obriga rótulo visível —
daí o nome de cada vendedora na legenda com o total, e o número no topo da coluna.

---

## 3. Código removido

Saíram, órfãs depois da troca: `desenharLinha`, `desenharLinhaMulti`,
`agregarSeries`, `diasUniao`, `serieNosDias`, `rotulosEixoX`, `legendaSeriePadrao`,
`legendaSerieVendedores` — 6,5 KB. A RPC `serie_atividades` continua no banco, sem
chamador no frontend.

---

## 4. Ordem de deploy

1. Migration 0015 no SQL Editor do Supabase — **antes** do frontend. Sem a RPC, o
   painel mostra o estado de erro com botão "Tentar novamente".
2. Push do `index.html`.

Nenhuma função existente foi alterada. Rollback do backend é `drop function`.

---

## 5. Checklist

- [x] **Segurança** — `security definer` com `search_path` fixo, `revoke` de anon, escopo por `rel_owner_efetivo`; nome de vendedor passa por `escapar()` antes do SVG
- [x] **Arquitetura** — nenhuma RPC existente tocada; single-file preservado; código morto removido
- [x] **Backend** — fuso de São Paulo como a 0013; comportamento provado em Postgres 16 com sessão UTC
- [x] **Frontend** — ES5, light mode, `role="img"` + `aria-label`, `<title>` em cada segmento, legenda com nome e total
- [x] **Dados** — o total do gráfico bate com a chave `ligacoes` do relatório no mesmo período (query de conferência na migration)
- [x] **DevOps** — migration antes do frontend
- [x] **QA** — `node --check` nos 4 blocos; 30 testes unitários (eixo, teto, fim de semana, path, SVG sem NaN, período vazio); paleta validada por script; render conferido em captura de tela
- [ ] **Teste manual** — abrir Relatórios com "Toda a equipe" e 30 dias; conferir se o total da legenda bate com o KPI "Ligações"
