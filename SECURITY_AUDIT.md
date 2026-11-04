# SECURITY_AUDIT — REA (`rea-agents@6.8.0`) en rea-kit

> Esta auditoría vale **solo para las versiones exactas fijadas en `kit/versions.json`**. `bootstrap.ps1` rechaza cualquier artefacto que no coincida con esos hashes. Cambiar de versión implica repetir la auditoría (ver `README.md`, "Actualizar REA de forma segura"). Las rutas `<kit>` se refieren a la carpeta donde clonaste el kit.

- **Fecha:** 2026-11-04
- **Sistema:** Windows 11 Home x64
- **Node:** v24.22.2 portátil (`./.tools`)
- **Tipo de auditoría:** **estática**. No se ejecutó código de REA ni de sus dependencias. Los paquetes se instalaron con `--ignore-scripts` y no se corrió `npm rebuild`.
- **Rutas:** relativas a `node_modules/rea-agents/` salvo que se indique otra cosa. Las líneas citadas corresponden a `dist/`, que es el código que realmente se ejecuta. `vendor/rea` (tag `rea-agents-6.8.0`) se usó para entender la intención del código.

**Escala:** **OK** = sin problema · **Revisar** = esperado, pero conviene configurarlo o vigilarlo · **Riesgo** = puede romper el aislamiento o exponer datos si se usa sin control.
**Naturaleza:** *Esperado* = coherente con lo que hace la herramienta · *Sospechoso* = sin justificación funcional.

---

## 0. Veredicto

1. **No se encontró código malicioso, telemetría, analítica ni hosts de exfiltración ocultos**, ni en REA ni en sus 175 dependencias. **Ningún hallazgo es *Sospechoso*.**
2. **Integridad y procedencia: OK.**
   - Los 176 paquetes tienen firma de registro válida.
   - `rea-agents` tiene attestation SLSA que apunta al commit `160d821` (tag `rea-agents-6.8.0`) construido en GitHub Actions.
   - El binario de frida coincide con el digest oficial que publica GitHub.
3. **Aislamiento (tu prioridad):**
   - El **servidor MCP de REA no contiene código que escriba configs de agentes, publique skills ni se actualice**. Eso solo existe en comandos CLI explícitos (`setup`, `update`, `uninstall`, `mcp add`), que hay que prohibir.
   - Por defecto, REA **sí escribe fuera de la carpeta**: temporales en `%TEMP%` (20 módulos) y, según la función, `~\.cache` y `%LOCALAPPDATA%`. **Todo se puede redirigir con variables de entorno**; queda para la Fase 4.
4. **Riesgo principal (por diseño, no malicioso):** REA le da al agente herramientas para
   - leer **cualquier ruta**,
   - **ejecutar comandos**,
   - **inyectar variables de entorno** en páginas de un origen que el agente elige.

   Un *prompt injection* escondido en un binario o en una web analizada podría usarlas para exfiltrar datos. **Las reglas `Read()`/`Edit()` de Claude Code no se aplican a herramientas MCP.** Esto se mitiga con permisos por herramienta y con un entorno mínimo para el proceso de REA.

---

## 1. Alcance y método

| Elemento | Resultado |
|---|---|
| Paquete | `rea-agents@6.8.0`, `repository: git+https://github.com/morluto/rea.git`, maintainer único `morluto` |
| Procedencia | SLSA v1. Workflow `.github/workflows/release.yml`, runner hospedado de GitHub, commit `160d821ac9a0310afcb8d1fc427862dd6508add5` (= tag `rea-agents-6.8.0`) |
| Integridad | `sha512-9QDeRnGq…PZ9ww==`, igual en registro, lockfile y attestation |
| Lockfile | 181 URLs `resolved`, todas de `https://registry.npmjs.org`. Ninguna dependencia git, file o URL |
| Revisado | `dist/` (2316 JS, sin minificar), `scripts/`, `bridge/`, `skills/`, `install.sh`, `native/`, y las 175 dependencias en `node_modules/` |
| Método | Tres revisiones estáticas paralelas (red/updater, datos sensibles/código dinámico/binario nativo, dependencias), más verificación manual de los hallazgos críticos: aislamiento MCP, chequeo de updates de incur, `mcp add`, hash del addon, F3/F13 y updater |
| No cubierto | Comportamiento en tiempo de ejecución de binarios nativos (solo se revisaron imports, strings y hashes). Herramientas externas que REA invoca (Ghidra, Java, adb, apktool…). Build reproducible del addon |

---

## 2. Huella fuera de la carpeta (prioridad: "que REA solo viva acá")

Cómo resuelve REA el "home" en Windows: `USERPROFILE` → `HOMEDRIVE`+`HOMEPATH` → `HOME` (`dist/config/homeDirectory.js:12`). Node resuelve `os.tmpdir()` desde `TEMP`/`TMP`. **Las dos cosas se pueden redirigir solo para el proceso de REA.**

