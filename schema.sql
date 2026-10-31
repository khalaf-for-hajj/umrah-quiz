-- =====================================================================
--  مسابقة المعتمرين — مخطط قاعدة البيانات (Supabase / PostgreSQL)
-- =====================================================================
--  طريقة التشغيل: Supabase ← SQL Editor ← الصق الملف كاملاً ← Run.
--  الملف آمن لإعادة التشغيل (لا يحذف بياناتك ولا يكرر البيانات التجريبية).
--
--  قبل التشغيل: عدّل بريد المشرف في قسم «7) المشرف» أسفل الملف.
--
--  مبدأ الأمان:
--   • المستخدم العام (anon) لا يملك أي صلاحية على الجداول إطلاقاً.
--   • كل ما يفعله المشترك يمر عبر دوال RPC (security definer) فقط.
--   • مفاتيح الإجابات في جدول منفصل لا يقرؤه إلا المشرف، ولا تُرسل للمتصفح.
--   • الوقت والنقاط والترتيب كلها تُحسب في الخادم.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) الجداول
-- ---------------------------------------------------------------------

-- المشرفون (البريد بحروف صغيرة)
create table if not exists public.admins (
  email text primary key check (email = lower(email))
);

-- الإعدادات (صف واحد فقط)
create table if not exists public.settings (
  id                    int primary key default 1 check (id = 1),
  campaign_name         text not null default 'حملة الخلف',
  logo_data             text,                       -- data URL مضغوط (حتى 200KB)
  logo_version          int  not null default 0,
  primary_color         text not null default '#2b7a70' check (primary_color ~ '^#[0-9a-fA-F]{6}$'),
  status                text not null default 'draft' check (status in ('draft','open','closed')),
  results_published     boolean not null default false,
  starts_at             timestamptz,
  ends_at               timestamptz,
  closed_at             timestamptz,
  self_register         boolean not null default true,
  show_score            boolean not null default true,    -- إظهار النقاط للمشترك بعد إنهائه
  show_correct          boolean not null default false,   -- إظهار صح/خطأ أثناء المسابقة
  leaderboard_size      int not null default 10 check (leaderboard_size between 3 and 100),
  base_points           int not null default 100 check (base_points between 0 and 10000),
  speed_bonus           int not null default 50  check (speed_bonus between 0 and 10000),
  default_seconds       int not null default 20  check (default_seconds between 5 and 300),
  questions_per_attempt int check (questions_per_attempt is null or questions_per_attempt >= 1),
  test_mode             boolean not null default false,
  updated_at            timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict do nothing;

-- الباصات
create table if not exists public.buses (
  id         serial primary key,
  name       text not null check (length(btrim(name)) between 1 and 40),
  created_at timestamptz not null default now()
);
create unique index if not exists buses_name_uq on public.buses (lower(btrim(name)));

-- المشتركون (رقم الجوال فريد = محاولة واحدة)
create table if not exists public.participants (
  id         uuid primary key default gen_random_uuid(),
  phone      text not null unique,
  name       text not null check (length(btrim(name)) between 2 and 80),
  gender     text not null check (gender in ('M','F')),
  bus_id     int references public.buses(id) on delete set null,
  source     text not null default 'admin' check (source in ('admin','import','self')),
  is_test    boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists participants_bus_idx on public.participants (bus_id);

-- الأسئلة (بدون الإجابة الصحيحة)
create table if not exists public.questions (
  id          uuid primary key default gen_random_uuid(),
  text        text not null check (length(btrim(text)) >= 3),
  category    text not null default 'fiqh' check (category in ('fiqh','culture','other')),
  explanation text,
  points      int check (points is null or points between 0 and 10000),
  seconds     int check (seconds is null or seconds between 5 and 300),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.question_options (
  id          uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions(id) on delete cascade,
  position    smallint not null default 0,
  text        text not null check (length(btrim(text)) >= 1)
);
create index if not exists question_options_q_idx on public.question_options (question_id);

-- مفاتيح الإجابات: جدول منفصل، المشرف فقط يقرؤه
create table if not exists public.answer_keys (
  question_id       uuid primary key references public.questions(id) on delete cascade,
  correct_option_id uuid not null references public.question_options(id) on delete cascade
);

-- محاولة المشترك (واحدة فقط لكل مشترك)
create table if not exists public.attempts (
  id              uuid primary key default gen_random_uuid(),
  participant_id  uuid not null unique references public.participants(id) on delete cascade,
  token_hash      text not null,                 -- هاش رمز المحاولة السري
  started_at      timestamptz not null default now(),
  finished_at     timestamptz,
  cur_idx         int not null default 0,
  total_questions int not null,
  total_points    int not null default 0,
  correct_count   int not null default 0,
  total_ms        bigint not null default 0,
  resume_count    int not null default 0,
  is_test         boolean not null default false
);

-- أسئلة المحاولة: ترتيب مستقل لكل مشترك + لقطة من الوقت والنقاط
create table if not exists public.attempt_questions (
  attempt_id       uuid not null references public.attempts(id) on delete cascade,
  idx              int  not null,
  question_id      uuid not null references public.questions(id) on delete cascade,
  seconds          int  not null,
  base_points      int  not null,
  bonus_points     int  not null,
  shown_at         timestamptz,                  -- بداية عدّاد السؤال (من الخادم)
  status           text not null default 'pending' check (status in ('pending','answered','timeout')),
  chosen_option_id uuid,
  is_correct       boolean,
  points_awarded   int  not null default 0,
  elapsed_ms       int,
  answered_at      timestamptz,
  primary key (attempt_id, idx)
);

-- اختيارات المحاولة: رموز مبهمة وترتيب عشوائي مستقل
create table if not exists public.attempt_options (
  attempt_id  uuid not null references public.attempts(id) on delete cascade,
  question_id uuid not null,
  token       text not null,
  option_id   uuid not null references public.question_options(id) on delete cascade,
  pos         smallint not null,
  primary key (attempt_id, token)
);
create index if not exists attempt_options_aq_idx on public.attempt_options (attempt_id, question_id);

-- ---------------------------------------------------------------------
-- 2) دوال مساعدة داخلية
-- ---------------------------------------------------------------------

-- تطبيع رقم الجوال إلى صيغة موحدة (+9665xxxxxxxx للسعودي) أو null إذا كان غير صالح
create or replace function public.normalize_phone(p text) returns text
language plpgsql immutable
as $$
declare
  s text; d text; intl boolean := false;
begin
  if p is null then return null; end if;
  -- الأرقام العربية والفارسية ← لاتينية
  s := translate(p, '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789');
  d := regexp_replace(s, '[^0-9]', '', 'g');
  if d = '' then return null; end if;
  if s ~ '^[^0-9]*\+' then
    intl := true;
  elsif d like '00%' then
    intl := true; d := substr(d, 3);
  end if;
  if intl then
    if d like '9660%' then d := '966' || substr(d, 5); end if;   -- +966 05xxxxxxxx
    if d like '966%' then
      if d ~ '^9665[0-9]{8}$' then return '+' || d; end if;
      return null;
    end if;
    if d ~ '^[1-9][0-9]{7,14}$' then return '+' || d; end if;    -- دولي آخر: يُقبل كما هو
    return null;
  end if;
  if d ~ '^05[0-9]{8}$'   then return '+966' || substr(d, 2); end if;
  if d ~ '^5[0-9]{8}$'    then return '+966' || d; end if;
  if d ~ '^9665[0-9]{8}$' then return '+' || d; end if;
  if d ~ '^[1-9][0-9]{10,14}$' then return '+' || d; end if;
  return null;
end $$;

-- تحويل نص الجنس إلى M / F
create or replace function public.parse_gender(p text) returns text
language sql immutable
as $$
  select case lower(btrim(coalesce(p, '')))
    when 'm' then 'M' when 'male' then 'M' when 'man' then 'M'
    when 'ذكر' then 'M' when 'رجل' then 'M' when 'رجال' then 'M' when 'ذ' then 'M'
    when 'f' then 'F' when 'female' then 'F' when 'woman' then 'F'
    when 'أنثى' then 'F' when 'انثى' then 'F' when 'امرأة' then 'F' when 'امراة' then 'F' when 'نساء' then 'F'
    else null end
$$;

create or replace function public._err(p_code text, p_msg text) returns jsonb
language sql immutable
as $$ select jsonb_build_object('ok', false, 'error', p_code, 'message', p_msg) $$;

create or replace function public._hash(p text) returns text
language sql immutable
as $$ select encode(sha256(convert_to(coalesce(p, ''), 'UTF8')), 'hex') $$;

create or replace function public._new_token() returns text
language sql volatile
as $$ select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '') $$;

-- هل المستخدم الحالي مشرف؟ (بريد الدخول موجود في جدول admins)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.admins a
    where a.email = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
$$;

create or replace function public.am_i_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$ select public.is_admin() $$;

-- حالة المسابقة الفعلية: draft / scheduled / open / closed / published
create or replace function public.contest_state() returns text
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare s public.settings; v_closed text;
begin
  select * into s from public.settings where id = 1;
  v_closed := case when s.results_published then 'published' else 'closed' end;
  if s.status = 'draft'  then return 'draft'; end if;
  if s.status = 'closed' then return v_closed; end if;
  if s.ends_at   is not null and now() >= s.ends_at   then return v_closed; end if;
  if s.starts_at is not null and now() <  s.starts_at then return 'scheduled'; end if;
  return 'open';
end $$;

-- هل يُسمح ببدء محاولة جديدة الآن؟ (مفتوحة، أو وضع التجربة قبل الإطلاق)
create or replace function public._can_play() returns boolean
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare st text := public.contest_state(); t boolean;
begin
  select test_mode into t from public.settings where id = 1;
  return st = 'open' or (t and st in ('draft', 'scheduled'));
end $$;

-- ---------------------------------------------------------------------
-- 3) محرك المحاولة (داخلي — لا يُمنح لأي مستخدم)
-- ---------------------------------------------------------------------

