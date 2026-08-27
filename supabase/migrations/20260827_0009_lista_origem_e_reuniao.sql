-- =============================================================================
-- MIGRATION 20260827_0009 — Etapa "Reunião", lista de origem e no-show contabilizado
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0008
-- =============================================================================
-- Três mudanças independentes. Cada seção pode ser rodada sozinha; nenhuma
-- depende da outra. Todas são aditivas ou reversíveis em uma linha.
--
--   1. pipeline_stages: "Qualificação" passa a se chamar "Reunião".
--   2. deals.lista_origem: nome da lista importada, gravado por lead.
--   3. rel_metricas: passa a devolver reunião realizada, não comparecida,
--      cancelada e a taxa de comparecimento do período.
--   4. metas: indicador 'reunioes_nao_realizadas' (teto, opcional — nasce em 0).
--
-- Nenhuma RPC muda de assinatura. Nenhum registro existente é apagado.
-- =============================================================================

begin;

-- =============================================================================
-- 1. ETAPA — Qualificação vira Reunião
-- =============================================================================
-- O nome da etapa é dado, não código: nada em index.html compara com a string
-- 'Qualificação'. A única etapa referenciada por nome no frontend é
-- 'Prospecção' (função etapaProspeccao), que não é tocada aqui.
--
-- Idempotente: rodar duas vezes não faz nada na segunda.
update public.pipeline_stages
   set name = 'Reunião'
 where name = 'Qualificação';


-- =============================================================================
-- 2. LISTA DE ORIGEM DO LEAD
-- =============================================================================
-- Sem isso, uma lista importada some no dia seguinte: o SDR não consegue
-- separar os 4.700 leads da lista da Receita dos 300 que vieram de indicação.
-- O campo é do lead, não da importação — lead que trocou de lista, ou que foi
-- classificado à mão depois, também precisa carregar a marca.
alter table public.deals add column if not exists lista_origem text;

comment on column public.deals.lista_origem is
  'Nome da lista de prospecção de onde o lead veio. Preenchido na importação e editável na ficha.';

-- Teto de tamanho: o campo é rótulo de filtro, não campo livre. 120 caracteres
-- cabe qualquer nome de arquivo real e impede que a lista do filtro vire lixo.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.deals'::regclass
       and conname  = 'deals_lista_origem_tamanho'
  ) then
    alter table public.deals
      add constraint deals_lista_origem_tamanho
      check (lista_origem is null or char_length(lista_origem) between 1 and 120);
  end if;
end $$;

-- Índice parcial: só as linhas que têm lista. O filtro do funil e a RPC abaixo
-- passam por aqui.
create index if not exists idx_deals_lista_origem
  on public.deals (lista_origem)
  where lista_origem is not null;


-- =============================================================================
-- 2.1 RPC — listas disponíveis para o seletor
-- =============================================================================
-- NÃO é security definer, de propósito: roda com a RLS de quem chamou. O
-- vendedor vê no seletor só as listas em que ele tem lead; o admin vê todas.
-- Uma função security definer aqui vazaria a existência de listas da equipe
-- inteira para qualquer vendedor.
create or replace function public.listas_importadas()
returns table (lista text, total bigint)
language sql
stable
set search_path = public, pg_temp
as $$
  select d.lista_origem, count(*)::bigint
    from public.deals d
   where d.lista_origem is not null
   group by d.lista_origem
   order by 2 desc, 1 asc;
$$;

comment on function public.listas_importadas() is
  'Listas de origem visíveis ao usuário atual, com a contagem de leads. Alimenta o seletor de filtro.';

revoke all on function public.listas_importadas() from public, anon;
grant execute on function public.listas_importadas() to authenticated;


