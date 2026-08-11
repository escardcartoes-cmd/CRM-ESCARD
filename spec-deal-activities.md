# Especificação — Registro de contatos e timeline unificada

Projeto: CRM Funil de Vendas (Escard)
Objetivo: substituir o follow-up baseado em campo único por um histórico de
interações que registra canal, resultado e próximo passo.

---

## Decisões já tomadas

| Questão | Decisão |
|---|---|
| Anotações e contatos | **Unificados** numa só timeline |
| Atividade editável | **Sim**, com marca de edição visível |
| `occurred_at` editável | **Sim** — permite registrar contato feito fora do sistema |
| Registro automático ao clicar no wa.me | **Não** — clicar não é contatar |

---

## 1. Migration — executar no dashboard do Supabase

`https://supabase.com/dashboard/project/heevguvboffziehftucp/sql/new`

**Não executar via MCP.** O conector está em `--read-only` por decisão
deliberada; escrita em produção passa pelo dashboard, com o SQL visível na tela.

### 1.1 Tabela

```sql
create table public.deal_activities (
  id uuid primary key default gen_random_uuid(),
  deal_id uuid not null references public.deals(id) on delete cascade,
  author_id uuid not null references public.profiles(id),
  channel text not null,
  outcome text,
  note text,
  occurred_at timestamptz not null default now(),
  next_action_date date,
  edited_at timestamptz,
  edited_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),

  constraint canal_valido check (
    channel in ('telefone','whatsapp','email','presencial','nota')
  ),

  constraint resultado_valido check (
    (channel = 'nota'       and outcome is null) or
    (channel = 'telefone'   and outcome in ('atendeu','nao_atendeu','caixa_postal','numero_errado')) or
    (channel = 'whatsapp'   and outcome in ('respondeu','visualizou','nao_visualizou','numero_invalido')) or
    (channel = 'email'      and outcome in ('respondeu','sem_resposta','bounce')) or
    (channel = 'presencial' and outcome in ('realizada','nao_compareceu'))
  ),

  constraint conteudo_minimo check (
    channel <> 'nota' or (note is not null and length(trim(note)) > 0)
  )
);
```

O `conteudo_minimo` impede nota vazia. Contato sem observação é legítimo — o
resultado já é a informação.

### 1.2 Índices

```sql
create index deal_activities_deal_occurred_idx
  on public.deal_activities (deal_id, occurred_at desc);

create index deal_activities_author_occurred_idx
  on public.deal_activities (author_id, occurred_at desc);
```

O primeiro serve a timeline do lead. O segundo serve o relatório de
produtividade por vendedor, que virá depois.

### 1.3 RLS

**Antes de escrever as policies, leia as políticas atuais de `deals`** e espelhe
a mesma lógica de visibilidade. O padrão do projeto usa:

- Uma policy `RESTRICTIVE` chamando `public.current_user_active()`, aplicada a
  `ALL`, presente em `deals`, `companies` e `contacts`
- Policies permissivas baseadas em `owner_id` e papel de admin

```sql
alter table public.deal_activities enable row level security;

-- Bloqueia usuário desativado, igual às demais tabelas
create policy activities_usuario_ativo on public.deal_activities
  as restrictive for all to authenticated
  using (public.current_user_active())
  with check (public.current_user_active());
```

As policies permissivas devem derivar do dono do **deal**, não do autor da
atividade. Um vendedor vê todas as atividades dos leads que possui, inclusive
as registradas pelo admin.

### 1.4 Migrar as notas existentes

```sql
insert into public.deal_activities
  (deal_id, author_id, channel, note, occurred_at, created_at)
select deal_id, author_id, 'nota', note, created_at, created_at
from public.deal_notes;
```

**Mantenha `deal_notes` intacta** até validar em produção por alguns dias.
Descarte depois, em migration separada.

Confira a contagem antes e depois:

```sql
select count(*) from public.deal_notes;
select count(*) from public.deal_activities where channel = 'nota';
```

### 1.5 ATENÇÃO — atualizar a função de transferência

A função `reassign_deals_to_admin()`, disparada pela trigger
`before_profile_delete`, hoje reatribui `deals.owner_id` e
`deal_notes.author_id`.

**Ela precisa passar a reatribuir `deal_activities.author_id` também.** Sem
isso, apagar um profile viola a FK e o DELETE falha — ou pior, deixa
atividades órfãs.