-- إعادة حساب مجاميع المحاولة من تفاصيل الأسئلة
-- (السؤال غير المُجاب يُحسب بزمنه الكامل حتى لا يستفيد من التخطي في كسر التعادل)
create or replace function public._recalc_attempt(p_att uuid) returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  update public.attempts a set
    total_points  = coalesce(x.pts, 0),
    correct_count = coalesce(x.cc, 0),
    total_ms      = coalesce(x.ms, 0)
  from (
    select sum(points_awarded)::int as pts,
           (count(*) filter (where is_correct))::int as cc,
           sum(case when status in ('answered','timeout') then coalesce(elapsed_ms, seconds * 1000) else 0 end)::bigint as ms
    from public.attempt_questions where attempt_id = p_att
  ) x
  where a.id = p_att;
end $$;

create or replace function public._finish_attempt(p_att uuid, p_at timestamptz) returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  update public.attempts
     set finished_at = greatest(started_at, p_at), cur_idx = total_questions
   where id = p_att and finished_at is null;
  perform public._recalc_attempt(p_att);
end $$;

-- ترحيل المحاولة: يُنهي الأسئلة التي انتهى وقتها (بلا إجابة) وينتقل للتالي،
-- ويُنهي المحاولة كلها إذا أُغلقت المسابقة. قابل للتكرار بأمان.
-- مهلة سماح 2 ثانية لتأخر الشبكة فقط (لا تدخل في حساب مكافأة السرعة).
create or replace function public._advance_attempt(p_att uuid) returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  a public.attempts; s public.settings; aq public.attempt_questions;
  v_grace constant interval := interval '2 seconds';
  v_close timestamptz; v_deadline timestamptz;
begin
  select * into a from public.attempts where id = p_att for update;
  if not found or a.finished_at is not null then return; end if;
  select * into s from public.settings where id = 1;

  -- المسابقة أُغلقت: تُحسب الإجابات المسجلة فقط وتُنهى المحاولة
  if public.contest_state() in ('closed', 'published') then
    v_close := least(now(), coalesce(case when s.status = 'closed' then s.closed_at else s.ends_at end, now()));
    update public.attempt_questions
       set status = 'timeout', elapsed_ms = seconds * 1000, is_correct = false, points_awarded = 0
     where attempt_id = p_att and status = 'pending';
    perform public._finish_attempt(p_att, v_close);
    return;
  end if;

  loop
    select * into aq from public.attempt_questions where attempt_id = p_att and idx = a.cur_idx;
    if not found then
      perform public._finish_attempt(p_att, now());
      return;
    end if;
    if aq.shown_at is null then   -- احتياط
      update public.attempt_questions set shown_at = now() where attempt_id = p_att and idx = aq.idx;
      exit;
    end if;
    v_deadline := aq.shown_at + make_interval(secs => aq.seconds);
    exit when now() <= v_deadline + v_grace;

    -- انتهى وقت السؤال بلا إجابة
    update public.attempt_questions
       set status = 'timeout', elapsed_ms = seconds * 1000, is_correct = false, points_awarded = 0
     where attempt_id = p_att and idx = aq.idx;
    a.cur_idx := a.cur_idx + 1;
    update public.attempts set cur_idx = a.cur_idx where id = p_att;
    if a.cur_idx >= a.total_questions then
      perform public._finish_attempt(p_att, v_deadline);
      return;
    end if;
    -- عدّاد السؤال التالي يبدأ من لحظة انتهاء السابق (على الخادم)
    update public.attempt_questions set shown_at = v_deadline where attempt_id = p_att and idx = a.cur_idx;
  end loop;
  perform public._recalc_attempt(p_att);
end $$;

-- إنهاء كل المحاولات المعلّقة التي حان وقتها (تُستدعى من لوحة المشرف وعند الإغلاق)
create or replace function public._sweep() returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare r record;
begin
  for r in select id from public.attempts where finished_at is null order by id loop
    perform public._advance_attempt(r.id);
  end loop;
end $$;

-- السؤال الحالي كما يراه المشترك (بدون أي إشارة للإجابة الصحيحة)
create or replace function public._question_payload(p_att uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare a public.attempts; aq public.attempt_questions; q public.questions;
begin
  select * into a  from public.attempts where id = p_att;
  select * into aq from public.attempt_questions where attempt_id = p_att and idx = a.cur_idx;
  select * into q  from public.questions where id = aq.question_id;
  return jsonb_build_object(
    'idx', aq.idx,
    'total', a.total_questions,
    'text', q.text,
    'category', q.category,
    'seconds', aq.seconds,
    'starts_in_ms', greatest(0, floor(extract(epoch from (aq.shown_at - now())) * 1000))::int,
    'remaining_ms', greatest(0, floor(extract(epoch from (aq.shown_at + make_interval(secs => aq.seconds) - now())) * 1000))::int,
    'options', (
      select jsonb_agg(jsonb_build_object('token', ao.token, 'text', o.text) order by ao.pos)
      from public.attempt_options ao join public.question_options o on o.id = ao.option_id
      where ao.attempt_id = p_att and ao.question_id = aq.question_id
    )
  );
end $$;

-- ملخص نهاية المحاولة
create or replace function public._summary(p_att uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare a public.attempts; s public.settings;
begin
  select * into a from public.attempts where id = p_att;
  select * into s from public.settings where id = 1;
  return jsonb_build_object(
    'total_questions', a.total_questions,
    'show_score', s.show_score,
    'points', case when s.show_score then a.total_points end
  );
end $$;

-- التحقق من (الجوال + رمز المحاولة السري) وإرجاع رقم المحاولة
create or replace function public._auth_attempt(p_phone text, p_token text) returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select a.id
  from public.attempts a join public.participants p on p.id = a.participant_id
  where p.phone = public.normalize_phone(p_phone)
    and a.token_hash = public._hash(p_token)
$$;

-- الترتيب: الأعلى نقاطاً ← الأقل زمناً ← الأسبق إنهاءً
create or replace function public._ranking(p_all boolean default false)
returns table (
  participant_id uuid, attempt_id uuid, name text, phone text, gender text,
  bus_id int, bus_name text, points int, correct_count int, total_ms bigint,
  finished_at timestamptz, resume_count int, is_test boolean, status text, rnk int
)
language sql stable security definer set search_path = public, pg_temp
as $$
  select p.id, a.id, p.name, p.phone, p.gender, p.bus_id, b.name,
         a.total_points, a.correct_count, a.total_ms, a.finished_at, a.resume_count, a.is_test,
         case when a.finished_at is null then 'in_progress' else 'finished' end,
         (rank() over (order by a.total_points desc, a.total_ms asc,
                       coalesce(a.finished_at, 'infinity'::timestamptz) asc))::int
  from public.attempts a
  join public.participants p on p.id = a.participant_id
  left join public.buses b on b.id = p.bus_id
  where p_all or a.finished_at is not null
$$;

-- ---------------------------------------------------------------------
-- 4) دوال المشترك (RPC) — الوحيدة المتاحة للمستخدم العام (anon)
-- ---------------------------------------------------------------------

-- إعدادات عامة خفيفة. الشعار لا يُرسل إذا كان المتصفح يملك نفس النسخة.
create or replace function public.get_public_config(p_logo_version int default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare s public.settings;
begin
  select * into s from public.settings where id = 1;
  return jsonb_build_object(
    'ok', true,
    'server_now', now(),
    'campaign_name', s.campaign_name,
    'primary_color', s.primary_color,
    'logo_version', s.logo_version,
    'has_logo', s.logo_data is not null,
    'logo', case when s.logo_data is not null and p_logo_version is distinct from s.logo_version then s.logo_data end,
    'state', public.contest_state(),
    'test_mode', s.test_mode,
    'starts_at', s.starts_at,
    'ends_at', s.ends_at,
    'self_register', s.self_register,
    'show_score', s.show_score,
    'leaderboard_size', s.leaderboard_size,
    'buses', coalesce((
      select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name)
             order by (case when btrim(b.name) ~ '^[0-9]{1,9}$' then 0 else 1 end),
                      (case when btrim(b.name) ~ '^[0-9]{1,9}$' then btrim(b.name)::int end),
                      b.name)
      from public.buses b), '[]'::jsonb)
  );
