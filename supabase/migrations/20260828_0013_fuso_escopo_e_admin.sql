-- =============================================================================
-- MIGRATION 20260828_0013 — Fuso de São Paulo, escopo da série e admin excluído
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0012
-- =============================================================================
-- Três correções, todas de leitura errada do próprio dado. Nenhuma assinatura de
-- função muda: são `create or replace` puros, sem `drop`, sem risco de sobrecarga.
--
-- 1. FUSO HORÁRIO
--    As RPCs de follow-up (0010/0011) convertem explicitamente com
--    `at time zone 'America/Sao_Paulo'`. As de relatório e metas não convertiam
--    nada — resolviam `date -> timestamptz` pelo TimeZone da sessão, que no
--    PostgREST do Supabase é UTC. A janela "de hoje" ia de ontem 21:00 a hoje
--    21:00 BRT: SDR que liga às 22h via a meta diária em zero.
--    A conversão explícita é idempotente: se a sessão já estiver em
--    America/Sao_Paulo, o resultado é exatamente o mesmo de antes.
--
-- 2. ESCOPO DA SÉRIE DIÁRIA
--    Em `serie_atividades`, o filtro de vendedor estava no WHERE de um LEFT JOIN.
--    Acertava "nenhuma atividade no dia" (aí `a.id is null` salvava a linha) e
--    errava "atividade só de outro vendedor": as linhas entravam no join,
--    falhavam no WHERE, o grupo não era gerado e o dia SUMIA do retorno.
--    Efeito: gráfico individual com 30 pontos num período de 31 dias, e a soma
--    das séries individuais não batendo com a série da equipe.
--
-- 3. ADMIN EXCLUÍDO
--    `audit_usuario_e_admin()` checa `role` e `active`, mas não `deleted_at` —
--    e o único fluxo de exclusão do produto grava só `deleted_at`. Admin
--    "excluído" mantinha escrita total e leitura da trilha inteira.
--    `is_admin()` tem o mesmo defeito, mas NÃO está versionada neste repositório:
--    o passo 4 é manual e está documentado no fim do arquivo.
-- =============================================================================

begin;

-- =============================================================================
-- 1. serie_atividades — fuso de São Paulo e filtro de vendedor no lugar certo
-- =============================================================================
-- O filtro sai do WHERE e vira um CTE aplicado ANTES do generate_series. Assim o
-- dia sem atividade do vendedor volta como zero, que é o que o gráfico precisa.
-- O bucket do dia passa a ser o dia civil de São Paulo.

create or replace function public.serie_atividades(
  p_de    date,
  p_ate   date,
  p_owner uuid default null
)
returns table (dia date, total bigint, efetivas bigint)
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
  with ativ as (
    select (coalesce(a.occurred_at, a.created_at)
              at time zone 'America/Sao_Paulo')::date as d,
           a.id,
           a.outcome
      from public.deal_activities a
      join public.deals dl on dl.id = a.deal_id
     where (v_owner is null or dl.owner_id = v_owner)
       and (coalesce(a.occurred_at, a.created_at)
              at time zone 'America/Sao_Paulo')::date between p_de and p_ate
  )
  select g.d::date,
         count(t.id),
         count(t.id) filter (where t.outcome in ('atendeu','respondeu'))
    from generate_series(p_de, p_ate, interval '1 day') g(d)
    left join ativ t on t.d = g.d::date
   group by g.d
   order by g.d;
end;
$$;

comment on function public.serie_atividades(date, date, uuid) is
  'Série diária de atividades no fuso de São Paulo. Dia sem atividade do vendedor volta como zero.';

-- =============================================================================
-- 2. rel_metricas — janela do relatório no fuso de São Paulo
-- =============================================================================
-- Corpo idêntico ao da 0011. Mudam apenas v_ini/v_fim e o current_date do
-- cálculo de followup_em_dia_pct.

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
  -- Fuso: a janela do relatorio e o dia civil de Sao Paulo, nao o dia UTC
  -- da sessao do PostgREST. Sem isso, tudo registrado depois das 21h cai no
  -- dia seguinte. Se a sessao ja estiver em America/Sao_Paulo, e no-op.
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
-- 3. metas_progresso — hoje / semana / mês no calendário de São Paulo
-- =============================================================================
-- Corpo idêntico ao da 0009. Muda apenas a CTE `janela`, que passa a usar v_hoje.

create or replace function public.metas_progresso(p_owner uuid default null::uuid)
 returns table(owner_id uuid, vendedor text, indicador text, periodicidade text, meta numeric, realizado numeric, pct numeric)
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_owner uuid := public.rel_owner_efetivo(p_owner);
  -- Hoje / esta semana / este mes sao os do calendario de Sao Paulo.
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
-- 4. PASSO MANUAL — audit_usuario_e_admin() e is_admin()
-- =============================================================================
-- `audit_usuario_e_admin()` está versionada (0001) e pode ser substituída à
-- vontade. `is_admin()` NÃO está — ela existe só no banco. Antes de tocá-la,
-- rode e confira o corpo atual:
--
--   select p.proname, pg_get_functiondef(p.oid)
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.proname in ('is_admin','audit_usuario_e_admin');
--
-- Se o corpo de is_admin() for equivalente ao de audit_usuario_e_admin(), aplique
-- o bloco abaixo. Se fizer algo a mais, acrescente só a linha do deleted_at ao
-- corpo real em vez de substituí-lo inteiro.

begin;

create or replace function public.audit_usuario_e_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.profiles p
     where p.id = auth.uid()
       and p.role = 'admin'
       and coalesce(p.active, true)
       and p.deleted_at is null      -- soft-delete tem que revogar privilégio
  );
$$;

comment on function public.audit_usuario_e_admin() is
  'True se o usuário autenticado é admin ativo e não excluído. Usada nas policies de auditoria.';

-- Descomente SOMENTE depois de conferir o corpo real de is_admin():
-- create or replace function public.is_admin()
-- returns boolean
-- language sql
-- stable
-- security definer
-- set search_path = public, pg_temp
-- as $$
--   select exists (
--     select 1
--       from public.profiles p
--      where p.id = auth.uid()
--        and p.role = 'admin'
--        and coalesce(p.active, true)
--        and p.deleted_at is null
--   );
-- $$;

commit;

-- =============================================================================
-- CONFERÊNCIA (rodar depois do commit)
-- =============================================================================
-- Fuso da sessão — se voltar UTC, a correção 1 era necessária:
--   show timezone;
--
-- A série não pode mais ter buraco: o count tem que ser igual ao nº de dias.
--   select count(*) from public.serie_atividades(current_date - 30, current_date, null);
--
-- Meta diária de hoje, comparada com a contagem crua no fuso local:
--   select * from public.metas_progresso(null) where periodicidade = 'diaria';
--
-- Admin excluído não passa mais:
--   select public.audit_usuario_e_admin();

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- Reexecutar, nesta ordem, os blocos originais:
--   serie_atividades  -> 20260819_0003_relatorios.sql
--   rel_metricas      -> 20260828_0011_ligacoes_e_contato_efetivo.sql
--   metas_progresso   -> 20260827_0009_lista_origem_e_reuniao.sql
--   audit_usuario_e_admin -> 20260819_0001_auditoria_base.sql
-- Nenhuma assinatura mudou, então é replace direto.