| ID | Ubicación por defecto | Quién / cuándo | Evidencia | Redirección | Clasif. |
|---|---|---|---|---|---|
| FS-1 | `%TEMP%\rea-extracted-<uuid>` con el **contenido extraído de los targets** (p. ej. el APK). También `rea-provider-*`, `rea-browser-scenario-*`, `rea-asar-snapshot-*`, `rea-pyz-*`, `rea-wakaru-*`, `rea-flutter-*` y las raíces de sesión de JADX y Ghidra | REA, al analizar, si no se le da un destino | `dist/application/artifacts/ArtifactExtractionDestination.js:5`, `dist/process/PrivateRuntimeRoot.js:35-38`, `dist/browser/PlaywrightScenarioBrowser.js:561`, `dist/android/JadxWorkspaceRoot.js:58`, `dist/ghidra/GhidraSessionRoot.js:29` (20 módulos en total) | `TEMP`, `TMP` | **Revisar** · Esperado |
| FS-2 | `~\.cache\rea\kuna` | Proveedor Kuna, al usarlo | `dist/config/kunaCacheDirectory.js:6-7` | `REA_KUNA_CACHE_DIR` o `XDG_CACHE_HOME` | OK · Esperado |
| FS-3 | `~\.rea\{cache,state}` | Solo lo **borra** `rea uninstall --purge` (limpieza heredada). En 6.8.0 nada lo crea | `dist/application/Uninstall.js:651` | `USERPROFILE` | OK |
| FS-4 | **Configs de unos 20 agentes** (`~\.claude.json`, `~\.codex\config.toml`, Claude Desktop, VS Code, Gemini, Cursor, OpenCode…) y skills en `~\.claude\skills`, `~\.agents\skills` | Solo `rea setup`, `rea update` (mantenimiento de registros) y `rea uninstall`. **Verificado: el runtime MCP (`dist/mcp/*`) no contiene ese código**; solo está en `dist/cli-runtime/*` | `dist/application/SupportedClients.js`, `Setup*.js`, `UpdateMaintenance.js`, `Uninstall.js` | Ninguna: **no ejecutar esos comandos** | **Riesgo** de aislamiento · Esperado |
| FS-5 | `npx add-mcp … -y -g` (**paquete de terceros sin versión fijada, en modo global**) más `~\.config\amp\settings.json` | `rea mcp add` (incluido en incur) | `node_modules/incur/dist/SyncMcp.js:18-24` | Ninguna: **no ejecutarlo** | **Riesgo** · Esperado |
| FS-6 | `~\.cache\incur\updates\rea-agents.json`, más un proceso **desacoplado** que hace `GET https://registry.npmjs.org/rea-agents` | Chequeo de updates de incur. Solo en la CLI interactiva (TTY, sin `--json`), como máximo cada 24 h. **No corre en modo MCP** | `incur/dist/internal/update.js:217, 239-252, 286-290`; `dist/cli.js:85` (REA no lo desactiva) | `NO_UPDATE_NOTIFIER=1` o `npm_config_update_notifier=false` (el `env.ps1` ya fija esta última); `XDG_CACHE_HOME` | **Revisar** · Esperado, no documentado |
| FS-7 | `%APPDATA%\npm` (prefix global) | `rea update` → `npm install --global --ignore-scripts --prefix <p>` | `dist/application/Update.js:5-17` | Ninguna: **no ejecutarlo** | **Riesgo** de aislamiento · Esperado |
| FS-8 | `%LOCALAPPDATA%\ms-playwright` (solo con una instalación explícita de navegadores) y `%TEMP%\playwright-{artifacts,tracing,download}-*` | playwright-core | `playwright-core/lib/server/registry/index.js:61-66`; `browserType.js:157,164` | `PLAYWRIGHT_BROWSERS_PATH`, `TEMP` | OK · Esperado |
| FS-9 | `%TEMP%\asar-*` | @electron/asar, al empaquetar con transformaciones | `@electron/asar/lib/filesystem.js:118` | `TEMP` | OK |
| FS-10 | Ghidra: REA **ya** redirige `LOCALAPPDATA` y `XDG_*` del proceso hijo a su raíz temporal | — | `dist/ghidra/GhidraLauncher.js:642-649` | — | OK |
| FS-11 | Herramientas externas que REA lanza pueden escribir en tu perfil por su cuenta. Por ejemplo, adb usa `~\.android` y Java resuelve `user.home` con APIs de Windows que **ignoran las variables de entorno** | Externo a REA | — | `ANDROID_USER_HOME`; para Java no hay redirección completa | **Revisar** (residual) |
| FS-12 | Claude Code guarda el stderr de los servidores MCP en sus propios logs (fuera de la carpeta). Es comportamiento de Claude Code, no de REA. REA solo loguea a stderr | — | `dist/logger.js:3-6` | — | OK (informativo) |

