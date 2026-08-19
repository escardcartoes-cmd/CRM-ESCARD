-- =============================================================================
-- MIGRATION 20260819_0001 — Fundação de auditoria e telemetria de uso
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- =============================================================================
-- Escopo desta migration:
--   1. Tabela app_settings          — parâmetros operacionais editáveis pelo admin
--   2. Tabela audit_log             — trilha imutável de alterações de dados
--   3. Tabela system_events         — trilha de uso do sistema (login, export, etc.)
--   4. Trigger genérico fn_audit()  — anexado às tabelas de negócio existentes
--   5. Blindagem append-only        — trilha não pode ser editada nem apagada
--   6. RLS                          — leitura restrita a admin
--   7. RPC registrar_evento()       — único caminho de escrita em system_events
--   8. Purga automática (18 meses)  — via pg_cron
--
-- NÃO altera nenhuma tabela existente. NÃO altera index.html.
-- Risco de regressão: limitado à latência de INSERT/UPDATE nas tabelas auditadas.
-- Idempotente: pode ser executada mais de uma vez sem efeito colateral.
-- =============================================================================

begin;

-- =============================================================================
-- 0. HELPER — identificação de admin
-- =============================================================================
-- Nome propositalmente específico para não colidir com função já existente.
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
  );
$$;

comment on function public.audit_usuario_e_admin() is
  'Retorna true se o usuário autenticado é admin ativo. Usada nas policies de auditoria.';


-- =============================================================================
-- 1. APP_SETTINGS — parâmetros operacionais
-- =============================================================================
create table if not exists public.app_settings (
  chave        text        primary key,
  valor        jsonb       not null,
  descricao    text        not null,
  updated_at   timestamptz not null default now(),
  updated_by   uuid        references public.profiles(id) on delete set null
);

comment on table public.app_settings is
  'Parâmetros operacionais do CRM. Evita constante mágica espalhada em código e RPC.';

insert into public.app_settings (chave, valor, descricao) values
  ('lead_dormente_dias',        '14'::jsonb,    'Dias sem atividade para um lead ser considerado dormente.'),
  ('auditoria_retencao_meses',  '18'::jsonb,    'Meses de retenção da trilha de auditoria antes da purga automática.'),
  ('sla_primeiro_contato_horas','24'::jsonb,    'Prazo alvo entre a criação do lead e o primeiro contato registrado.'),
  ('ranking_aberto_vendedor',   'false'::jsonb, 'Se false, o vendedor vê apenas os próprios números e a média da equipe.')
on conflict (chave) do nothing;

-- Leitura livre para autenticado (são parâmetros de comportamento, não segredo).
-- Escrita apenas para admin.
alter table public.app_settings enable row level security;

drop policy if exists app_settings_select on public.app_settings;
create policy app_settings_select on public.app_settings
  for select to authenticated using (true);

drop policy if exists app_settings_update on public.app_settings;
create policy app_settings_update on public.app_settings
  for update to authenticated
  using (public.audit_usuario_e_admin())
  with check (public.audit_usuario_e_admin());

