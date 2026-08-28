-- =============================================================================
-- MIGRATION 20260828_0018 — Esforço conta para quem executou, não para o dono
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0017
-- =============================================================================
-- O PROBLEMA
--
-- `rel_metricas`, `metas_progresso` e `serie_ligacoes` contavam ligação, e-mail,
-- WhatsApp e atividade filtrando pelo DONO DO LEAD (`deals.owner_id`), não por
-- quem registrou o contato (`deal_activities.author_id`).
--
-- Efeito: a vendedora liga para um lead que pertence a outra pessoa — coisa que
-- acontece o tempo todo quando ela retoma lead já contatado — e a ligação é
-- creditada à DONA DO LEAD. Quem discou não recebe nada. A meta diária dela
-- aparece zerada num dia em que ela trabalhou.
--
-- A INCONSISTÊNCIA JÁ ESTAVA DENTRO DA MESMA FUNÇÃO
--
-- Em `metas_progresso`, os ramos escritos depois (`conversas_efetivas`,
-- `reunioes`, `reunioes_nao_realizadas`) já usavam `a.author_id`. Os mais antigos
-- (`atividades`, `ligacoes`, `whatsapp`, `emails`) usavam `d.owner_id`. Dois
-- critérios convivendo no mesmo `case`. Esta migration uniformiza.
--
-- A REGRA, DAQUI EM DIANTE
--
--   ESFORÇO  -> conta para quem EXECUTOU  (deal_activities.author_id)
--     ligações, atendidas, taxa de atendimento, atividades, atividades efetivas,
--     por canal, por desfecho, reuniões, conversas efetivas, whatsapp, e-mails
--
--   CARTEIRA -> conta para o DONO DO LEAD  (deals.owner_id)
--     leads trabalhados, contatados, enriquecidos, movimentados, cobertura,
--     alcançados, alcance, dormentes, contatos inválidos, ganhos, valor ganho
--
-- A separação é a que a operação já pratica: a meta é de discagem (esforço), e a
-- cobertura é da carteira. Misturar as duas foi o que produziu vendedora com
-- meta zerada em dia trabalhado.
--
-- Nenhuma assinatura muda: os três são `create or replace` puros.
-- =============================================================================

begin;