-- =============================================================================
-- 3. REL_METRICAS — reunião que não aconteceu passa a ser contada
-- =============================================================================
-- Corpo idêntico ao da migration 0005, com um CTE novo (reuni) e quatro chaves
-- novas no jsonb de saída. Nada é removido: 'por_desfecho' e todo o resto
-- continuam vindo iguais, então o frontend antigo não quebra se o deploy do
-- index.html vier depois.
--
-- Definição de cada número:
--   reunioes_realizadas      — outcome 'realizada'
--   reunioes_nao_realizadas  — outcome 'nao_compareceu' (o cliente furou)
--   reunioes_canceladas      — meeting_status 'cancelada' (desmarcada antes)
--   reunioes_taxa_pct        — realizadas ÷ (realizadas + não comparecidas)
--
-- Cancelada fica FORA do denominador da taxa: reunião desmarcada com
-- antecedência não é falha de comparecimento, é reagendamento. Misturar as
-- duas produz uma taxa que pune o vendedor pelo que ele fez certo.
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
  -- Reuniões do período. Lê meeting_status quando existe e cai para o outcome
  -- nas linhas antigas de 'presencial', gravadas antes da migration 0008.
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
       and a.actor_id is not null          -- só alteração feita por pessoa
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
    -- ---- reuniões (novo em 0009) ----
    'reunioes_agendadas',     (select count(*) from reuni where situacao = 'agendada'),
    'reunioes_realizadas',    (select count(*) from reuni where situacao = 'realizada'),
    'reunioes_nao_realizadas',(select count(*) from reuni where situacao = 'nao_compareceu'),
    'reunioes_canceladas',    (select count(*) from reuni where situacao = 'cancelada'),
    'reunioes_taxa_pct',  case when (select count(*) from reuni where situacao in ('realizada','nao_compareceu')) = 0 then null
                            else round(100.0 * (select count(*) from reuni where situacao = 'realizada')
                                       / (select count(*) from reuni where situacao in ('realizada','nao_compareceu')), 1) end,
    -- ---------------------------------
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
-- 4. META DE TETO — 'reunioes_nao_realizadas'
-- =============================================================================
-- Nasce em 0 para todo mundo. metas_progresso só devolve linha com valor > 0,
-- então enquanto ninguém definir um teto, NADA muda em nenhuma tela.
--
-- Leia isto antes de definir um valor: esta é uma meta de TETO, não de alvo.
-- Ela sobe quando o desempenho piora. A barra de progresso do painel de metas
-- é a mesma dos outros indicadores — vai ficar verde quando o vendedor tiver
-- MUITO no-show. Se isso incomodar, o número honesto para acompanhar é a
-- 'reunioes_taxa_pct' do relatório, que já vem pronta na seção 3.
--
-- A meta 'reunioes' NÃO é alterada: continua contando só 'realizada'. Somar
-- no-show nela reescreveria o atingimento histórico de agosto para cima, sem
-- que ninguém tivesse feito nada diferente.
alter table public.metas drop constraint metas_indicador_check;

alter table public.metas add constraint metas_indicador_check check (
  indicador = any (array[
    'atividades'::text,
    'trabalhados'::text,
    'movimentacoes'::text,
    'ganhos'::text,
    'valor_ganho'::text,
    'ligacoes'::text,
    'whatsapp'::text,
    'emails'::text,
    'conversas_efetivas'::text,
    'reunioes'::text,
    'reunioes_nao_realizadas'::text
  ])
);

insert into public.metas (owner_id, indicador, periodicidade, valor)
select distinct m.owner_id, 'reunioes_nao_realizadas', m.periodicidade, 0
from public.metas m
on conflict (owner_id, indicador, periodicidade) do nothing;

