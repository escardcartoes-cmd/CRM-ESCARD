# Especificação — Agenda de reuniões

Projeto: CRM Funil de Vendas (Escard)
Objetivo: registrar reunião **marcada** (presencial ou online) a partir do lead,
acompanhar o desfecho e mostrar a agenda no Dashboard com data, hora, empresa,
CNPJ, contato e telefone.

---

## Decisões tomadas

| Questão | Decisão |
|---|---|
| Momento do registro | **Marcada** (data futura), com status até o desfecho |
| Ciclo de status | Agendada → Realizada / Não compareceu / Cancelada |
| Modalidade | Presencial **ou online**, com link da sala quando online |
| Origem | **Sempre a partir de um lead** do funil (sem reunião avulsa) |
| Modelagem | **Estende `deal_activities`**, não cria tabela nova |
| Dashboard | Card de métrica + painel "Próximas reuniões" |

### Por que estender `deal_activities` e não criar `deal_meetings`

A reunião **já é** uma atividade do canal `presencial`. Criar tabela nova obrigaria
a alterar `metas_progresso()`, os relatórios de produtividade e
`reassign_deals_to_admin()` — três funções em produção — para um ganho de modelagem
que não existe na prática. Estendendo:

- a meta `reunioes` (migration `20260825_0007`) continua contando
  `presencial + outcome = 'realizada'`, **sem uma linha de alteração**;
- `reassign_deals_to_admin()` já reatribui `deal_activities.author_id`, nada a fazer;
- a timeline do lead já renderiza a atividade — ganha só um enfeite a mais.

---

## 1. Migration

`supabase/migrations/20260826_0008_agenda_reunioes.sql`

Executar **no dashboard do Supabase**, não via MCP (conector em `--read-only`
por decisão deliberada):
`https://supabase.com/dashboard/project/heevguvboffziehftucp/sql/new`

### 1.1 Colunas novas (todas nullable, aditivas)

| Coluna | Tipo | Papel |
|---|---|---|
| `meeting_status` | `text` | `agendada` \| `realizada` \| `nao_compareceu` \| `cancelada`. NULL = atividade que não é reunião |
| `meeting_mode` | `text` | `presencial` \| `online` |
| `meeting_link` | `text` | URL da sala (Meet/Zoom/Teams). Só quando `online`, só `https://` |
| `meeting_contact_name` | `text` | Quem participa da reunião — pode ser diferente do contato principal do lead |
| `meeting_contact_phone` | `text` | Telefone de quem participa (snapshot do momento do agendamento) |

`occurred_at` passa a ser a **data/hora da reunião** — futura enquanto ela está
marcada. É o mesmo eixo que a timeline, o índice
`deal_activities_deal_occurred_idx` e os relatórios já usam.

Empresa e CNPJ **não são duplicados**: vêm do join com `deals` (`title`, `cnpj`).
Copiar razão social e CNPJ para a atividade criaria dois lugares para corrigir o
mesmo erro de digitação.

### 1.2 Constraints

- `agenda_valida` — agenda só existe com `channel = 'presencial'` e status do
  domínio fechado.
- `agenda_outcome_coerente` — amarra `outcome` ao `meeting_status`
  (`realizada` ↔ `realizada`, `nao_compareceu` ↔ `nao_compareceu`,
  `agendada`/`cancelada` ↔ `outcome is null`).
- `agenda_modalidade_valida` — toda reunião tem modalidade; quem não é reunião
  não tem.
- `agenda_link_valido` — link só em reunião online, só `https://`, no máximo
  500 caracteres. Bloqueia `javascript:` e `data:` **na origem**, antes de
  qualquer render. O frontend valida de novo com `new URL()` e monta o `href`
  por propriedade — duas barreiras, nenhuma URL interpolada em HTML.

### Sobre reunião online continuar em `channel = 'presencial'`

Reunião online **não é** presencial, e o nome da coluna passa a mentir um pouco.
Foi decisão consciente: `channel` é o valor que `metas_progresso()` e os
relatórios já contam. Trocar por um canal novo (`reuniao`) obrigaria a alterar
`resultado_valido`, `metas_progresso()` e a leitura de canal nos relatórios — três
pontos em produção — para renomear um enum. `meeting_mode` carrega a verdade;
a UI nunca mostra a palavra "presencial" como canal (o chip diz **Reunião**).
Se um dia o canal for renomeado, é um `update` de uma coluna.

`resultado_valido` **não é alterada**. Reunião marcada e ainda sem desfecho grava
`outcome NULL`; a constraint atual aceita porque, para `channel = 'presencial'`
com `outcome NULL`, o ramo avalia `NULL` e um CHECK só rejeita `FALSE`. Isso era
acidental — `agenda_outcome_coerente` torna deliberado.

### 1.3 Índice

Parcial, só em linhas de agenda:

```sql
create index deal_activities_agenda_idx
  on public.deal_activities (occurred_at)
  where meeting_status is not null;
```

