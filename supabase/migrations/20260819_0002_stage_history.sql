-- =============================================================================
-- MIGRATION 20260819_0002 — Histórico de transição de etapas
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 20260819_0001_auditoria_base.sql
-- =============================================================================
-- Por que uma tabela separada do audit_log:
--   audit_log é COMPLIANCE  — linha larga, jsonb genérico, leitura pontual por registro.
--   deal_stage_history é ANALYTICS — linha estreita, leitura agregada sobre milhares
--   de linhas com filtro por período e vendedor.
--   Extrair campos->'stage_id'->>'de' com cast para uuid em varredura de milhares de
--   deals seria lento e frágil. Aqui o funil vira índice simples.
--
-- Diferença de tratamento: audit_log é imutável (trilha legal). Esta tabela é
-- derivada e aceita cascade delete — o registro legal da mudança continua no audit_log.
--
-- Aditiva: NÃO altera tabela existente, NÃO altera index.html.
-- Idempotente: pode ser executada mais de uma vez.
-- =============================================================================

begin;

-- =============================================================================
-- 1. TABELA
-- =============================================================================
create table if not exists public.deal_stage_history (
  id             bigint generated always as identity primary key,
  deal_id        uuid        not null references public.deals(id)           on delete cascade,
  from_stage_id  uuid                 references public.pipeline_stages(id) on delete set null,
  to_stage_id    uuid                 references public.pipeline_stages(id) on delete set null,
  changed_by     uuid                 references public.profiles(id)        on delete set null,
  owner_id       uuid                 references public.profiles(id)        on delete set null,
  changed_at     timestamptz not null default now(),
  dias_anterior  numeric(10,2),
  origem         text        not null default 'app'
                 check (origem in ('app','sistema','entrada'))
);

comment on table public.deal_stage_history is
  'Histórico de transição de etapa dos leads. Fonte do funil e do tempo por etapa.';
comment on column public.deal_stage_history.owner_id is
  'Responsável pelo lead no momento da mudança. Desnormalizado de propósito: se o lead for '
  'transferido depois, o histórico continua atribuído a quem de fato trabalhou o lead.';
comment on column public.deal_stage_history.dias_anterior is
  'Dias que o lead permaneceu na etapa de origem. Null na entrada no funil.';
comment on column public.deal_stage_history.origem is
  'entrada = criação do lead · app = mudança por usuário · sistema = integração sem sessão.';

create index if not exists idx_dsh_changed    on public.deal_stage_history (changed_at desc);
create index if not exists idx_dsh_deal       on public.deal_stage_history (deal_id, changed_at desc);
create index if not exists idx_dsh_to_stage   on public.deal_stage_history (to_stage_id, changed_at desc);
create index if not exists idx_dsh_owner      on public.deal_stage_history (owner_id, changed_at desc);


-- =============================================================================
-- 2. TRIGGER — entrada no funil
-- =============================================================================
create or replace function public.fn_stage_history_entrada()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.stage_id is null then
    return null;
  end if;

  insert into public.deal_stage_history
    (deal_id, from_stage_id, to_stage_id, changed_by, owner_id, changed_at, dias_anterior, origem)
  values
    (new.id, null, new.stage_id, auth.uid(), new.owner_id,
     coalesce(new.created_at, now()), null,
     case when auth.uid() is null then 'sistema' else 'entrada' end);

  return null;
end;
$$;


-- =============================================================================
-- 3. TRIGGER — mudança de etapa
-- =============================================================================
create or replace function public.fn_stage_history_mudanca()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_desde timestamptz;
  v_dias  numeric(10,2);
begin
  -- Momento em que o lead entrou na etapa que está deixando agora.
  -- stage_changed_at é mantido pelo front; created_at é o fallback.
  v_desde := coalesce(old.stage_changed_at, old.created_at);

  if v_desde is not null then
    v_dias := round(extract(epoch from (now() - v_desde)) / 86400.0, 2);
    if v_dias < 0 then
      v_dias := null;  -- relógio inconsistente: melhor nulo que número mentiroso
    end if;
  end if;

  insert into public.deal_stage_history
    (deal_id, from_stage_id, to_stage_id, changed_by, owner_id, changed_at, dias_anterior, origem)
  values
    (new.id, old.stage_id, new.stage_id, auth.uid(), coalesce(new.owner_id, old.owner_id),
     now(), v_dias,
     case when auth.uid() is null then 'sistema' else 'app' end);

  return null;
end;
$$;


-- =============================================================================
-- 4. ANEXO DOS TRIGGERS
-- =============================================================================
drop trigger if exists trg_stage_history_entrada on public.deals;
create trigger trg_stage_history_entrada
  after insert on public.deals
  for each row execute function public.fn_stage_history_entrada();

-- AFTER UPDATE OF stage_id + WHEN: só dispara quando a etapa realmente muda.
-- Mais barato que o trigger genérico de auditoria, que roda em qualquer update.
drop trigger if exists trg_stage_history_mudanca on public.deals;
create trigger trg_stage_history_mudanca
  after update of stage_id on public.deals
  for each row
  when (old.stage_id is distinct from new.stage_id)
  execute function public.fn_stage_history_mudanca();


-- =============================================================================
-- 5. RLS
-- =============================================================================
alter table public.deal_stage_history enable row level security;

-- Admin vê tudo. Vendedor vê apenas o histórico dos leads que eram dele.
drop policy if exists dsh_select on public.deal_stage_history;
create policy dsh_select on public.deal_stage_history
  for select to authenticated
  using (public.audit_usuario_e_admin() or owner_id = auth.uid());

revoke insert, update, delete, truncate on public.deal_stage_history from anon, authenticated;


-- =============================================================================
-- 6. MARCO ZERO — posição atual como linha de base
-- =============================================================================
-- Sem isto, um lead que já está em "Negociação" há 40 dias não aparece em
-- nenhuma etapa até a próxima movimentação. Registra a posição atual usando
-- stage_changed_at (ou created_at) como data — não inventa transição anterior.
insert into public.deal_stage_history
  (deal_id, from_stage_id, to_stage_id, changed_by, owner_id, changed_at, dias_anterior, origem)
select d.id, null, d.stage_id, null, d.owner_id,
       coalesce(d.stage_changed_at, d.created_at, now()), null, 'sistema'
  from public.deals d
 where d.stage_id is not null
   and not exists (select 1 from public.deal_stage_history h where h.deal_id = d.id);


-- =============================================================================
-- 7. LEITURA — etapa atual e tempo parado
-- =============================================================================
create or replace view public.vw_deal_etapa_atual as
select distinct on (h.deal_id)
       h.deal_id,
       h.to_stage_id                                              as stage_id,
       h.owner_id,
       h.changed_at                                               as desde,
       round(extract(epoch from (now() - h.changed_at)) / 86400.0, 2) as dias_parado
  from public.deal_stage_history h
 order by h.deal_id, h.changed_at desc, h.id desc;

comment on view public.vw_deal_etapa_atual is
  'Etapa atual de cada lead segundo o histórico, com dias parado. Alimenta o painel de aging.';

commit;

-- =============================================================================
-- ROLLBACK — executar apenas se for necessário reverter
-- =============================================================================
-- begin;
--   drop view if exists public.vw_deal_etapa_atual;
--   drop trigger if exists trg_stage_history_mudanca on public.deals;
--   drop trigger if exists trg_stage_history_entrada on public.deals;
--   drop function if exists public.fn_stage_history_mudanca();
--   drop function if exists public.fn_stage_history_entrada();
--   drop table if exists public.deal_stage_history;
-- commit;
