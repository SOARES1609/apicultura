
-- Tables for Apicultura HB synced storage
CREATE TABLE public.apiarios (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  name TEXT NOT NULL,
  location TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.colmeias (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  apiario_id UUID NOT NULL REFERENCES public.apiarios(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.tasks (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  title TEXT NOT NULL,
  notes TEXT,
  due_at TIMESTAMPTZ NOT NULL,
  scope TEXT NOT NULL CHECK (scope IN ('geral','apiario','colmeia')),
  apiario_id UUID REFERENCES public.apiarios(id) ON DELETE CASCADE,
  colmeia_id UUID REFERENCES public.colmeias(id) ON DELETE CASCADE,
  done BOOLEAN NOT NULL DEFAULT false,
  notified BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.inspections (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  colmeia_id UUID NOT NULL REFERENCES public.colmeias(id) ON DELETE CASCADE,
  date TIMESTAMPTZ NOT NULL,
  queen_seen BOOLEAN NOT NULL DEFAULT false,
  queen_status SMALLINT NOT NULL DEFAULT 1 CHECK (queen_status BETWEEN 0 AND 3),
  queen_notes TEXT,
  general_notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.apiarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.colmeias ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inspections ENABLE ROW LEVEL SECURITY;

CREATE POLICY "own apiarios" ON public.apiarios FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own colmeias" ON public.colmeias FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own tasks" ON public.tasks FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own inspections" ON public.inspections FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE INDEX ON public.colmeias(apiario_id);
CREATE INDEX ON public.tasks(user_id, due_at);
CREATE INDEX ON public.inspections(colmeia_id, date DESC);
CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  user_agent TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user_id ON public.push_subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_tasks_due_notifications ON public.tasks(done, notified, due_at) WHERE done = false AND notified = false;

CREATE OR REPLACE FUNCTION public.update_push_subscriptions_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS update_push_subscriptions_updated_at ON public.push_subscriptions;
CREATE TRIGGER update_push_subscriptions_updated_at
BEFORE UPDATE ON public.push_subscriptions
FOR EACH ROW
EXECUTE FUNCTION public.update_push_subscriptions_updated_at();

DROP POLICY IF EXISTS "Users can view own push subscriptions" ON public.push_subscriptions;
CREATE POLICY "Users can view own push subscriptions"
ON public.push_subscriptions
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can create own push subscriptions" ON public.push_subscriptions;
CREATE POLICY "Users can create own push subscriptions"
ON public.push_subscriptions
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own push subscriptions" ON public.push_subscriptions;
CREATE POLICY "Users can update own push subscriptions"
ON public.push_subscriptions
FOR UPDATE
TO authenticated
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own push subscriptions" ON public.push_subscriptions;
CREATE POLICY "Users can delete own push subscriptions"
ON public.push_subscriptions
FOR DELETE
TO authenticated
USING (auth.uid() = user_id);ALTER TABLE public.colmeias
  ADD COLUMN IF NOT EXISTS status_green boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS status_red boolean NOT NULL DEFAULT false;-- Substitui o único flag "notified" por três estágios independentes,
-- para permitir 3 notificações por tarefa: início do dia, 2h antes, e no vencimento.

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS notified_day_start boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS notified_2h_before boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS notified_due boolean NOT NULL DEFAULT false;

-- Tarefas já marcadas como "notified" na versão antiga não devem voltar a notificar tudo de repente.
UPDATE public.tasks
SET notified_day_start = true, notified_2h_before = true, notified_due = true
WHERE notified = true;

DROP INDEX IF EXISTS idx_tasks_due_notifications;
CREATE INDEX IF NOT EXISTS idx_tasks_pending_notifications
  ON public.tasks (done, due_at)
  WHERE done = false AND (notified_day_start = false OR notified_2h_before = false OR notified_due = false);

-- Função chamada pela edge function a cada minuto: devolve, já calculada em UTC,
-- cada (tarefa, estágio) que está pendente de notificação.
-- p_tz define o fuso horário usado para determinar "o início do dia" da tarefa;
-- p_day_start_hour define a que hora local esse aviso deve disparar (padrão 08:00).
CREATE OR REPLACE FUNCTION public.get_pending_task_notifications(
  p_tz text DEFAULT 'Europe/Lisbon',
  p_day_start_hour int DEFAULT 8
)
RETURNS TABLE (
  task_id uuid,
  user_id uuid,
  title text,
  due_at timestamptz,
  kind text
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      t.id,
      t.user_id,
      t.title,
      t.due_at,
      t.notified_day_start,
      t.notified_2h_before,
      t.notified_due,
      -- início do dia local da tarefa, convertido de volta para instante UTC
      ((date_trunc('day', t.due_at AT TIME ZONE p_tz) + make_interval(hours => p_day_start_hour)) AT TIME ZONE p_tz) AS day_start_utc,
      (t.due_at - interval '2 hours') AS two_h_before_utc
    FROM public.tasks t
    WHERE t.done = false
  )
  SELECT id, user_id, title, due_at, 'day_start'::text
  FROM base
  WHERE notified_day_start = false AND day_start_utc <= now()
  UNION ALL
  SELECT id, user_id, title, due_at, '2h_before'::text
  FROM base
  WHERE notified_2h_before = false AND two_h_before_utc <= now()
  UNION ALL
  SELECT id, user_id, title, due_at, 'due'::text
  FROM base
  WHERE notified_due = false AND due_at <= now();
$$;

-- IMPORTANTE — passo manual ainda necessário depois de aplicar esta migração:
-- ativar as extensões pg_cron e pg_net no novo projeto (Database → Extensions)
-- e agendar a chamada à edge function a cada minuto. Ver instruções à parte,
-- porque o URL da função e a chave dependem do projeto novo.
