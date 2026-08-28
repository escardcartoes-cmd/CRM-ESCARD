# Especificação — Régua de cadência (5 toques em 15 dias)

Projeto: CRM Funil de Vendas (Escard)
Migration: `supabase/migrations/20260828_0014_cadencia.sql`
Frontend: `index.html`
Data: 27/08/2026

---

## O problema

O CRM tinha meta de ligação, mas não tinha fila. O SDR sabia **quanto** ligar e
continuava decidindo **para quem** ligar agora — dezenas de vezes por dia. Escolher
é a tarefa mais cara do dia, e é ela que segura o volume em 8,6 discagens/dia
quando o padrão de outbound B2B é 40–60.

O campo "Próximo passo" existia e era opcional. Contato registrado sem próximo
passo não voltava para a esteira do Follow-up: o lead simplesmente sumia.

---

## Decisões tomadas

| Questão | Decisão |
|---|---|
| Quem decide o próximo toque | **O sistema**, automaticamente, ao registrar o desfecho |
| Escolha manual do SDR | **Sempre vence** a régua |
| Intervalos | 1, 3, 7 e 15 dias — os mesmos chips que já existiam |
| Nº de toques | 5 (o registrado + 4 agendados) |
| Fim da régua | Sai da esteira, marcado para revisão — não vira "perdido" |
| Contato inválido | Esgota na hora: insistir num número errado não resolve |
| Onde vive | Follow-up, que já existe. **Sem tela nova** |

A tela "Modo Discagem" foi adiada por decisão do Roberto (sem telefone conectado
ainda). A régua funciona sem ela: em vez de a fila empurrar o próximo lead, o
Follow-up enche sozinho e o SDR trabalha a lista.

---

## 1. A régua

| Tentativa sem contato | Próximo toque |
|---|---|
| 1ª | D+1 |
| 2ª | D+3 |
| 3ª | D+7 |
| 4ª | D+15 |
| 5ª | **sai da esteira** |

Os intervalos são exatamente os valores de `PROXIMO_OPCOES`, de propósito: o chip
correspondente fica marcado, o SDR reconhece o que foi agendado e troca num
clique. Uma régua com D+6 e D+12 exigiria o campo de data aberto a cada registro —
mais fricção, que é justamente o que se quer eliminar.

### O que conta como tentativa

- **Zera a régua:** `atendeu`, `respondeu`, `realizada`. Quem atendeu uma vez
  recomeça do zero — a contagem é de tentativas **consecutivas** desde o último
  contato efetivo.
- **Esgota na hora:** `numero_errado`, `numero_invalido`. Cinco tentativas num
  número errado é desperdício puro; o lead vai direto para revisão.
- **Avança a régua:** todo o resto, incluindo `visualizou` (viu e não respondeu) e
  `bounce`/"Enviado". São trabalho feito sem resposta.
- **Não conta:** nota. Não tem desfecho.

### Onde a conta acontece

Na hora de salvar, contra o **banco** — a atividade recém-inserida já está lá, e a
timeline em memória pode não estar carregada quando o registro é aberto pelo
Follow-up. Uma consulta de 30 linhas por registro.

A prévia mostrada no modal usa a timeline em memória, para dar retorno imediato.
Quando ela não existe, a prévia assume a 1ª tentativa e o cálculo do salvar
corrige — o toast final diz o que foi de fato agendado.

### Quando a régua NÃO age

- O SDR tocou no "Próximo passo" (a escolha manual desliga a régua)
- Edição de atividade já registrada
- Canal `nota` ou `presencial` (reunião tem fluxo próprio)
- Falha na consulta ao banco — o contato fica registrado do mesmo jeito; a régua
  é a parte dispensável da operação, o registro não é

---

## 2. Fim da régua

O lead sai da esteira (`next_followup_date = null`) e ganha
`deals.cadencia_esgotada_em`. **Não vira "perdido"** — perder um lead porque o
telefone da lista comprada está errado seria queimar base por defeito de dado, e
43,9% da carteira já é o que sobrou da triagem.

O marcador existe porque, sem ele, o lead esgotado fica indistinguível do lead que
nunca teve follow-up agendado: some da fila e ninguém nunca mais o encontra.

Volta a `null` sozinho no primeiro contato efetivo ou quando o lead retorna à
régua.

### Onde eles aparecem

Relatórios → Visão geral → **Precisa de atenção**, linha "Esgotados na régua". É
situação de hoje, não do período — por isso a consulta não filtra data. A RLS de
`deals` limita o vendedor à própria carteira; o filtro de vendedor do relatório
cobre a visão de equipe.

**Ainda não aparece como selo no card do Kanban.** O card vem da RPC
`kanban_cards`, e acrescentar a coluna ao `returns table` muda a assinatura de
retorno — exige `drop` + `create`. Fica para quando houver outra razão para mexer
nessa função.

---

## 3. Ordem de deploy

1. Migration 0014 no SQL Editor do Supabase — **antes** do frontend. Sem a coluna,
   o `update` que marca o lead esgotado falha com "column does not exist" e o
   registro de contato quebra.
2. Push do `index.html`.

A migration é aditiva e idempotente (`add column if not exists`,
`create index if not exists`), verificada rodando duas vezes.

---

## 4. Checklist

- [x] **Segurança** — nenhuma policy nova; a coluna herda a RLS de `deals`; nenhum dado do usuário entra em HTML sem escape
- [x] **Arquitetura** — nenhuma RPC alterada, nenhuma assinatura mexida, single-file preservado
- [x] **Backend** — coluna nullable, índice parcial, rollback de duas linhas
- [x] **Frontend** — light mode, CSS por token e sem inline, `aria-live` no aviso, escolha manual sempre prevalece
- [x] **Dados** — a contagem que vale vem do banco, não da memória
- [x] **DevOps** — migration antes do frontend; ordem inversa quebra o registro de contato
- [x] **QA** — `node --check` nos 4 blocos; 23 testes unitários da régua (zerar no efetivo, nota que não conta, teto, contato inválido, datas); migration aplicada 2x no Postgres 16
- [ ] **Teste manual** — registrar "Não atendeu" três vezes no mesmo lead e conferir a sequência D+1, D+3, D+7; registrar "Número errado" e conferir que o lead sai da esteira na hora
