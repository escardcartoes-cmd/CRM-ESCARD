-- =============================================================================
-- MIGRATION 20260828_0019 — Desempenho: uma varredura e os índices que faltavam
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0018
-- =============================================================================
-- O SINTOMA
--
--   canceling statement due to statement timeout
--
-- Todo o Relatório caiu depois da 0018. O erro apareceu na tela porque o bloco
-- de erro passou a mostrar a mensagem real — antes disso teria sido um vermelho
-- mudo e uma hora de F12.
--
-- A CAUSA, QUE FOI MINHA
--
-- A 0018 separou esforço de carteira criando DOIS CTEs — `ativ` (por autor) e
-- `ativ_dono` (por dono). Cada um varria `deal_activities` join `deals` de novo,
-- na mesma janela. Custo dobrado numa função que já era a mais pesada do
-- sistema, e ela passou do statement_timeout.
--
-- A CORREÇÃO
--
--   1. UMA varredura (`ativ_janela`), dois recortes em cima dela.
--      `as materialized` é obrigatório: sem isso o Postgres faz inline do CTE em
--      cada uso e volta a varrer duas vezes — o padrão desde a versão 12.
--
--   2. Os índices que nunca existiram. `coalesce(occurred_at, created_at)` é
--      expressão: sem índice sobre a expressão, toda janela de período é
--      sequential scan na tabela inteira. Isso já era assim antes da 0018 — a
--      0018 só tornou visível ao dobrar o trabalho.
--
-- Índice não muda resultado, só tempo. A função continua devolvendo exatamente
-- as mesmas chaves.
-- =============================================================================

begin;

-- =============================================================================
-- 1. ÍNDICES
-- =============================================================================
-- A janela de período do relatório filtra por coalesce(occurred_at, created_at).
-- É a condição de TODA consulta de atividade no sistema.
create index if not exists deal_activities_quando_idx
  on public.deal_activities ((coalesce(occurred_at, created_at)));

-- Desde a 0018 o esforço é filtrado por author_id. Sem índice, cada relatório de
-- vendedor varria a tabela inteira.
create index if not exists deal_activities_author_quando_idx
  on public.deal_activities (author_id, (coalesce(occurred_at, created_at)));

-- Reunião é sempre filtrada por channel antes de qualquer coisa. Índice parcial:
-- fica pequeno porque só indexa o canal presencial.
create index if not exists deal_activities_presencial_idx
  on public.deal_activities ((coalesce(occurred_at, created_at)))
  where channel = 'presencial';

-- serie_ligacoes e os KPIs de ligação filtram por channel = 'telefone'.
create index if not exists deal_activities_telefone_idx
  on public.deal_activities (author_id, (coalesce(occurred_at, created_at)))
  where channel = 'telefone';

-- =============================================================================
-- 2. rel_metricas — uma varredura em vez de duas
-- =============================================================================

