# Especificação — Aba de Follow-up

Projeto: CRM Funil de Vendas (Escard)
Depende de: `deal_activities` (já em produção)

---

## Por que uma tela nova

O follow-up hoje existe como um número no Dashboard e uma data dentro de cada
lead. Não há lugar onde o vendedor abra de manhã e veja o que precisa ser feito.

Esta tela é uma **fila de trabalho**, não um relatório. O critério de sucesso é
o vendedor conseguir trabalhar de cima para baixo sem abrir outra coisa.

---

## Restrição arquitetural obrigatória

**Esta tela NÃO pode ler do array `deals` em memória.**

O `loadDeals()` traz no máximo 1.000 dos 2.564 registros — limite padrão do
PostgREST — ordenados por `created_at` desc. Os leads ausentes são os **mais
antigos**, que são justamente os que mais precisam de follow-up.

Toda a leitura desta tela vem de uma RPC dedicada, com filtro, busca e
paginação no servidor.

---

## 1. RPC — `followups_list()`

Executar no dashboard do Supabase. Não via MCP.

### Assinatura

```sql
create or replace function public.followups_list(
  p_filtro   text default 'atrasados',
  p_busca    text default null,
  p_owner    uuid default null,
  p_limit    int  default 50,
  p_offset   int  default 0
)
returns table (
  id                 uuid,
  title              text,
  contact_name       text,
  contact_phone      text,
  whatsapp           text,
  contact_email      text,
  value              numeric,
  stage_id           uuid,
  owner_id           uuid,
  owner_name         text,
  next_followup_date date,
  ultima_atividade   timestamptz,
  dias_sem_contato   int,
  total_atividades   bigint,
  total_registros    bigint
)
language sql
stable
security invoker
set search_path to 'public'
as $$
  with base as (
    select
      d.*,
      p.full_name as owner_name,
      (select max(a.occurred_at) from public.deal_activities a
        where a.deal_id = d.id) as ultima_atividade,
      (select count(*) from public.deal_activities a
        where a.deal_id = d.id) as total_atividades
    from public.deals d
    left join public.profiles p on p.id = d.owner_id
    join public.stages s on s.id = d.stage_id
    where s.is_won = false
      and s.is_lost = false
      and (p_owner is null or d.owner_id = p_owner)
      and (
        p_busca is null or p_busca = '' or
        d.title        ilike '%' || p_busca || '%' or
        d.contact_name ilike '%' || p_busca || '%' or
        d.cnpj         ilike '%' || p_busca || '%'
      )
  ),
  filtrado as (
    select * from base
    where case p_filtro
      when 'atrasados'  then next_followup_date <  (now() at time zone 'America/Sao_Paulo')::date
      when 'hoje'       then next_followup_date =  (now() at time zone 'America/Sao_Paulo')::date
      when 'semana'     then next_followup_date between
                                (now() at time zone 'America/Sao_Paulo')::date
                            and (now() at time zone 'America/Sao_Paulo')::date + 7
      when 'sem_passo'  then next_followup_date is null
      when 'frios'      then ultima_atividade is null
                             or ultima_atividade < now() - interval '15 days'
      else true
    end
  )
  select
    f.id, f.title, f.contact_name, f.contact_phone, f.whatsapp,
    f.contact_email, f.value, f.stage_id, f.owner_id, f.owner_name,
    f.next_followup_date, f.ultima_atividade,
    case when f.ultima_atividade is null then null
         else extract(day from now() - f.ultima_atividade)::int end,
    f.total_atividades,
    count(*) over () as total_registros
  from filtrado f
  order by
    f.next_followup_date asc nulls last,
    f.ultima_atividade asc nulls first
  limit p_limit offset p_offset;
$$;
```

**`security invoker` é obrigatório.** Assim a RLS aplica como o usuário logado:
admin vê todos, vendedor vê os seus. Nunca use `security definer` aqui.

**Verificação antes de executar:** confirme via MCP que a tabela `stages` tem
as colunas `is_won` e `is_lost`, e que `deals.cnpj` existe. Ajuste se divergir.

### Índice de apoio

```sql
create index if not exists deals_followup_idx
  on public.deals (next_followup_date, owner_id)
  where next_followup_date is not null;
```

---

## 2. RPC de contadores — `followups_contadores()`

Alimenta os números do topo. Consulta separada porque não pagina.

