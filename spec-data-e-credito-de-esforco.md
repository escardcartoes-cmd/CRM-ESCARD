# Especificação — Data do contato automática e esforço por quem executou

Projeto: CRM Funil de Vendas (Escard)
Migrations: `20260828_0017_data_contato_futura.sql` · `20260828_0017b_corrigir_datas_futuras.sql` · `20260828_0018_esforco_por_autor.sql`
Frontend: `index.html`
Data: 28/08/2026

---

## Os dois defeitos

Uma pergunta simples — *"como o CRM conta as ligações?"* — abriu duas falhas que,
juntas, faziam a meta diária mostrar **zero para vendedora que trabalhou o dia todo**.

### 1. A data era digitada, e vinha errada

41 atividades estavam gravadas com `occurred_at` no futuro, 28 delas ligações. A
mesma pessoa repetiu em 26, 27 e 28/08, sempre apontando para 31/08, e uma segunda
pessoa fez o mesmo.

O deslocamento não é constante (26→31 são 5 dias, 27→31 são 4, 28→31 são 3): não é
fuso nem offset fixo. É o campo "Quando" recebendo a data do **próximo contato**. O
formulário tinha dois campos de data e o operador preenchia o errado.

Ligação com data futura não entra na meta do dia em que foi feita. No total do mês
contava (31/08 ainda é agosto), então o número mensal estava certo e o diário,
errado — justamente o que a gestão cobra todo dia.

### 2. O esforço era creditado ao dono do lead, não a quem ligou

`rel_metricas`, `metas_progresso` e `serie_ligacoes` contavam ligação, e-mail,
WhatsApp e atividade filtrando por `deals.owner_id`, não por
`deal_activities.author_id`.

A vendedora liga para um lead que pertence a outra pessoa — o que acontece o tempo
todo quando ela retoma lead já contatado — e a ligação vai para a **dona do lead**.
Quem discou não recebe nada.

**A inconsistência já estava dentro da mesma função.** Em `metas_progresso`, os
ramos escritos depois (`conversas_efetivas`, `reunioes`, `reunioes_nao_realizadas`)
já usavam `author_id`; os mais antigos (`atividades`, `ligacoes`, `whatsapp`,
`emails`) usavam `owner_id`. Dois critérios convivendo no mesmo `case`.

---

## A regra, daqui em diante

| Tipo | Conta para | Indicadores |
|---|---|---|
| **Esforço** | quem **executou** (`author_id`) | ligações, atendidas, taxa de atendimento, atividades, atividades efetivas, por canal, por desfecho, reuniões, conversas efetivas, whatsapp, e-mails |
| **Carteira** | **dono do lead** (`owner_id`) | leads trabalhados, contatados, enriquecidos, movimentados, cobertura, alcançados, alcance, dormentes, contatos inválidos, ganhos, valor ganho |

É a separação que a operação já pratica: a meta é de discagem, a cobertura é da
carteira. Misturar as duas foi o que produziu vendedora com meta zerada em dia
trabalhado.

Em `rel_metricas` isso virou dois CTEs: `ativ` (por autor) e `ativ_dono` (por dono).

### A prova

Cenário: Priscila faz 10 ligações (2 atendidas) num lead que pertence à Micheli.

| | ligações | atendidas | leads trabalhados |
|---|---|---|---|
| **Priscila** (discou) | **10** | 2 | 0 |
| **Micheli** (dona) | 0 | 0 | **1** |
| Equipe | 10 | 2 | 1 |

Antes, a Priscila teria 0 e a Micheli 10. O total da equipe não muda — só a
distribuição, que é o ponto.

---

## A data agora é automática

Para **contato**, o campo passa a se chamar **"Registrado em"**, fica travado
(`readonly`) e o valor gravado é o **momento do salvamento** — não o horário em
que o modal foi aberto, que pode ter ficado parado.

Para **reunião**, nada muda: a data é a da agenda e continua editável.

Editar um contato já registrado **preserva** a data original. Reescrevê-la moveria
a atividade de dia no relatório sem que nada tivesse acontecido.

Três camadas, porque uma só não basta:

1. campo travado no formulário — remove a chance do erro
2. validação no `salvar` — o `readonly` não impede submissão por JS
3. trigger `trg_atividade_data_valida` no banco — vale para qualquer via de entrada

Reunião (`channel = 'presencial'`) é exceção nas três. Tolerância de 5 minutos para
relógio de navegador adiantado.

---

## Correção dos 41 registros — condicional

`0017b` move `occurred_at = created_at`, com backup em
`bkp_occurred_futuro_20260828` antes. **Só rodar depois de confirmar com a
Priscila e a Heloísa que os registros correspondem a contatos já feitos.**

Se alguma delas usava o registro para *agendar* ligações futuras, esses registros
não são contatos: devem ser apagados e o retorno reagendado no campo próprio. E aí
o problema é maior — a taxa de atendimento e todo o baseline de discagens estariam
contaminados.

---

## O que ainda pode fazer uma ligação sumir

| Caminho | Situação |
|---|---|
| Data futura | **fechado** — 0017 |
| Crédito ao dono do lead | **fechado** — 0018 |
| Fuso horário (dia UTC) | **fechado** — 0013 |
| Etapa do lead | nunca filtrou — ligação em lead ganho ou perdido sempre contou |
| Desfecho | nunca filtrou — "não atendeu" sempre contou |
| **Registrada como "Nota"** | **aberto** — canal `nota` não é ligação. Se o operador escolhe Nota e escreve "liguei, caiu na caixa postal", não conta em lugar nenhum. É treinamento, não código |
| Lead excluído | a atividade sai da contagem junto com o lead. Raro e correto |

Auditoria do caso ainda aberto:

```sql
select count(*) from public.deal_activities
 where channel = 'nota'
   and (note ilike '%lig%' or note ilike '%telefon%' or note ilike '%caixa postal%'
        or note ilike '%não atend%' or note ilike '%nao atend%')
   and occurred_at >= date_trunc('month', now());
```

---

## Ordem de deploy

1. `0017` — a trava. Independente, pode ir primeiro.
2. `0018` — o crédito por autor.
3. Push do `index.html`.
4. `0017b` — só depois de falar com a equipe.

Nenhuma assinatura de função muda. Rollback documentado em cada arquivo.

---

## Checklist

- [x] **Segurança** — `security definer` com `search_path` fixo; `revoke` de anon mantido; nenhuma policy nova
- [x] **Arquitetura** — três camadas para a data (formulário, aplicação, banco); a regra esforço/carteira fica escrita em um lugar só, no comentário da 0018
- [x] **Backend** — `create or replace` puro; corpos derivados dos originais com trocas verificadas uma a uma
- [x] **Frontend** — campo travado com CSS por token; rótulo mudou para "Registrado em" para comunicar que é automático
- [x] **Dados** — cenário Priscila/Micheli provado em Postgres 16; total da equipe inalterado, só a distribuição muda
- [x] **DevOps** — 0017 e 0018 independentes; 0017b condicional, com backup e rollback
- [x] **QA** — 6 testes da trava de data (futuro barrado, agora passa, 4 min passa, reunião passa, UPDATE barrado, passado passa) + teste da correção com 29 registros + cenário de crédito cruzado; `node --check` nos 4 blocos
- [ ] **Teste manual** — abrir "Registrar contato" e conferir que o campo está travado; ligar num lead de outra vendedora e conferir que a ligação aparece na SUA meta