-- metas_progresso: corpo idêntico ao da 0825_0007, com um único ramo novo.
create or replace function public.metas_progresso(p_owner uuid default null::uuid)
 returns table(owner_id uuid, vendedor text, indicador text, periodicidade text, meta numeric, realizado numeric, pct numeric)
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_owner uuid := public.rel_owner_efetivo(p_owner);
begin
  return query
  with janela as (
    select 'diaria'::text  as p, current_date                                  as ini, current_date + 1 as fim
    union all
    select 'semanal',      date_trunc('week',  current_date)::date, (date_trunc('week',  current_date) + interval '7 days')::date
    union all
    select 'mensal',       date_trunc('month', current_date)::date, (date_trunc('month', current_date) + interval '1 month')::date
  ),
  base as (
    select m.owner_id, p.full_name, m.indicador, m.periodicidade, m.valor, j.ini, j.fim
      from public.metas m
      join public.profiles p on p.id = m.owner_id
      join janela j on j.p = m.periodicidade
     where m.valor > 0
       and (v_owner is null or m.owner_id = v_owner)
  )
  select b.owner_id,
         b.full_name,
         b.indicador,
         b.periodicidade,
         b.valor,
         r.realizado,
         case when b.valor = 0 then 0 else round(100.0 * r.realizado / b.valor, 1) end
    from base b
    cross join lateral (
      select case b.indicador

        when 'atividades' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'trabalhados' then
          (select count(distinct a.deal_id)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'ligacoes' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id and a.channel = 'telefone'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'whatsapp' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id and a.channel = 'whatsapp'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'emails' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id and a.channel = 'email'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        -- Conversa efetiva: alguém do outro lado respondeu. É o indicador que
        -- distingue trabalho de discagem — meta só de volume produz ligação
        -- feita e desligada para bater número.
        when 'conversas_efetivas' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id
              and a.outcome in ('atendeu','respondeu')
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        -- Reunião: encontro presencial que aconteceu. Filtra por outcome
        -- 'realizada' para não contar no-show como resultado. Para contar
        -- toda reunião marcada, remover a linha do outcome abaixo.
        when 'reunioes' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id
              and a.channel = 'presencial'
              and a.outcome = 'realizada'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        -- Reunião marcada em que o cliente não apareceu. Meta de TETO.
        when 'reunioes_nao_realizadas' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id
              and a.channel = 'presencial'
              and a.outcome = 'nao_compareceu'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'movimentacoes' then
          (select count(*)::numeric from public.deal_stage_history h
            where h.owner_id = b.owner_id and h.origem = 'app'
              and h.changed_at >= b.ini and h.changed_at < b.fim)

        when 'ganhos' then
          (select count(*)::numeric from public.deal_stage_history h
             join public.pipeline_stages s on s.id = h.to_stage_id
            where h.owner_id = b.owner_id and coalesce(s.is_won, false)
              and h.origem <> 'baseline'
              and h.changed_at >= b.ini and h.changed_at < b.fim)

        when 'valor_ganho' then
          coalesce((select sum(d.value) from public.deal_stage_history h
             join public.pipeline_stages s on s.id = h.to_stage_id
             join public.deals d on d.id = h.deal_id
            where h.owner_id = b.owner_id and coalesce(s.is_won, false)
              and h.origem <> 'baseline'
              and h.changed_at >= b.ini and h.changed_at < b.fim), 0)

        else 0
      end as realizado
    ) r
   order by b.full_name, b.indicador, b.periodicidade;
end;
$function$;

commit;

-- =============================================================================
-- CONFERÊNCIA (rodar depois do commit)
-- =============================================================================
-- select name, order_index from public.pipeline_stages order by order_index;
-- select count(*) filter (where lista_origem is not null) as com_lista, count(*) from public.deals;
-- select * from public.listas_importadas();
-- select public.rel_metricas(date_trunc('month', current_date)::date, current_date) -> 'reunioes_taxa_pct';

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- begin;
--   update public.pipeline_stages set name = 'Qualificação' where name = 'Reunião';
--   drop function if exists public.listas_importadas();
--   drop index if exists public.idx_deals_lista_origem;
--   alter table public.deals drop constraint if exists deals_lista_origem_tamanho;
--   alter table public.deals drop column if exists lista_origem;
--   delete from public.metas where indicador = 'reunioes_nao_realizadas';
--   -- e reexecutar 20260819_0005 (rel_metricas) e 20260825_0007 (metas_progresso)
-- commit;
