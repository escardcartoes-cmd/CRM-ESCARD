-- Suporte ao coletor de notícias (Cloudflare Worker, service_role). Aditivo. APLICADA em 10/09/2026.
create table if not exists escard.intel_coleta (
  deal_id        uuid primary key references public.deals(id) on delete cascade,
  ultima_coleta  timestamptz not null default now(),
  noticias       integer not null default 0
);
alter table escard.intel_coleta enable row level security;
revoke all on escard.intel_coleta from anon, authenticated;

create or replace view public.vw_intel_alvos_coleta as
  select d.id as deal_id, d.razao_social, regexp_replace(coalesce(d.cnpj,''),'\D','','g') as cnpj, c.tier, ic.ultima_coleta
  from public.deals d
  join escard.deal_classificacao c on c.deal_id = d.id
  join public.pipeline_stages s on s.id = d.stage_id
  left join escard.intel_coleta ic on ic.deal_id = d.id
  where c.tier in ('S','A')
    and coalesce(s.is_won,false) = false and coalesce(s.is_lost,false) = false
    and d.razao_social is not null and length(trim(d.razao_social)) >= 6
    and (ic.ultima_coleta is null or ic.ultima_coleta < now() - interval '14 days')
  order by ic.ultima_coleta nulls first, c.tier, d.id;
revoke all on public.vw_intel_alvos_coleta from anon, authenticated;
grant select on public.vw_intel_alvos_coleta to service_role;

create or replace function public.fn_intel_registrar_sinal(
  p_cnpj text, p_deal_id uuid, p_municipio text, p_cnae_divisao text,
  p_categoria text, p_tipo text, p_descricao text, p_fonte text, p_url text,
  p_data_evento date, p_peso int, p_expira_em date, p_hash text
) returns text language plpgsql security definer set search_path = public, escard as $$
begin
  insert into escard.sinais_mercado (cnpj, deal_id, municipio, cnae_divisao, categoria, tipo, descricao, fonte, url, data_evento, peso, expira_em, hash)
  values (nullif(p_cnpj,''), p_deal_id, nullif(p_municipio,''), nullif(p_cnae_divisao,''), p_categoria, p_tipo,
          left(p_descricao, 300), p_fonte, p_url, p_data_evento, greatest(0, least(20, p_peso)), p_expira_em, p_hash)
  on conflict (hash) do nothing;
  if found then return 'inserido'; else return 'duplicado'; end if;
end; $$;
revoke all on function public.fn_intel_registrar_sinal(text,uuid,text,text,text,text,text,text,text,date,int,date,text) from public, anon, authenticated;
grant execute on function public.fn_intel_registrar_sinal(text,uuid,text,text,text,text,text,text,text,date,int,date,text) to service_role;

create or replace function public.fn_intel_marcar_coleta(p_deal_id uuid, p_noticias int)
returns void language sql security definer set search_path = public, escard as $$
  insert into escard.intel_coleta (deal_id, ultima_coleta, noticias) values (p_deal_id, now(), coalesce(p_noticias,0))
  on conflict (deal_id) do update set ultima_coleta = now(), noticias = excluded.noticias;
$$;
revoke all on function public.fn_intel_marcar_coleta(uuid,int) from public, anon, authenticated;
grant execute on function public.fn_intel_marcar_coleta(uuid,int) to service_role;
