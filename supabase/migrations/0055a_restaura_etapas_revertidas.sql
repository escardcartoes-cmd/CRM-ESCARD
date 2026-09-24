-- 0055a — Restaura os leads que o "Salvar" do modal devolveu à etapa anterior
-- Rodar DEPOIS da 0055. Seções separadas: executar uma por vez.

-- ============================================================
-- SEÇÃO 1 — BACKUP
-- ============================================================
create table if not exists public.bkp_reversao_etapa_20260924 as
with h as (
  select h.*,
         lag(h.origem)        over w as prev_origem,
         lag(h.changed_at)    over w as prev_at,
         lag(h.from_stage_id) over w as prev_from,
         lag(h.to_stage_id)   over w as prev_to,
         row_number() over (partition by h.deal_id order by h.changed_at desc) as rn
    from public.deal_stage_history h
  window w as (partition by h.deal_id order by h.changed_at)
)
select d.id,
       d.stage_id            as stage_atual,
       d.stage_changed_at    as stage_changed_at_atual,
       d.next_followup_date  as followup_atual,
       d.loss_reason         as motivo_atual,
       h.prev_to             as stage_correta,
       h.prev_at             as movido_pelo_sistema_em,
       (select (a.campos->'next_followup_date'->>'de')::date
          from public.audit_log a
         where a.tabela = 'deals' and a.registro_id = d.id
           and a.created_at = h.changed_at and a.campos ? 'stage_id'
         limit 1)            as followup_perdido,
       now()                 as salvo_em
  from h
  join public.deals d on d.id = h.deal_id and d.stage_id = h.to_stage_id
 where h.rn = 1
   and h.origem = 'app'
   and h.prev_origem = 'sistema'
   and h.to_stage_id = h.prev_from
   and h.changed_at - h.prev_at < interval '10 minutes';

alter table public.bkp_reversao_etapa_20260924 enable row level security;
revoke all on public.bkp_reversao_etapa_20260924 from anon, authenticated;

-- ============================================================
-- SEÇÃO 2 — CONFERÊNCIA (antes de restaurar)
-- ============================================================
-- select a.name atual, c.name vai_para, count(*), count(b.followup_perdido) com_followup
--   from public.bkp_reversao_etapa_20260924 b
--   join public.pipeline_stages a on a.id = b.stage_atual
--   join public.pipeline_stages c on c.id = b.stage_correta
--  group by 1,2 order by 3 desc;

-- ============================================================
-- SEÇÃO 3 — RESTAURAÇÃO
-- Mesma regra do trigger 0041: 4+ tentativas sem contato efetivo -> Perdidos.
-- Marcada como 'sistema' (não credita vendedor).
-- ============================================================
do $$
declare v_perdidos uuid;
begin
  select id into v_perdidos from public.pipeline_stages where is_lost order by order_index limit 1;
  perform set_config('app.mov_automatica', 'on', true);

  with t as (
    select b.*,
      (select count(*) from public.deal_activities x
        where x.deal_id = b.id and x.channel in ('telefone','whatsapp','email')
          and x.occurred_at > coalesce((select max(y.occurred_at) from public.deal_activities y
                                         where y.deal_id = b.id
                                           and (y.outcome in ('atendeu','respondeu','realizada')
                                                or y.meeting_status in ('agendada','realizada'))),
                                       '-infinity'::timestamptz)) as tentativas
      from public.bkp_reversao_etapa_20260924 b
  )
  update public.deals d
     set stage_id           = case when t.tentativas >= 4 and v_perdidos is not null
                                   then v_perdidos else t.stage_correta end,
         stage_changed_at   = t.movido_pelo_sistema_em,
         next_followup_date = case when t.tentativas >= 4 then null else t.followup_perdido end,
         loss_reason        = case when t.tentativas >= 4
                                   then coalesce(nullif(d.loss_reason,''), 'Sem resposta')
                                   else d.loss_reason end
    from t
   where d.id = t.id
     and d.stage_id = t.stage_atual;   -- não mexe em quem já foi movido desde o backup

  perform set_config('app.mov_automatica', 'off', true);
end $$;

-- Conferência pós:
-- select s.name, count(*) from public.deals d
--   join public.bkp_reversao_etapa_20260924 b on b.id = d.id
--   join public.pipeline_stages s on s.id = d.stage_id group by 1;