-- Leitor tipado, para as RPCs de relatório não repetirem cast.
create or replace function public.app_setting_int(p_chave text, p_padrao integer)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select (valor #>> '{}')::integer from public.app_settings where chave = p_chave), p_padrao);
$$;


-- =============================================================================
-- 2. AUDIT_LOG — trilha de alterações
-- =============================================================================
create table if not exists public.audit_log (
  id             bigint generated always as identity primary key,
  tabela         text        not null,
  registro_id    uuid,
  acao           text        not null check (acao in ('INSERT','UPDATE','DELETE')),
  rotulo         text,                       -- descrição legível do registro afetado
  actor_id       uuid,                       -- null = operação de sistema/integração
  txid           bigint      not null,       -- agrupa operações em lote na mesma transação
  campos         jsonb,                      -- {campo: {de: ..., para: ...}} apenas no UPDATE
  dados          jsonb,                      -- linha completa no INSERT e no DELETE
  created_at     timestamptz not null default now()
);

comment on table public.audit_log is
  'Trilha imutável de alterações de dados. Append-only: UPDATE e DELETE bloqueados por trigger.';
comment on column public.audit_log.txid is
  'ID da transação. Operações em lote (import, transferência em massa) compartilham o mesmo txid.';
comment on column public.audit_log.campos is
  'No UPDATE guarda somente os campos que mudaram — reduz volume em ~80% frente à linha inteira.';

create index if not exists idx_audit_log_created      on public.audit_log (created_at desc);
create index if not exists idx_audit_log_actor        on public.audit_log (actor_id, created_at desc);
create index if not exists idx_audit_log_registro     on public.audit_log (tabela, registro_id, created_at desc);
create index if not exists idx_audit_log_txid         on public.audit_log (txid);


-- =============================================================================
-- 3. SYSTEM_EVENTS — trilha de uso
-- =============================================================================
create table if not exists public.system_events (
  id           bigint generated always as identity primary key,
  actor_id     uuid,
  event_type   text        not null check (event_type in (
                 'login','logout','page_view','search','export','import',
                 'deal_open','bulk_transfer','password_reset'
               )),
  entidade     text,
  entidade_id  uuid,
  metadata     jsonb       not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);

comment on table public.system_events is
  'Eventos de uso do sistema. Escrita exclusivamente via RPC registrar_evento().';

create index if not exists idx_system_events_actor on public.system_events (actor_id, created_at desc);
create index if not exists idx_system_events_tipo  on public.system_events (event_type, created_at desc);
create index if not exists idx_system_events_data  on public.system_events (created_at desc);


-- =============================================================================
-- 4. TRIGGER GENÉRICO DE AUDITORIA
-- =============================================================================
create or replace function public.fn_audit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_old     jsonb;
  v_new     jsonb;
  v_campos  jsonb := '{}'::jsonb;
  v_chave   text;
  v_rotulo  text;
  v_id      uuid;
begin
  if tg_op = 'INSERT' then
    v_new := to_jsonb(new);

  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);

    for v_chave in select jsonb_object_keys(v_new) loop
      if (v_new -> v_chave) is distinct from (v_old -> v_chave) then
        v_campos := v_campos || jsonb_build_object(
          v_chave,
          jsonb_build_object('de', v_old -> v_chave, 'para', v_new -> v_chave)
        );
      end if;
    end loop;

    -- UPDATE que não alterou nada de fato não entra na trilha.
    if v_campos = '{}'::jsonb then
      return null;
    end if;

  else -- DELETE
    v_old := to_jsonb(old);
  end if;

  -- Rótulo legível: primeira coluna descritiva encontrada.
  v_rotulo := coalesce(
    coalesce(v_new, v_old) ->> 'title',
    coalesce(v_new, v_old) ->> 'full_name',
    coalesce(v_new, v_old) ->> 'name',
    coalesce(v_new, v_old) ->> 'nome',
    coalesce(v_new, v_old) ->> 'email'
  );

  begin
    v_id := (coalesce(v_new, v_old) ->> 'id')::uuid;
  exception when others then
    v_id := null;  -- tabela com PK não-UUID: registra sem o vínculo
  end;

  insert into public.audit_log (tabela, registro_id, acao, rotulo, actor_id, txid, campos, dados)
  values (
    tg_table_name,
    v_id,
    tg_op,
    v_rotulo,
    auth.uid(),
    txid_current(),
    case when tg_op = 'UPDATE' then v_campos else null end,
    case when tg_op = 'INSERT' then v_new
         when tg_op = 'DELETE' then v_old
         else null end
  );

  return null;  -- trigger AFTER: valor de retorno é ignorado
end;
$$;

comment on function public.fn_audit() is
  'Trigger genérico de auditoria. Grava apenas os campos alterados no UPDATE e a linha completa em INSERT/DELETE.';


-- Anexa o trigger somente às tabelas que realmente existem no schema.
-- Evita que a migration falhe se alguma tabela tiver outro nome.
do $anexa$
declare
  v_tabela text;
  v_alvos  text[] := array['deals','profiles','companies','contacts','deal_activities','deal_notes','pipeline_stages'];
begin
  foreach v_tabela in array v_alvos loop
    if to_regclass('public.' || v_tabela) is not null then
      execute format('drop trigger if exists trg_audit_%1$s on public.%1$I', v_tabela);
      execute format(
        'create trigger trg_audit_%1$s
           after insert or update or delete on public.%1$I
           for each row execute function public.fn_audit()',
        v_tabela
      );
      raise notice 'Auditoria anexada em public.%', v_tabela;
    else
      raise notice 'Tabela public.% não existe — ignorada', v_tabela;
    end if;
  end loop;
end;
$anexa$;


-- =============================================================================
-- 5. BLINDAGEM APPEND-ONLY
-- =============================================================================
-- Trilha que pode ser editada não é trilha. A única exceção é a purga por
-- retenção, que sinaliza a intenção via app.purga_auditoria = 'on'.
create or replace function public.fn_bloquear_alteracao_trilha()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('app.purga_auditoria', true), 'off') = 'on' then
    return null;
  end if;
  raise exception
    'A trilha de auditoria é imutável: % em % não é permitido.', tg_op, tg_table_name
    using errcode = '42501';
end;
$$;

drop trigger if exists trg_audit_log_imutavel on public.audit_log;
create trigger trg_audit_log_imutavel
  before update or delete on public.audit_log
  for each statement execute function public.fn_bloquear_alteracao_trilha();

drop trigger if exists trg_system_events_imutavel on public.system_events;
create trigger trg_system_events_imutavel
  before update or delete on public.system_events
  for each statement execute function public.fn_bloquear_alteracao_trilha();

-- TRUNCATE não é coberto por trigger de UPDATE/DELETE: precisa de gatilho próprio.
drop trigger if exists trg_audit_log_truncate on public.audit_log;
create trigger trg_audit_log_truncate
  before truncate on public.audit_log
  for each statement execute function public.fn_bloquear_alteracao_trilha();

