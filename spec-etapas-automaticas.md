# Especificação — Movimentação automática de etapa

Projeto: CRM Funil de Vendas (Escard)
Migration: `supabase/migrations/20260828_0016_etapas_automaticas.sql`
Frontend: `index.html` (selo de 4 dias no Follow-up)
Data: 28/08/2026

---

## O problema

`Leads Novos` tem `in_followup = false`, e a fila do Follow-up só lista etapas com
`in_followup = true`.

A régua de cadência agendava o próximo toque para um lead de "Leads Novos" e **esse
lead nunca aparecia na fila**. A data ficava gravada e ninguém via.

São **12.890 leads** nessa situação contra 774 em "Contato Feito": a cadência
estava alcançando **6%** da base.

---

## As três regras

| Gatilho | Destino |
|---|---|
| 1ª atividade num lead de "Leads Novos", sem contato efetivo | **Sem Contato** (entra na esteira) |
| 1º contato efetivo, vindo de "Leads Novos" ou "Sem Contato" | **Contato Feito** |
| Qualquer coisa a partir de "Contato Feito" | **nada** — quem manda é o operador |

Sempre para frente. Um lead nunca é rebaixado: mover para trás inflaria a contagem
de movimentações e quebraria o "% avançam" do relatório de funil.

**Contato efetivo** é `atendeu`, `respondeu`, `realizada` ou reunião com
`meeting_status` em `agendada`/`realizada` — ninguém marca reunião sem ter falado
com a empresa.

**Nota não move nada.** Anotar não é tentativa de contato.

**Lead ganho ou perdido não volta sozinho** para o funil. Reabrir é decisão de gente.

---

## Os "4 dias" não viraram movimentação

Depois da regra 1 o lead já está em "Sem Contato" — não há para onde movê-lo sem
andar para trás.

E o número já existe: `followups_list.dias_parado` conta sobre o **último contato
efetivo** desde a 0011. É calculado na leitura: sem `pg_cron`, sem job noturno, sem
estado que envelhece. Um lead que atender hoje sai do alerta sozinho.

O tratamento é visual: o selo `Nd sem contato` na fila do Follow-up fica **âmbar a
partir de 4 dias** (e vermelho acima de 30, como já era).

---

## A trava que impede crédito indevido

`fn_stage_history_mudanca` gravava `origem = 'app'` sempre que existisse
`auth.uid()`. Movimentação automática gravada como `'app'` entraria em
`movimentacoes` e em `trabalhados`: **o vendedor ganharia crédito de trabalho por
algo que o sistema fez.**

A função passa a checar `app.mov_automatica` — a mesma trava de sessão que a purga
de auditoria já usava — e grava `'sistema'`. Verificado no teste: as 5 movimentações
automáticas e as 4 do backfill saíram todas como `sistema`.

`stage_changed_at` é atualizado junto com o `stage_id`. Sem isso, o "dias parado" do
card continuaria contando desde a entrada na etapa antiga.

---

## Backfill

O trigger só age em atividade **nova**. Os leads já trabalhados antes da migration
continuariam fora da esteira para sempre.

Contagem em produção antes de aplicar: **422 leads** em "Leads Novos" com atividade
registrada. Cada um vai para o destino que a regra daria: quem já teve contato
efetivo para "Contato Feito", o resto para "Sem Contato".

**Efeito colateral esperado:** a fila do Follow-up cresce. É o objetivo — mas a
Heloísa precisa saber antes de abrir e ver a fila maior.

---

## Identificação por nome

As etapas são resolvidas por nome, como fez a 0012. Renomear "Sem Contato" ou
"Contato Feito" pelo painel faz a automação **parar de mover** — sem erro, sem
estrago, só deixa de agir. É a degradação preferível a gravar UUID nesta migration
e ela apontar para uma etapa apagada.

O backfill, ao contrário, **aborta com exceção** se não achar as três etapas: mover
422 leads para o lugar errado é pior que não mover.

---

## Ordem de deploy

1. Migration 0016 no SQL Editor do Supabase
2. Conferir a distribuição das etapas (queries no fim do arquivo)
3. Push do `index.html` (só o selo de 4 dias — o front não depende do banco aqui)

Rollback: `drop trigger` + `drop function` + reexecutar `fn_stage_history_mudanca`
da 0002. Os leads movidos **não voltam sozinhos** — `deal_stage_history` com
`origem = 'sistema'` e o `changed_at` da janela permite reconstruir.

---

## Checklist

- [x] **Segurança** — `security definer` com `search_path` fixo; nenhuma policy nova; a trava de sessão é local à transação (`set_config(..., true)`)
- [x] **Arquitetura** — trigger no banco, não no frontend: o front move etapa em três telas, e regra de negócio espalhada em três telas diverge na primeira pressa
- [x] **Backend** — `create or replace` sem `drop` nas funções; trigger recriado; backfill em bloco `do` com contagem em `raise notice`
- [x] **Frontend** — só o limiar do selo; ES5 no bloco onde entra; cor por token
- [x] **Dados** — o backfill não credita movimentação a ninguém (`origem = 'sistema'` verificado)
- [x] **DevOps** — migration independente do frontend; rollback documentado
- [x] **QA** — 10 testes de comportamento em Postgres 16 (tentativa, segunda tentativa, contato efetivo, não-rebaixamento, resposta direta, nota, reunião agendada, lead perdido, origem no histórico, `stage_changed_at`) + teste do backfill com 6 leads cobrindo os 4 destinos possíveis
- [ ] **Teste manual** — registrar "Não atendeu" num lead de "Leads Novos" e conferir que ele aparece no Follow-up logo depois
