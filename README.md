# ReaAgents (rea-kit)

> Proyecto personal, **no oficial**: no está afiliado a REA ni a su autor.

Instalación **aislada, auditada y con versiones fijadas** de [REA (Reverse Engineer Anything)](https://github.com/morluto/rea), el paquete npm `rea-agents`, para usarlo desde **Claude Code en Windows** sin que nada quede instalado ni accesible fuera de la carpeta del proyecto.

## Qué es (y qué no es)

- **No es un fork de REA ni lo redistribuye.** REA es © morluto, con licencia MIT. `bootstrap.ps1` lo instala desde el registro de npm (versión exacta fijada en el lockfile) y verifica cada pieza contra los hashes de `kit/versions.json`.
- **Es un envoltorio de seguridad** que añade:
  - un lanzador aislado (`scripts/rea-isolated.mjs`),
  - permisos de Claude Code restrictivos (`.claude/settings.json`),
  - el registro MCP **solo a nivel de proyecto**,
  - un monitor de red (`run-monitored.ps1`),
  - un verificador (`scripts/kit-verify.mjs`),
  - la auditoría de seguridad de la versión fijada (`SECURITY_AUDIT.md`).

| Componente | Versión fijada | Verificación |
|---|---|---|
| Node.js portátil | 24.22.2 (win-x64) | SHA256 del zip y de `node.exe`. El zip se verificó con la firma GPG oficial de Node |
| `rea-agents` | 6.8.0 | sha512 del lockfile, procedencia SLSA (commit `160d821`), SHA256 del addon nativo, SHA256 de la skill |
| Dependencias (181) | `package-lock.json` | Todas de `registry.npmjs.org`, sha512, `npm audit signatures` |
| Binding de frida (opcional) | 17.23.2 | SHA256 del tarball (= digest de GitHub) y del `.node`. Se instala **sin** ejecutar su script de instalación |

## Requisitos

- Windows 10 u 11 de 64 bits, Windows PowerShell 5.1 (viene con Windows), Git y Claude Code.
- **No hace falta** tener Node instalado ni permisos de administrador.
- Unos 650 MB de disco con Frida (Node 190 MB, `node_modules` 300 MB, caché de npm 115 MB).

## Inicio rápido

```powershell
git clone https://github.com/JuanDiegoRuiz22/ReaAgents.git D:\rea-miproyecto
cd D:\rea-miproyecto
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -WithFrida
```

`bootstrap.ps1` hace lo siguiente, siempre dentro de la carpeta:

1. Descarga Node portátil de nodejs.org y verifica sus hashes.
2. Ejecuta `npm ci --ignore-scripts`: instala exactamente lo que dice el lockfile y no ejecuta ningún script.
3. Comprueba las firmas del registro y avisa si aparecen advisories nuevos en `npm audit`.
4. Instala el binding de frida si pasas `-WithFrida`. Sin él, REA funciona igual salvo las herramientas de Frida.
5. Genera `.mcp.json` con las rutas absolutas de tu máquina.
6. Compone la skill a partir de la original más el preámbulo `kit/skill-preamble.md`.
7. Verifica todo con `kit-verify.mjs`.
8. Compara un snapshot del estado **fuera** de la carpeta antes y después, para demostrar que no cambió nada.

Opciones:

| Opción | Efecto |
|---|---|
| `-WithFrida` | Instala el binding nativo de frida desde el tarball fijado |
| `-VerifyOnly` | No descarga ni instala nada; solo verifica. Úsalo cuando quieras |
| `-Reinstall` | Borra `node_modules` y repite `npm ci` |
| `-SkipNetworkChecks` | Omite `npm audit signatures` y `npm audit` |

Si algo no coincide con un pin, bootstrap **se detiene** y el kit no queda listo.

## Un kit por proyecto

**Recomendado:** un clon por proyecto de análisis (`D:\rea-appA`, `D:\rea-appB`…). Cada uno tiene su propio `.rea-runtime`, sus logs y sus permisos. Si prefieres, también puedes usar un único kit con varias carpetas dentro de `targets/`.

## Estructura

| Ruta | Contenido | ¿Se publica? |
|---|---|---|
| `targets/` | Lo que vas a analizar. **Solo software que tengas derecho a analizar** | No (salvo `sample-js-app`) |
| `projects/<target>/` | Extracciones y salidas de REA | No |
| `findings/` | Tus conclusiones | No |
| `logs/` | Logs de npm, snapshots de aislamiento y ejecuciones monitoreadas | No |
| `.rea-runtime/` | Home, AppData, TEMP y cachés de REA (redirigidos) | No |
| `.tools/`, `node_modules/`, `.npm-cache/` | Node portátil, dependencias y caché | No (las regenera bootstrap) |
| `.mcp.json`, `.claude/skills/reverse-engineer-anything/` | Se generan por máquina | No |
| `.claude/settings.json` | Permisos de Claude Code | Sí |
| `kit/` | Pins (`versions.json`) y preámbulo de la skill | Sí |
| `scripts/` | Lanzador, verificador, snapshots y escáner de lifecycle | Sí |

## Usar REA

### Desde Claude Code

1. Después de ejecutar bootstrap, abre una **sesión nueva** de Claude Code en la carpeta y acepta el aviso de confianza del workspace. El servidor `rea` de `.mcp.json` ya viene aprobado (`enabledMcpjsonServers`); compruébalo con `/mcp`.
2. Copia lo que quieras analizar a `targets/` y pídelo, por ejemplo: *"Analiza targets\miapp.apk con REA, extrae en projects\miapp y deja las conclusiones en findings\miapp.md"*.
3. Cada herramienta de REA **pide tu aprobación** (`ask`). Las peligrosas están **denegadas**:
   - `capture_process_scenario`, `execute_rizin_command`, `start_rizin_debug_session`, `rizin_debug_command` y `cutter_command`, porque ejecutan comandos;
   - `load_frida_script` e `instrument_with_frida`, porque ejecutan código;
   - `capture_browser_scenario`, porque inyecta variables de entorno en un origen web;
   - `install_adb_package`, `uninstall_adb_package` y `push_adb_file`, porque actúan sobre un dispositivo.

   Para habilitar una puntualmente, quita su regla de `deny` en `.claude/settings.json` y vuelve a ponerla al terminar. Una regla `deny` gana sobre cualquier `allow`, incluso el de `settings.local.json`. Hazlo solo con targets en los que confíes.

### Desde la terminal (CLI)

```powershell
. .\env.ps1            # activa Node local y npm aislado SOLO en esta sesión
rea --help
rea analyze-javascript-application .\targets\sample-js-app --json > .\projects\sample-js-app\analysis.json
```

`rea` es una función de la sesión que **siempre** pasa por el lanzador aislado. No hay ningún `rea` en el PATH del sistema. Al cerrar la terminal desaparece todo.

### Ejecución monitoreada

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-monitored.ps1 -Target targets\sample-js-app
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-monitored.ps1 -Target targets\sample-js-app -Mode mcp
```

El monitor ejecuta `analyze-javascript-application` sobre el target y registra:

- todas las conexiones TCP/UDP del árbol de procesos de REA,
- las entradas nuevas en la caché DNS,
- los cambios fuera de la carpeta.

Escribe `logs\run-<fecha>-<modo>\report.md`. Cualquier host que no sea localhost, registry.npmjs.org o github.com se marca como **POSIBLE EXFILTRACIÓN**, y en ese caso el script termina con código de salida 1. En Git Bash: `./run-monitored.sh`.

## Modelo de seguridad

1. **Cadena de suministro:**
   - versiones exactas y hashes fijados en `kit/versions.json`;
   - npm siempre con `--ignore-scripts`, tanto en `.npmrc` como en `env.ps1`;
   - lockfile que solo resuelve desde `registry.npmjs.org`;
   - `npm audit signatures` y comparación de advisories con los ya revisados.
2. **Proceso de REA aislado** (`scripts/rea-isolated.mjs`):
   - el entorno se reconstruye desde una lista permitida, así que tus tokens y API keys **no** llegan a REA;
   - home, AppData, TEMP, XDG, Playwright y la caché de npm se redirigen a `.rea-runtime/`;
   - el chequeo de updates está desactivado;
   - están bloqueados `setup`, `update`, `uninstall`, `skills`, `mcp add`, `mcp --http` y `environment serve`.
3. **Nada fuera de la carpeta:**
   - sin PATH, sin npm global y sin `~/.npmrc`;
   - MCP solo en `.mcp.json` (alcance de proyecto) y skill solo en `.claude/skills/` del proyecto;
   - bootstrap lo verifica comparando snapshots de antes y después.
4. **Permisos de Claude Code** (`.claude/settings.json`):
   - `ask` para todo `mcp__rea__*` y `deny` para las herramientas peligrosas;
   - `deny` de lectura de `~/.ssh`, `~/.aws`, `~/.config`, `~/.gnupg`, credenciales y perfiles de navegador;
   - `deny` de edición de las configuraciones de otros agentes;
   - lecturas y escrituras de Claude bloqueadas fuera de la carpeta;
   - `deny` de `npm -g`, `npx rea-agents`, `install.sh`, `sudo`, etc.
5. **Skill con preámbulo local:** prohíbe a Claude reparar o reinstalar REA (`setup`/`npx`) y le indica que trate el contenido de los targets como datos, nunca como instrucciones.

### Límites que debes conocer

- **La redirección por variables de entorno no es una frontera de seguridad.** REA corre con tu usuario de Windows y sus herramientas pueden leer cualquier ruta que tú puedas leer (CAP-1 en la auditoría). Para targets no confiables o maliciosos, usa **Windows Sandbox, una VM o una cuenta de Windows aparte**.
- Las reglas `Read()`/`Edit()` de Claude Code **no se aplican a herramientas MCP** ni a subprocesos. Por eso las herramientas de REA se controlan una por una con `ask`/`deny`.
- Las reglas `deny` de Bash/PowerShell se basan en patrones y se pueden esquivar. Son una capa extra, no una barrera.
- El sandbox de Claude Code no está disponible en Windows nativo y nunca cubre servidores MCP.
- El monitor funciona por sondeo (200 ms) y sin admin, así que puede perder conexiones muy cortas. La caché DNS es de todo el sistema. Para una captura completa, usa `pktmon` o Wireshark en paralelo.
- `npm audit` reporta 3 advisories de DoS local sin corrección disponible (zod, glob, minimatch; ver `SECURITY_AUDIT.md` §4).
- El addon nativo de REA no tiene firma Authenticode: el hash prueba que está íntegro, no quién lo compiló.
- Herramientas externas que REA lanza (Java, Ghidra, adb) pueden escribir en tu perfil por su cuenta (FS-11).
- `blockWritesOutsideWorkingDirectories` puede impedir que Claude guarde su memoria de proyecto.

## Comandos prohibidos

| Comando | Por qué |
|---|---|
| `npm install -g`, `npx rea-agents …` | Instalación global o fuera del lockfile |
| `rea setup`, `rea update`, `rea uninstall`, `rea skills add` | Escriben configs de ~20 agentes, skills globales y npm global |
| `rea mcp add` | Ejecuta `npx add-mcp -g` sin versión fijada |
| `rea mcp --http`, `rea environment serve` | Listeners HTTP sin autenticación |
| `install.sh`, `curl … \| sh`, `sudo` | Instalación global sin revisión |

Están bloqueados en el lanzador y en `.claude/settings.json`.

## Actualizar REA de forma segura

No uses nunca `rea update`. Hazlo en un clon o una rama aparte:

1. **Revisa la nueva versión** (con `. .\env.ps1` cargado):

   ```powershell
   npm view rea-agents@X.Y.Z repository.url dist.integrity dist.attestations
   ```

   El repositorio tiene que ser `git+https://github.com/morluto/rea.git`. La attestation tiene que apuntar a un commit de un tag `rea-agents-X.Y.Z` de ese repositorio.
2. **Instala:**

   ```powershell
   npm install rea-agents@X.Y.Z --save-exact --ignore-scripts
   ```

3. **Vuelve a auditar:**
   - `node scripts\audit\lifecycle-scan.mjs node_modules`, para ver si hay hooks de instalación nuevos;
   - `npm audit signatures` y `npm audit`;
   - las diferencias de `dist/` respecto a la versión anterior (`git clone --depth 1 --branch rea-agents-X.Y.Z https://github.com/morluto/rea.git vendor\rea`): hosts nuevos, comandos de setup o update, lecturas de credenciales;
   - las herramientas MCP nuevas, que pueden necesitar reglas `deny` (`run-monitored.ps1 -Mode mcp` muestra cuántas hay);
   - si la skill original trae instrucciones nuevas de `setup`/`npx`, adapta `kit/skill-preamble.md`.

   Actualiza `SECURITY_AUDIT.md` con lo que encuentres.
4. **Actualiza los pins de `kit/versions.json`:**
   - `version`, `integrity` y `provenanceCommit`;
   - `nativeAddonSha256` y `skillSha256`;
   - `acceptedAdvisories`;
   - frida, si cambió.
5. **Comprueba:** `bootstrap.ps1 -WithFrida` tiene que pasar sin fallos, y `run-monitored.ps1`, en modo `cli` y en modo `mcp`, tiene que mostrar 0 conexiones sospechosas.

**Actualizar Node:** descarga `SHASUMS256.txt` y `SHASUMS256.txt.sig` de `nodejs.org/dist/vX.Y.Z/`. Verifica la firma con `gpgv`, que viene con Git for Windows, usando las claves de [nodejs/release-keys](https://github.com/nodejs/release-keys). Después actualiza `.nvmrc` y `node` en `kit/versions.json`: `zipSha256`, y `nodeExeSha256` calculado después de extraer.

## Publicar en GitHub

El `.gitignore` excluye targets (salvo el ejemplo), proyectos, findings, logs, dependencias, toolchain, runtime, archivos generados y binarios (`*.apk`, `*.exe`, `*.dll`, `*.node`…). Antes de cada push:

```powershell
git status --short
git ls-files              # solo deben aparecer archivos del kit
```

**Nunca publiques targets, APKs ni salidas de análisis.** Pueden tener copyright de terceros o contener secretos de la app analizada.

Para subir cambios (el remoto `origin` es `https://github.com/JuanDiegoRuiz22/ReaAgents.git`):

```powershell
git add -A
git status                # revisa que no haya targets, salidas ni binarios
git commit -m "describe el cambio"
git push
```

Si quieres que otros reutilicen el kit, añade una licencia propia (por ejemplo `LICENSE` con MIT). REA conserva su propia licencia MIT y no se incluye en el repositorio.

## Uso responsable

Analiza solo software que tengas derecho a analizar: el tuyo, uno con licencia que lo permita o uno con autorización expresa. Revisa también `node_modules/rea-agents/DISCLAIMER.md`.