create or replace function public.rel_metricas(
  p_de    date,
  p_ate   date,
  p_owner uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner    uuid    := p_owner;
  -- Fuso: a janela do relatorio e o dia civil de Sao Paulo (0013).
  v_ini      timestamptz := (p_de::timestamp        at time zone 'America/Sao_Paulo');
  v_fim      timestamptz := ((p_ate + 1)::timestamp at time zone 'America/Sao_Paulo');
  v_dorm     integer := public.app_setting_int('lead_dormente_dias', 14);
  v_result   jsonb;
begin
  if p_de is null or p_ate is null or p_ate < p_de then
    raise exception 'Período inválido.' using errcode = '22023';
  end if;

  with carteira as (
    select d.id, d.owner_id, d.next_followup_date, d.created_at
      from public.deals d
      join public.pipeline_stages s on s.id = d.stage_id
     where not coalesce(s.is_won, false)
       and not coalesce(s.is_lost, false)
       and (v_owner is null or d.owner_id = v_owner)
  ),
  -- UMA varredura da janela, dois recortes em cima dela.
  -- A 0018 tinha criado `ativ` e `ativ_dono` como dois CTEs independentes, cada
  -- um varrendo deal_activities + deals de novo. Dobrou o custo da função e ela
  -- passou a estourar o statement_timeout do Supabase.
  -- `as materialized` é obrigatório: sem isso o Postgres faz inline do CTE nos
  -- dois usos e volta a varrer duas vezes.
  ativ_janela as materialized (
    select a.deal_id, a.channel, a.outcome, a.author_id,
           d.owner_id as dono,
           coalesce(a.occurred_at, a.created_at) as quando
      from public.deal_activities a
      join public.deals d on d.id = a.deal_id
     where coalesce(a.occurred_at, a.created_at) >= v_ini
       and coalesce(a.occurred_at, a.created_at) <  v_fim
  ),
  -- ESFORÇO: quem EXECUTOU o contato. Ligar num lead de outra pessoa credita a
  -- ligação a quem discou, não à dona do lead.
  ativ as (
    select deal_id, channel, outcome, author_id, quando
      from ativ_janela
     where v_owner is null or author_id = v_owner
  ),
  -- CARTEIRA: leads DO DONO que receberam algum toque, de quem quer que seja.
  -- É o que sustenta "trabalhados", cobertura e alcance.
  ativ_dono as (
    select deal_id, outcome
      from ativ_janela
     where v_owner is null or dono = v_owner
  ),
  -- Reunião reaproveita a mesma varredura. meeting_status não está no CTE
  -- materializado (só ele precisa), então volta à tabela — mas já filtrado por
  -- channel, que é um subconjunto pequeno.
  reuni as (
    select coalesce(a.meeting_status,
                    case a.outcome
                      when 'realizada'      then 'realizada'
                      when 'nao_compareceu' then 'nao_compareceu'
                    end) as situacao
      from public.deal_activities a
      join public.deals d on d.id = a.deal_id
     where a.channel = 'presencial'
       and coalesce(a.occurred_at, a.created_at) >= v_ini
       and coalesce(a.occurred_at, a.created_at) <  v_fim
       and (v_owner is null or a.author_id = v_owner)
  ),
  enriq as (
    select distinct a.registro_id as deal_id
      from public.audit_log a
      join public.deals d on d.id = a.registro_id
     where a.tabela = 'deals'
       and a.acao   = 'UPDATE'
       and a.actor_id is not null
       and a.created_at >= v_ini and a.created_at < v_fim
       and a.campos ?| array['contact_name','contact_phone','contact_email',
                             'whatsapp','cnpj','company_id','contact_id','value','city']
       and (v_owner is null or d.owner_id = v_owner)
  ),
  movim as (
    select distinct h.deal_id
      from public.deal_stage_history h
     where h.origem = 'app'
       and h.changed_at >= v_ini and h.changed_at < v_fim
       and (v_owner is null or h.owner_id = v_owner)
  ),
  tocados as (
    select deal_id from ativ_dono
    union
    select deal_id from enriq
    union
    select deal_id from movim
  ),
  ativ_carteira as (
    select t.deal_id from tocados t join carteira c on c.id = t.deal_id
  ),
  ultimo_toque as (
    select c.id,
           (select max(coalesce(a.occurred_at, a.created_at))
              from public.deal_activities a where a.deal_id = c.id) as ultima
      from carteira c
  ),
  primeiro_contato as (
    select d.id,
           extract(epoch from (
             (select min(coalesce(a.occurred_at, a.created_at))
                from public.deal_activities a where a.deal_id = d.id) - d.created_at
           )) / 3600.0 as horas
      from public.deals d
     where d.created_at >= v_ini and d.created_at < v_fim
       and (v_owner is null or d.owner_id = v_owner)
  ),
  desfecho as (
    select h.deal_id, s.is_won, s.is_lost, h.changed_at, d.value, d.created_at
      from public.deal_stage_history h
      join public.pipeline_stages s on s.id = h.to_stage_id
      join public.deals d           on d.id = h.deal_id
     where h.changed_at >= v_ini and h.changed_at < v_fim
       and h.origem <> 'baseline'
       and (coalesce(s.is_won, false) or coalesce(s.is_lost, false))
       and (v_owner is null or h.owner_id = v_owner)
  )
  select jsonb_build_object(
    'periodo',            jsonb_build_object('de', p_de, 'ate', p_ate, 'dias', (p_ate - p_de) + 1),
    'carteira',           (select count(*) from carteira),
    'trabalhados',        (select count(*) from tocados),
    'contatados',         (select count(distinct deal_id) from ativ_dono),
    'enriquecidos',       (select count(*) from enriq),
    'movimentados',       (select count(*) from movim),
    'trabalhados_carteira',(select count(*) from ativ_carteira),
    'cobertura_pct',      case when (select count(*) from carteira) = 0 then 0
                            else round(100.0 * (select count(*) from ativ_carteira)
                                       / (select count(*) from carteira), 1) end,
    'primeiro_contato_h', (select round(avg(horas)::numeric, 1) from primeiro_contato where horas is not null),
    'leads_criados',      (select count(*) from public.deals d
                            where d.created_at >= v_ini and d.created_at < v_fim
                              and (v_owner is null or d.owner_id = v_owner)),
    'followup_em_dia_pct',case when (select count(*) from carteira) = 0 then 0
                            else round(100.0 * (select count(*) from carteira
                                                 where next_followup_date >= (now() at time zone 'America/Sao_Paulo')::date)
                                       / (select count(*) from carteira), 1) end,
    'dormentes',          (select count(*) from ultimo_toque u
                            where coalesce(u.ultima, (select created_at from carteira c where c.id = u.id))
                                  < now() - make_interval(days => v_dorm)),
    'dormentes_dias',     v_dorm,
    'ganhos',             (select count(*) from desfecho where is_won),
    'perdidos',           (select count(*) from desfecho where is_lost),
    'conversao_pct',      case when (select count(*) from desfecho) = 0 then 0
                            else round(100.0 * (select count(*) from desfecho where is_won)
                                       / (select count(*) from desfecho), 1) end,
    'valor_ganho',        coalesce((select sum(value) from desfecho where is_won), 0),
    'ciclo_medio_dias',   (select round(avg(extract(epoch from (changed_at - created_at)) / 86400.0)::numeric, 1)
                             from desfecho where is_won),
    'atividades',         (select count(*) from ativ),
    'atividades_efetivas',(select count(*) from ativ where outcome in ('atendeu','respondeu')),
    'taxa_efetiva_pct',   case when (select count(*) from ativ) = 0 then 0
                            else round(100.0 * (select count(*) from ativ where outcome in ('atendeu','respondeu'))
                                       / (select count(*) from ativ), 1) end,
    'contatos_invalidos', (select count(distinct deal_id) from ativ_dono
                            where outcome in ('numero_errado','numero_invalido')),
    -- ---- ligações e alcance (novo em 0011) ----
    'ligacoes',           (select count(*) from ativ where channel = 'telefone'),
    'ligacoes_atendidas', (select count(*) from ativ where channel = 'telefone' and outcome = 'atendeu'),
    'ligacoes_taxa_pct',  case when (select count(*) from ativ where channel = 'telefone') = 0 then null
                            else round(100.0 * (select count(*) from ativ where channel = 'telefone' and outcome = 'atendeu')
                                       / (select count(*) from ativ where channel = 'telefone'), 1) end,
    'alcancados',         (select count(distinct deal_id) from ativ_dono
                            where outcome in ('atendeu','respondeu','realizada')),
    'alcance_pct',        case when (select count(*) from carteira) = 0 then 0
                            else round(100.0 * (select count(distinct a.deal_id) from ativ_dono a
                                                  join carteira c on c.id = a.deal_id
                                                 where a.outcome in ('atendeu','respondeu','realizada'))
                                       / (select count(*) from carteira), 1) end,
    -- -------------------------------------------
    'reunioes_agendadas',     (select count(*) from reuni where situacao = 'agendada'),
    'reunioes_realizadas',    (select count(*) from reuni where situacao = 'realizada'),
    'reunioes_nao_realizadas',(select count(*) from reuni where situacao = 'nao_compareceu'),
    'reunioes_canceladas',    (select count(*) from reuni where situacao = 'cancelada'),
    'reunioes_taxa_pct',  case when (select count(*) from reuni where situacao in ('realizada','nao_compareceu')) = 0 then null
                            else round(100.0 * (select count(*) from reuni where situacao = 'realizada')
                                       / (select count(*) from reuni where situacao in ('realizada','nao_compareceu')), 1) end,
    'por_canal',          coalesce((select jsonb_object_agg(coalesce(channel,'(sem canal)'), n)
                                      from (select channel, count(*) n from ativ group by 1) x), '{}'::jsonb),
    'por_desfecho',       coalesce((select jsonb_object_agg(coalesce(outcome,'(sem registro)'), n)
                                      from (select outcome, count(*) n from ativ group by 1) x), '{}'::jsonb),
    'motivos_perda',      coalesce((select jsonb_object_agg(coalesce(lr,'(não preenchido)'), n)
                                      from (select coalesce(d.loss_reason,'(não preenchido)') lr, count(*) n
                                              from desfecho f join public.deals d on d.id = f.deal_id
                                             where f.is_lost group by 1) x), '{}'::jsonb),
    'top_municipios',     coalesce((select jsonb_agg(jsonb_build_object('city', city, 'leads', n) order by n desc)
                                      from (select c.city, count(*) n
                                              from carteira ca join public.deals c on c.id = ca.id
                                             where c.city is not null group by 1 order by 2 desc limit 10) x), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

commit;

-- =============================================================================
-- CONFERÊNCIA
-- =============================================================================
-- Os índices existem:
--   select indexname from pg_indexes
--    where tablename = 'deal_activities' and indexname like 'deal_activities_%'
--    order by 1;
--
-- O tempo da função (vestindo a identidade de um admin real — ela exige
-- auth.uid()). Antes disso estourava o timeout; agora tem que responder rápido:
--   begin;
--     set local role authenticated;
--     set local request.jwt.claims = '{"sub":"<uuid de um admin>"}';
--     explain analyze select public.relatorio_produtividade(current_date - 30, current_date, null);
--   rollback;
--
-- O CTE está mesmo materializado (uma varredura, não duas): procure por
-- "CTE ativ_janela" aparecendo UMA vez no plano acima.

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- Os índices podem ficar — não mudam resultado, só tempo.
-- Para voltar a função:
--   reexecutar o bloco de rel_metricas de 20260828_0018_esforco_por_autor.sql
--
-- begin;
--   drop index if exists public.deal_activities_quando_idx;
--   drop index if exists public.deal_activities_author_quando_idx;
--   drop index if exists public.deal_activities_presencial_idx;
--   drop index if exists public.deal_activities_telefone_idx;
-- commit;