```sql
create or replace function public.followups_contadores(
  p_owner uuid default null
)
returns jsonb
language sql
stable
security invoker
set search_path to 'public'
as $$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
  base as (
    select d.id, d.next_followup_date,
      (select max(a.occurred_at) from public.deal_activities a
        where a.deal_id = d.id) as ultima
    from public.deals d
    join public.stages s on s.id = d.stage_id
    where s.is_won = false and s.is_lost = false
      and (p_owner is null or d.owner_id = p_owner)
  )
  select jsonb_build_object(
    'atrasados', count(*) filter (where next_followup_date < (select d from hoje)),
    'hoje',      count(*) filter (where next_followup_date = (select d from hoje)),
    'semana',    count(*) filter (where next_followup_date between (select d from hoje) and (select d from hoje) + 7),
    'sem_passo', count(*) filter (where next_followup_date is null),
    'frios',     count(*) filter (where ultima is null or ultima < now() - interval '15 days'),
    'total',     count(*)
  )
  from base;
$$;
```

---

## 3. Interface

### 3.1 Item no menu lateral

Novo item entre "Funil de Vendas" e "Empresas":

```
🔔 Follow-up
```

Com badge numérico mostrando `atrasados + hoje` quando maior que zero. É o
sinal que faz o vendedor clicar.

### 3.2 Cabeçalho da página

Título "Follow-up", subtítulo variando por papel — admin: "Acompanhamento de
toda a equipe"; vendedor: "Seus leads aguardando contato".

### 3.3 Contadores clicáveis

Linha de cartões que funcionam como filtro. O ativo fica destacado.

```
Atrasados 47   |   Hoje 12   |   Próximos 7 dias 34   |
Sem próximo passo 89   |   Sem contato há 15+ dias 128
```

Padrão ao abrir: **Atrasados**.

### 3.4 Barra de ferramentas

- Campo de busca (nome, contato ou CNPJ) — com debounce de 400ms
- Seletor de vendedor — **somente admin**, com opção "Todos" como padrão

### 3.5 Lista

Cada linha mostra:

```
CONSTRUTORA EXEMPLO LTDA                          Prospecção
João Silva · (27) 99660-7403                      Heloísa
⚠ Follow-up atrasado 12d  ·  Último contato há 34d  ·  5 atividades
[💬] [📞] [✉️]                          [Registrar contato]  [Abrir lead]
```

- Ícones de canal usam os mesmos links rápidos já implementados no modal
- "Follow-up atrasado" em `--lost`; "hoje" em `--primary`; futuro em texto normal
- "Último contato há Nd" em `--lost` quando > 15 dias
- Se `total_atividades = 0`, exibir "Nunca contatado" em `--lost`

**Escapar todo conteúdo com `escapeHtml`.**

### 3.6 Registrar contato inline

O botão "Registrar contato" abre o **mesmo formulário da timeline**, expandido
na própria linha da lista — sem abrir o modal do lead.

Reutilize as funções já existentes (`ACTIVITY_CHANNELS`, `ACTIVITY_OUTCOMES`,
`selecionarCanal`, etc.). Não duplique a lógica.

Ao salvar:
- Insere em `deal_activities`
- Atualiza `deals.next_followup_date` se houver próximo passo
- **Remove a linha da lista** se ela deixou de atender o filtro atual
- Atualiza os contadores

Esse comportamento — o item sumindo da fila ao ser tratado — é o que faz a tela
funcionar como fila de trabalho.

### 3.7 Paginação

50 por página. Botão "Carregar mais" ao final. `total_registros` vem na própria
RPC, então mostre "Exibindo 50 de 247".

---

## 4. Fora de escopo

- Envio de relatório por e-mail
- Notificação push ou lembrete
- Regra automática de descarte após N tentativas
- Métricas de taxa de atendimento por canal

Todos ficam viáveis com o dado que esta tela e a `deal_activities` produzem.

---

## 5. Checklist antes de declarar pronto

- [ ] **Segurança** — RPCs com `security invoker`; testar logando como vendedor
      e confirmar que só vê os próprios leads; `escapeHtml` em todo render
- [ ] **Arquitetura** — nenhuma leitura do array `deals`; tudo via RPC
- [ ] **Backend** — todo `async` tratado; busca com debounce
- [ ] **Frontend** — semântico; responsivo; light mode; funciona em iOS Safari
- [ ] **Dados** — índice criado; fuso `America/Sao_Paulo` em todas as
      comparações de data
- [ ] **DevOps** — RPCs aplicadas antes do deploy do frontend
- [ ] **QA** — lista vazia; busca sem resultado; lead nunca contatado;
      registrar contato e ver o item sair da lista; paginação com 200+ itens;
      trocar de vendedor como admin
- [ ] **Regressão** — Dashboard, Kanban e modal de lead intactos
