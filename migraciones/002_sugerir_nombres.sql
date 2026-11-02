-- Actualización: sugerencias de nombres. Correr en Supabase > SQL Editor.

-- ---------- Funciones ----------
create or replace function public.normalizar(t text) returns text
language sql immutable as $$
  select regexp_replace(
           translate(lower(trim(t)), 'áéíóúüñàèìòùäëïö', 'aeiouunaeiouaeio'),
           '\s+', ' ', 'g')
$$;

create or replace function public.hora_servidor() returns timestamptz
language sql stable as $$ select now() $$;

-- Marcar entrada: la hora la pone el servidor.
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
    return json_build_object('ok', false, 'error', 'abierta', 'registro', row_to_json(r));
  end if;

  begin
    insert into public.registros (nombre, apellido, clave, empresa)
    values (v_nombre, v_apellido, v_clave, v_empresa)
    returning * into r;
  exception when unique_violation then
    select * into r from public.registros where clave = v_clave and salida is null;
    return json_build_object('ok', false, 'error', 'abierta', 'registro', row_to_json(r));
  end;
  return json_build_object('ok', true, 'registro', row_to_json(r));
end $$;

-- Marcar salida: la hora la pone el servidor.
create or replace function public.marcar_salida(p_id uuid)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare r public.registros;
begin
  update public.registros set salida = now()
   where id = p_id and salida is null
  returning * into r;
  if not found then
    return json_build_object('ok', false, 'error', 'no_abierta');
  end if;
  return json_build_object('ok', true, 'registro', row_to_json(r));
end $$;

-- Personas en turno ahora (lo que ven los trabajadores).
create or replace function public.en_turno()
returns table (id uuid, nombre text, apellido text, empresa text, entrada timestamptz, dia date)
language sql stable security definer set search_path = public as $$
  select id, nombre, apellido, empresa, entrada, dia
    from public.registros where salida is null
   order by entrada asc limit 500
$$;

-- Lista de empresas ya usadas (para sugerencias).
create or replace function public.empresas()
returns setof text language sql stable security definer set search_path = public as $$
  select empresa from (
    select distinct on (normalizar(empresa)) empresa
      from public.registros
     order by normalizar(empresa), entrada desc
  ) t order by empresa limit 300
$$;

-- Personas ya registradas (para sugerir el nombre al escribir).
create or replace function public.personas()
returns table (nombre text, apellido text)
language sql stable security definer set search_path = public as $$
  select nombre, apellido from (
    select distinct on (clave) clave, nombre, apellido
      from public.registros
     order by clave, entrada desc
  ) t order by apellido, nombre limit 3000
$$;

-- Reportes: solo con el PIN del administrador.
create or replace function public.reporte(p_pin text, p_desde date, p_hasta date)
returns setof public.registros language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from public.config where pin_hash = crypt(coalesce(p_pin,''), pin_hash)) then
    raise exception 'PIN incorrecto' using errcode = '28000';
  end if;
  if p_hasta - p_desde > 62 then
    raise exception 'Rango demasiado grande' using errcode = '22023';
  end if;
  return query select * from public.registros
                where dia between p_desde and p_hasta
                order by entrada asc;
end $$;

-- Cambiar el PIN desde el panel.
create or replace function public.cambiar_pin(p_actual text, p_nuevo text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  if char_length(coalesce(p_nuevo,'')) < 6 then
    raise exception 'El PIN nuevo debe tener al menos 6 caracteres' using errcode = '22023';
  end if;
  update public.config set pin_hash = crypt(p_nuevo, gen_salt('bf'))
   where id = 1 and pin_hash = crypt(coalesce(p_actual,''), pin_hash);
  if not found then raise exception 'PIN incorrecto' using errcode = '28000'; end if;
  return true;
end $$;

revoke all on function public.marcar_entrada(text,text,text), public.marcar_salida(uuid),
  public.en_turno(), public.empresas(), public.personas(), public.reporte(text,date,date),
  public.cambiar_pin(text,text), public.hora_servidor() from public;
grant execute on function public.marcar_entrada(text,text,text), public.marcar_salida(uuid),
  public.en_turno(), public.empresas(), public.personas(), public.reporte(text,date,date),
  public.cambiar_pin(text,text), public.hora_servidor() to anon, authenticated;
