# gemma-vast: guía para agentes

Eres un agente (Claude Code, Codex, Gemini CLI, etc.) en la máquina Linux del
usuario. Este paquete monta **Gemma 4 26B-A4B con visión** en una VM GPU
alquilada (Vast.ai, RunPod o cualquier VM con GPU NVIDIA y SSH) y lo deja
accesible en el navegador del usuario por un túnel SSH. Tu trabajo es manejar
`adminvast.sh` por él.

## Archivos

| Archivo | Qué es |
|---|---|
| `adminvast.sh` | Todo el control: conexión SSH, compilación, descarga, lanzamiento, túnel, estado, prueba. Corre en la PC local. |
| `prompts/*.md` | System prompt que el proxy inyecta en cada chat sin mensaje `system`. Se suben a la VM en cada `--launch`. |
| `README.md` | Guía para humanos. |

El proxy (Python, solo stdlib) va dentro de `adminvast.sh` (`proxy_source`). No es un archivo aparte.

## Reglas

1. **Usa siempre flags, nunca el menú.** `./adminvast.sh` sin argumentos abre un menú
   que se queda esperando input y te bloquea.
2. **Los pasos se ejecutan en el orden en que los escribes.** `--build` va antes de
   `--pull`, y los dos antes de `--launch`. `--setup` equivale a los tres.
3. **Todos los pasos se pueden repetir sin riesgo.** `--build` salta si ya hay
   `llama-server` (compilado antes o el de la imagen `vastai/llama-cpp` en `/opt/llama.cpp`), `--pull` salta los archivos completos (verifica el tamaño contra
   Hugging Face) y `--launch` no relanza si ya responde.
4. **Pasos largos.** `--build` tarda 5-10 min si compila (0 con la plantilla Llama.cpp), `--pull` 2-10 min (~15GB) y
   `--launch` 30-90 s. Córrelos en segundo plano o con un timeout de 20 min o más.
   Si la sesión SSH se corta a mitad de camino, vuelve a correr el mismo comando:
   la compilación sigue donde quedó y la descarga empieza de cero (los links de HF
   no se pueden reanudar).
5. **Verifica, no asumas.** Un exit 0 no prueba que funcione. Después de lanzar,
   corre `--status` y `--test`. `--test` manda texto y una imagen; si responde
   "Rojo"/"Red", la visión funciona.
6. **No expongas puertos.** Todo escucha en `127.0.0.1` de la VM y se usa por el
   túnel. Nunca cambies `--host` a `0.0.0.0` ni abras puertos en el proveedor.
7. **La VM cuesta dinero por hora.** Nunca destruyas, reinicies ni recicles la
   instancia desde el panel del proveedor sin que el usuario lo pida. En Vast, un
   reboot en una instancia sin volumen borra `/workspace` (modelo y compilación
   incluidos).
8. **Comparte GPU.** Si el usuario también usa la VM para ComfyUI u otra cosa,
   `--stop` libera la VRAM. Pregúntale antes de matar procesos que no lanzó este script.

## Comandos

```bash
# Primera vez (la conexión se guarda en ~/.config/gemma-vast/last_ssh)
./adminvast.sh --connect 'ssh -p PORT root@IP' --setup --test

# Clave SSH que no es la de por defecto
./adminvast.sh --connect 'ssh -p PORT root@IP' --key ~/.ssh/clave --setup

# Sin --connect se usa la última VM guardada
./adminvast.sh --status
./adminvast.sh --restart --test
./adminvast.sh --stop
./adminvast.sh --tunnel            # solo el túnel (http://localhost:8082)
./adminvast.sh --tunnel-stop
```

El string de `--connect` se acepta tal como lo copia el usuario del panel de Vast,
con o sin `-L ...`, porque los `-L` se ignoran. El túnel lo abre `--launch`/`--tunnel`
en `LOCAL_PORT` (8082 por defecto) como un proceso `ssh -f -N` separado, que sigue
vivo después de que el script termina.

## Cómo inspeccionar la VM

`--shell` es interactivo, así que no lo uses. Lee la conexión guardada y usa ssh
directamente:

```bash
CONN=$(sed -n 1p ~/.config/gemma-vast/last_ssh)   # ej. 'ssh -p 30043 root@1.2.3.4 ...'
KEY=$(sed -n 2p ~/.config/gemma-vast/last_ssh)    # puede estar vacío
```

Con eso, arma `ssh -p PORT [-i KEY] root@IP '<comando>'`.

Rutas en la VM. `BASE` es `/workspace/gemma`, o `$HOME/gemma` si no existe `/workspace`:

| Ruta | Contenido |
|---|---|
| `$BASE/llama.cpp/build/bin/llama-server` | binario compilado (si no, usa `/opt/llama.cpp/llama-server` de la imagen o el del `PATH`) |
| `$BASE/models/` | `.gguf` del modelo + `mmproj` (visión) |
| `$BASE/prompts/` | copia de `prompts/` local (se reemplaza en cada `--launch`) |
| `$BASE/gemma-vast-proxy.py` | proxy (se reescribe en cada `--launch`) |
| `$BASE/logs/build.log` | log de compilación |
| `$BASE/logs/server.log` | log de llama-server (carga, VRAM, errores) |
| `$BASE/logs/proxy.log` | log del proxy |

