# Especificação — Transferência de carteira

Projeto: CRM Funil de Vendas (Escard)
Acesso: **somente admin**

---

## Objetivo

Permitir que o admin transfira leads de um vendedor para outro, escolhendo
quantidade, filtros e ordem — com preview antes, registro no histórico do lead
e possibilidade de desfazer.

Caso de uso imediato: o admin acumulou 1.461 deals porque a importação não
tinha seletor de vendedor. Precisa redistribuir.

---

## Princípio de segurança

**A transferência é uma operação em lote sobre dados de produção.** Se sair
errada, não há tela de correção — só outra transferência.

Por isso:
- Tudo acontece dentro de **uma RPC transacional**. Ou move todos, ou nenhum.
- **Preview obrigatório** antes de confirmar, com contagem e amostra.
- **Backup automático** de cada operação, permitindo desfazer.
- **Registro em `deal_activities`**, para o lead carregar sua própria história.

---

## 1. Banco

### 1.1 Tabela de auditoria

```sql
create table public.transferencias (
  id           uuid primary key default gen_random_uuid(),
  executado_por uuid not null references public.profiles(id),
  de_owner     uuid not null references public.profiles(id),
  para_owner   uuid not null references public.profiles(id),
  filtros      jsonb not null,
  total        int  not null,
  deal_ids     uuid[] not null,
  desfeita_em  timestamptz,
  created_at   timestamptz not null default now()
);

alter table public.transferencias enable row level security;

create policy transferencias_admin_only on public.transferencias
  for all to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));
```

`deal_ids` guarda exatamente quais leads foram movidos — é o que torna o
desfazer confiável, em vez de tentar reconstruir por filtro.

### 1.2 RPC de preview

```sql
create or replace function public.transferencia_preview(
  p_de        uuid,
  p_stage     uuid default null,
  p_min_dias  int  default null,
  p_sem_passo boolean default false,
  p_ordem     text default 'antigos',
  p_limite    int  default 100
)
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public'
as $$
declare
  v_total int;
  v_amostra jsonb;
begin
  if not (select public.is_admin()) then
    raise exception 'Apenas administradores podem transferir leads';
  end if;

  with candidatos as (
    select d.id, d.title, d.contact_name, s.name as stage_name,
           d.created_at, d.next_followup_date,
           extract(day from
             (now() at time zone 'America/Sao_Paulo')
             - coalesce(
                 (select max(a.occurred_at) from public.deal_activities a
                   where a.deal_id = d.id) at time zone 'America/Sao_Paulo',
                 d.stage_changed_at at time zone 'America/Sao_Paulo',
                 d.created_at at time zone 'America/Sao_Paulo'
               ))::int as dias_parado
    from public.deals d
    join public.pipeline_stages s on s.id = d.stage_id
    where d.owner_id = p_de
      and s.is_won = false
      and s.is_lost = false
      and (p_stage is null or d.stage_id = p_stage)
      and (p_sem_passo = false or d.next_followup_date is null)
  ),
  filtrados as (
    select * from candidatos
    where p_min_dias is null or dias_parado >= p_min_dias
  ),
  ordenados as (
    select * from filtrados
    order by
      case when p_ordem = 'antigos'  then created_at end asc,
      case when p_ordem = 'recentes' then created_at end desc
    limit p_limite
  )
  select count(*), coalesce(jsonb_agg(t), '[]'::jsonb)
    into v_total, v_amostra
  from (select * from ordenados limit 10) t;

  select count(*) into v_total from ordenados;

  return jsonb_build_object(
    'total', v_total,
    'disponivel', (select count(*) from filtrados),
    'amostra', v_amostra
  );
end;
$$;
```

> **Ao implementar:** o bloco acima tem uma imprecisão na contagem (o `v_total`
> é sobrescrito). Corrija usando CTEs materializadas ou variáveis separadas.
> O comportamento correto é: `disponivel` = total que atende aos filtros,
> `total` = quantos serão efetivamente movidos (o menor entre `disponivel` e
> `p_limite`), `amostra` = os 10 primeiros.

### 1.3 RPC de execução

```sql
create or replace function public.transferencia_executar(
  p_de        uuid,
  p_para      uuid,
  p_stage     uuid default null,
  p_min_dias  int  default null,
  p_sem_passo boolean default false,
  p_ordem     text default 'antigos',
  p_limite    int  default 100
)
returns jsonb
language plpgsql
security invoker
set search_path to 'public'
as $$
declare
  v_ids uuid[];
  v_total int;
  v_transf_id uuid;
  v_nome_de text;
  v_nome_para text;
begin
  if not (select public.is_admin()) then
    raise exception 'Apenas administradores podem transferir leads';
  end if;

  if p_de = p_para then
    raise exception 'Origem e destino não podem ser o mesmo vendedor';
  end if;

  if not exists (select 1 from public.profiles
                 where id = p_para and active = true) then
    raise exception 'O vendedor de destino não está ativo';
  end if;

  -- Seleciona os ids exatos (mesma lógica do preview)
  -- ... (aplicar filtros, ordem e limite; coletar em v_ids)

  v_total := coalesce(array_length(v_ids, 1), 0);
  if v_total = 0 then
    return jsonb_build_object('total', 0, 'mensagem', 'Nenhum lead atende aos filtros');
  end if;

  select full_name into v_nome_de   from public.profiles where id = p_de;
  select full_name into v_nome_para from public.profiles where id = p_para;

  -- Auditoria ANTES do update
  insert into public.transferencias
    (executado_por, de_owner, para_owner, filtros, total, deal_ids)
  values (
    auth.uid(), p_de, p_para,
    jsonb_build_object('stage', p_stage, 'min_dias', p_min_dias,
                       'sem_passo', p_sem_passo, 'ordem', p_ordem,
                       'limite', p_limite),
    v_total, v_ids
  )
  returning id into v_transf_id;

  -- Move
  update public.deals
     set owner_id = p_para
   where id = any(v_ids);

  -- Registra no histórico de cada lead
  insert into public.deal_activities
    (deal_id, author_id, channel, note, occurred_at)
  select unnest(v_ids), auth.uid(), 'nota',
         'Lead transferido de ' || v_nome_de || ' para ' || v_nome_para,
         now();

  return jsonb_build_object(
    'total', v_total,
    'transferencia_id', v_transf_id
  );
end;
$$;
```