Leia a definição atual via MCP e produza o `CREATE OR REPLACE` incluindo a
tabela nova.

---

## 2. Interface — modal do lead

### 2.1 Substituir a seção de anotações pela timeline

A seção atual "Histórico de anotações" (`deal-notes-section`) passa a ser
"Histórico de contatos", alimentada por `deal_activities`.

Cada item da timeline mostra:

```
📞 Telefone · Não atendeu          10/08/2026 14:32 · Heloísa
   Tentei duas vezes, cai na caixa postal.
   → Próximo contato: 13/08/2026
```

- Ícone por canal: 📞 telefone · 💬 whatsapp · ✉️ e-mail · 🤝 presencial · 📝 nota
- Resultado com cor semântica: positivo em `--won`, negativo em `--lost`,
  neutro no texto padrão
- Se `edited_at` não for nulo, exibir `· editado` ao lado da data
- Ordem: `occurred_at` decrescente
- **Escapar todo conteúdo com `escapeHtml`** — a função já existe no arquivo

### 2.2 Registrar contato

Botão "Registrar contato" acima da timeline. Abre um formulário compacto —
inline na própria seção, não um modal sobre modal.

Campos, nesta ordem:

1. **Canal** — botões, não select. Cinco opções, seleção única.
2. **Resultado** — aparece após escolher o canal, com as opções daquele canal.
   Oculto quando o canal é "nota".
3. **Observação** — textarea, opcional (obrigatório só para nota)
4. **Quando** — datetime-local, pré-preenchido com agora, editável
5. **Próximo contato** — atalhos: `Amanhã` · `3 dias` · `1 semana` · `15 dias` ·
   `Data...` · `Sem próximo passo`

O fluxo mínimo precisa ser: **canal → resultado → salvar**. Dois cliques mais
o salvar. Se exigir mais, ninguém registra, e dado parcial é pior que dado
nenhum.

### 2.3 Editar atividade

Ícone de edição em cada item. Permite alterar `note`, `outcome` e `occurred_at`.

Ao salvar edição, gravar `edited_at = now()` e `edited_by = currentProfile.id`.

Não permitir alterar `channel` — mudar o canal de uma atividade registrada
descaracteriza o registro. Se errou o canal, apague e registre de novo.

### 2.4 Excluir atividade

Permitido apenas para o autor ou admin. Com confirmação.

---

## 3. Loop do próximo passo

Ao salvar uma atividade com `next_action_date` preenchida, atualizar também
`deals.next_followup_date` com o mesmo valor.

Fazer isso na camada da aplicação, na mesma operação. Alternativa seria uma
trigger no banco — mais robusta, porém acopla e esconde o comportamento.
Para este projeto, a camada de aplicação é mais legível e suficiente.

Se o usuário escolher "Sem próximo passo", não alterar `next_followup_date`.

---

## 4. Fora de escopo nesta entrega

Registrado para não virar improviso no meio do caminho:

- Tela "Meu dia" com follow-ups vencidos — depende de resolver o Kanban truncado
- Relatório diário por e-mail — depende de ter dado acumulado
- Métricas derivadas (taxa de atendimento por canal, tentativas até contato)
- Alerta de lead com 3+ tentativas sem resposta

A modelagem acima sustenta todos eles sem migration nova.

---

## 5. Checklist antes de declarar pronto

- [ ] **Segurança** — `escapeHtml` em todo conteúdo renderizado; RLS ativo e
      testada com conta de vendedor; nenhum segredo novo
- [ ] **Arquitetura** — single-file preservado; sem dependência nova
- [ ] **Backend** — todo `async` com erro tratado; contagem de notas migradas
      confere; `reassign_deals_to_admin` atualizada
- [ ] **Frontend** — semântico; acessível (labels, aria); responsivo; light mode
- [ ] **Dados** — constraints validadas com valor inválido; índices criados
- [ ] **DevOps** — migration aplicada antes do deploy do frontend
- [ ] **QA** — registrar contato de cada canal; editar; excluir; timeline vazia;
      lead com 50+ atividades; `occurred_at` no passado
- [ ] **Ordem de deploy** — migration primeiro, frontend depois. O inverso
      quebra a interface para todo mundo.
