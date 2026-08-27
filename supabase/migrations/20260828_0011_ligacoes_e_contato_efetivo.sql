-- =============================================================================
-- MIGRATION 20260828_0011 — Volume de ligação e o conceito de contato efetivo
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0010
-- =============================================================================
-- Origem: "o SDR liga, marca Não atendeu, e isso tem que constar."
--
-- A tentativa SEMPRE constou — grava channel='telefone', outcome='nao_atendeu',
-- e entra na meta 'ligacoes', no total de atividades, nos gráficos por canal e
-- por desfecho, na série diária e na timeline. O que faltava era outra coisa:
--
--   1. O relatório não mostrava volume de ligação como NÚMERO em lugar nenhum.
--      Para saber quantas ligações a equipe fez era preciso ler uma barra.
--   2. "Leads trabalhados" trata tentativa e conversa como a mesma coisa. Uma
--      cobertura de 90% pode ser 90% de telefone tocando sem ninguém atender.
--   3. No Follow-up, ligar e não ser atendido zerava o "dias parado" e tirava o
--      lead da fila — sem ninguém ter falado com ele.
--
-- CONTATO EFETIVO, daqui em diante, é outcome in ('atendeu','respondeu',
-- 'realizada'): alguém do outro lado apareceu. Tentativa continua sendo
-- trabalho e continua contando em 'trabalhados'; ela só não vale mais como
-- alcance.
--
-- Nenhuma RPC muda de assinatura — as três são CREATE OR REPLACE puro, sem
-- drop, sem risco de sobrecarga.
-- =============================================================================

begin;

