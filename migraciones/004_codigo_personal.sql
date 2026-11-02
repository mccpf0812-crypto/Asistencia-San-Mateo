-- =====================================================================
--  Actualización 004 · Código personal de 4 números para marcar la salida
--  - Al marcar entrada, cada persona elige un código de 4 números.
--  - Para marcar la salida se necesita ese código (y el mismo celular).
--  - 5 intentos fallidos bloquean el turno: solo el panel puede cerrarlo.
--  Correr en Supabase > SQL Editor > Run.
-- =====================================================================

alter table public.registros add column if not exists codigo_hash text;
alter table public.registros add column if not exists intentos    int not null default 0;

-- La versión sin código deja de existir.
drop function if exists public.marcar_entrada(text, text, text);
drop function if exists public.marcar_salida(uuid, text);

create or replace function public.marcar_entrada(p_nombre text, p_apellido text, p_empresa text, p_codigo text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_nombre   text := regexp_replace(trim(coalesce(p_nombre,'')),   '\s+', ' ', 'g');
  v_apellido text := regexp_replace(trim(coalesce(p_apellido,'')), '\s+', ' ', 'g');
  v_empresa  text := regexp_replace(trim(coalesce(p_empresa,'')),  '\s+', ' ', 'g');
  v_clave    text;
  v_exist    text;
  v_n2       text;
  v_a2       text;
  v_token    text := encode(extensions.gen_random_bytes(24), 'hex');
  r          public.registros;
begin
  if char_length(v_nombre) < 2 or char_length(v_apellido) < 2 then
    return json_build_object('ok', false, 'error', 'nombre');
  end if;
  if char_length(v_empresa) < 2 then
    return json_build_object('ok', false, 'error', 'empresa');
  end if;
  if coalesce(p_codigo,'') !~ '^[0-9]{4}$' then
    return json_build_object('ok', false, 'error', 'codigo');
  end if;
  -- Reutiliza la forma ya escrita de la empresa (evita "campero" vs "Campero").
  select empresa into v_exist from public.registros
   where normalizar(empresa) = normalizar(v_empresa)
   order by entrada desc limit 1;
  if v_exist is not null then v_empresa := v_exist; end if;

  v_clave := normalizar(v_nombre || ' ' || v_apellido);

  -- Reutiliza la forma ya escrita del nombre (evita "jose lopez" vs "José López").
  select nombre, apellido into v_n2, v_a2 from public.registros
   where clave = v_clave order by entrada desc limit 1;
  if found then v_nombre := v_n2; v_apellido := v_a2; end if;

  select * into r from public.registros where clave = v_clave and salida is null;
  if found then
    return json_build_object('ok', false, 'error', 'abierta', 'registro', reg_json(r));
  end if;

  begin
    insert into public.registros (nombre, apellido, clave, empresa, token_hash, codigo_hash)
    values (v_nombre, v_apellido, v_clave, v_empresa, hash_token(v_token),
            extensions.crypt(p_codigo, extensions.gen_salt('bf', 6)))
    returning * into r;
  exception when unique_violation then
    select * into r from public.registros where clave = v_clave and salida is null;
    return json_build_object('ok', false, 'error', 'abierta', 'registro', reg_json(r));
  end;
  return json_build_object('ok', true, 'registro', reg_json(r), 'token', v_token);
end $$;

-- Marcar salida: mismo celular (clave del turno) + código personal. 5 intentos.
create or replace function public.marcar_salida(p_id uuid, p_token text, p_codigo text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare r public.registros;
begin
  select * into r from public.registros
   where id = p_id and salida is null
     and token_hash is not null and token_hash = hash_token(p_token)
   for update;
  if not found then
    return json_build_object('ok', false, 'error', 'no_abierta');
  end if;
  if r.intentos >= 5 then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  if r.codigo_hash is not null
     and r.codigo_hash <> extensions.crypt(coalesce(p_codigo,''), r.codigo_hash) then
    update public.registros set intentos = intentos + 1 where id = r.id;
    if r.intentos + 1 >= 5 then
      return json_build_object('ok', false, 'error', 'bloqueado');
    end if;
    return json_build_object('ok', false, 'error', 'codigo', 'restantes', 5 - (r.intentos + 1));
  end if;
  update public.registros set salida = now() where id = r.id returning * into r;
  return json_build_object('ok', true, 'registro', reg_json(r));
end $$;

-- Panel: mostrar si un turno quedó bloqueado por intentos.
drop function if exists public.abiertos(text);
create or replace function public.abiertos(p_pin text)
returns table (id uuid, nombre text, apellido text, clave text, empresa text,
               entrada timestamptz, salida timestamptz, dia date, salida_manual boolean, bloqueado boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from public.config where pin_hash = crypt(coalesce(p_pin,''), pin_hash)) then
    raise exception 'PIN incorrecto' using errcode = '28000';
  end if;
  return query select r.id, r.nombre, r.apellido, r.clave, r.empresa,
                      r.entrada, r.salida, r.dia, r.salida_manual, r.intentos >= 5
                 from public.registros r
                where r.salida is null
                order by r.entrada asc limit 500;
end $$;

revoke all on function public.marcar_entrada(text,text,text,text), public.marcar_salida(uuid,text,text),
  public.abiertos(text) from public;
grant execute on function public.marcar_entrada(text,text,text,text), public.marcar_salida(uuid,text,text),
  public.abiertos(text) to anon, authenticated;