-- =============================================================================
-- 1. rel_metricas — dois CTEs em vez de um
-- =============================================================================
-- Corpo da 0011 com o fuso da 0013. A mudança desta migration é o CTE `ativ`
-- passar a filtrar por autor e nascer um `ativ_dono` para o que é de carteira.

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
  -- ESFORÇO: quem EXECUTOU o contato (author_id). Antes filtrava pelo dono do
  -- lead, então ligar num lead de outra pessoa creditava a ligação a ela.
  ativ as (
    select a.deal_id, a.channel, a.outcome, a.author_id,
           coalesce(a.occurred_at, a.created_at) as quando
      from public.deal_activities a
      join public.deals d on d.id = a.deal_id
     where coalesce(a.occurred_at, a.created_at) >= v_ini
       and coalesce(a.occurred_at, a.created_at) <  v_fim
       and (v_owner is null or a.author_id = v_owner)
  ),
  -- CARTEIRA: leads DO DONO que receberam algum toque, de quem quer que seja.
  -- É o que sustenta "trabalhados", cobertura e alcance.
  ativ_dono as (
    select a.deal_id, a.outcome
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

-- =============================================================================
-- 2. metas_progresso — ramos de esforço por autor
-- =============================================================================
-- Corpo da 0009 com o v_hoje da 0013. Mudam os ramos `atividades`, `ligacoes`,
-- `whatsapp` e `emails`, que passam de `d.owner_id` para `a.author_id`.
-- `trabalhados` continua por dono — é carteira. `movimentacoes`, `ganhos` e
-- `valor_ganho` continuam por `h.owner_id`, que é o dono no momento do evento.

create or replace function public.metas_progresso(p_owner uuid default null::uuid)
 returns table(owner_id uuid, vendedor text, indicador text, periodicidade text, meta numeric, realizado numeric, pct numeric)
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_owner uuid := public.rel_owner_efetivo(p_owner);
  -- Hoje / semana / mes no calendario de Sao Paulo (0013).
  v_hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  return query
  with janela as (
    select 'diaria'::text  as p, v_hoje as ini, v_hoje + 1 as fim
    union all
    select 'semanal',      date_trunc('week',  v_hoje)::date, (date_trunc('week',  v_hoje) + interval '7 days')::date
    union all
    select 'mensal',       date_trunc('month', v_hoje)::date, (date_trunc('month', v_hoje) + interval '1 month')::date
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
            where a.author_id = b.owner_id
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
            where a.author_id = b.owner_id and a.channel = 'telefone'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'whatsapp' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where a.author_id = b.owner_id and a.channel = 'whatsapp'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'emails' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where a.author_id = b.owner_id and a.channel = 'email'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        -- Conversa efetiva: alguém do outro lado respondeu. É o indicador que
        -- distingue trabalho de discagem — meta só de volume produz ligação
        -- feita e desligada para bater número.
        when 'conversas_efetivas' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where a.author_id = b.owner_id
              and a.outcome in ('atendeu','respondeu')
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        -- Reunião: encontro presencial que aconteceu. Filtra por outcome
        -- 'realizada' para não contar no-show como resultado. Para contar
        -- toda reunião marcada, remover a linha do outcome abaixo.
        when 'reunioes' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where a.author_id = b.owner_id
              and a.channel = 'presencial'
              and a.outcome = 'realizada'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        -- Reunião marcada em que o cliente não apareceu. Meta de TETO.
        when 'reunioes_nao_realizadas' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where a.author_id = b.owner_id
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

-- =============================================================================
-- 3. serie_ligacoes — o gráfico de colunas segue a mesma regra
-- =============================================================================
-- A coluna do dia passa a ser de quem discou. Sem isso, o gráfico e a meta
-- diária contariam coisas diferentes na mesma tela.

create or replace function public.serie_ligacoes(
  p_de    date,
  p_ate   date,
  p_owner uuid default null
)
returns table (
  dia       date,
  owner_id  uuid,
  vendedor  text,
  ligacoes  bigint,
  atendidas bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid := public.rel_owner_efetivo(p_owner);
begin
  if p_de is null or p_ate is null or p_ate < p_de then
    raise exception 'Período inválido.' using errcode = '22023';
  end if;

  return query
  select (coalesce(a.occurred_at, a.created_at)
            at time zone 'America/Sao_Paulo')::date as dia,
         a.author_id                                as owner_id,
         coalesce(p.full_name, '—')                 as vendedor,
         count(*)                                   as ligacoes,
         count(*) filter (where a.outcome = 'atendeu') as atendidas
    from public.deal_activities a
    left join public.profiles p on p.id = a.author_id
   where a.channel = 'telefone'
     and (v_owner is null or a.author_id = v_owner)
     and (coalesce(a.occurred_at, a.created_at)
            at time zone 'America/Sao_Paulo')::date between p_de and p_ate
   group by 1, 2, 3
   order by 1, 3;
end;
$$;

comment on function public.serie_ligacoes(date, date, uuid) is
  'Ligações por dia e por QUEM DISCOU (author_id), no fuso de São Paulo. A coluna owner_id devolve o autor — o nome foi mantido para não quebrar o frontend.';

revoke all    on function public.serie_ligacoes(date, date, uuid) from public, anon;
grant execute on function public.serie_ligacoes(date, date, uuid) to authenticated;

commit;

-- =============================================================================
-- CONFERÊNCIA (rodar depois do commit)
-- =============================================================================
-- Quantas ligações foram feitas em lead de OUTRA pessoa neste mês — é o tamanho
-- exato do crédito que estava indo para o lugar errado:
--   select autor.full_name as quem_ligou, dono.full_name as dono_do_lead, count(*)
--     from public.deal_activities a
--     join public.deals d      on d.id = a.deal_id
--     left join public.profiles autor on autor.id = a.author_id
--     left join public.profiles dono  on dono.id  = d.owner_id
--    where a.channel = 'telefone'
--      and a.author_id is distinct from d.owner_id
--      and a.occurred_at >= date_trunc('month', now())
--    group by 1,2 order by 3 desc;
--
-- O total do mês não pode mudar (só a distribuição entre pessoas):
--   select sum(ligacoes) from public.serie_ligacoes(date_trunc('month', current_date)::date, current_date, null);
--
-- A meta diária de cada uma, com o novo critério:
--   select * from public.metas_progresso(null) where periodicidade = 'diaria';

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- Reexecutar, nesta ordem:
--   rel_metricas    -> 20260828_0013_fuso_escopo_e_admin.sql
--   metas_progresso -> 20260828_0013_fuso_escopo_e_admin.sql
--   serie_ligacoes  -> 20260828_0015_serie_ligacoes.sql