end $$;

-- البحث عن مشترك برقم جواله
create or replace function public.lookup_participant(p_phone text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  ph text := public.normalize_phone(p_phone);
  p public.participants; a public.attempts; s public.settings;
  v_bus text; v_att text := 'none';
begin
  if ph is null then
    return public._err('invalid_phone', 'رقم الجوال غير صحيح. اكتب رقماً سعودياً مثل 0501234567 أو رقماً دولياً يبدأ بـ +');
  end if;
  select * into s from public.settings where id = 1;
  select * into p from public.participants where phone = ph;
  if not found then
    return jsonb_build_object('ok', true, 'found', false, 'phone', ph,
                              'self_register', s.self_register, 'state', public.contest_state());
  end if;
  select * into a from public.attempts where participant_id = p.id;
  if found then
    perform public._advance_attempt(a.id);
    select * into a from public.attempts where id = a.id;
    v_att := case when a.finished_at is null then 'in_progress' else 'finished' end;
  end if;
  select name into v_bus from public.buses where id = p.bus_id;
  return jsonb_build_object('ok', true, 'found', true, 'phone', ph, 'name', p.name, 'bus_name', v_bus,
                            'gender', p.gender, 'attempt', v_att, 'state', public.contest_state(),
                            'can_play', public._can_play(), 'self_register', s.self_register);
end $$;

-- تسجيل ذاتي (إذا فعّله المشرف)
create or replace function public.register_participant(p_name text, p_phone text, p_gender text, p_bus_id int)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  ph text := public.normalize_phone(p_phone);
  v_name text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_g text := public.parse_gender(p_gender);
  s public.settings;
begin
  if ph is null then
    return public._err('invalid_phone', 'رقم الجوال غير صحيح. اكتب رقماً سعودياً مثل 0501234567 أو رقماً دولياً يبدأ بـ +');
  end if;
  if length(v_name) < 2 or length(v_name) > 80 then
    return public._err('invalid_name', 'اكتب اسمك الكامل (حرفان على الأقل)');
  end if;
  if v_g is null then return public._err('invalid_gender', 'اختر الجنس'); end if;
  select * into s from public.settings where id = 1;
  if exists (select 1 from public.participants where phone = ph) then
    return public.lookup_participant(ph);          -- مسجل مسبقاً: لا نعدّل بياناته
  end if;
  if not s.self_register then
    return public._err('registration_closed', 'التسجيل الذاتي مغلق. رقمك غير مسجل، تواصل مع مشرف الحملة');
  end if;
  if public.contest_state() in ('closed', 'published') then
    return public._err('closed', 'انتهت المسابقة');
  end if;
  if p_bus_id is null then
    if exists (select 1 from public.buses) then return public._err('invalid_bus', 'اختر رقم الباص'); end if;
  elsif not exists (select 1 from public.buses where id = p_bus_id) then
    return public._err('invalid_bus', 'رقم الباص غير صحيح');
  end if;
  insert into public.participants (phone, name, gender, bus_id, source, is_test)
  values (ph, v_name, v_g, p_bus_id, 'self', s.test_mode)
  on conflict (phone) do nothing;
  return public.lookup_participant(ph);
end $$;

-- بدء المحاولة أو استئنافها. تُنشئ ترتيباً عشوائياً مستقلاً للأسئلة والاختيارات.
-- عند الاستئناف بدون رمز صالح يُصدر الخادم رمزاً جديداً ويُبطل القديم.
create or replace function public.start_attempt(p_phone text, p_token text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  ph text := public.normalize_phone(p_phone);
  p public.participants; a public.attempts; s public.settings; st text;
  v_token text; v_aid uuid; v_n int;
begin
  if ph is null then
    return public._err('invalid_phone', 'رقم الجوال غير صحيح. اكتب رقماً سعودياً مثل 0501234567 أو رقماً دولياً يبدأ بـ +');
  end if;
  select * into p from public.participants where phone = ph;
  if not found then
    return public._err('not_registered', 'رقمك غير مسجل. تواصل مع مشرف الحملة');
  end if;
  select * into s from public.settings where id = 1;

  select * into a from public.attempts where participant_id = p.id for update;
  if found then
    perform public._advance_attempt(a.id);
    select * into a from public.attempts where id = a.id;
    if a.finished_at is not null then
      return jsonb_build_object('ok', true, 'status', 'finished', 'summary', public._summary(a.id),
                                'state', public.contest_state());
    end if;
    if a.token_hash = public._hash(p_token) then
      v_token := null;                              -- المتصفح يملك الرمز الصحيح
    else
      v_token := public._new_token();               -- استئناف من متصفح آخر/بعد فقد الرمز
      update public.attempts set token_hash = public._hash(v_token), resume_count = resume_count + 1
       where id = a.id;
    end if;
    return jsonb_build_object('ok', true, 'status', 'in_progress', 'token', v_token,
                              'question', public._question_payload(a.id));
  end if;

  -- محاولة جديدة
  st := public.contest_state();
  if not public._can_play() then
    if st = 'draft' then return public._err('not_open', 'المسابقة لم تُفتح بعد'); end if;
    if st = 'scheduled' then return public._err('not_started', 'المسابقة لم تبدأ بعد'); end if;
    return public._err('closed', 'انتهت المسابقة');
  end if;

  v_token := public._new_token();
  begin
    insert into public.attempts (participant_id, token_hash, total_questions, is_test)
    values (p.id, public._hash(v_token), 0, s.test_mode)
    returning id into v_aid;
  exception when unique_violation then
    return public._err('retry', 'تعذّر بدء المحاولة، حاول مرة أخرى');
  end;

  -- اختيار الأسئلة (الكل أو N عشوائية) وترتيبها عشوائياً لهذا المشترك فقط
  with picked as (
    select q.id, q.seconds as q_seconds, q.points as q_points
    from public.questions q
    where q.active
      and exists (select 1 from public.answer_keys k where k.question_id = q.id)
      and (select count(*) from public.question_options o where o.question_id = q.id) >= 2
    order by random()
    limit coalesce(s.questions_per_attempt, 100000)
  )
  insert into public.attempt_questions (attempt_id, idx, question_id, seconds, base_points, bonus_points)
  select v_aid, (row_number() over (order by random()) - 1)::int, id,
         coalesce(q_seconds, s.default_seconds), coalesce(q_points, s.base_points), s.speed_bonus
  from picked;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    delete from public.attempts where id = v_aid;
    return public._err('no_questions', 'لا توجد أسئلة جاهزة بعد. تواصل مع مشرف الحملة');
  end if;

  -- ترتيب عشوائي مستقل للاختيارات + رموز مبهمة
  insert into public.attempt_options (attempt_id, question_id, token, option_id, pos)
  select v_aid, o.question_id, substr(replace(gen_random_uuid()::text, '-', ''), 1, 12), o.id,
         (row_number() over (partition by o.question_id order by random()) - 1)::smallint
  from public.question_options o
  where o.question_id in (select question_id from public.attempt_questions where attempt_id = v_aid);

  update public.attempts set total_questions = v_n where id = v_aid;
  update public.attempt_questions set shown_at = now() where attempt_id = v_aid and idx = 0;

  return jsonb_build_object('ok', true, 'status', 'in_progress', 'token', v_token,
                            'question', public._question_payload(v_aid));
end $$;

-- السؤال الحالي (للمتابعة بعد إعادة تحميل الصفحة)
create or replace function public.get_current_question(p_phone text, p_token text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_aid uuid; a public.attempts;
begin
  v_aid := public._auth_attempt(p_phone, p_token);
  if v_aid is null then
    return public._err('bad_token', 'انتهت صلاحية جلستك. أدخل رقم جوالك مرة أخرى للمتابعة');
  end if;
  perform public._advance_attempt(v_aid);
  select * into a from public.attempts where id = v_aid;
  if a.finished_at is not null then
    return jsonb_build_object('ok', true, 'status', 'finished', 'summary', public._summary(v_aid),
                              'state', public.contest_state());
  end if;
  return jsonb_build_object('ok', true, 'status', 'in_progress', 'question', public._question_payload(v_aid));
end $$;

-- تسجيل إجابة. الزمن يُحسب هنا بالكامل. آمنة للتكرار (إعادة المحاولة عند انقطاع الإنترنت).
-- p_option = null تعني انتهاء الوقت بلا إجابة. تُرجع السؤال التالي مباشرة.
create or replace function public.submit_answer(p_phone text, p_token text, p_idx int, p_option text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_aid uuid; a public.attempts; s public.settings; aq public.attempt_questions; ao public.attempt_options;
  v_key uuid; v_elapsed int; v_ok boolean := null; v_pts int := 0; v_fb jsonb := null; v_ctok text;
begin
  v_aid := public._auth_attempt(p_phone, p_token);
  if v_aid is null then
    return public._err('bad_token', 'انتهت صلاحية جلستك. أدخل رقم جوالك مرة أخرى للمتابعة');
  end if;
  perform public._advance_attempt(v_aid);          -- يقفل المحاولة ويُنهي ما انتهى وقته
  select * into a from public.attempts where id = v_aid;
  select * into s from public.settings where id = 1;

  if a.finished_at is not null then
    return jsonb_build_object('ok', true, 'status', 'finished', 'summary', public._summary(v_aid),
                              'state', public.contest_state());
  end if;

  select * into aq from public.attempt_questions where attempt_id = v_aid and idx = p_idx;
  if not found then return public._err('bad_idx', 'سؤال غير صالح'); end if;

  if p_idx < a.cur_idx then                         -- سؤال أُغلق مسبقاً (تكرار أو إجابة متأخرة)
    return jsonb_build_object('ok', true, 'status', 'in_progress', 'duplicate', true,
                              'late', (aq.status = 'timeout' and p_option is not null),
                              'question', public._question_payload(v_aid));
  end if;
  if p_idx > a.cur_idx then return public._err('bad_idx', 'سؤال غير صالح'); end if;

  if p_option is null then
    update public.attempt_questions
       set status = 'timeout', elapsed_ms = seconds * 1000, is_correct = false, points_awarded = 0
     where attempt_id = v_aid and idx = p_idx;
  else
    select * into ao from public.attempt_options
     where attempt_id = v_aid and question_id = aq.question_id and token = p_option;
    if not found then return public._err('invalid_option', 'اختيار غير صالح'); end if;
    select correct_option_id into v_key from public.answer_keys where question_id = aq.question_id;
    v_elapsed := greatest(0, least(floor(extract(epoch from (now() - aq.shown_at)) * 1000), aq.seconds * 1000))::int;
    v_ok := (ao.option_id = v_key);
    if v_ok then
      v_pts := aq.base_points + round(aq.bonus_points * (1 - v_elapsed::numeric / (aq.seconds * 1000)))::int;
    end if;
    update public.attempt_questions
       set status = 'answered', chosen_option_id = ao.option_id, is_correct = v_ok,
           points_awarded = v_pts, elapsed_ms = v_elapsed, answered_at = now()
     where attempt_id = v_aid and idx = p_idx;
    if s.show_correct then
      select token into v_ctok from public.attempt_options
       where attempt_id = v_aid and question_id = aq.question_id and option_id = v_key;
      v_fb := jsonb_build_object('correct', v_ok, 'correct_token', v_ctok);
    end if;
  end if;

  update public.attempts set cur_idx = p_idx + 1 where id = v_aid;
  if p_idx + 1 >= a.total_questions then
    perform public._finish_attempt(v_aid, now());
    return jsonb_build_object('ok', true, 'status', 'finished', 'feedback', v_fb, 'summary', public._summary(v_aid));
  end if;
  -- عدّاد التالي يبدأ الآن (وبعد ثانيتين إذا كان عرض الصح/الخطأ مفعّلاً)
  update public.attempt_questions
     set shown_at = now() + case when v_fb is not null then interval '2 seconds' else interval '0' end
   where attempt_id = v_aid and idx = p_idx + 1;
  perform public._recalc_attempt(v_aid);
  return jsonb_build_object('ok', true, 'status', 'in_progress', 'feedback', v_fb,
                            'question', public._question_payload(v_aid));
end $$;

-- نتيجتي: قبل النشر نقاط فقط (برمز المحاولة)، وبعد النشر الترتيب والمراجعة (بالجوال)
create or replace function public.get_my_result(p_phone text, p_token text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  ph text := public.normalize_phone(p_phone);
  p public.participants; a public.attempts; s public.settings; st text;
  v_rank int; v_total int; v_review jsonb; v_bus text;
begin
  if ph is null then return public._err('invalid_phone', 'رقم الجوال غير صحيح'); end if;
  select * into p from public.participants where phone = ph;
  if not found then return public._err('not_registered', 'رقمك غير مسجل. تواصل مع مشرف الحملة'); end if;
  select * into a from public.attempts where participant_id = p.id;
  if not found then
    return jsonb_build_object('ok', true, 'status', 'none', 'state', public.contest_state());
  end if;
  perform public._advance_attempt(a.id);
  select * into a from public.attempts where id = a.id;
  select * into s from public.settings where id = 1;
  st := public.contest_state();
  if a.finished_at is null then
    return jsonb_build_object('ok', true, 'status', 'in_progress', 'state', st);
  end if;
  if st <> 'published' then
    return jsonb_build_object('ok', true, 'status', 'finished', 'state', st,
      'points', case when s.show_score and a.token_hash = public._hash(p_token) then a.total_points end);
  end if;

  select rnk into v_rank from public._ranking() where participant_id = p.id;
  select count(*) into v_total from public._ranking();
  select name into v_bus from public.buses where id = p.bus_id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'n', aq.idx + 1, 'text', q.text, 'category', q.category, 'status', aq.status,
           'is_correct', coalesce(aq.is_correct, false), 'points', aq.points_awarded,
           'chosen_text', (select o.text from public.question_options o where o.id = aq.chosen_option_id),
           'correct_text', (select o2.text from public.answer_keys k
                              join public.question_options o2 on o2.id = k.correct_option_id
                             where k.question_id = aq.question_id),
           'explanation', q.explanation) order by aq.idx), '[]'::jsonb)
    into v_review
    from public.attempt_questions aq join public.questions q on q.id = aq.question_id
   where aq.attempt_id = a.id;

  return jsonb_build_object('ok', true, 'status', 'published', 'state', st,
    'name', p.name, 'bus_name', v_bus, 'rank', v_rank, 'ranked_total', v_total,
    'points', a.total_points, 'correct_count', a.correct_count, 'total_questions', a.total_questions,
    'total_ms', a.total_ms, 'review', v_review);
end $$;

-- المتصدرون: تعمل فقط بعد نشر النتائج. p_gender = 'M' أو 'F' أو null للكل.
create or replace function public.get_leaderboard(p_phone text default null, p_gender text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  s public.settings; ph text := public.normalize_phone(p_phone);
  g text := nullif(upper(btrim(coalesce(p_gender, ''))), '');
  v_top jsonb; v_me jsonb;
begin
  if public.contest_state() <> 'published' then
    return public._err('not_published', 'لم تُنشر النتائج بعد');
  end if;
  if g is not null and g not in ('M', 'F') then g := null; end if;
  select * into s from public.settings where id = 1;

  with r as (
    select x.*, (rank() over (order by x.points desc, x.total_ms asc, x.finished_at asc))::int as frank
    from public._ranking() x
    where g is null or x.gender = g
  )
  select
    (select coalesce(jsonb_agg(jsonb_build_object(
        'rank', r.frank, 'name', r.name, 'bus', r.bus_name, 'points', r.points,
        'correct', r.correct_count, 'ms', r.total_ms, 'me', coalesce(r.phone = ph, false))
        order by r.frank, r.finished_at), '[]'::jsonb)
       from r where r.frank <= s.leaderboard_size),
    (select jsonb_build_object('rank', r.frank, 'overall_rank', r.rnk, 'name', r.name, 'bus', r.bus_name,
        'points', r.points, 'correct', r.correct_count, 'ms', r.total_ms)
       from r where ph is not null and r.phone = ph limit 1)
  into v_top, v_me;

  return jsonb_build_object('ok', true, 'gender', g, 'size', s.leaderboard_size, 'rows', v_top, 'me', v_me);
end $$;

-- ---------------------------------------------------------------------
-- 5) دوال المشرف (RPC) — تتطلب تسجيل دخول بريد موجود في جدول admins
-- ---------------------------------------------------------------------

create or replace function public._require_admin() returns void
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'غير مصرّح لك بهذه العملية' using errcode = '42501';
  end if;
end $$;

-- الإعدادات الكاملة (مع الشعار)
create or replace function public.admin_get_settings() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare s public.settings;
begin
  perform public._require_admin();
  select * into s from public.settings where id = 1;
  return to_jsonb(s) || jsonb_build_object('state', public.contest_state(), 'server_now', now());
end $$;

-- حفظ الإعدادات (تُرسل الحقول المراد تغييرها فقط)
create or replace function public.admin_save_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_logo text; v_new_test boolean; s public.settings; v_start timestamptz; v_end timestamptz;
begin
  perform public._require_admin();
  select * into s from public.settings where id = 1;

  if p ? 'logo_data' then
    v_logo := nullif(p ->> 'logo_data', '');
    if v_logo is not null and (v_logo !~ '^data:image/' or length(v_logo) > 273100) then
      raise exception 'حجم الشعار يتجاوز 200KB أو أن صيغته غير صالحة';
    end if;
  end if;
  if p ? 'primary_color' and (p ->> 'primary_color') !~ '^#[0-9a-fA-F]{6}$' then
    raise exception 'لون غير صالح';
  end if;
  if p ? 'campaign_name' and length(btrim(coalesce(p ->> 'campaign_name', ''))) = 0 then
    raise exception 'اسم الحملة مطلوب';
  end if;

  v_start := case when p ? 'starts_at' then nullif(p ->> 'starts_at', '')::timestamptz else s.starts_at end;
  v_end   := case when p ? 'ends_at'   then nullif(p ->> 'ends_at', '')::timestamptz   else s.ends_at end;
  if v_start is not null and v_end is not null and v_end <= v_start then
    raise exception 'وقت النهاية يجب أن يكون بعد وقت البداية';
  end if;

  v_new_test := case when p ? 'test_mode' then (p ->> 'test_mode')::boolean else s.test_mode end;
  if v_new_test and not s.test_mode and public.contest_state() not in ('draft', 'scheduled') then
    raise exception 'وضع التجربة متاح فقط قبل فتح المسابقة';
  end if;

  update public.settings set
    campaign_name         = case when p ? 'campaign_name' then btrim(p ->> 'campaign_name') else campaign_name end,
    primary_color         = case when p ? 'primary_color' then p ->> 'primary_color' else primary_color end,
    logo_data             = case when p ? 'logo_data' then v_logo else logo_data end,
    logo_version          = case when p ? 'logo_data' then logo_version + 1 else logo_version end,
    starts_at             = v_start,
    ends_at               = v_end,
    self_register         = case when p ? 'self_register' then (p ->> 'self_register')::boolean else self_register end,
    show_score            = case when p ? 'show_score' then (p ->> 'show_score')::boolean else show_score end,
    show_correct          = case when p ? 'show_correct' then (p ->> 'show_correct')::boolean else show_correct end,
    leaderboard_size      = case when p ? 'leaderboard_size' then (p ->> 'leaderboard_size')::int else leaderboard_size end,
    base_points           = case when p ? 'base_points' then (p ->> 'base_points')::int else base_points end,
    speed_bonus           = case when p ? 'speed_bonus' then (p ->> 'speed_bonus')::int else speed_bonus end,
    default_seconds       = case when p ? 'default_seconds' then (p ->> 'default_seconds')::int else default_seconds end,
    questions_per_attempt = case when p ? 'questions_per_attempt' then nullif(p ->> 'questions_per_attempt', '')::int else questions_per_attempt end,
    test_mode             = v_new_test,
    updated_at            = now()
  where id = 1;

  -- لا تبقى نتائج «منشورة» إذا لم تعد المسابقة منتهية
  if public.contest_state() not in ('closed', 'published') then
    update public.settings set results_published = false where id = 1;
  end if;
  return public.admin_get_settings();
end $$;

-- تغيير حالة المسابقة: draft / open / closed
create or replace function public.admin_set_status(p_status text, p_keep_schedule boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare s public.settings;
begin
  perform public._require_admin();
  select * into s from public.settings where id = 1;

  if p_status = 'open' then
    if exists (select 1 from public.attempts where is_test) or exists (select 1 from public.participants where is_test) then
      raise exception 'توجد بيانات تجريبية. احذفها أولاً من الإعدادات قبل فتح المسابقة الحقيقية';
    end if;
    update public.settings set
      status = 'open', test_mode = false, results_published = false, closed_at = null,
      starts_at = case when p_keep_schedule then starts_at when starts_at > now() then null else starts_at end,
      ends_at   = case when p_keep_schedule then ends_at   when ends_at <= now() then null else ends_at end,
      updated_at = now()
    where id = 1;
  elsif p_status = 'closed' then
    update public.settings set status = 'closed', closed_at = now(), updated_at = now() where id = 1;
    perform public._sweep();                          -- تُنهى كل المحاولات الجارية ويُحسب ما أُجيب
  elsif p_status = 'draft' then
    update public.settings set status = 'draft', results_published = false, closed_at = null, updated_at = now() where id = 1;
  else
    raise exception 'حالة غير معروفة';
  end if;
  return public.admin_get_settings();
end $$;

-- نشر النتائج / إخفاؤها (النشر بعد انتهاء المسابقة فقط)
create or replace function public.admin_publish_results(p_publish boolean) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_test int;
begin
  perform public._require_admin();
  if p_publish then
    if public.contest_state() not in ('closed', 'published') then
      raise exception 'لا يمكن نشر النتائج قبل انتهاء المسابقة';
    end if;
    perform public._sweep();
    update public.settings set results_published = true, updated_at = now() where id = 1;
  else
    update public.settings set results_published = false, updated_at = now() where id = 1;
  end if;
  select count(*) into v_test from public.attempts where is_test;
  return public.admin_get_settings() || jsonb_build_object('test_attempts', v_test);
end $$;

-- اللوحة الرئيسية
create or replace function public.admin_dashboard() returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_reg int; v_att int; v_fin int; v_avg numeric; v_buses jsonb; v_top jsonb;
begin
  perform public._require_admin();
  perform public._sweep();
  select count(*) into v_reg from public.participants;
  select count(*), count(*) filter (where finished_at is not null), round(avg(total_points) filter (where finished_at is not null), 1)
    into v_att, v_fin, v_avg from public.attempts;

  select coalesce(jsonb_agg(t order by t.sortkey, t.name), '[]'::jsonb) into v_buses from (
    select b.id, b.name, count(p.id)::int as registered, count(a.id)::int as participated,
           case when count(p.id) = 0 then 0 else round(100.0 * count(a.id) / count(p.id)) end as pct,
           case when btrim(b.name) ~ '^[0-9]{1,9}$' then btrim(b.name)::int else 1000000000 end as sortkey
    from public.buses b
    left join public.participants p on p.bus_id = b.id
    left join public.attempts a on a.participant_id = p.id
    group by b.id, b.name
    union all
    select null, null, count(p.id)::int, count(a.id)::int,
           case when count(p.id) = 0 then 0 else round(100.0 * count(a.id) / count(p.id)) end, 2000000000
    from public.participants p left join public.attempts a on a.participant_id = p.id
    where p.bus_id is null having count(p.id) > 0
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object('rank', r.rnk, 'name', r.name, 'bus', r.bus_name,
           'points', r.points, 'correct', r.correct_count, 'status', r.status) order by r.rnk, r.name), '[]'::jsonb)
    into v_top from (select * from public._ranking(true) x order by x.rnk, x.name limit 10) r;

  return jsonb_build_object('ok', true, 'server_now', now(), 'state', public.contest_state(),
    'registered', v_reg, 'participated', v_att, 'finished', v_fin, 'in_progress', v_att - v_fin,
    'not_participated', v_reg - v_att, 'avg_points', coalesce(v_avg, 0),
    'buses', v_buses, 'top', v_top,
    'test_attempts', (select count(*) from public.attempts where is_test),
    'test_participants', (select count(*) from public.participants where is_test));
end $$;

-- ---------------- الأسئلة ----------------

-- حفظ سؤال (إضافة/تعديل) داخلياً. الاختيارات: [{id?, text}] والصحيح بالفهرس correct_index (يبدأ من 0)
create or replace function public._save_question(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  qid uuid; opts jsonb; n int; i int; item jsonb; oid uuid; correct_id uuid; keep uuid[] := '{}';
  v_text text := btrim(coalesce(p ->> 'text', ''));
  v_cat text := coalesce(nullif(p ->> 'category', ''), 'fiqh');
  v_ci int; v_real boolean := false; v_seen text[] := '{}'; v_t text;
begin
  if length(v_text) < 3 then raise exception 'نص السؤال قصير جداً'; end if;
  if v_cat not in ('fiqh', 'culture', 'other') then raise exception 'تصنيف غير صالح'; end if;
  opts := p -> 'options';
  if opts is null or jsonb_typeof(opts) <> 'array' then raise exception 'الاختيارات مطلوبة'; end if;
  n := jsonb_array_length(opts);
  if n < 2 or n > 6 then raise exception 'عدد الاختيارات يجب أن يكون من 2 إلى 6'; end if;
  v_ci := nullif(p ->> 'correct_index', '')::int;
  if v_ci is null or v_ci < 0 or v_ci >= n then raise exception 'حدد الإجابة الصحيحة'; end if;
  for i in 0 .. n - 1 loop
    v_t := lower(btrim(coalesce(opts -> i ->> 'text', '')));
    if v_t = '' then raise exception 'اختيار فارغ'; end if;
    if v_t = any (v_seen) then raise exception 'اختيارات مكررة'; end if;
    v_seen := v_seen || v_t;
  end loop;

  if nullif(p ->> 'id', '') is not null then
    qid := (p ->> 'id')::uuid;
    if not exists (select 1 from public.questions where id = qid) then raise exception 'السؤال غير موجود'; end if;
    v_real := exists (select 1 from public.attempt_questions aq join public.attempts a on a.id = aq.attempt_id
                      where aq.question_id = qid and not a.is_test);
    if v_real then
      -- بعد بدء المسابقة: لا يُسمح بتغيير مجموعة الاختيارات (يمكن تعديل نصوصها والإجابة الصحيحة)
      if (select count(*) from public.question_options where question_id = qid) <> n
         or exists (select 1 from jsonb_array_elements(opts) e
                    where nullif(e ->> 'id', '') is null
                       or not exists (select 1 from public.question_options o
                                      where o.id = (e ->> 'id')::uuid and o.question_id = qid)) then
        raise exception 'لا يمكن إضافة أو حذف اختيارات بعد بدء المسابقة';
      end if;
    end if;
    update public.questions set
      text = v_text, category = v_cat, explanation = nullif(btrim(coalesce(p ->> 'explanation', '')), ''),
      points = nullif(p ->> 'points', '')::int, seconds = nullif(p ->> 'seconds', '')::int,
      active = coalesce((p ->> 'active')::boolean, active)
    where id = qid;
  else
    insert into public.questions (text, category, explanation, points, seconds, active)
    values (v_text, v_cat, nullif(btrim(coalesce(p ->> 'explanation', '')), ''),
            nullif(p ->> 'points', '')::int, nullif(p ->> 'seconds', '')::int,
            coalesce((p ->> 'active')::boolean, true))
    returning id into qid;
  end if;

  for i in 0 .. n - 1 loop
    item := opts -> i;
    oid := nullif(item ->> 'id', '')::uuid;
    if oid is not null and exists (select 1 from public.question_options where id = oid and question_id = qid) then
      update public.question_options set text = btrim(item ->> 'text'), position = i where id = oid;
    else
      insert into public.question_options (question_id, position, text)
      values (qid, i, btrim(item ->> 'text')) returning id into oid;
    end if;
    keep := keep || oid;
    if i = v_ci then correct_id := oid; end if;
  end loop;
  delete from public.question_options where question_id = qid and id <> all (keep);
  insert into public.answer_keys (question_id, correct_option_id) values (qid, correct_id)
  on conflict (question_id) do update set correct_option_id = excluded.correct_option_id;
  return qid;
end $$;

create or replace function public.admin_save_question(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare qid uuid;
begin
  perform public._require_admin();
  qid := public._save_question(p);
  return jsonb_build_object('ok', true, 'id', qid,
    'has_attempts', exists (select 1 from public.attempt_questions aq join public.attempts a on a.id = aq.attempt_id
                            where aq.question_id = qid and not a.is_test));
end $$;

create or replace function public.admin_list_questions() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public._require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'text', q.text, 'category', q.category, 'explanation', q.explanation,
      'points', q.points, 'seconds', q.seconds, 'active', q.active,
      'correct_option_id', k.correct_option_id,
      'has_attempts', exists (select 1 from public.attempt_questions aq join public.attempts a on a.id = aq.attempt_id
                              where aq.question_id = q.id and not a.is_test),
      'options', (select jsonb_agg(jsonb_build_object('id', o.id, 'text', o.text) order by o.position)
                  from public.question_options o where o.question_id = q.id)
    ) order by q.created_at, q.id)
    from public.questions q left join public.answer_keys k on k.question_id = q.id
  ), '[]'::jsonb);
