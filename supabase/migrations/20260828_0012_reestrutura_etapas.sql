-- =============================================================================
-- MIGRATION 20260828_0012 — Reestruturação das etapas do funil
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0011
-- =============================================================================
-- ANTES                                    DEPOIS
--   1 Prospecção        12.067  (fora)       1 Leads Novos    12.890  (fora)
--   2 Novo Lead            823  (fila)       2 Sem Contato         0  (fila)
--   3 Contato Feito        774  (fila)       3 Contato Feito     774  (fila)
--   4 Reunião                5  (fila)       4 Reunião             5  (fila)
--   5 Proposta/Orçam.        0  (fila)       5 Negociação          1  (fila)
--   6 Negociação             1  (fila)       6 Fechado Ganho       1  (fila)
--   7 Fechado Ganho          1  (fila)       7 Perdidos          660  (fila)
--   8 Fechado Perdido      660  (fila)
--
-- POR QUE "LEADS NOVOS" FICA FORA DA FILA DE FOLLOW-UP
-- A Prospecção já era in_followup = false, e é isso que impede os 12 mil leads
-- importados de afogarem a esteira do SDR. Herdando esse comportamento, a fila
-- continua com ~1.440 itens trabalháveis em vez de saltar para ~12.900. Os 823
-- leads hoje em "Novo Lead" saem da esteira — passam a ser garimpados pelo
-- Kanban e pelo filtro de lista, não pela fila.
--
-- IDENTIFICAÇÃO POR NOME, NÃO POR UUID
-- A migration resolve os ids por nome dentro de blocos DO. Nenhum UUID fica
-- gravado aqui, e rodar duas vezes não faz estrago: cada bloco checa antes.
-- =============================================================================

begin;

-- =============================================================================
-- 1. LEADS NOVOS — Prospecção absorve Novo Lead
-- =============================================================================
-- Mantemos a linha da Prospecção (12.067 leads) e movemos os 823 de Novo Lead
-- para ela — 823 updates em vez de 12.067.
--
-- O histórico de Novo Lead (1.107 linhas) NÃO é descartado: é repontado para a
-- etapa unificada, porque a movimentação continua existindo, só que com outro
-- nome. Sem isso, o ON DELETE SET NULL da FK transformaria 1.107 movimentações
-- em "etapa desconhecida" nos relatórios.
--
-- A exceção são as transições ENTRE as duas etapas fundidas. Repontadas, elas
-- virariam "Leads Novos → Leads Novos" e inflariam a meta 'movimentacoes' com
-- um avanço de funil que deixou de existir. Essas linhas são removidas.
do $$
declare
  v_destino uuid;
  v_origem  uuid;
  v_circ    integer;
  v_hist    integer;
  v_deals   integer;
begin
  select id into v_destino from public.pipeline_stages where name = 'Prospecção';
  select id into v_origem  from public.pipeline_stages where name = 'Novo Lead';

  if v_destino is null or v_origem is null then
    raise notice 'Fusao ja aplicada ou etapas nao encontradas - nada a fazer.';
    return;
  end if;

  delete from public.deal_stage_history
   where (from_stage_id = v_origem  and to_stage_id = v_destino)
      or (from_stage_id = v_destino and to_stage_id = v_origem);
  get diagnostics v_circ = row_count;

  update public.deal_stage_history set to_stage_id   = v_destino where to_stage_id   = v_origem;
  get diagnostics v_hist = row_count;
  update public.deal_stage_history set from_stage_id = v_destino where from_stage_id = v_origem;

  -- stage_changed_at NAO e tocado: o lead nao avancou no funil, a etapa e que
  -- mudou de nome. Mexer no carimbo zeraria o "tempo parado" de 823 leads.
  update public.deals set stage_id = v_destino where stage_id = v_origem;
  get diagnostics v_deals = row_count;

  delete from public.pipeline_stages where id = v_origem;

  raise notice 'Fusao: % leads movidos, % linhas de historico repontadas, % circulares removidas.',
    v_deals, v_hist, v_circ;
end $$;

update public.pipeline_stages
   set name        = 'Leads Novos',
       in_followup = false
 where name = 'Prospecção';


-- =============================================================================
-- 2. PROPOSTA/ORÇAMENTO — apagada
-- =============================================================================
-- Tem 0 leads, então a FK deals.stage_id (NO ACTION) não bloqueia. As 8 linhas
-- de deal_stage_history perdem a referência via ON DELETE SET NULL — decisão
-- consciente: são 8 movimentações de uma etapa que a operação nunca usou.
--
-- A trava do 'if' cobre o caso de alguém ter movido um lead para lá entre a
-- leitura e a execução: com lead dentro, a migration para com mensagem clara
-- em vez de estourar a FK no meio da transação.
do $$
declare
  v_id    uuid;
  v_leads integer;
begin
  select id into v_id from public.pipeline_stages where name = 'Proposta/Orçamento';
  if v_id is null then
    raise notice 'Proposta/Orcamento ja removida.';
    return;
  end if;

  select count(*) into v_leads from public.deals where stage_id = v_id;
  if v_leads > 0 then
    raise exception 'Proposta/Orcamento tem % lead(s). Mova-os antes de apagar a etapa.', v_leads
      using errcode = '23503';
  end if;

  delete from public.pipeline_stages where id = v_id;
end $$;


-- =============================================================================
-- 3. PERDIDOS
-- =============================================================================
update public.pipeline_stages set name = 'Perdidos' where name = 'Fechado Perdido';


-- =============================================================================
-- 4. SEM CONTATO — etapa nova
-- =============================================================================
-- Onde o SDR joga quem ele tentou e não conseguiu falar. Dentro da fila de
-- follow-up de propósito: combinada com a 0011 (dias_parado só zera com contato
-- efetivo), vira a lista de rediscagem — o lead fica visível e o contador
-- continua correndo.
insert into public.pipeline_stages (name, order_index, is_won, is_lost, in_followup)
select 'Sem Contato', 0, false, false, true
 where not exists (select 1 from public.pipeline_stages where name = 'Sem Contato');


-- =============================================================================
-- 5. ORDEM DAS COLUNAS
-- =============================================================================
update public.pipeline_stages s
   set order_index = v.ordem
  from (values
    ('Leads Novos',    1),
    ('Sem Contato',    2),
    ('Contato Feito',  3),
    ('Reunião',        4),
    ('Negociação',     5),
    ('Fechado Ganho',  6),
    ('Perdidos',       7)
  ) as v(nome, ordem)
 where s.name = v.nome;

commit;

-- =============================================================================
-- CONFERÊNCIA (rodar depois do commit)
-- =============================================================================
-- select s.order_index, s.name, s.is_won, s.is_lost, s.in_followup,
--        (select count(*) from public.deals d where d.stage_id = s.id) as leads
--   from public.pipeline_stages s order by s.order_index;
--
-- select count(*) as leads_orfaos from public.deals d
--  where not exists (select 1 from public.pipeline_stages s where s.id = d.stage_id);
--
-- select public.followups_contadores();

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- Parcial. Os renomes voltam; a fusão e a exclusão NÃO voltam sozinhas — os 823
-- leads não sabem mais de qual etapa vieram. Restauração completa só por backup
-- do Supabase (Database > Backups), ponto no tempo anterior a esta migration.
