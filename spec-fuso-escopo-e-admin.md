# Especificação — Fuso de São Paulo, escopo da série e admin excluído

Projeto: CRM Funil de Vendas (Escard)
Migration: `supabase/migrations/20260828_0013_fuso_escopo_e_admin.sql`
**Status:** escrita e validada. **Falta aplicar no dashboard do Supabase.**

Origem: auditoria de 27/08/2026 (`claude/auditoria-crm-2026-08-27.md`), achados
críticos 1, 2 e 3. Somente banco — o `index.html` não muda.

---

## 1. O dia do relatório era o dia UTC

As RPCs de follow-up (0010/0011) convertem explicitamente com
`at time zone 'America/Sao_Paulo'`. As de relatório e metas não convertiam nada —
resolviam `date → timestamptz` pelo `TimeZone` da sessão, que no PostgREST do
Supabase é UTC.

A janela "de hoje" ia de **ontem 21:00 até hoje 21:00 BRT**. O SDR que ligava às
22h via a meta diária em zero, e a ligação aparecia no dia seguinte.

Corrigido em `rel_metricas` (`v_ini`/`v_fim` e o `current_date` do
`followup_em_dia_pct`), em `metas_progresso` (a CTE `janela` passa a usar
`v_hoje`) e em `serie_atividades` (o bucket do dia).

**A conversão é idempotente.** Se a sessão já estiver em `America/Sao_Paulo`, o
resultado é exatamente o de antes — por isso a migration pode ser aplicada sem
confirmar `show timezone;` antes.

---

## 2. A série diária apagava o dia em vez de mostrar zero

Em `serie_atividades`, o filtro de vendedor estava no `WHERE` de um `LEFT JOIN`.
Acertava "nenhuma atividade no dia" (aí `a.id is null` salvava a linha) e errava
"atividade só de outro vendedor": as linhas entravam no join, falhavam no `WHERE`,
o `group by` não gerava grupo e o dia **sumia** do retorno.

O filtro saiu do `WHERE` e virou um CTE aplicado antes do `generate_series`.

### A prova

Cenário montado num Postgres 16 local, sessão em UTC: 10/08 só a vendedora B
trabalhou (30 atividades); 11/08 só a A (2); 12/08 a A ligou às **22h30 BRT**.
Consulta filtrando pela vendedora A, de 10/08 a 13/08:

| Dia | Antiga (produção) | Corrigida | Correto |
|---|---|---|---|
| 10/08 | **linha ausente** | 0 | 0 |
| 11/08 | 2 | 2 | 2 |
| 12/08 | 0 | **1** | 1 |
| 13/08 | 1 | 0 | 0 |
| Total de linhas | **3** | **4** | 4 |

Os dois defeitos aparecem juntos: o dia 10 desaparece do gráfico, e a ligação das
22h30 do dia 12 é contada no dia 13.

---

## 3. Admin excluído continuava admin

`audit_usuario_e_admin()` checa `role` e `active`, mas não `deleted_at` — e o
único fluxo de exclusão do produto grava só `deleted_at`. Admin "excluído" mantinha
escrita total e leitura da trilha de auditoria inteira.

`is_admin()` tem o mesmo defeito, **mas não está versionada neste repositório** —
existe só no banco (achado 21 da auditoria). Por isso o passo 4 da migration é
manual: conferir o corpo real com `pg_get_functiondef` antes de substituir.

Falta ainda, no `index.html`: o fluxo de exclusão deve gravar
`active = false, role = 'vendedor'` junto com o `deleted_at`. Soft-delete que não
revoga privilégio não é revogação.

---

## 4. Ordem de deploy

1. Migration no SQL Editor do Supabase
   `https://supabase.com/dashboard/project/heevguvboffziehftucp/sql/new`
2. Passo 4 (o bloco de `audit_usuario_e_admin`), depois de conferir `is_admin()`
3. Nada a fazer no frontend

Nenhuma assinatura de função muda — são `create or replace` puros, sem `drop`.
Rollback: reexecutar os blocos originais das migrations 0003, 0009, 0011 e 0001.

---

## 5. Checklist

- [x] **Segurança** — o passo 3 fecha uma escalação de privilégio; nenhuma policy nova
- [x] **Arquitetura** — nenhuma assinatura alterada; frontend intocado
- [x] **Backend** — corpos copiados literalmente das migrations de origem, com trocas cirúrgicas verificadas uma a uma
- [x] **Frontend** — não se aplica
- [x] **Dados** — comportamento provado em Postgres 16 com sessão em UTC, incluindo a borda das 22h30
- [x] **DevOps** — migration idempotente; aplicável sem janela de manutenção
- [x] **QA** — arquivo inteiro executado com `check_function_bodies = on`; 10 statements externos validados pelo parser; teste de borda de fuso e de dia vazio
- [ ] **Teste manual** — abrir Relatórios após as 21h e conferir que a meta diária conta a ligação do próprio dia
