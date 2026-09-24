-- 0050 — "Número errado" / "Número inválido" não contam como contato no Kanban (regra de Roberto, 24/09/2026).
-- Afeta: selo "Xd parado" (campo ultima_atividade) e a ordenação da coluna "Contato Feito".
-- Ligação para número errado não zera o "parado" nem joga o lead para o topo.
-- Continua contando como ESFORÇO (metas/ligações do dia) e como tentativa na regra dos 4 registros -> Perdidos.
-- Mesma assinatura e retorno da 0049: CREATE OR REPLACE (grants preservados). Sem mudança no index.html.
-- APLICADA EM PRODUÇÃO via MCP. ROLLBACK: reaplicar o CREATE da 0049 como CREATE OR REPLACE.

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
    -- subconsulta escalar (avaliada só após o LIMIT); 0050: número errado/inválido não conta
    (select max(a2.occurred_at)
       from public.deal_activities a2
      where a2.deal_id = d.id
        and a2.occurred_at <= now()
        and (a2.outcome is null or a2.outcome not in ('numero_errado','numero_invalido'))) as ultima_atividade
  from public.deals d
  cross join cfg
  left join public.profiles p on p.id = d.owner_id
  left join lateral (
    select max(a.occurred_at) as ult
    from public.deal_activities a
    where cfg.por_contato
      and a.deal_id = d.id
      and a.occurred_at <= now()
      and (a.outcome is null or a.outcome not in ('numero_errado','numero_invalido'))
  ) ua on true
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
    case when cfg.por_contato then greatest(ua.ult, d.stage_changed_at) end desc nulls last,
    case when cfg.por_contato then null else d.quente end desc nulls last,
    d.created_at desc,
    d.id
  limit p_limit offset p_offset;
$function$;

