-- supabase/migrations/20260826_0008_agenda_reunioes.sql
-- Agenda de reuniões: registrar reunião MARCADA (data futura), presencial ou
-- online, e acompanhar o desfecho até Realizada / Não compareceu / Cancelada.
--
-- Decisão de modelagem: estende deal_activities em vez de criar tabela nova.
--   * A reunião JÁ é uma atividade do canal 'presencial' (canal existente).
--   * occurred_at passa a ser a data/hora DA REUNIÃO — para reunião marcada,
--     uma data futura. É o mesmo eixo que a timeline e os relatórios já usam.
--   * A meta 'reunioes' (migration 20260825_0007) conta presencial + outcome
--     'realizada'. Continua funcionando sem uma linha de alteração.
--   * reassign_deals_to_admin() já reatribui deal_activities.author_id.
--     Nada a mudar lá.
--
-- Sobre outcome NULL em 'presencial': a constraint resultado_valido é uma
-- disjunção; para channel='presencial' com outcome NULL o ramo avalia NULL e o
-- CHECK aceita (CHECK só rejeita FALSE). Reunião marcada ainda sem desfecho
-- depende disso. Para tornar isso deliberado em vez de acidental, a constraint
-- agenda_outcome_coerente abaixo amarra outcome ao meeting_status.
-- resultado_valido NÃO é alterada.

begin;

-- 1) Colunas ------------------------------------------------------------
alter table public.deal_activities
  add column if not exists meeting_status        text,
  add column if not exists meeting_mode          text,
  add column if not exists meeting_link          text,
  add column if not exists meeting_contact_name  text,
  add column if not exists meeting_contact_phone text;

comment on column public.deal_activities.meeting_status is
  'Situação da reunião: agendada | realizada | nao_compareceu | cancelada. NULL = atividade que não é reunião.';
comment on column public.deal_activities.meeting_mode is
  'Modalidade da reunião: presencial | online. O channel continua ''presencial'' para toda reunião — é o valor que a meta reunioes e os relatórios já contam. Quem diz se é remota é esta coluna.';
comment on column public.deal_activities.meeting_link is
  'URL da sala (Meet/Zoom/Teams) quando meeting_mode = online. Só https.';
comment on column public.deal_activities.meeting_contact_name is
  'Quem participa da reunião. Pode diferir do contato principal do lead.';
comment on column public.deal_activities.meeting_contact_phone is
  'Telefone de quem participa da reunião. Snapshot no momento do agendamento.';

-- 2) Constraints --------------------------------------------------------
-- Agenda só existe no canal presencial, e com status de um domínio fechado.
alter table public.deal_activities
  drop constraint if exists agenda_valida;

alter table public.deal_activities
  add constraint agenda_valida check (
    meeting_status is null
    or (channel = 'presencial'
        and meeting_status in ('agendada','realizada','nao_compareceu','cancelada'))
  );

-- outcome é derivado do status. Impede timeline dizendo uma coisa e a meta
-- 'reunioes' contando outra.
alter table public.deal_activities
  drop constraint if exists agenda_outcome_coerente;

alter table public.deal_activities
  add constraint agenda_outcome_coerente check (
    meeting_status is null
    or (meeting_status = 'realizada'       and outcome = 'realizada')
    or (meeting_status = 'nao_compareceu'  and outcome = 'nao_compareceu')
    or (meeting_status in ('agendada','cancelada') and outcome is null)
  );

-- Modalidade pertence à agenda e tem domínio fechado.
alter table public.deal_activities
  drop constraint if exists agenda_modalidade_valida;

alter table public.deal_activities
  add constraint agenda_modalidade_valida check (
    (meeting_status is null and meeting_mode is null)
    or (meeting_status is not null and meeting_mode in ('presencial','online'))
  );

-- Link só existe em reunião online, e só https. Bloqueia javascript:, data:
-- e afins na origem, antes de qualquer render.
alter table public.deal_activities
  drop constraint if exists agenda_link_valido;

alter table public.deal_activities
  add constraint agenda_link_valido check (
    meeting_link is null
    or (meeting_mode = 'online' and meeting_link like 'https://%' and length(meeting_link) <= 500)
  );

-- Contato sem telefone é aceitável; telefone sem nome também. Reunião online sem
-- link também: o link costuma sair depois de confirmar a data. Sem constraint —
-- exigir preenchimento aqui só faria o vendedor inventar dado para salvar.

-- 3) Índice do painel do Dashboard --------------------------------------
-- Parcial: só linhas de agenda entram. A consulta é
-- "reuniões com meeting_status a partir de <data>, ordenadas por occurred_at".
create index if not exists deal_activities_agenda_idx
  on public.deal_activities (occurred_at)
  where meeting_status is not null;

-- 4) Backfill -----------------------------------------------------------
-- O canal 'presencial' estava sem uso (ver 20260825_0007). Se houver alguma
-- linha, herda o status a partir do outcome já registrado.
update public.deal_activities
   set meeting_status = outcome
 where channel = 'presencial'
   and outcome in ('realizada','nao_compareceu')
   and meeting_status is null;

-- Toda reunião precisa de modalidade. O que existia era presencial de fato.
update public.deal_activities
   set meeting_mode = 'presencial'
 where meeting_status is not null
   and meeting_mode is null;

commit;

-- ======================================================================
-- Conferência pós-migration (rodar avulso, fora da transação):
--
--   select meeting_status, meeting_mode, count(*)
--     from public.deal_activities
--    group by 1, 2 order by 1, 2;
--
--   -- deve falhar (link fora de https):
--   -- update public.deal_activities set meeting_link = 'javascript:alert(1)'
--   --  where meeting_status is not null;
--
--   -- deve falhar (status realizada exige outcome realizada):
--   -- insert into public.deal_activities
--   --   (deal_id, author_id, channel, outcome, meeting_status, occurred_at)
--   -- values ('<deal>', '<profile>', 'presencial', null, 'realizada', now());
--
--   -- deve passar (reunião marcada, sem desfecho):
--   -- insert into public.deal_activities
--   --   (deal_id, author_id, channel, meeting_status, occurred_at)
--   -- values ('<deal>', '<profile>', 'presencial', 'agendada', now() + interval '2 days');
-- ======================================================================