-- =============================================================================
-- 1. REL_METRICAS — volume de ligação e leads alcançados
-- =============================================================================
-- Corpo da 0009 com um CTE novo (nada) e cinco chaves novas no jsonb. Nada é
-- removido: 'trabalhados' e 'cobertura_pct' continuam significando exatamente o
-- que significavam. Quem quiser o número honesto de alcance usa 'alcancados'.
--
--   ligacoes            — tentativas de telefone no período (todas)
--   ligacoes_atendidas  — as que o cliente atendeu
--   ligacoes_taxa_pct   — atendidas ÷ tentativas (null se não houve tentativa)
--   alcancados          — leads distintos com contato EFETIVO no período
--   alcance_pct         — alcançados da carteira ÷ carteira
--
-- 'dormentes' NÃO muda de critério: continua "sem nenhuma atividade há N dias".
-- Mudá-lo junto inflaria a contagem de dormentes de um dia para o outro sem
-- que nada tivesse acontecido na operação. Se fizer sentido depois, é uma
-- linha — mas é decisão separada.
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
  v_ini      timestamptz := p_de::timestamptz;
  v_fim      timestamptz := (p_ate + 1)::timestamptz;
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
  ativ as (
    select a.deal_id, a.channel, a.outcome, coalesce(a.occurred_at, a.created_at) as quando
      from public.deal_activities a
      join public.deals d on d.id = a.deal_id
     where coalesce(a.occurred_at, a.created_at) >= v_ini
       and coalesce(a.occurred_at, a.created_at) <  v_fim
       and (v_owner is null or d.owner_id = v_owner)
  ),
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
       and (v_owner is null or d.owner_id = v_owner)
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
    select deal_id from ativ
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
    'contatados',         (select count(distinct deal_id) from ativ),
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
                                                 where next_followup_date >= current_date)
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
    'contatos_invalidos', (select count(distinct deal_id) from ativ
                            where outcome in ('numero_errado','numero_invalido')),
    -- ---- ligações e alcance (novo em 0011) ----
    'ligacoes',           (select count(*) from ativ where channel = 'telefone'),
    'ligacoes_atendidas', (select count(*) from ativ where channel = 'telefone' and outcome = 'atendeu'),
    'ligacoes_taxa_pct',  case when (select count(*) from ativ where channel = 'telefone') = 0 then null
                            else round(100.0 * (select count(*) from ativ where channel = 'telefone' and outcome = 'atendeu')
                                       / (select count(*) from ativ where channel = 'telefone'), 1) end,
    'alcancados',         (select count(distinct deal_id) from ativ
                            where outcome in ('atendeu','respondeu','realizada')),
    'alcance_pct',        case when (select count(*) from carteira) = 0 then 0
                            else round(100.0 * (select count(distinct a.deal_id) from ativ a
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


-- =============================================================================
-- 2. FOLLOW-UP — "dias parado" passa a medir dias sem CONTATO EFETIVO
-- =============================================================================
-- Antes: qualquer atividade zerava o contador. Ligar às 9h e o telefone tocar
-- no vazio tirava o lead da fila do "7+ dias parado" — o SDR perdia de vista
-- justamente o lead que ele não conseguiu falar.
--
-- Agora só zera quando alguém do outro lado apareceu.
--
-- 'ultima_atividade' e 'total_atividades' NÃO mudam: continuam contando toda
-- tentativa. É o que mostra o esforço na linha do lead. O que mudou é só o
-- critério do contador de dias.
--
-- Assinatura idêntica à da 0010 — CREATE OR REPLACE puro, sem drop.
create or replace function public.followups_list(
  p_filtro    text    default 'esteira'::text,
  p_busca     text    default null::text,
  p_owner     uuid    default null::uuid,
  p_min_dias  integer default 0,
  p_stage     uuid    default null::uuid,
  p_limit     integer default 50,
  p_offset    integer default 0,
  p_lista     text    default null::text,
  p_sem_lista boolean default false
)
returns table (
  id                uuid,
  title             text,
  contact_name      text,
  contact_phone     text,
  whatsapp          text,
  contact_email     text,
  value             numeric,
  stage_id          uuid,
  stage_name        text,
  owner_id          uuid,
  owner_name        text,
  next_followup_date date,
  ultima_atividade  timestamp with time zone,
  dias_parado       integer,
  total_atividades  bigint,
  total_registros   bigint
)
language sql
stable
set search_path to 'public'
as $function$
  with base as (
    select
      d.*,
      s.name as stage_name,
      p.full_name as owner_name,
      (select max(a.occurred_at) from public.deal_activities a
        where a.deal_id = d.id) as ultima_atividade,
      (select count(*) from public.deal_activities a
        where a.deal_id = d.id) as total_atividades,
      extract(day from
        (now() at time zone 'America/Sao_Paulo')
        - coalesce(
            (select max(a.occurred_at) from public.deal_activities a
              where a.deal_id = d.id
                and a.outcome in ('atendeu','respondeu','realizada')
            ) at time zone 'America/Sao_Paulo',
            d.stage_changed_at at time zone 'America/Sao_Paulo',
            d.created_at at time zone 'America/Sao_Paulo'
          )
      )::int as dias_parado
    from public.deals d
    join public.pipeline_stages s on s.id = d.stage_id
    left join public.profiles p on p.id = d.owner_id
    where s.in_followup = true
      and s.is_won = false
      and s.is_lost = false
      and (p_owner is null or d.owner_id = p_owner)
      and (p_stage is null or d.stage_id = p_stage)
      and (
        p_busca is null or p_busca = '' or
        d.title ilike '%' || p_busca || '%' or
        d.contact_name ilike '%' || p_busca || '%' or
        d.cnpj ilike '%' || p_busca || '%'
      )
      and (case when p_sem_lista      then d.lista_origem is null
                when p_lista is null  then true
                else d.lista_origem = p_lista end)
  ),
  filtrado as (
    select * from base
    where dias_parado >= coalesce(p_min_dias, 0)
      and case p_filtro
            when 'esteira'   then true
            when 'atrasados' then next_followup_date < (now() at time zone 'America/Sao_Paulo')::date
            when 'hoje'      then next_followup_date = (now() at time zone 'America/Sao_Paulo')::date
            when 'semana'    then next_followup_date between
                                    (now() at time zone 'America/Sao_Paulo')::date
                                and (now() at time zone 'America/Sao_Paulo')::date + 7
            when 'sem_passo' then next_followup_date is null
            else true
          end
  )
  select
    f.id, f.title, f.contact_name, f.contact_phone, f.whatsapp,
    f.contact_email, f.value, f.stage_id, f.stage_name,
    f.owner_id, f.owner_name, f.next_followup_date, f.ultima_atividade,
    f.dias_parado, f.total_atividades,
    count(*) over () as total_registros
  from filtrado f
  order by f.dias_parado desc, f.next_followup_date asc nulls last
  limit p_limit offset p_offset;
$function$;


create or replace function public.followups_contadores(
  p_owner     uuid    default null::uuid,
  p_min_dias  integer default 0,
  p_stage     uuid    default null::uuid,
  p_lista     text    default null::text,
  p_sem_lista boolean default false
)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
  base as (
    select
      d.next_followup_date,
      d.stage_id,
      s.name as stage_name,
      s.order_index,
      extract(day from
        (now() at time zone 'America/Sao_Paulo')
        - coalesce(
            (select max(a.occurred_at) from public.deal_activities a
              where a.deal_id = d.id
                and a.outcome in ('atendeu','respondeu','realizada')
            ) at time zone 'America/Sao_Paulo',
            d.stage_changed_at at time zone 'America/Sao_Paulo',
            d.created_at at time zone 'America/Sao_Paulo'
          )
      )::int as dias_parado
    from public.deals d
    join public.pipeline_stages s on s.id = d.stage_id
    where s.in_followup = true
      and s.is_won = false
      and s.is_lost = false
      and (p_owner is null or d.owner_id = p_owner)
      and (case when p_sem_lista      then d.lista_origem is null
                when p_lista is null  then true
                else d.lista_origem = p_lista end)
  ),
  no_periodo as (
    select * from base where dias_parado >= coalesce(p_min_dias, 0)
  ),
  com_etapa as (
    select * from no_periodo where (p_stage is null or stage_id = p_stage)
  )
  select jsonb_build_object(
    'esteira',   (select count(*) from com_etapa),
    'atrasados', (select count(*) from com_etapa where next_followup_date < (select d from hoje)),
    'hoje',      (select count(*) from com_etapa where next_followup_date = (select d from hoje)),
    'semana',    (select count(*) from com_etapa where next_followup_date between (select d from hoje) and (select d from hoje) + 7),
    'sem_passo', (select count(*) from com_etapa where next_followup_date is null),
    'por_etapa', (
      select coalesce(jsonb_object_agg(stage_id, jsonb_build_object(
               'nome', stage_name, 'ordem', order_index, 'total', qtd)), '{}'::jsonb)
      from (
        select stage_id, stage_name, order_index, count(*) as qtd
        from no_periodo
        group by stage_id, stage_name, order_index
      ) t
    )
  );
$function$;

commit;

-- =============================================================================
-- CONFERÊNCIA (rodar depois do commit)
-- =============================================================================
-- Ligações do mês e taxa de atendimento:
-- select public.rel_metricas(date_trunc('month', current_date)::date, current_date)
--        -> 'ligacoes' as tentativas,
--        public.rel_metricas(date_trunc('month', current_date)::date, current_date)
--        -> 'ligacoes_atendidas' as atendidas;
--
-- Trabalhados x alcançados (a diferença é o volume de tentativa sem resposta):
-- select (m -> 'trabalhados') as trabalhados, (m -> 'alcancados') as alcancados
--   from (select public.rel_metricas(date_trunc('month', current_date)::date, current_date) m) x;
--
-- Fila do follow-up com o novo critério:
-- select public.followups_contadores();

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- Reexecutar 20260827_0009 (rel_metricas) e 20260827_0010 (followups_list e
-- followups_contadores). Nenhuma assinatura mudou, então é replace direto.