**Conclusión de la sección:** con las redirecciones de la Fase 4 (`TEMP`, `TMP`, `USERPROFILE`, `HOME`, `APPDATA`, `LOCALAPPDATA`, `XDG_*`, `PLAYWRIGHT_BROWSERS_PATH`, `REA_KUNA_CACHE_DIR`, `NO_UPDATE_NOTIFIER`) y sin ejecutar nunca FS-4, FS-5 y FS-7, **REA queda contenido en la carpeta**. Quedan dos excepciones: lo residual de FS-11, y que la redirección por variables **no es una frontera de seguridad** (ver §10).

---

## 3. Scripts de ciclo de vida (punto 1)

| Paquete | Hook | ¿Lo ejecuta npm al instalar desde el registro? | Qué hace | Clasif. |
|---|---|---|---|---|
| `frida@17.23.2` (opcional) | `install: node scripts/install.js` | **Sí.** Es el **único** | Ver §3.1 | **Revisar** |
| `rea-agents@6.8.0` | `prepare: node scripts/prepare.mjs` | No | Solo actúa si existe `src/` (checkout de desarrollo): parche de release-please y husky. No hace nada en el paquete publicado (`scripts/prepare.mjs:7-39`) | OK |
| `@cfworker/json-schema`, `balanced-match`, `brace-expansion`, `minimatch`, `minipass`, `path-scurry` | `prepare: tshy` | No | Compilación de desarrollo | OK |
| `glob`, `lru-cache` | `prepare: tshy && bash scripts/build.sh` | No | Ídem | OK |
| `@electron/asar`, `lossless-json`, `pino-abstract-transport` | `prepare: husky…` | No | Git hooks de desarrollo | OK |
| `@msgpack/msgpack`, `eventsource`, `openpgp`, `signal-exit` | `prepare` / `preprepare` (build) | No | Build de desarrollo | OK |

- No hay `binding.gyp` en ningún paquete, así que **no hay compilación implícita con `node-gyp rebuild`**.
- **Binarios nativos incluidos:**
  - `rea-agents/native/windows/build/rea-windows-x64.node`: SHA256 `6a015bfe…b6ff7b`, igual al de `manifest.json`.
  - `@lydell/node-pty-win32-x64/conpty.node` (`4a18d193…a54834`) y `conpty_console_list.node` (`6f780d0a…e372`).
- `install.sh` **no lo ejecuta npm**. Consulta `api.github.com`, ejecuta `npm install -g` y luego `rea setup` (`install.sh:133,150-179`). **No es necesario y no debe ejecutarse** · Revisar.

### 3.1 `frida/scripts/install.js`

1. Si ya existe `build/frida_binding.node`, termina sin hacer nada.
2. Ejecuta `prebuild-install`. Busca, en este orden:
   - un prebuild local en `node_modules/frida/prebuilds/`,
   - la caché `%npm_config_cache%\_prebuilds`.

   Si no lo encuentra, **descarga** `https://github.com/frida/frida/releases/download/17.23.2/frida-v17.23.2-napi-v8-win32-x64.tar.gz` y lo extrae en `node_modules/frida`. **No verifica hash ni firma**; confía solo en HTTPS (`prebuild-install/download.js:41-76`).
