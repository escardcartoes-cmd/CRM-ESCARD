-- 0051 — REGRA ÚNICA de "último contato" e "dias parado" para Kanban e Follow-up (24/09/2026).
--
-- Problema: cada tela tinha sua própria conta.
--   * Kanban (0049/0050): último registro qualquer — contava NOTA interna como contato.
--   * Follow-up (0011): só contato EFETIVO (atendeu/respondeu/realizada) e chamava isso de "sem contato".
--     E-mail enviado hoje aparecia como "90d sem contato".
--
-- Regra única (Roberto, 24/09):
--   Contato válido = qualquer registro de contato já ocorrido, EXCETO:
--     - nota interna (channel = 'nota')                 -> não é contato com o cliente
--     - número errado / número inválido                 -> não chegou ao cliente
--   ATENÇÃO: 'bounce' é o valor GRAVADO para o rótulo "Enviado" do e-mail (legado do front).
--   Ele CONTA como contato. (0051b corrigiu a primeira versão, que o excluía por engano.)
--   Dias parado = hoje - MAIS RECENTE entre (último contato válido, entrada na etapa).
--
-- Fonte única: public.fn_ultimo_contato(deal). Kanban, lista e contadores do Follow-up usam só ela.
-- Entrada no Follow-up (0047): passa a exigir ao menos um registro que NÃO seja nota.
-- Mantido: 0046 (quente só na Esteira), 0048 (número errado sai da fila), 0045 (ordem de Contato Feito),
--          p_cidade (0026), grants. Métricas de "contato efetivo" (metas, séries, relatório) NÃO mudam:
--          lá "efetivo" é KPI de conversa, e continua correto.
-- APLICADA EM PRODUÇÃO via MCP. ROLLBACK: reaplicar 0050 (kanban_cards) e 0048 (followups_*), depois
--          DROP FUNCTION public.fn_ultimo_contato(uuid).

CREATE OR REPLACE FUNCTION public.fn_ultimo_contato(p_deal uuid)
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select max(a.occurred_at)
    from public.deal_activities a
   where a.deal_id = p_deal
     and a.occurred_at <= now()
     and a.channel is distinct from 'nota'
     and (a.outcome is null
          or a.outcome not in ('numero_errado','numero_invalido'));
$function$;

REVOKE ALL ON FUNCTION public.fn_ultimo_contato(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_ultimo_contato(uuid) TO authenticated, service_role;

-- ------------------------------------------------------------------ Kanban
CREATE OR REPLACE FUNCTION public.kanban_cards(p_stage uuid, p_owner uuid DEFAULT NULL::uuid, p_busca text DEFAULT NULL::text, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_lista text DEFAULT NULL::text, p_sem_lista boolean DEFAULT false, p_cidade text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, title text, value numeric, contact_name text, expected_close_date date, next_followup_date date, stage_changed_at timestamp with time zone, loss_reason text, owner_id uuid, owner_name text, stage_id uuid, quente boolean, quente_em timestamp with time zone, ultima_atividade timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with cfg as (
    select exists (
      select 1 from public.pipeline_stages s
      where s.id = p_stage and lower(trim(s.name)) = 'contato feito'
    ) as por_contato
  )
  select
    d.id, d.title, d.value, d.contact_name,
    d.expected_close_date, d.next_followup_date, d.stage_changed_at,
    d.loss_reason, d.owner_id, p.full_name as owner_name, d.stage_id,
    d.quente, d.quente_em,
    public.fn_ultimo_contato(d.id) as ultima_atividade   -- nome mantido: o index.html lê este campo
  from public.deals d
  cross join cfg
  left join public.profiles p on p.id = d.owner_id
  where d.stage_id = p_stage
    and (p_owner is null or d.owner_id = p_owner)
    and (
      p_busca is null or p_busca = '' or
      d.title ilike '%' || p_busca || '%' or
      d.contact_name ilike '%' || p_busca || '%' or
      d.contact_email ilike '%' || p_busca || '%' or
      d.contact_phone ilike '%' || p_busca || '%'
    )
    and (case when p_sem_lista      then d.lista_origem is null
              when p_lista is null  then true
              else d.lista_origem = p_lista end)
    and (p_cidade is null or p_cidade = '' or d.city = p_cidade)
  order by
    case when cfg.por_contato then greatest(public.fn_ultimo_contato(d.id), d.stage_changed_at) end desc nulls last,
    case when cfg.por_contato then null else d.quente end desc nulls last,
    d.created_at desc,
    d.id
  limit p_limit offset p_offset;
$function$;

-- ------------------------------------------------------------------ Follow-up: lista
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
        - (greatest(public.fn_ultimo_contato(d.id), d.stage_changed_at, d.created_at)
             at time zone 'America/Sao_Paulo')
      )::int as dias_parado
    from public.pipeline_stages s
    join public.deals d on d.stage_id = s.id
    left join public.profiles p on p.id = d.owner_id
    left join lateral (
      select max(a.occurred_at) as ultima_atividade,
             count(*)          as total_atividades,
             count(*) filter (where a.channel is distinct from 'nota') as registros_contato
        from public.deal_activities a
       where a.deal_id = d.id
    ) ag on true
    where coalesce(ag.registros_contato, 0) > 0   -- 0047/0051: só lead já trabalhado (nota não conta)
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

-- ------------------------------------------------------------------ Follow-up: contadores
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
        - (greatest(public.fn_ultimo_contato(d.id), d.stage_changed_at, d.created_at)
             at time zone 'America/Sao_Paulo')
      )::int as dias_parado
    from public.pipeline_stages s
    join public.deals d on d.stage_id = s.id
    where exists (select 1 from public.deal_activities x
                   where x.deal_id = d.id and x.channel is distinct from 'nota')   -- 0047/0051
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
