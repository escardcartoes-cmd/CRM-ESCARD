-- =============================================================================
-- VERIFICAÇÃO PÓS-DEPLOY — migrations 0017 e 0018
-- Rodar inteiro no SQL Editor. Cada bloco tem o resultado esperado no comentário.
-- Só leitura, exceto o teste 2 (que faz rollback sozinho).
-- =============================================================================

-- 1) AS FUNÇÕES FORAM MESMO SUBSTITUÍDAS?
--    Esperado: as quatro linhas com 'ok'. Uma linha faltando = a migration não
--    chegou nessa função.
select 'rel_metricas'    as funcao,
       case when d ilike '%a.author_id = v_owner%' and d ilike '%ativ_dono%'
                 and d ilike '%America/Sao_Paulo%'                 then 'ok' else 'FALTOU' end as estado
  from (select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='rel_metricas') x
union all
select 'metas_progresso',
       case when d ilike '%a.author_id = b.owner_id%' and d ilike '%America/Sao_Paulo%'
            then 'ok' else 'FALTOU' end
  from (select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='metas_progresso') x
union all
select 'serie_ligacoes',
       case when d ilike '%a.author_id = v_owner%' then 'ok' else 'FALTOU' end
  from (select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='serie_ligacoes') x
union all
select 'fn_atividade_data_valida (trava)',
       case when d ilike '%presencial%' and d ilike '%interval ''5 minutes''%'
            then 'ok' else 'FALTOU' end
  from (select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='fn_atividade_data_valida') x;


-- 2) A TRAVA DE DATA FUNCIONA?
--    Esperado: a mensagem 'TRAVA OK'. Se aparecer 'TRAVA FALHOU', a 0017 não pegou.
--    Faz rollback sozinho — não grava nada.
do $$
declare v_deal uuid; v_ok boolean := false;
begin
  select id into v_deal from public.deals limit 1;
  if v_deal is null then raise notice 'Sem lead para testar.'; return; end if;
  begin
    insert into public.deal_activities (deal_id, channel, outcome, occurred_at)
    values (v_deal, 'telefone', 'nao_atendeu', now() + interval '3 days');
  exception when others then
    v_ok := true;
  end;
  raise notice '%', case when v_ok then 'TRAVA OK — data futura foi barrada' else 'TRAVA FALHOU — o insert passou' end;
  raise exception 'rollback proposital do teste';
exception when others then
  if sqlerrm <> 'rollback proposital do teste' then raise; end if;
end $$;


-- 3) QUANTOS REGISTROS COM DATA FUTURA AINDA EXISTEM?
--    Esperado: SÓ 'presencial' (reunião agendada é legítima).
--    Se aparecer telefone/email/whatsapp, a 0017b ainda não foi rodada — e essas
--    ligações continuam fora da meta do dia em que foram feitas.
select channel,
       count(*) as qtd,
       min(date(occurred_at at time zone 'America/Sao_Paulo')) as primeiro_dia,
       max(date(occurred_at at time zone 'America/Sao_Paulo')) as ultimo_dia
  from public.deal_activities
 where occurred_at > now()
 group by 1 order by 2 desc;


-- 4) O TAMANHO DO CRÉDITO QUE ESTAVA INDO PARA O LUGAR ERRADO
--    Ligações do mês feitas em lead de OUTRA pessoa. Antes da 0018, tudo isso
--    era creditado à coluna 'dono_do_lead'. Agora vai para 'quem_ligou'.
select coalesce(autor.full_name, '(sem autor)') as quem_ligou,
       coalesce(dono.full_name,  '(sem dono)')  as dono_do_lead,
       count(*) as ligacoes
  from public.deal_activities a
  join public.deals d           on d.id = a.deal_id
  left join public.profiles autor on autor.id = a.author_id
  left join public.profiles dono  on dono.id  = d.owner_id
 where a.channel = 'telefone'
   and a.author_id is distinct from d.owner_id
   and a.occurred_at >= date_trunc('month', now())
 group by 1,2 order by 3 desc;


-- 5) LIGAÇÕES DO MÊS: POR QUEM DISCOU vs POR DONO DO LEAD
--    As duas colunas juntas mostram quanto a leitura mudou para cada pessoa.
--    O total das duas tem que ser igual.
with por_autor as (
  select a.author_id as pid, count(*) n from public.deal_activities a
   where a.channel='telefone' and a.occurred_at >= date_trunc('month', now()) group by 1
), por_dono as (
  select d.owner_id as pid, count(*) n from public.deal_activities a
    join public.deals d on d.id = a.deal_id
   where a.channel='telefone' and a.occurred_at >= date_trunc('month', now()) group by 1
)
select coalesce(p.full_name, '(sem nome)') as pessoa,
       coalesce(aa.n, 0) as ligacoes_que_ela_fez,
       coalesce(dd.n, 0) as ligacoes_na_carteira_dela
  from public.profiles p
  left join por_autor aa on aa.pid = p.id
  left join por_dono  dd on dd.pid = p.id
 where coalesce(aa.n,0) + coalesce(dd.n,0) > 0
 order by 2 desc;


-- 6) A META DIÁRIA AGORA
--    É a tela que a Heloísa cobra às 17h. Compare com o painel.
select p.full_name, m.indicador, m.realizado, m.meta, m.pct
  from public.metas_progresso(null) m
  join public.profiles p on p.id = m.owner_id
 where m.periodicidade = 'diaria'
 order by 3 desc;


-- 7) O CASO QUE SOBROU: ligação registrada como "Nota"
--    Não conta em lugar nenhum. Se der mais que zero, é treinamento da equipe.
select count(*) as notas_que_parecem_ligacao
  from public.deal_activities
 where channel = 'nota'
   and (note ilike '%lig%' or note ilike '%telefon%' or note ilike '%caixa postal%'
        or note ilike '%não atend%' or note ilike '%nao atend%')
   and occurred_at >= date_trunc('month', now());