3. **Si el paso 2 falla, compila desde el código fuente** con `make.bat`, Python y meson. Esa compilación descarga toolchains de `build.frida.re`, headers de `nodejs.org` y clona `frida-core` desde GitHub, todo **sin verificar hashes** · **Riesgo** si llega a ejecutarse.
4. Vectores que podrían redirigir la descarga hacia otro servidor:
   - `npm_config_frida_binary_host[_mirror]`, `npm_config_download` y proxies,
   - un archivo `.prebuild-installrc` en la carpeta, en `D:\` o en `%USERPROFILE%`.

   **Verificado: ninguno está presente.**

**Verificación independiente del binario:** el tarball que ya está en tu caché global, `%LOCALAPPDATA%\npm-cache\_prebuilds\6d4dd5-frida-v17.23.2-napi-v8-win32-x64.tar.gz`, tiene SHA256 `e9dbc08d386130610430137f0bb31d90af7b08c0f5710942d4313368ada930ea` y 50 515 627 bytes. **Coincide exactamente con el `digest` que publica la API de GitHub** para el asset oficial del release 17.23.2 (publicado por `github-actions[bot]` el 2026-10-09). Contiene solo `build/frida_binding.node`, cuyo SHA256 `32C73230…57DC` coincide con el de la instalación global 6.5.0.

---

## 4. `npm audit` y `npm audit signatures` (punto 2)

`npm audit signatures`: **176/176 paquetes con firma de registro verificada; 39 con attestation de procedencia.** · OK

`npm audit`: 6 entradas, que en realidad son **3 advisories**. Ninguna es crítica ni de exfiltración, y ninguna tiene corrección disponible porque REA fija versiones exactas.

| Advisory | Paquete | Severidad | Impacto | Clasif. |
|---|---|---|---|---|
| GHSA-mrhx-c7xc-m3w5 | `zod <4.6.6` (directa de REA) | Alta | DoS por memoria al validar colecciones enormes | Revisar |
| GHSA-3g3m-2fjr-6pw4 | `glob 9.0–14.0.1` (vía `@electron/asar`) | Moderada | Un `AbortSignal` no detiene el recorrido de archivos tras el timeout | Revisar |
| GHSA-g3hv-75wg-m249 | `minimatch <11.0.1` (vía asar y frida) | Moderada | DoS por amplificación de patrones | Revisar |

`rea-agents` aparece como "alta" solo porque hereda la de `zod`. Mitigación posible: `overrides` en `package.json`, aunque podría romper compatibilidad; de momento se acepta el riesgo, que se limita a DoS local. También: incur trae anidado `@modelcontextprotocol/server@2.0.0-alpha.4`, una versión **alfa** · Revisar (menor).

---

## 5. Tráfico de red (punto 3)

**Modo MCP stdio, que es el que se va a usar:** no abre puertos TCP ni hace llamadas de red al arrancar (`dist/main.js:59-77`). REA no usa curl, wget ni PowerShell en ningún lugar.

| Host | Disparador | Evidencia | Clasif. |
|---|---|---|---|
| `registry.npmjs.org` | (a) chequeo de updates de incur (FS-6); (b) `rea update`; (c) `rea mcp add` vía npx | ver FS-6, FS-7 y FS-5 | Revisar · Esperado |
| `github.com/frida/frida/releases` (y el CDN de assets) | Solo `npm rebuild frida` sin un prebuild local | §3.1 | Revisar · Esperado |
| `build.frida.re`, `nodejs.org`, `github.com/frida/frida-core` | Solo la compilación de respaldo de frida | §3.1 | **Riesgo** si ocurre · Esperado |
| `www.hopperapp.com` | Instalador de Hopper (solo macOS/Linux, **nunca en Windows**). Verifica OpenPGP con huella fijada más sha1/sha256 | `dist/application/HopperReleaseFeed.js:6-9`, `HopperDownload.js:51-86` | OK |
| `cdn.playwright.dev`, `playwright.download.prss.microsoft.com` | Solo con una instalación explícita de navegadores Playwright; sin checksum | `playwright-core/lib/server/registry/index.js:470-490,1008-1030` | OK · Esperado |
| `api.github.com` | Solo `install.sh`, que no se ejecuta | `install.sh:133` | OK |
| **Elegido por el caller** | Sitios web analizados (navegador con perfil temporal); source maps solo de `allowed_origins` y con `fetch_source_maps=false` por defecto; peticiones in-page del mismo origen | `dist/browser/WebSourceMapFetcher.js:264-283`, `PlaywrightScenarioRequest.js:91-118`, `PlaywrightScenarioBrowser.js:561-567` | OK · Esperado |
| **Elegido por el caller: cualquier host** | Frida `remote.address` acepta cualquier `host:port`, no solo loopback | `dist/contracts/fridaRemoteAddress.js:2-17` | Revisar |
| **Elegido por el cliente: cualquier https** | `rea environment serve`: el método `data/add` acepta URIs `https://`, que REA descarga, y `file://` | `dist/server/environment/stateIntake.js:202-218` | Revisar (no usar) |
| Solo loopback | CDP y V8 inspector (el esquema exige 127.0.0.1 o ::1), IDA/JEB MCP, bridges de Ghidra y Cutter (127.0.0.1 con token por sesión), named pipe `\\.\pipe\rea-lease-*` | `dist/domain/browserObservation.js:52-106`, `bridge/ghidra/ReaGhidraBridge.java:270-289`, `dist/process/OwnedLease.js` | OK |
| Listener HTTP | `rea mcp --http` y `environment serve` escuchan en `127.0.0.1` por defecto **sin autenticación**. Si se fija `MCP_HOST`/`--host` a otra dirección, la validación de Host/Origin se desactiva por completo | `dist/config/mcpHttpEndpoint.js:5-33`, `dist/server/http/serveStreamableHttp.js:381-385,474-475` | **Revisar** → **Riesgo** fuera de loopback |
| isomorphic-git | Sin proxy CORS por defecto, pero si no se le pasa uno, lee `http.corsProxy` del `.git/config` **del repo analizado** | `isomorphic-git/index.cjs:9899-9900` | Revisar |

**Documentación solamente** (strings en mensajes, nunca se contactan): `github.com/morluto/rea`, `iBotPeaches/Apktool`, `ReFirmLabs/binwalk`, `onekey-sec/unblob`, `WebAssembly/wabt`, `pionxzh/wakaru`, `1013503897/jadx-headless-mcp`, `docs.oracle.com`, `chromedevtools.github.io`, `json-schema.org`, `w3.org`, dominios de ejemplo.

---