end $$;

create or replace function public.admin_set_question_active(p_id uuid, p_active boolean) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform public._require_admin();
  update public.questions set active = p_active where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_delete_question(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform public._require_admin();
  if exists (select 1 from public.attempt_questions aq join public.attempts a on a.id = aq.attempt_id
             where aq.question_id = p_id and not a.is_test) then
    raise exception 'لا يمكن حذف سؤال له إجابات مسجلة. عطّله بدلاً من حذفه';
  end if;
  delete from public.questions where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- استيراد أسئلة: [{text, category, options:[...نصوص], correct_index, explanation, points, seconds}]
create or replace function public.admin_import_questions(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare i int; r jsonb; v_ins int := 0; v_skip int := 0; v_errs jsonb := '[]'::jsonb; opts jsonb;
begin
  perform public._require_admin();
  for i in 0 .. coalesce(jsonb_array_length(p_rows), 0) - 1 loop
    r := p_rows -> i;
    begin
      if exists (select 1 from public.questions where btrim(text) = btrim(coalesce(r ->> 'text', ''))) then
        v_skip := v_skip + 1; continue;
      end if;
      select jsonb_agg(jsonb_build_object('text', t)) into opts from jsonb_array_elements_text(r -> 'options') t;
      perform public._save_question(jsonb_set(r - 'id', '{options}', coalesce(opts, '[]'::jsonb)));
      v_ins := v_ins + 1;
    exception when others then
      v_errs := v_errs || jsonb_build_object('row', coalesce((r ->> '_row')::int, i + 1), 'message', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('ok', true, 'inserted', v_ins, 'skipped', v_skip, 'errors', v_errs);
end $$;

-- ---------------- الباصات ----------------

create or replace function public.admin_list_buses() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public._require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name,
             'participants', (select count(*) from public.participants p where p.bus_id = b.id))
           order by (case when btrim(b.name) ~ '^[0-9]{1,9}$' then 0 else 1 end),
                    (case when btrim(b.name) ~ '^[0-9]{1,9}$' then btrim(b.name)::int end), b.name)
    from public.buses b), '[]'::jsonb);