**Tudo numa função `plpgsql` = uma transação.** Se o insert em
`deal_activities` falhar, o update dos deals é revertido junto.

### 1.4 RPC de desfazer

```sql
create or replace function public.transferencia_desfazer(p_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path to 'public'
as $$
-- Valida admin; busca a transferência; se já desfeita, erro;
-- update deals set owner_id = de_owner where id = any(deal_ids);
-- marca desfeita_em = now();
-- registra atividade de reversão em cada lead
$$;
```

**Limitação a documentar na interface:** se um lead foi transferido de novo
depois, ou teve o dono alterado manualmente, desfazer vai sobrescrever essa
mudança. O desfazer é para correção imediata, não para reverter histórico
antigo.

---

## 2. Interface

Nova seção na aba **Administração**, visível apenas para admin.

### 2.1 Formulário

```
Transferir carteira

De:    [Roberto Cassiano (1.461 leads) ▾]
Para:  [Selecione ▾]

Filtros (opcionais)
Etapa:            [Todas as etapas ▾]
Parados há:       [Qualquer período ▾]  7+ · 15+ · 30+ · 60+ · 90+ dias
                  [ ] Apenas sem próximo passo definido

Quantidade:       [100]  leads
Ordem:            (•) Mais antigos primeiro   ( ) Mais recentes primeiro

                                    [Ver preview]
```

- "De" e "Para" listam profiles ativos; "Para" exclui o selecionado em "De"
- Quantidade tem máximo de 500 por operação
- O contador ao lado de "De" vem de uma consulta de contagem

### 2.2 Preview

Ao clicar em "Ver preview", chama `transferencia_preview` e mostra:

```
1.364 leads atendem aos filtros.
Serão transferidos os 100 mais antigos.

Amostra dos 10 primeiros:
  CONSTRUTORA EXEMPLO LTDA    Prospecção    parado há 87d
  MARIA SILVA ME              Prospecção    parado há 85d
  ...

        [Cancelar]   [Confirmar transferência de 100 leads]
```

O botão de confirmação **repete o número** no rótulo. Isso é deliberado:
força o admin a ler quantos leads serão movidos antes de clicar.

### 2.3 Confirmação

Ao confirmar, chama `transferencia_executar` com os mesmos parâmetros.

Durante a execução, desabilite o botão e mostre estado de carregamento.
Uma transferência de 500 leads pode levar alguns segundos.

Depois:

```
✓ 100 leads transferidos para Priscila.
                                          [Desfazer]
```

O botão "Desfazer" fica disponível enquanto a tela estiver aberta e chama
`transferencia_desfazer` com o id retornado.

### 2.4 Histórico

Abaixo do formulário, as últimas 10 transferências:

```
14/08 10:32  Roberto → Priscila   100 leads   [Desfazer]
14/08 09:15  Roberto → Heloísa    250 leads   ✓ concluída
13/08 16:40  Heloísa → Roberto     45 leads   ↩ desfeita
```

Desfazer disponível apenas para transferências não desfeitas.

---

## 3. Fora de escopo

- Transferir leads ganhos ou perdidos (a RPC já os exclui)
- Distribuição automática round-robin entre vários vendedores
- Agendamento de transferência
- Regra automática do tipo "todo lead parado há 60 dias volta para o admin"

---

## 4. Checklist antes de declarar pronto

- [ ] **Segurança** — todas as RPCs verificam `is_admin()`; RLS na tabela de
      auditoria; a interface some para vendedor
- [ ] **Atomicidade** — testar falha no meio (ex.: violar uma constraint) e
      confirmar que nada foi movido
- [ ] **Backend** — `deal_ids` gravado ANTES do update; async tratado
- [ ] **Frontend** — preview obrigatório; botão repete a quantidade;
      estado de carregamento; light mode
- [ ] **Dados** — validar origem ≠ destino; destino ativo; limite de 500
- [ ] **QA** — transferir 1 lead · transferir 100 · filtros sem resultado ·
      desfazer imediato · desfazer duas vezes (deve bloquear) · vendedor
      tentando acessar a tela
- [ ] **Regressão** — Kanban, Follow-up e Dashboard refletem os novos donos
      após transferir

---

## 5. Nota de gestão

Transferir 500 leads de lista fria de uma vez costuma não funcionar: a pessoa
abre, vê o volume e não começa. Lotes de 50 a 100 tendem a funcionar melhor,
e a tela permite repetir quando a pessoa terminar.

A ferramenta não impõe isso — é decisão de quem gerencia.