## 6. Telemetría (punto 4)

| ID | Resultado | Clasif. |
|---|---|---|
| TEL-1 | **No hay telemetría, analítica ni crash reporting** en REA (búsqueda de telemetry, analytics, posthog, sentry, segment, mixpanel, amplitude, otel, beacon). Las coincidencias son funciones de análisis, como el parser de `.ips` de Apple o la detección de `sendBeacon` en el JS analizado | OK |
| TEL-2 | Ninguna dependencia tiene telemetría. Chromium lanzado por Playwright usa `--disable-background-networking`, `--disable-component-update` y `--disable-sync` | OK |
| TEL-3 | La única "llamada a casa" automática es el **chequeo de versión de incur** (FS-6). Envía solo el nombre del paquete, tu IP y el User-Agent, y solo en la CLI interactiva. **Para desactivarlo:** `NO_UPDATE_NOTIFIER=1` (o `npm_config_update_notifier=false`, o `CI=true`) | Revisar |

---

## 7. Acceso a datos sensibles (punto 5)

| ID | Hallazgo | Evidencia | Clasif. |
|---|---|---|---|
| SEC-1 | REA **no lee** `~\.ssh`, `~\.aws`, `~\.gnupg`, `~\.npmrc`, `~\.netrc`, perfiles de navegador, `Login Data`/`Local State`, DPAPI (`CryptUnprotectData`), Credential Manager ni keychain. Las coincidencias son listas de clasificación de nombres de archivo y detectores de credenciales | `dist/domain/referenceSourceClassification.js:137`, `dist/application/environment/environmentBuildReport.js:9-48` | OK |
| SEC-2 | `process.env` completo: **solo se hereda a los procesos hijos de REA**; nunca se serializa, sube ni escribe. Las apps Electron analizadas reciben un entorno **filtrado por lista permitida** | `dist/process/capture/ProcessCaptureEnvironment.js:2-9`, `dist/browser/PlaywrightElectronActiveProvider.js:264-296` | OK |
| SEC-3 | Cookies: `Network.getCookies` se usa solo sobre la página analizada, y **solo se guardan hashes SHA-256**, no valores | `dist/browser/CdpCaptureStorageFingerprints.js:35,283-297` | OK |
| SEC-4 | `capture_browser_scenario` permite que el caller declare **cualquier variable de entorno** como "secreto". REA la lee de `process.env` y la **inyecta en una página o petición de un origen que el caller elige** | `dist/browser/BrowserScenarioSecrets.js:181-200` (verificado) | **Riesgo** · Esperado (diseño) |
| SEC-5 | La importación de código de referencia no excluye `.env`, `*.pem` ni `*.key` por defecto (`REA_REFERENCE_SECRET_PATTERNS_JSON=[]`) | `dist/config/environment.js:77`; `dist/application/ReferenceSourceImportPolicy.js:250` | Revisar |
| SEC-6 | `export_environment_bundle` conserva campos con nombres de credencial en `evidence.json` y solo avisa | `dist/application/environment/environmentBuildReport.js:232-246` | Revisar |
| SEC-7 | Al buscar `apktool` en Windows, REA mira **primero el directorio actual** (igual que `CreateProcess`). Un `apktool.bat` plantado ahí se ejecutaría | `dist/apktool/ApktoolConfiguration.js:62` | Revisar · mitigación: `NODEFAULTCURRENTDIRECTORYINEXEPATH=1` |
| SEC-8 | No hay persistencia: ni tareas programadas, ni claves `Run`, ni servicios, ni carpeta de inicio, ni `setx`/PATH. `taskkill /t /f` solo actúa sobre árboles de procesos hijos de REA. Un helper (`rea-android-workspace-guardian.mjs`) puede sobrevivir a un crash de REA reintentando limpiar su carpeta temporal, pero no sobrevive a un reinicio | `dist/android/JadxWorkspaceRoot.js:59` | OK |

---

## 8. Código ofuscado o dinámico y binarios (punto 6)