### 1.4 RLS

Nenhuma policy nova. As policies de `deal_activities` derivam do dono do **deal**:
vendedor vê a própria agenda, admin vê a da equipe. O painel do Dashboard não
filtra owner no cliente — quem decide é o servidor.

---

## 2. Interface — modal do lead

O chip do canal presencial passa a se chamar **🤝 Reunião**. Ao escolhê-lo o
formulário entra em modo agenda:

- "Resultado" some — no lugar entra **Situação da reunião** (4 chips)
- **Modalidade**: 🏢 Presencial · 💻 Online (presencial pré-selecionado)
- **Link da reunião** aparece só quando a modalidade é Online
- **Contato da reunião** e **Telefone**, pré-preenchidos com o contato do lead e
  editáveis (a reunião costuma ser com outra pessoa)
- O rótulo "Quando" vira **"Data e hora da reunião"**
- O botão vira **"Salvar reunião"**

Fluxo mínimo: `Reunião → Agendada → modalidade → data/hora → salvar`.
Reunião online sem link é aceita — o link costuma sair depois de confirmar a data.

`outcome` é derivado da situação na camada da aplicação, espelhando
`agenda_outcome_coerente`. O vendedor nunca escolhe `outcome` numa reunião.

Na timeline do lead a reunião aparece como `🤝 Reunião · Agendada` com o contato
abaixo. Edição e exclusão seguem as regras já existentes (canal travado na edição;
excluir só autor ou admin).

Linha antiga de `presencial` sem `meeting_status` deriva o status do `outcome` ao
ser aberta para edição — nada se perde.

---

## 3. Interface — Dashboard

**Card de métrica** `🤝 Reuniões agendadas`
- valor: reuniões futuras com status `agendada`
- sub: `N aguardando desfecho` quando houver reunião vencida sem desfecho;
  senão `N realizada(s) no mês`

**Painel "Próximas reuniões"** (largura total, abaixo do funil)
- Vencidas sem desfecho primeiro, com selo vermelho `AGUARDANDO DESFECHO` —
  cobrança de fechamento do ciclo, não decoração
- Depois as futuras em ordem crescente, com selo `HOJE` / `AMANHÃ` / `EM Nd`
- Cada linha: data · hora · empresa (clica e abre o lead) · CNPJ · modalidade ·
  contato · telefone · atalhos de ligar e WhatsApp · responsável (só para
  admin/gestor)
- Reunião online com link ganha o botão **Entrar**, que abre a sala em nova aba
- Teto de 12 linhas, com rodapé informando quantas ficaram de fora
- `cancelada` e `nao_compareceu` não entram no painel

Consulta própria a `deal_activities`, independente de `dashboard_stats`. Se falhar,
o card mostra `—`, o painel mostra o erro e **o resto do Dashboard continua de pé**.
Janela: do primeiro dia do mês em diante, teto de 300 linhas.

---

## 4. Efeito colateral conhecido

Reunião marcada para data futura **dentro do mês corrente** entra na meta
`atividades` (e `trabalhados`) antes de acontecer, porque essas metas contam por
`occurred_at`. É consistente com "agendar é trabalho", mas se incomodar, o
conserto é uma linha em `metas_progresso()`:

```sql
and (a.meeting_status is null or a.meeting_status <> 'agendada')
```

A meta `reunioes` **não** é afetada: exige `outcome = 'realizada'`.

---

## 5. Ordem de deploy

1. Migration no dashboard do Supabase
2. Conferência: `select meeting_status, meeting_mode, count(*) from deal_activities group by 1,2;`
3. Push do `index.html` → Cloudflare Pages
4. Validar em janela anônima

O inverso quebra o registro de reunião para todo mundo — o insert falha por
coluna inexistente.

---

## 6. Checklist

- [x] **Segurança** — `escapeHtml` em todo conteúdo; nenhuma URL interpolada no
      HTML (href por propriedade); RLS herdada de `deal_activities`; sem segredo novo
- [x] **Arquitetura** — single-file preservado; nenhuma dependência nova
- [x] **Backend** — todo `async` com erro tratado; falha da agenda não derruba o Dashboard
- [x] **Frontend** — semântico (`button`, `label for`); light mode; tokens em `:root`;
      responsivo conferido em 390px
- [x] **Dados** — constraints fecham o domínio; índice parcial; migration versionada
- [x] **DevOps** — migration antes do frontend; rollback = `drop column` (colunas nullable)
- [x] **QA** — 33 testes automatizados (render, XSS, `javascript:` no link,
      datas, limite, estado vazio, estado de erro, classificação e visibilidade
      por papel); `node --check` nos 4 blocos
- [ ] **Teste manual** — registrar reunião presencial e online pelo modal e pela
      fila de follow-up, editar, cancelar, marcar como realizada, testar o botão
      Entrar, conferir a meta `reunioes`