Puertos en la VM: `8081` = llama-server (sin system prompt) y `8082` = proxy (con
`prompts/`). El usuario siempre usa el proxy.

`--stop` solo mata procesos de este paquete: el binario en `$BASE/llama.cpp/...` y
`gemma-vast-proxy.py`. No toca otros llama-server ni otros servicios de la VM.

**Gemma 4 piensa antes de responder.** Por la API, el razonamiento sale en
`reasoning_content` y la respuesta en `content`. Si llamas a
`/v1/chat/completions` con un `max_tokens` bajo, puede gastarlo entero pensando y
devolver `content` vacío. No pongas `max_tokens`, o ponlo alto (más de 4000), en
tareas largas como un prompt de MiniMax.

## Problemas conocidos

| Síntoma | Causa | Solución |
|---|---|---|
| `No conecta` | La instancia todavía arranca, falta la clave o el puerto cambió | Espera 1-2 min. Pide el comando SSH actual al usuario (en Vast el puerto cambia al recrear la instancia). Prueba `--key`. |
| `No hay CUDA toolkit (nvcc)` | La imagen no trae `llama-server` ni es CUDA *devel* | Lo más fácil: recrear la instancia con la plantilla Llama.cpp de Vast (`LLAMA_MODEL` vacía). Si no, una imagen CUDA devel. No intentes instalar CUDA a mano. |
| VRAM ocupada nada más arrancar con la plantilla Llama.cpp | La plantilla tiene `LLAMA_MODEL` y lanzó su propio llama-server (supervisor, puerto 18000) | Pregunta al usuario; con su OK, `supervisorctl stop llama` en la VM, o que recree la instancia con `LLAMA_MODEL` vacía. |
| La compilación falla con una GPU RTX 50xx | La imagen trae CUDA < 12.8 (no tiene sm_120) | Hace falta una imagen con CUDA 12.8 o más nuevo. |
| `llama-server se cerró` + `out of memory` | Otro proceso usa la VRAM, o el contexto es muy grande | Revisa `nvidia-smi`. Pregunta antes de matar lo que encuentres. O baja el contexto: `CTX=16384 ./adminvast.sh --restart`. |
| Respuestas lentas | Con menos de 16GB, llama.cpp (`--fit`) manda más expertos a CPU | Es esperado. Revisa en `server.log` qué quedó en CPU. |
| `content` vacío por la API | `max_tokens` se gastó en el razonamiento | Quita `max_tokens` o súbelo. En el webui no pasa. |
| `El puerto 8082 de tu PC ya está en uso` | Otro túnel o servicio local | `./adminvast.sh --tunnel-stop` o `LOCAL_PORT=8090 ./adminvast.sh --tunnel`. |
| `Falló la descarga` / `incompleto` | Corte de red o CDN de HF | Vuelve a correr `--pull`: borra el `.part` y empieza de cero. |
| `git falló, probando tarball` | GitHub bloqueado o con límite en la IP de la VM | Es automático: baja el tarball del mismo commit. |
| El webui ignora `prompts/` | Se usa el puerto 8081 en vez de 8082, o el chat ya trae un system prompt propio (en la configuración del webui) | Usa `http://localhost:8082` y borra el system prompt de la configuración del webui. |

## Personalizar

- **System prompt**: edita o agrega `.md` en `prompts/` y corre `--launch` (o
  `--restart`) para subirlos. El proxy los relee en cada request: después de
  subirlos no hace falta reiniciar llama-server. Se concatenan por orden
  alfabético (por eso `00_base.md` va primero).
- **Variables de entorno** (prefijo del comando, ej. `CTX=16384 ./adminvast.sh --restart`):
  `LOCAL_PORT`, `CTX`, `PROMPTS_DIR`, `MODEL_FILE`, `LLAMA_CPP_REF`
  (`master` = lo último, puede romper; por defecto usa el commit probado).
- **Otro modelo**: este paquete está pensado para 16GB. Con `MODEL_REPO`/`MODEL_FILE`/
  `MMPROJ_SRC`/`MMPROJ_FILE` se puede apuntar a otro GGUF de Hugging Face. Avísale
  al usuario que esa combinación no está probada.

## Si modificas adminvast.sh

- La lógica remota va en strings con comillas simples que se pasan a `remote`.
  Las variables (`$BASE`, `$MODEL_FILE`, ...) llegan definidas en el header que
  arma `remote()`. Un `$` que tiene que expandirse en la VM *dentro de comillas
  dobles remotas* va como `\$`.
- `remote` ejecuta el script desde un archivo temporal con stdin=`/dev/null`. No
  lo cambies a `bash -s` ni a `bash -c "$script"`: el primero deja que apt/curl se
  coman el script y el segundo hace que `pkill -f` se mate a sí mismo.
- Mantén solo `bash`, `ssh` y `tar` como dependencias locales, para que funcione
  en cualquier distro.
- Verifica con `bash -n adminvast.sh` y una corrida real de `--status --test`.