drop trigger if exists trg_system_events_truncate on public.system_events;
create trigger trg_system_events_truncate
  before truncate on public.system_events
  for each statement execute function public.fn_bloquear_alteracao_trilha();

-- Cinto e suspensório: além do trigger, remove o privilégio.
revoke insert, update, delete, truncate on public.audit_log     from anon, authenticated;
revoke insert, update, delete, truncate on public.system_events from anon, authenticated;


-- =============================================================================
-- 6. RLS — leitura restrita a admin
-- =============================================================================
alter table public.audit_log     enable row level security;
alter table public.system_events enable row level security;

drop policy if exists audit_log_select_admin on public.audit_log;
create policy audit_log_select_admin on public.audit_log
  for select to authenticated using (public.audit_usuario_e_admin());

drop policy if exists system_events_select_admin on public.system_events;
create policy system_events_select_admin on public.system_events
  for select to authenticated using (public.audit_usuario_e_admin());

-- Sem policy de INSERT: a escrita ocorre por função SECURITY DEFINER,
-- executada pelo owner da tabela, que não é submetido à RLS.


-- =============================================================================
-- 7. RPC — registro de evento de uso
-- =============================================================================
create or replace function public.registrar_evento(
  p_event_type  text,
  p_entidade    text    default null,
  p_entidade_id uuid    default null,
  p_metadata    jsonb   default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Evento de uso exige usuário autenticado.' using errcode = '42501';
  end if;

  if p_event_type not in (
    'login','logout','page_view','search','export','import',
    'deal_open','bulk_transfer','password_reset'
  ) then
    raise exception 'Tipo de evento inválido: %', p_event_type using errcode = '22023';
  end if;

  -- Limite defensivo: metadata não é depósito de payload.
  if length(p_metadata::text) > 4000 then
    raise exception 'Metadata excede o limite de 4000 caracteres.' using errcode = '22001';
  end if;

  insert into public.system_events (actor_id, event_type, entidade, entidade_id, metadata)
  values (auth.uid(), p_event_type, p_entidade, p_entidade_id, coalesce(p_metadata, '{}'::jsonb));
end;
$$;

revoke all on function public.registrar_evento(text, text, uuid, jsonb) from public, anon;
grant execute on function public.registrar_evento(text, text, uuid, jsonb) to authenticated;


-- =============================================================================
-- 8. PURGA POR RETENÇÃO
-- =============================================================================
create or replace function public.fn_purgar_auditoria()
returns table (audit_removidos bigint, eventos_removidos bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_meses integer := public.app_setting_int('auditoria_retencao_meses', 18);
  v_corte timestamptz;
  v_a bigint;
  v_e bigint;
begin
  v_corte := now() - make_interval(months => v_meses);

  perform set_config('app.purga_auditoria', 'on', true);  -- válido só nesta transação

  delete from public.audit_log where created_at < v_corte;
  get diagnostics v_a = row_count;

  delete from public.system_events where created_at < v_corte;
  get diagnostics v_e = row_count;

  perform set_config('app.purga_auditoria', 'off', true);

  audit_removidos   := v_a;
  eventos_removidos := v_e;
  return next;
end;
$$;

revoke all on function public.fn_purgar_auditoria() from public, anon, authenticated;

-- Agendamento mensal. Se pg_cron não estiver habilitado, a migration segue
-- sem falhar e o agendamento deve ser feito pelo painel do Supabase.
do $cron$
begin
  if to_regnamespace('cron') is not null then
    perform cron.unschedule('purga_auditoria_crm')
      where exists (select 1 from cron.job where jobname = 'purga_auditoria_crm');
    perform cron.schedule(
      'purga_auditoria_crm',
      '0 4 1 * *',                       -- todo dia 1, 04:00 UTC
      'select public.fn_purgar_auditoria()'
    );
    raise notice 'Purga agendada via pg_cron.';
  else
    raise notice 'pg_cron não habilitado — agendar a purga manualmente no painel do Supabase.';
  end if;
end;
$cron$;

commit;

-- =============================================================================
-- ROLLBACK — executar apenas se for necessário reverter esta migration
-- =============================================================================
-- begin;
--   do $$
--   declare v_t text;
--   begin
--     foreach v_t in array array['deals','profiles','companies','contacts','deal_activities','deal_notes','pipeline_stages'] loop
--       if to_regclass('public.' || v_t) is not null then
--         execute format('drop trigger if exists trg_audit_%1$s on public.%1$I', v_t);
--       end if;
--     end loop;
--   end $$;
--   select cron.unschedule('purga_auditoria_crm');
--   drop function if exists public.fn_purgar_auditoria();
--   drop function if exists public.registrar_evento(text, text, uuid, jsonb);
--   drop function if exists public.fn_audit();
--   drop function if exists public.fn_bloquear_alteracao_trilha();
--   drop function if exists public.app_setting_int(text, integer);
--   drop table if exists public.system_events;
--   drop table if exists public.audit_log;
--   drop table if exists public.app_settings;
--   drop function if exists public.audit_usuario_e_admin();
-- commit;