| ID | Hallazgo | Clasif. |
|---|---|---|
| DYN-1 | REA: **no usa** `eval`, `new Function`, `vm.*`, ni `import()`/`require` de rutas remotas o calculadas. No tiene blobs base64 o hex de más de 800 caracteres. El código no está minificado | OK |
| DYN-2 | Dependencias: `new Function`/`eval` solo en generación de código legítima (ajv, playwright injected script, `get-intrinsic`). Los blobs de zip.js (unos 57 y 55 KB) son workers de compresión, **decodificados y revisados**: sin URLs, fetch ni eval. Los blobs de openpgp son WASM de argon2id (`\0asm`) | OK |
| DYN-3 | Scripts inyectados: el hook de Electron (`scripts/electron-active-hook.cjs`) solo se inyecta en apps que **REA lanza**. Registra nombres de canales IPC y **tipos** de argumentos (no valores), en memoria y solo para uso local. Los scripts de Frida los aporta el caller; REA no trae payloads propios | OK |
| DYN-4 | **`rea-windows-x64.node`**: sus imports (KERNEL32, ADVAPI32, ntdll, bcrypt, msvcrt) encajan con su propósito: handles NTFS, carpetas temporales con DACL privada, Job Objects y SHA-256. **No importa** winhttp, wininet, ws2_32, urlmon, crypt32, `CredRead`, `CryptUnprotectData`, `Reg*`, `CreateRemoteThread`, `WriteProcessMemory` ni `SetWindowsHookEx`. Contiene 160/165 strings del código fuente de 6.8.0. Hash = manifest; el loader verifica hash y cabecera PE antes de cargarlo (`dist/windows/WindowsNativeLoader.js:73-79,121-160`). **No tiene firma Authenticode** y el manifest viaja en el mismo tarball: esto prueba que el archivo está íntegro, no quién lo compiló. Se carga solo bajo demanda (Ghidra, JADX, Cutter, doctor) | **Revisar** |
| DYN-5 | `frida_binding.node` (135 MB): autenticidad verificada contra el digest de GitHub (§3.1). Su comportamiento en tiempo de ejecución no se puede auditar estáticamente (es el motor de Frida) | Revisar |

---

## 9. Updater (punto 7)

| ID | Mecanismo | Hosts | Cuándo | Clasif. |
|---|---|---|---|---|
| UPD-1 | `rea update` / `rea --update`: `npm view rea-agents dist-tags.latest`; si hay una versión nueva y detecta una instalación global, ejecuta `npm install --global --ignore-scripts --prefix <p> rea-agents@X` | `registry.npmjs.org` | **Solo si lo ejecutas explícitamente.** Además mantiene los registros de agentes (FS-4). Integridad solo por el hash del registro | **Riesgo** de aislamiento (prohibido) |
| UPD-2 | Chequeo de versión de incur | `registry.npmjs.org` | Automático en la CLI interactiva, cada 24 h; no en MCP | Revisar → desactivar (FS-6) |
| UPD-3 | Instalador de Hopper | `www.hopperapp.com` | `rea setup --install-hopper` o setup interactivo; solo macOS/Linux | OK (no aplica en Windows) |
| UPD-4 | La skill incluida indica, ante fallos de conexión, ejecutar `npx -y rea-agents@6.8.0 setup --client … --yes` (con aprobación) | — | Cuando el agente lee la skill | **Riesgo** de aislamiento → neutralizar al copiarla (`skills/reverse-engineer-anything/SKILL.md:46-68`) |

No existe auto-update en segundo plano que reemplace el binario.

---

## 10. Riesgos por capacidad (por diseño, no maliciosos)

REA expone 229 herramientas MCP. Algunas, combinadas con un *prompt injection* contenido en el material analizado (strings de un binario, HTML de una web), permitirían exfiltrar datos sin ningún código malicioso en REA.

| ID | Capacidad | Herramientas | Evidencia | Clasif. |
|---|---|---|---|---|
| CAP-1 | **Leer cualquier ruta.** Las rutas solo se resuelven, sin raíz ni lista permitida (por ejemplo, `~\.ssh\id_*` sería legible y se le devolvería al agente) | `read_bytes`, `extract_artifact`, `push_adb_file`, analizadores de archivos… | `dist/filesystem/callerPath.js:12` (verificado) | **Riesgo** |
| CAP-2 | **Ejecutar comandos arbitrarios** | `capture_process_scenario`; `execute_rizin_command` y `rizin_debug_command` (rizin `!cmd`, sin `cfg.sandbox`); `cutter_command`; `load_frida_script`/`instrument_with_frida` | `dist/process/capture/ProcessHarness.js:129`, `dist/rizin/RizinCommand.js:8-16` (verificado) | **Riesgo** |
| CAP-3 | **Enviar variables de entorno a un origen elegido** | `capture_browser_scenario` | SEC-4 | **Riesgo** |
| CAP-4 | **Acciones sobre dispositivos Android** | `install_adb_package`, `uninstall_adb_package`, `push_adb_file`, `start_adb_*`… | — | Revisar |
| CAP-5 | Servidor HTTP sin autenticación | `rea mcp --http`, `rea environment serve` | §5 | Revisar |

**Importante para la Fase 4:** las reglas `permissions.deny` de tipo `Read(~/.ssh/**)` de Claude Code **solo afectan a las herramientas propias de Claude** (Read, Edit, Bash…). **No limitan lo que hace un servidor MCP.** Para REA hay que usar reglas **por herramienta** (`mcp__rea__<tool>`): pedir aprobación o denegar. Las variables de entorno redirigen dónde *escribe* REA, pero **no son una frontera de seguridad**: REA sigue pudiendo leer todo lo que tu usuario de Windows puede leer. El aislamiento fuerte requiere otra cuenta de Windows, Windows Sandbox o una VM.

---