end $$;

create or replace function public.admin_save_bus(p_id int, p_name text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_name text := btrim(translate(coalesce(p_name, ''), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789')); v_id int;
begin
  perform public._require_admin();
  if length(v_name) < 1 or length(v_name) > 40 then raise exception 'اسم أو رقم الباص مطلوب (حتى 40 حرفاً)'; end if;
  begin
    if p_id is null then
      insert into public.buses (name) values (v_name) returning id into v_id;
    else
      update public.buses set name = v_name where id = p_id returning id into v_id;
    end if;
  exception when unique_violation then
    raise exception 'هذا الباص موجود مسبقاً';
  end;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.admin_delete_bus(p_id int) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform public._require_admin();
  delete from public.buses where id = p_id;       -- مشتركو الباص يصبحون «بدون باص»
  return jsonb_build_object('ok', true);
end $$;

-- ---------------- المشتركون ----------------

create or replace function public.admin_list_participants() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public._require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'phone', p.phone, 'gender', p.gender, 'bus_id', p.bus_id, 'bus_name', b.name,
      'source', p.source, 'is_test', p.is_test,
      'status', case when a.id is null then 'none' when a.finished_at is null then 'in_progress' else 'finished' end,
      'points', a.total_points) order by p.created_at, p.name)
    from public.participants p
    left join public.buses b on b.id = p.bus_id
    left join public.attempts a on a.participant_id = p.id
  ), '[]'::jsonb);
