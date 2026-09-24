-- 0048 — Follow-up: lead com "Número errado" (ou "Número inválido") no histórico sai da fila (regra de Roberto, 24/09/2026).
-- Exceção: se DEPOIS do número errado houve contato efetivo (atendeu / respondeu / reunião realizada), o lead volta,
-- porque alguém achou o número certo e falou com o cliente.
-- Sai da Esteira, de todos os cards e dos contadores. Continua no Kanban.
-- Sobre a 0047 (mesma assinatura; grants e p_cidade preservados). APLICADA EM PRODUÇÃO via MCP.
-- ROLLBACK: reaplicar 0047_followup_somente_com_atividade.sql.

CREATE OR REPLACE FUNCTION public.followups_list(p_filtro text DEFAULT 'esteira'::text, p_busca text DEFAULT NULL::text, p_owner uuid DEFAULT NULL::uuid, p_min_dias integer DEFAULT 0, p_stage uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_lista text DEFAULT NULL::text, p_sem_lista boolean DEFAULT false, p_cidade text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, title text, contact_name text, contact_phone text, whatsapp text, contact_email text, value numeric, stage_id uuid, stage_name text, owner_id uuid, owner_name text, next_followup_date date, ultima_atividade timestamp with time zone, dias_parado integer, total_atividades bigint, total_registros bigint, quente boolean, quente_em timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with base as materialized (
    select
      d.*,
      s.name as stage_name,
      p.full_name as owner_name,
      ag.ultima_atividade,
      coalesce(ag.total_atividades, 0) as total_atividades,
      extract(day from
        (now() at time zone 'America/Sao_Paulo')
        - coalesce(
            ag.ultimo_efetivo at time zone 'America/Sao_Paulo',
            d.stage_changed_at at time zone 'America/Sao_Paulo',
            d.created_at at time zone 'America/Sao_Paulo'
          )
      )::int as dias_parado
    from public.pipeline_stages s
    join public.deals d on d.stage_id = s.id
    left join public.profiles p on p.id = d.owner_id
    left join lateral (
      select max(a.occurred_at) as ultima_atividade,
             count(*)          as total_atividades,
             max(a.occurred_at) filter (
               where a.outcome in ('atendeu','respondeu','realizada')
             ) as ultimo_efetivo
        from public.deal_activities a
       where a.deal_id = d.id
    ) ag on true
    where coalesce(ag.total_atividades, 0) > 0   -- 0047: sem atividade não é follow-up
      -- 0048: número errado/inválido sem contato efetivo posterior não é follow-up
      and not exists (
        select 1 from public.deal_activities e
         where e.deal_id = d.id
           and e.outcome in ('numero_errado','numero_invalido')
           and not exists (
             select 1 from public.deal_activities k
              where k.deal_id = d.id
                and k.outcome in ('atendeu','respondeu','realizada')
                and k.occurred_at > e.occurred_at
           )
      )
      and (s.in_followup = true or d.quente = true)
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
      and (p_cidade is null or p_cidade = '' or d.city = p_cidade)
  ),
  filtrado as (
    select * from base
    where (quente = true or dias_parado >= coalesce(p_min_dias, 0))
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
    count(*) over () as total_registros,
    f.quente, f.quente_em
  from filtrado f
  order by f.quente desc, f.dias_parado desc, f.next_followup_date asc nulls last
  limit p_limit offset p_offset;
$function$;

CREATE OR REPLACE FUNCTION public.followups_contadores(p_owner uuid DEFAULT NULL::uuid, p_min_dias integer DEFAULT 0, p_stage uuid DEFAULT NULL::uuid, p_lista text DEFAULT NULL::text, p_sem_lista boolean DEFAULT false, p_cidade text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
  base as materialized (
    select
      d.next_followup_date,
      d.stage_id,
      d.quente,
      s.name as stage_name,
      s.order_index,
      extract(day from
        (now() at time zone 'America/Sao_Paulo')
        - coalesce(
            ef.ultimo_efetivo at time zone 'America/Sao_Paulo',
            d.stage_changed_at at time zone 'America/Sao_Paulo',
            d.created_at at time zone 'America/Sao_Paulo'
          )
      )::int as dias_parado
    from public.pipeline_stages s
    join public.deals d on d.stage_id = s.id
    left join lateral (
      select max(a.occurred_at) as ultimo_efetivo
        from public.deal_activities a
       where a.deal_id = d.id
         and a.outcome in ('atendeu','respondeu','realizada')
    ) ef on true
    where exists (select 1 from public.deal_activities x where x.deal_id = d.id)   -- 0047
      -- 0048: número errado/inválido sem contato efetivo posterior não é follow-up
      and not exists (
        select 1 from public.deal_activities e
         where e.deal_id = d.id
           and e.outcome in ('numero_errado','numero_invalido')
           and not exists (
             select 1 from public.deal_activities k
              where k.deal_id = d.id
                and k.outcome in ('atendeu','respondeu','realizada')
                and k.occurred_at > e.occurred_at
           )
      )
      and (s.in_followup = true or d.quente = true)
      and s.is_won = false
      and s.is_lost = false
      and (p_owner is null or d.owner_id = p_owner)
      and (case when p_sem_lista      then d.lista_origem is null
                when p_lista is null  then true
                else d.lista_origem = p_lista end)
      and (p_cidade is null or p_cidade = '' or d.city = p_cidade)
  ),
  no_periodo as (
    select * from base where quente = true or dias_parado >= coalesce(p_min_dias, 0)
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

