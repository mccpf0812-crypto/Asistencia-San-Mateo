-- =====================================================================
--  Actualización 003 · La salida solo se marca desde el celular de la entrada
--  - Cada entrada recibe una clave secreta que queda guardada en ese celular.
--  - Nadie puede ver la lista de compañeros en turno.
--  - El administrador (con PIN) puede cerrar turnos olvidados; quedan como "manual".
--  Correr en Supabase > SQL Editor > Run.
-- =====================================================================

alter table public.registros add column if not exists token_hash    text;
alter table public.registros add column if not exists salida_manual boolean not null default false;

-- Quitar las funciones viejas que dejaban ver a todos o cerrar cualquier turno.
drop function if exists public.en_turno();
drop function if exists public.marcar_salida(uuid);

-- Registro en formato público (sin claves internas).
create or replace function public.reg_json(r public.registros) returns json
language sql immutable as $$
  select json_build_object('id', r.id, 'nombre', r.nombre, 'apellido', r.apellido,
    'empresa', r.empresa, 'entrada', r.entrada, 'salida', r.salida, 'dia', r.dia,
    'salida_manual', r.salida_manual)
$$;

create or replace function public.hash_token(t text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(coalesce(t,''), 'sha256'), 'hex')
$$;

-- Marcar entrada: la hora la pone el servidor y devuelve la clave del turno.
create or replace function public.marcar_entrada(p_nombre text, p_apellido text, p_empresa text)
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
    insert into public.registros (nombre, apellido, clave, empresa, token_hash)
    values (v_nombre, v_apellido, v_clave, v_empresa, hash_token(v_token))
    returning * into r;
  exception when unique_violation then
    select * into r from public.registros where clave = v_clave and salida is null;
    return json_build_object('ok', false, 'error', 'abierta', 'registro', reg_json(r));
  end;
  return json_build_object('ok', true, 'registro', reg_json(r), 'token', v_token);
end $$;

-- Marcar salida: solo con la clave que recibió el celular al marcar la entrada.
create or replace function public.marcar_salida(p_id uuid, p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare r public.registros;
begin
  update public.registros set salida = now()
   where id = p_id and salida is null
     and token_hash is not null and token_hash = hash_token(p_token)
  returning * into r;
  if not found then
    return json_build_object('ok', false, 'error', 'no_abierta');
  end if;
  return json_build_object('ok', true, 'registro', reg_json(r));
end $$;

-- Turnos abiertos de ESTE celular (solo los que tiene clave).
create or replace function public.mis_turnos(p_tokens text[])
returns table (id uuid, nombre text, apellido text, empresa text, entrada timestamptz, dia date)
language sql stable security definer set search_path = public, extensions as $$
  select id, nombre, apellido, empresa, entrada, dia
    from public.registros
   where salida is null
     and token_hash in (select hash_token(t) from unnest(coalesce(p_tokens[1:50], '{}')) t)
   order by entrada asc
$$;

-- Cerrar un turno olvidado desde el panel (con PIN). Queda marcado como manual.
create or replace function public.cerrar_turno(p_pin text, p_id uuid, p_salida timestamptz)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare r public.registros; v_sal timestamptz := coalesce(p_salida, now());
begin
  if not exists (select 1 from public.config where pin_hash = crypt(coalesce(p_pin,''), pin_hash)) then
    raise exception 'PIN incorrecto' using errcode = '28000';
  end if;
  if v_sal > now() then
    raise exception 'La hora de salida no puede ser en el futuro' using errcode = '22023';
  end if;
  update public.registros set salida = v_sal, salida_manual = true
   where id = p_id and salida is null and entrada <= v_sal
  returning * into r;
  if not found then
    raise exception 'No se pudo cerrar: el turno ya estaba cerrado o la salida es antes de la entrada' using errcode = '22023';
  end if;
  return reg_json(r);
end $$;

-- Reportes: solo con el PIN del administrador (sin claves internas).
drop function if exists public.reporte(text, date, date);
create or replace function public.reporte(p_pin text, p_desde date, p_hasta date)
returns table (id uuid, nombre text, apellido text, clave text, empresa text,
               entrada timestamptz, salida timestamptz, dia date, salida_manual boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from public.config where pin_hash = crypt(coalesce(p_pin,''), pin_hash)) then
    raise exception 'PIN incorrecto' using errcode = '28000';
  end if;
  if p_hasta - p_desde > 62 then
    raise exception 'Rango demasiado grande' using errcode = '22023';
  end if;
  return query select r.id, r.nombre, r.apellido, r.clave, r.empresa,
                      r.entrada, r.salida, r.dia, r.salida_manual
                 from public.registros r
                where r.dia between p_desde and p_hasta
                order by r.entrada asc;
end $$;

-- Todos los turnos sin salida (para el panel, con PIN).
create or replace function public.abiertos(p_pin text)
returns table (id uuid, nombre text, apellido text, clave text, empresa text,
               entrada timestamptz, salida timestamptz, dia date, salida_manual boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from public.config where pin_hash = crypt(coalesce(p_pin,''), pin_hash)) then
    raise exception 'PIN incorrecto' using errcode = '28000';
  end if;
  return query select r.id, r.nombre, r.apellido, r.clave, r.empresa,
                      r.entrada, r.salida, r.dia, r.salida_manual
                 from public.registros r
                where r.salida is null
                order by r.entrada asc limit 500;
end $$;

revoke all on function public.marcar_salida(uuid,text), public.mis_turnos(text[]),
  public.cerrar_turno(text,uuid,timestamptz), public.reporte(text,date,date), public.abiertos(text),
  public.reg_json(public.registros), public.hash_token(text) from public;
revoke all on function public.reg_json(public.registros), public.hash_token(text) from anon, authenticated;
grant execute on function public.marcar_salida(uuid,text), public.mis_turnos(text[]),
  public.cerrar_turno(text,uuid,timestamptz), public.reporte(text,date,date), public.abiertos(text) to anon, authenticated;
