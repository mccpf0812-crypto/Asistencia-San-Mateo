# Reloj de Asistencia

Registro de entrada y salida desde el celular, sin cuentas para los trabajadores.

- **Pantalla de marcaje** (`index.html`): nombre, apellido y empresa obligatorios; botón de entrada; lista "En turno ahora" con botón de salida.
- **Panel de reportes** (`admin.html`, protegido con PIN): bitácora por día, filtro por empresa, reporte **diario** y **semanal** en Excel (.xlsx).
- **Hora verificable**: la pone la base de datos (Supabase), no el celular. Nadie puede leer ni modificar los registros directamente; solo marcar entrada/salida, y los reportes piden PIN.

## Puesta en marcha

### 1. Base de datos (Supabase, gratis)
1. Entra a https://supabase.com y crea un proyecto nuevo (región: la más cercana, por ejemplo *East US*). Guarda la contraseña que te pida.
2. Ve a **SQL Editor → New query**, pega todo el contenido de `schema.sql`.
3. **Antes de correrlo**, busca `CAMBIA_ESTE_PIN` y cámbialo por tu PIN de administrador (mínimo 6 caracteres).
4. Toca **Run**. Debe decir *Success*.
5. Ve a **Project Settings → API** (o *Data API*) y copia:
   - **Project URL**
   - **anon public key**

### 2. Configuración
Abre `config.js` y pega esos dos datos en `supabaseUrl` y `supabaseAnonKey`. Guarda (en GitHub: botón **Commit changes**).

### 3. Publicar
**Vercel**: *Add New → Project → Import* este repositorio → *Deploy*. No hay que configurar nada más.

**Cloudflare Pages** (gratis también para uso de empresa): *Workers & Pages → Create → Pages → Connect to Git* → elige este repositorio → *Framework preset: None*, *Build command:* vacío, *Output directory:* `/` → *Save and Deploy*.

### 4. Usar
- Comparte el enlace principal con los trabajadores. Pueden agregarlo a la pantalla de inicio (Android: menú ⋮ → *Agregar a pantalla principal*; iPhone: Compartir → *Agregar a inicio*).
- El panel está en `tu-enlace/admin.html`. Entra con tu PIN. Desde ahí puedes cambiar el PIN.

## Notas
- La zona horaria es Guatemala (`config.js` → `zonaHoraria`).
- Cada marca de entrada guarda el día; si alguien sale después de medianoche, la salida se cuenta en el día de entrada.
- El plan gratuito de Supabase pausa el proyecto tras 7 días sin uso; con uso diario no pasa.