end $$;

create or replace function public.admin_save_participant(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  ph text := public.normalize_phone(p ->> 'phone');
  v_name text := regexp_replace(btrim(coalesce(p ->> 'name', '')), '\s+', ' ', 'g');
  v_g text := public.parse_gender(p ->> 'gender');
  v_bus int := nullif(p ->> 'bus_id', '')::int; v_id uuid := nullif(p ->> 'id', '')::uuid;
begin
  perform public._require_admin();
  if ph is null then raise exception 'رقم الجوال غير صحيح'; end if;
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'الاسم مطلوب (حرفان على الأقل)'; end if;
  if v_g is null then raise exception 'اختر الجنس'; end if;
  if v_bus is not null and not exists (select 1 from public.buses where id = v_bus) then raise exception 'الباص غير موجود'; end if;
  begin
    if v_id is null then
      insert into public.participants (phone, name, gender, bus_id, source) values (ph, v_name, v_g, v_bus, 'admin')
      returning id into v_id;
    else
      update public.participants set phone = ph, name = v_name, gender = v_g, bus_id = v_bus where id = v_id;
    end if;
  exception when unique_violation then
    raise exception 'رقم الجوال مسجل مسبقاً لمشترك آخر';
  end;
  return jsonb_build_object('ok', true, 'id', v_id, 'phone', ph);
end $$;

create or replace function public.admin_delete_participant(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform public._require_admin();
  delete from public.participants where id = p_id;   -- تُحذف محاولته معه
  return jsonb_build_object('ok', true);
end $$;

-- استيراد مشتركين: [{name, phone, gender, bus, _row?}] ، p_mode = 'update' | 'skip' للمكرر
create or replace function public.admin_import_participants(p_rows jsonb, p_mode text default 'skip') returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  i int; r jsonb; ph text; v_name text; v_g text; v_bus_txt text; v_bus int; v_row int; v_exist uuid;
  v_ins int := 0; v_upd int := 0; v_skip int := 0; v_busnew int := 0; v_errs jsonb := '[]'::jsonb;
begin
  perform public._require_admin();
  for i in 0 .. coalesce(jsonb_array_length(p_rows), 0) - 1 loop
    r := p_rows -> i;
    v_row := coalesce(nullif(r ->> '_row', '')::int, i + 1);
    begin
      ph := public.normalize_phone(r ->> 'phone');
      v_name := regexp_replace(btrim(coalesce(r ->> 'name', '')), '\s+', ' ', 'g');
      v_g := public.parse_gender(r ->> 'gender');
      v_bus_txt := btrim(translate(coalesce(r ->> 'bus', ''), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789'));
      if ph is null then raise exception 'رقم الجوال غير صحيح'; end if;
      if length(v_name) < 2 or length(v_name) > 80 then raise exception 'الاسم مطلوب'; end if;
      if v_g is null then raise exception 'الجنس غير معروف (استخدم ذكر/أنثى)'; end if;
      v_bus := null;
      if v_bus_txt <> '' then
        select id into v_bus from public.buses where lower(btrim(name)) = lower(v_bus_txt);
        if v_bus is null then
          insert into public.buses (name) values (left(v_bus_txt, 40)) returning id into v_bus;
          v_busnew := v_busnew + 1;
        end if;
      end if;
      select id into v_exist from public.participants where phone = ph;
      if v_exist is null then
        insert into public.participants (phone, name, gender, bus_id, source) values (ph, v_name, v_g, v_bus, 'import');
        v_ins := v_ins + 1;
      elsif p_mode = 'update' then
        update public.participants set name = v_name, gender = v_g, bus_id = v_bus where id = v_exist;
        v_upd := v_upd + 1;
      else
        v_skip := v_skip + 1;
      end if;
    exception when others then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('ok', true, 'inserted', v_ins, 'updated', v_upd, 'skipped', v_skip,
                            'buses_created', v_busnew, 'errors', v_errs);
end $$;

-- ---------------- النتائج وأدوات الأمان ----------------

create or replace function public.admin_results() returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform public._require_admin();
  perform public._sweep();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'participant_id', r.participant_id, 'rank', r.rnk, 'name', r.name, 'phone', r.phone, 'gender', r.gender,
      'bus_id', r.bus_id, 'bus_name', r.bus_name, 'points', r.points, 'correct', r.correct_count,
      'total_ms', r.total_ms, 'status', r.status, 'finished_at', r.finished_at,
      'resumes', r.resume_count, 'is_test', r.is_test) order by r.rnk, r.finished_at, r.name)
    from public._ranking(true) r), '[]'::jsonb);
