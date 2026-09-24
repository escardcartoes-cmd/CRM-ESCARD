-- 0055b — ROLLBACK da 0055a. Rodar SOZINHO, só se precisar desfazer.
do $$
begin
  perform set_config('app.mov_automatica', 'on', true);
  update public.deals d
     set stage_id           = b.stage_atual,
         stage_changed_at   = b.stage_changed_at_atual,
         next_followup_date = b.followup_atual,
         loss_reason        = b.motivo_atual
    from public.bkp_reversao_etapa_20260924 b
   where d.id = b.id;
  perform set_config('app.mov_automatica', 'off', true);
end $$;
