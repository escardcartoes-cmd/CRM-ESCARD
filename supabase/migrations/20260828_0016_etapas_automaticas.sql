-- =============================================================================
-- MIGRATION 20260828_0016 — Movimentação automática de etapa
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0015
-- =============================================================================
-- O PROBLEMA QUE ISTO RESOLVE
--
-- "Leads Novos" tem in_followup = false, e a fila do Follow-up só lista etapas
-- com in_followup = true. Resultado: a régua de cadência agenda o próximo toque
-- para um lead de "Leads Novos" e esse lead NUNCA aparece na fila. A data fica
-- gravada e ninguém vê. São 12.890 leads nessa situação contra 774 em "Contato
-- Feito" — a cadência estava alcançando 6% da base.
--
-- AS TRÊS REGRAS
--
--   1. Primeira atividade num lead de "Leads Novos", sem contato efetivo
--        -> "Sem Contato"   (que tem in_followup = true: entra na esteira)
--   2. Primeiro contato efetivo, vindo de "Leads Novos" ou "Sem Contato"
--        -> "Contato Feito"
--   3. De "Contato Feito" em diante, NADA é automático. Quem manda é o operador.
--
-- Sempre para frente. Um lead nunca é rebaixado: mover para trás inflaria a
-- contagem de movimentações e quebraria o "% avançam" do relatório de funil.
--
-- OS "4 DIAS SEM FALAR" NÃO ESTÃO AQUI, DE PROPÓSITO
--
-- Depois da regra 1 o lead já está em "Sem Contato" — não há para onde movê-lo.
-- E o número já existe: `followups_list.dias_parado` conta sobre o último contato
-- EFETIVO desde a migration 0011. É calculado na leitura, não precisa de pg_cron,
-- não vira estado que envelhece, e um lead que atender hoje sai do alerta sozinho.
-- O tratamento é visual, no frontend.
--
-- IDENTIFICAÇÃO POR NOME
--
-- As etapas são resolvidas por nome, como fez a 0012. Se alguém renomear "Sem
-- Contato" ou "Contato Feito" pelo painel, a automação para de mover — sem erro,
-- sem estrago, só deixa de agir. É a degradação preferível à alternativa (gravar
-- UUID nesta migration e ela apontar para uma etapa apagada).
-- =============================================================================

begin;

-- =============================================================================
-- 1. O HISTÓRICO PRECISA SABER QUEM MOVEU
-- =============================================================================
-- fn_stage_history_mudanca grava origem = 'app' sempre que existe auth.uid().
-- Movimentação automática gravada como 'app' entraria em `movimentacoes` e em
-- `trabalhados`: o vendedor ganharia crédito de trabalho por algo que o sistema
-- fez. A trava de sessão é o mesmo padrão que a purga de auditoria já usa.
--
-- Corpo idêntico ao da 0002 fora o `case` da origem.

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
  v_desde := coalesce(old.stage_changed_at, old.created_at);

  if v_desde is not null then
    v_dias := round(extract(epoch from (now() - v_desde)) / 86400.0, 2);
    if v_dias < 0 then
      v_dias := null;
    end if;
  end if;

  insert into public.deal_stage_history
    (deal_id, from_stage_id, to_stage_id, changed_by, owner_id, changed_at, dias_anterior, origem)
  values
    (new.id, old.stage_id, new.stage_id, auth.uid(), coalesce(new.owner_id, old.owner_id),
     now(), v_dias,
     case
       when coalesce(current_setting('app.mov_automatica', true), 'off') = 'on' then 'sistema'
       when auth.uid() is null then 'sistema'
       else 'app'
     end);

  return null;
end;
$$;


-- =============================================================================
-- 2. A AUTOMAÇÃO
-- =============================================================================
create or replace function public.fn_etapa_automatica()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stage    uuid;
  v_nome     text;
  v_won      boolean;
  v_lost     boolean;
  v_destino  uuid;
  v_efetivo  boolean;
begin
  -- Nota não é tentativa de contato: anotar não pode mover o lead de etapa.
  if new.channel = 'nota' then
    return null;
  end if;

  select d.stage_id, s.name, coalesce(s.is_won, false), coalesce(s.is_lost, false)
    into v_stage, v_nome, v_won, v_lost
    from public.deals d
    left join public.pipeline_stages s on s.id = d.stage_id
   where d.id = new.deal_id;

  if v_stage is null then return null; end if;

  -- Ganho e perdido não voltam sozinhos para o funil. Reabrir um lead perdido é
  -- decisão de gente.
  if v_won or v_lost then return null; end if;

  -- Contato efetivo: alguém do outro lado apareceu. Reunião marcada conta —
  -- ninguém agenda reunião sem ter falado com a empresa.
  v_efetivo := coalesce(new.outcome in ('atendeu', 'respondeu', 'realizada'), false)
               or coalesce(new.meeting_status in ('agendada', 'realizada'), false);

  if v_efetivo then
    if v_nome not in ('Leads Novos', 'Sem Contato') then return null; end if;
    select id into v_destino from public.pipeline_stages where name = 'Contato Feito';
  else
    if v_nome <> 'Leads Novos' then return null; end if;
    select id into v_destino from public.pipeline_stages where name = 'Sem Contato';
  end if;

  if v_destino is null or v_destino = v_stage then return null; end if;

  -- stage_changed_at vai junto: sem ele o "dias parado" do card contaria a partir
  -- da entrada na etapa antiga.
  perform set_config('app.mov_automatica', 'on', true);
  update public.deals
     set stage_id = v_destino,
         stage_changed_at = now()
   where id = new.deal_id;
  perform set_config('app.mov_automatica', 'off', true);

  return null;