end $$;

-- حذف كل البيانات التجريبية (المحاولات التجريبية + المسجلون ذاتياً أثناء التجربة)
create or replace function public.admin_delete_test_data() returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_a int; v_p int;
begin
  perform public._require_admin();
  delete from public.attempts where is_test;           get diagnostics v_a = row_count;
  delete from public.participants where is_test;       get diagnostics v_p = row_count;
  return jsonb_build_object('ok', true, 'attempts', v_a, 'participants', v_p);
end $$;

-- إعادة محاولة تجريبية فقط (لتجربة المسابقة بنفس الرقم). المحاولات الحقيقية لا تُمسح أبداً.
create or replace function public.admin_reset_test_attempt(p_participant_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v int;
begin
  perform public._require_admin();
  delete from public.attempts where participant_id = p_participant_id and is_test;
  get diagnostics v = row_count;
  return jsonb_build_object('ok', true, 'deleted', v);
end $$;

-- إعادة التصحيح بعد تعديل إجابة صحيحة خاطئة (تعتمد على اللقطات المحفوظة لكل محاولة)
create or replace function public.admin_regrade() returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_n int; r record;
begin
  perform public._require_admin();
  update public.attempt_questions aq set
    is_correct = (aq.chosen_option_id is not null and aq.chosen_option_id = k.correct_option_id),
    points_awarded = case when aq.chosen_option_id is not null and aq.chosen_option_id = k.correct_option_id
      then aq.base_points + round(aq.bonus_points * greatest(0, 1 - coalesce(aq.elapsed_ms, aq.seconds * 1000)::numeric / (aq.seconds * 1000)))::int
      else 0 end
  from public.answer_keys k
  where k.question_id = aq.question_id and aq.status = 'answered';
  get diagnostics v_n = row_count;
  for r in select id from public.attempts loop perform public._recalc_attempt(r.id); end loop;
  return jsonb_build_object('ok', true, 'regraded', v_n);
end $$;

-- ---------------------------------------------------------------------
-- 6) الأمان: RLS + الصلاحيات
-- ---------------------------------------------------------------------

