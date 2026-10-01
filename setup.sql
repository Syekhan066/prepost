-- Jalankan sekali di Supabase: SQL Editor > New query > Run
create extension if not exists pgcrypto with schema extensions;

create table public.students (
  nim text primary key, nama text not null,
  scores jsonb not null default '{}',   -- lengkap (skor + jawaban per soal), hanya admin
  pub jsonb not null default '{}',      -- hanya persen, dipakai leaderboard publik
  created_at timestamptz default now(), updated_at timestamptz default now());
create table public.attempts (          -- riwayat setiap pengumpulan tes (tidak ditimpa)
  id bigserial primary key, nim text, week int, type text, result jsonb, at timestamptz default now());
create table public.admin (pw_hash text);
alter table public.students enable row level security;
alter table public.attempts enable row level security;
alter table public.admin enable row level security;  -- tanpa policy: tidak bisa diakses langsung dari browser

insert into public.admin values (extensions.crypt('CEILINKSTRIAL2026', extensions.gen_salt('bf')));

create function public.is_admin(p text) returns boolean language sql security definer set search_path = '' as
$$ select exists(select 1 from public.admin where pw_hash = extensions.crypt(p, pw_hash)) $$;
revoke all on function public.is_admin(text) from public, anon, authenticated;

create function public.register_student(p_nim text, p_nama text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_nim text := left(trim(coalesce(p_nim,'')),40);
begin
  if v_nim = '' or length(trim(coalesce(p_nama,''))) = 0 then raise exception 'Nama dan NIM wajib diisi'; end if;
  insert into public.students(nim,nama) values (v_nim, left(trim(p_nama),80))
    on conflict (nim) do update set nama = excluded.nama, updated_at = now();
  return (select jsonb_build_object('nama',nama,'nim',nim,'scores',scores) from public.students where nim = v_nim);
end $$;

create function public.save_score(p_nim text, p_week int, p_type text, p_result jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare w text := p_week::text; pct numeric := (p_result->>'percent')::numeric;
begin
  if p_type not in ('pretest','posttest') or p_week < 1 or p_week > 50 then raise exception 'Data tidak valid'; end if;
  if pct is null or pct < 0 or pct > 100 then raise exception 'Skor tidak valid'; end if;
  if not exists (select 1 from public.students where nim = p_nim) then raise exception 'NIM belum terdaftar'; end if;
  update public.students set
    scores = jsonb_set(scores, array[w], coalesce(scores->w,'{}'::jsonb) || jsonb_build_object(p_type, p_result), true),
    pub    = jsonb_set(pub,    array[w], coalesce(pub->w,'{}'::jsonb)    || jsonb_build_object(p_type, jsonb_build_object('percent', pct)), true),
    updated_at = now()
  where nim = p_nim;
  insert into public.attempts(nim,week,type,result) values (p_nim,p_week,p_type,p_result);
end $$;

create function public.get_leaderboard() returns jsonb language sql security definer set search_path = '' as
$$ select coalesce(jsonb_agg(jsonb_build_object('nama',nama,'nim',nim,'scores',pub)), '[]'::jsonb) from public.students $$;

create function public.admin_students(pw text) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin(pw) then raise exception 'Password salah'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('nama',nama,'nim',nim,'scores',scores)), '[]'::jsonb) from public.students);
end $$;