## 11. Recomendaciones (aplicar en las Fases 4 y 5)

1. **Lanzador con entorno mínimo** para el MCP. El proceso se arranca con un entorno construido desde cero, solo con lo necesario (`SystemRoot`, `PATH` saneado con el Node local, `PATHEXT`, etc.), para que no herede tokens ni API keys de tu sesión. Además, redirigir dentro de `<kit>\.rea-runtime\`:
   - `TEMP`, `TMP`, `USERPROFILE`, `HOME`, `APPDATA`, `LOCALAPPDATA`
   - `XDG_CACHE_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`
   - `PLAYWRIGHT_BROWSERS_PATH`, `REA_KUNA_CACHE_DIR`, `ANDROID_USER_HOME`, `npm_config_cache`

   Y fijar `NO_UPDATE_NOTIFIER=1`, `npm_config_update_notifier=false`, `NODEFAULTCURRENTDIRECTORYINEXEPATH=1` y `REA_REFERENCE_SECRET_PATTERNS_JSON=[".env*","*.pem","*.key","id_*"]`.
2. **No ejecutar nunca:** `rea setup`, `rea update`, `rea uninstall`, `rea mcp add`, `rea skills add`, `rea mcp --http`, `rea environment serve`, `install.sh`, `npx rea-agents …`, `npm i -g`. Reforzarlo con reglas `deny` de Bash en `.claude/settings.json`.
3. **Permisos MCP por herramienta:** las herramientas de REA quedan **en "ask"** (nunca auto-aprobadas), y se **deniegan por defecto** las de CAP-2 y CAP-3 (`capture_process_scenario`, `execute_rizin_command`, `rizin_debug_command`, `cutter_command`, `load_frida_script`, `instrument_with_frida`, `capture_browser_scenario`, `install_adb_package`, `uninstall_adb_package`, `push_adb_file`). Se habilitan puntualmente cuando hagan falta.
4. **Skill:** copiarla a `./.claude/skills/` con un preámbulo local que anule las instrucciones de `setup` y `npx` (UPD-4) y diga que REA está registrado en `./.mcp.json`.
5. **Destinos explícitos:** pedirle a REA que extraiga en `./projects/<target>/` en lugar de su destino temporal por defecto.
6. **Fase 5:** monitorear las conexiones durante una prueba y comparar la línea base de aislamiento (`scripts/snapshot-outside.ps1`).

---

## 12. Decisión pendiente: scripts de instalación (`npm rebuild`)

El **único** script que falta por ejecutar es el `install` de **frida**, que es una dependencia **opcional**. Sin frida, REA funciona igual salvo las 9 herramientas `*frida*` (instrumentación dinámica en dispositivos o procesos).

| Opción | Qué se ejecuta | Red | Riesgo |
|---|---|---|---|
| **A. No instalar frida** | Nada | Ninguna | El mínimo. Se pierden las herramientas de Frida |
| **B. Instalación manual verificada** | Ningún script: se copia y extrae en `node_modules/frida` el tarball ya verificado contra el digest de GitHub, y se comprueba que `build/frida_binding.node` = `32C73230…57DC` | Ninguna | Bajo. Mismo resultado que el script, sin ejecutar `install.js` |
| **C. `npm rebuild frida --ignore-scripts=false`** con el prebuild verificado sembrado en `node_modules/frida/prebuilds/` | `install.js` → `prebuild-install` (offline) | Ninguna si encuentra el prebuild local; si falla, intentaría la compilación de respaldo (§3.1) | Bajo-medio |

Ningún otro paquete necesita `npm rebuild`.

---

## 13. Verificación en ejecución (Fase 5, 2026-11-04)

Primeras ejecuciones de REA, todas a través de `scripts/rea-isolated.mjs` y monitoreadas con `run-monitored.ps1`. Logs en `logs/run-*`.

| Prueba | Resultado |
|---|---|
| CLI `analyze-javascript-application targets/sample-js-app --json` | Exit 0 en 2.5 s. Árbol de procesos: launcher → worker `javascriptAnalysisWorkerProcess.js` (Node local) → conhost. **0 conexiones TCP/UDP, 0 entradas DNS nuevas, 0 cambios fuera de la carpeta.** La evidencia (371 KB) detecta estáticamente `api.example.invalid`, `fetch` y `localStorage` **sin consultar ese host**: no hubo búsqueda DNS de `*.example.invalid` |
| MCP stdio (`initialize` → `tools/list` → `tools/call analyze_javascript_application`) | Servidor `rea` 6.8.0, protocolo `2025-06-18`, 229 herramientas, análisis correcto. **0 conexiones, 0 DNS, 0 cambios fuera** |
| Privacidad de la salida | Las salidas no contienen la ruta del perfil de usuario (`%USERPROFILE%`) ni variables de entorno |
| `rea` desde otra carpeta (PATH real del registro) | `Get-Command` y `where.exe`: no encontrado. `npm ls -g rea-agents`: vacío |
| `claude mcp list` desde otra carpeta | No aparece `rea` |
| `claude mcp list` en la carpeta del kit (control) | `rea: …\node.exe …\rea-isolated.mjs - √ Connected` |
| Estado global vs línea base inicial | PATH de usuario igual. PATH de máquina con las mismas entradas (reordenado por el instalador de otra aplicación, ajeno a REA). MCP en `~/.claude.json` sin cambios. `~/.claude/skills` igual. Paquetes globales: sin `rea-agents` (se desinstaló con tu aprobación). `claude_desktop_config.json` cambió porque la app Claude Desktop lo reescribe al iniciar (00:23); no menciona REA |
| Ubicaciones por defecto de REA | No existen `~\.rea`, `~\.cache\rea`, `~\.cache\incur`, `~\.local\share\incur` ni skills de REA en `~\.claude` o `~\.agents`. `%LOCALAPPDATA%\ms-playwright` y los perfiles `playwright_*` en `%TEMP%` son **anteriores** (jun–oct 2026, otros usos de Playwright). No hay ninguna entrada `rea-*` en el `%TEMP%` real |

**Límite del monitoreo:** sondeo sin permisos de administrador, que puede perder conexiones más cortas que el intervalo. Lo compensa la comparación de la caché DNS, que también registra los intentos fallidos. Para una captura completa, ejecutar `pktmon` o Wireshark (con admin) en paralelo.

---

## 14. Kit reutilizable (Fase 6, 2026-11-04)

`bootstrap.ps1` reconstruye la instalación en cualquier carpeta y **rechaza cualquier artefacto que no coincida con los pins de `kit/versions.json`**:

- zip y `node.exe` de Node,
- integridad del lockfile, con todas las URLs de `registry.npmjs.org`,
- integridad, repositorio y addon nativo de `rea-agents`,
- SHA256 de la skill original,
- tarball y binding de frida, incluida la lista exacta de entradas del tar para evitar *path traversal*.

Nunca ejecuta scripts de npm. Toda escritura pasa por una comprobación de "dentro de la carpeta". `scripts/kit-verify.mjs` repite las comprobaciones: pins, lockfile, árbol instalado, hooks de instalación nuevos, skill, `.mcp.json`, permisos, entorno del lanzador y comandos bloqueados.

| Prueba (copia limpia de los 30 archivos publicables, como tras un `git clone`) | Resultado |
|---|---|
| `bootstrap.ps1 -WithFrida` desde cero | Node descargado de nodejs.org, 176 paquetes de registry.npmjs.org y tarball de frida de github.com. **Todos los hashes coinciden con los pins.** Firmas 176/176, attestations 39. Advisories: solo los 3 ya revisados (§4). 36/36 comprobaciones OK, 0 advertencias |
| Fuera de la carpeta durante el bootstrap | `rea` no está en el PATH del sistema, no hay servidor REA en `~/.claude.json` y **0 cambios** entre los snapshots de antes y después |
| `run-monitored.ps1 -Mode cli` y `-Mode mcp` en la copia | Exit 0. **0 conexiones TCP/UDP del árbol de REA.** 229 herramientas MCP. 0 cambios fuera. Una entrada DNS nueva de otra aplicación del sistema, no atribuible a REA, que no abrió ninguna conexión |
| Aviso de npm | `prebuild-install@7.1.3` está deprecado. Es dependencia de frida y nunca se ejecuta, porque el binding se instala desde el tarball verificado |

---

## Anexo: hashes de referencia

| Artefacto | SHA256 |
|---|---|
| `rea-agents-6.8.0.tgz` | sha512 `9QDeRnGqEDzABZyr04eLnBXBv/c6I9/TWu/6M0MD4pEfkySI/BIgwTODIbAReX3C1x6hjw9+Jlx4A2yUSPZ9ww==` |
| `native/windows/build/rea-windows-x64.node` | `6a015bfefee7fafb6cbafab659f040170848a45425bbcef6caf962fd39b6ff7b` |
| `frida-v17.23.2-napi-v8-win32-x64.tar.gz` (= digest de GitHub) | `e9dbc08d386130610430137f0bb31d90af7b08c0f5710942d4313368ada930ea` |
| `frida/build/frida_binding.node` | `32C73230BDFD4B9A8F1F1871EF616001E486269919F18A111A195854352057DC` |
| `node-v24.22.2-win-x64.zip` (firma GPG de Node verificada) | `ca1bff5d8ead13c9f2ea404a176db46bd430704d5b5113734049fa365e7799e2` |

Logs de la auditoría (locales, no se publican): `logs/audit-lifecycle.json` y `logs/audit-npm.json`. Línea base: `logs/isolation/baseline-*.json`. Se regeneran con `node scripts/audit/lifecycle-scan.mjs node_modules`, `npm audit --json` y `scripts/snapshot-outside.ps1`.