end;
$$;

comment on function public.fn_etapa_automatica() is
  'Move o lead de Leads Novos para Sem Contato na primeira tentativa, e para Contato Feito no primeiro contato efetivo. Nunca move de Contato Feito em diante, nem lead ganho ou perdido.';

drop trigger if exists trg_etapa_automatica on public.deal_activities;
create trigger trg_etapa_automatica
  after insert on public.deal_activities
  for each row execute function public.fn_etapa_automatica();


-- =============================================================================
-- 3. BACKFILL — os 422 leads já tocados que ficaram em "Leads Novos"
-- =============================================================================
-- O trigger só age em atividade NOVA. Estes leads já foram trabalhados antes
-- desta migration e continuariam fora da esteira para sempre.
--
-- O destino de cada um segue a mesma regra: quem já teve contato efetivo vai
-- para "Contato Feito"; o resto vai para "Sem Contato".

do $$
declare
  v_novos     uuid;
  v_sem       uuid;
  v_feito     uuid;
  v_qtd_sem   bigint;
  v_qtd_feito bigint;
begin
  select id into v_novos from public.pipeline_stages where name = 'Leads Novos';
  select id into v_sem   from public.pipeline_stages where name = 'Sem Contato';
  select id into v_feito from public.pipeline_stages where name = 'Contato Feito';

  if v_novos is null or v_sem is null or v_feito is null then
    raise exception 'Etapa não encontrada (Leads Novos / Sem Contato / Contato Feito). Confira os nomes antes de rodar.';
  end if;

  perform set_config('app.mov_automatica', 'on', true);

  -- 3.1 já falaram com alguém -> Contato Feito
  with alvo as (
    select d.id
      from public.deals d
     where d.stage_id = v_novos
       and exists (
         select 1 from public.deal_activities a
          where a.deal_id = d.id
            and (a.outcome in ('atendeu','respondeu','realizada')
                 or a.meeting_status in ('agendada','realizada'))
       )
  )
  update public.deals d
     set stage_id = v_feito, stage_changed_at = now()
    from alvo
   where d.id = alvo.id;
  get diagnostics v_qtd_feito = row_count;

  -- 3.2 só tentativas -> Sem Contato
  with alvo as (
    select d.id
      from public.deals d
     where d.stage_id = v_novos
       and exists (
         select 1 from public.deal_activities a
          where a.deal_id = d.id
            and a.channel <> 'nota'
       )
  )
  update public.deals d
     set stage_id = v_sem, stage_changed_at = now()
    from alvo
   where d.id = alvo.id;
  get diagnostics v_qtd_sem = row_count;

  perform set_config('app.mov_automatica', 'off', true);

  raise notice 'Backfill: % para Contato Feito, % para Sem Contato.', v_qtd_feito, v_qtd_sem;
end $$;

commit;

-- =============================================================================
-- CONFERÊNCIA (rodar depois do commit)
-- =============================================================================
-- Distribuição das etapas:
--   select s.order_index, s.name, s.in_followup,
--          (select count(*) from public.deals d where d.stage_id = s.id) as leads
--     from public.pipeline_stages s order by s.order_index;
--
-- Nenhum lead tocado pode continuar em "Leads Novos" (tem que dar 0):
--   select count(*) from public.deals d
--    join public.pipeline_stages s on s.id = d.stage_id
--   where s.name = 'Leads Novos'
--     and exists (select 1 from public.deal_activities a
--                  where a.deal_id = d.id and a.channel <> 'nota');
--
-- O backfill não pode ter creditado movimentação a ninguém:
--   select origem, count(*) from public.deal_stage_history
--    where changed_at > now() - interval '10 minutes' group by 1;
--   -- espera-se tudo em 'sistema'
--
-- Teste do trigger, num lead de "Leads Novos" à sua escolha:
--   insert into public.deal_activities (deal_id, author_id, channel, outcome, occurred_at)
--   values ('<uuid do lead>', auth.uid(), 'telefone', 'nao_atendeu', now());
--   -- o lead tem que estar em "Sem Contato" logo depois

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- begin;
--   drop trigger if exists trg_etapa_automatica on public.deal_activities;
--   drop function if exists public.fn_etapa_automatica();
--   -- e reexecutar fn_stage_history_mudanca de 20260819_0002_stage_history.sql
--   -- Os leads movidos NÃO voltam sozinhos: se quiser desfazer, use
--   -- deal_stage_history (origem = 'sistema', changed_at da janela) para
--   -- reconstruir o stage_id anterior de cada um.
-- commit;