-- تفعيل RLS على كل الجداول؛ المشرف فقط يملك سياسة كاملة
do $$
declare t text;
begin
  foreach t in array array['admins','settings','buses','participants','questions','question_options',
                           'answer_keys','attempts','attempt_questions','attempt_options']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists admin_all on public.%I', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

-- لا صلاحيات للمستخدم العام على أي جدول. المشرف المسجّل تحكمه سياسات RLS أعلاه.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- الدوال: نسحب كل شيء ثم نمنح ما يلزم فقط
revoke execute on all functions in schema public from public, anon, authenticated;

-- دوال المشترك (للمستخدم العام)
grant execute on function
  public.get_public_config(int),
  public.lookup_participant(text),
  public.register_participant(text, text, text, int),
  public.start_attempt(text, text),
  public.get_current_question(text, text),
  public.submit_answer(text, text, int, text),
  public.get_my_result(text, text),
  public.get_leaderboard(text, text),
  public.am_i_admin()
to anon, authenticated;

-- دوال المشرف (تتحقق أيضاً من is_admin() داخلياً)
grant execute on function
  public.is_admin(),
  public.admin_get_settings(),
  public.admin_save_settings(jsonb),
  public.admin_set_status(text, boolean),
  public.admin_publish_results(boolean),
  public.admin_dashboard(),
  public.admin_save_question(jsonb),
  public.admin_list_questions(),
  public.admin_set_question_active(uuid, boolean),
  public.admin_delete_question(uuid),
  public.admin_import_questions(jsonb),
  public.admin_list_buses(),
  public.admin_save_bus(int, text),
  public.admin_delete_bus(int),
  public.admin_list_participants(),
  public.admin_save_participant(jsonb),
  public.admin_delete_participant(uuid),
  public.admin_import_participants(jsonb, text),
  public.admin_results(),
  public.admin_delete_test_data(),
  public.admin_reset_test_attempt(uuid),
  public.admin_regrade()
to authenticated;

-- ---------------------------------------------------------------------
-- 7) المشرف  ← ⚠️ عدّل البريد أدناه إلى بريدك الحقيقي (حروف صغيرة)
--    ثم أنشئ المستخدم بنفس البريد من: Authentication ← Users ← Add user
-- ---------------------------------------------------------------------
insert into public.admins (email) values ('change-me@example.invalid') on conflict do nothing;

-- ---------------------------------------------------------------------
-- 8) بيانات تجريبية (للتجربة فقط — احذفها من لوحة المشرف قبل الإطلاق)
--    تُضاف مرة واحدة فقط إذا كانت الجداول فارغة.
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.buses) then
    insert into public.buses (name) values ('1'), ('2');
  end if;

  if not exists (select 1 from public.questions) then
    perform public._save_question(e) from jsonb_array_elements($json$[
      {"text":"ما ميقات أهل المدينة المنورة؟","category":"fiqh",
       "options":[{"text":"الجحفة"},{"text":"ذو الحليفة"},{"text":"يلملم"},{"text":"قرن المنازل"}],"correct_index":1,
       "explanation":"ميقات أهل المدينة ومن مرّ بها هو ذو الحليفة، ويُعرف اليوم بأبيار علي، وهو أبعد المواقيت عن مكة."},
      {"text":"كم عدد أشواط الطواف حول الكعبة؟","category":"fiqh",
       "options":[{"text":"خمسة"},{"text":"سبعة"},{"text":"ثلاثة"},{"text":"تسعة"}],"correct_index":1,
       "explanation":"الطواف سبعة أشواط، يبدأ من الحجر الأسود وينتهي عنده، وتكون الكعبة عن يسار الطائف."},
      {"text":"من أين يبدأ السعي وأين ينتهي؟","category":"fiqh",
       "options":[{"text":"يبدأ من المروة وينتهي بالصفا"},{"text":"يبدأ من الصفا وينتهي بالصفا"},{"text":"يبدأ من الصفا وينتهي بالمروة"},{"text":"يبدأ من المروة وينتهي بالمروة"}],"correct_index":2,
       "explanation":"السعي سبعة أشواط يبدأ بالصفا وينتهي بالمروة؛ فالذهاب من الصفا إلى المروة شوط، والرجوع منها إلى الصفا شوط آخر."},
      {"text":"أي مما يلي ليس من محظورات الإحرام؟","category":"fiqh",
       "options":[{"text":"لبس المخيط للرجل"},{"text":"تغطية الرأس للرجل"},{"text":"قصّ الأظافر"},{"text":"الاغتسال بالماء"}],"correct_index":3,
       "explanation":"الاغتسال وتنظيف البدن مباح للمحرم، أما لبس المخيط للرجل وتغطية رأسه وقصّ الأظافر والشعر فمن محظورات الإحرام."},
      {"text":"ما الذي يفعله المعتمر بعد السعي ليتحلل من إحرامه؟","category":"fiqh",
       "options":[{"text":"يبيت بمزدلفة"},{"text":"يرمي الجمرات"},{"text":"يقف بعرفة"},{"text":"يحلق رأسه أو يقصّره"}],"correct_index":3,
       "explanation":"بعد السعي يحلق الرجل رأسه أو يقصّره، وتقصّر المرأة قدر أنملة من أطراف شعرها، فيتحلل المعتمر وتنتهي عمرته."},
      {"text":"لمن نبعت بئر زمزم بأمر الله تعالى؟","category":"culture",
       "options":[{"text":"لإبراهيم وسارة عليهما السلام"},{"text":"لهاجر وابنها إسماعيل عليهما السلام"},{"text":"لآدم وحواء عليهما السلام"},{"text":"لنوح وابنه عليهما السلام"}],"correct_index":1,
       "explanation":"نبعت زمزم حين تُركت هاجر وابنها الرضيع إسماعيل عليهما السلام في وادٍ غير ذي زرع، فجعلها الله سقيا لهما ولمن بعدهما."},
      {"text":"في أي جبل يقع غار حراء الذي نزل فيه أول الوحي؟","category":"culture",
       "options":[{"text":"جبل ثور"},{"text":"جبل أبي قبيس"},{"text":"جبل النور"},{"text":"جبل أحد"}],"correct_index":2,
       "explanation":"غار حراء في جبل النور بمكة المكرمة، وفيه نزل جبريل عليه السلام على النبي ﷺ بأول آيات القرآن."},
      {"text":"في أي سنة هجرية كان فتح مكة؟","category":"culture",
       "options":[{"text":"السنة السادسة"},{"text":"السنة السابعة"},{"text":"السنة الثامنة"},{"text":"السنة العاشرة"}],"correct_index":2,
       "explanation":"كان فتح مكة في رمضان من السنة الثامنة للهجرة، ودخلها النبي ﷺ فاتحاً وعفا عن أهلها."}
    ]$json$::jsonb) as t(e);
  end if;
end $$;
