# gemma-vast

**Gemma 4 26B-A4B con visión** (chat + imágenes) en una GPU alquilada de 16GB,
manejado desde tu PC con un solo script. Lo usas en tu navegador, todo privado
por túnel SSH y sin API keys.

- Modelo: `gemma-4-26B-A4B-it` (MoE, 4B activos por token), cuantizado UD-IQ4_XS por
  [unsloth](https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF). Son 13.6GB, más 1.2GB de visión.
- Motor: [llama.cpp](https://github.com/ggml-org/llama.cpp). Usa el `llama-server` que trae la imagen
  (plantilla Llama.cpp de Vast) o, si no hay, lo compila con CUDA en la VM.
- Probado en una RTX A4000 16GB: ~49 tokens/s, ~15GB de VRAM, contexto de 32k.

## Qué necesitas

- **Tu PC**: Linux o macOS con `bash`, `ssh`, `tar` y `pgrep`/`pkill` (vienen en casi
  todos; en macOS además `brew install bash`, porque trae bash 3). En Windows, usa WSL (Ubuntu dentro de Windows) y corre el script desde ahí.
- **La VM**: GPU NVIDIA de 16GB o más, unos 20GB de disco y tu clave SSH cargada en el proveedor.
  - **Recomendado: plantilla Llama.cpp de Vast** (imagen `vastai/llama-cpp`). Trae
    `llama-server` ya compilado, así que no hay que compilar nada. Deja la variable
    `LLAMA_MODEL` vacía al crear la instancia: si no, la plantilla arranca su propio
    modelo y ocupa la GPU.
  - Cualquier otra imagen con CUDA *devel* (con `nvcc`) también vale: el script compila
    llama.cpp la primera vez (5-10 min más).

## Uso rápido

```bash
chmod +x adminvast.sh
./adminvast.sh --connect 'ssh -p PUERTO root@IP' --setup --test --open
```

Pega el comando SSH tal como te lo da Vast. La primera vez descarga el modelo
(unos 5 min con la plantilla Llama.cpp, 15 si tiene que compilar); después se abre
`http://localhost:8082` en tu navegador.

Sin argumentos, `./adminvast.sh` abre un menú. Recuerda la última VM.

| Comando | Qué hace |
|---|---|
| `--setup` | Compila (si hace falta) + descarga + lanza + abre el túnel |
| `--status` | Estado de todo |
| `--test` | Prueba de texto + imagen |
| `--stop` | Apaga Gemma (libera la GPU) |
| `--tunnel` / `--tunnel-stop` | Abre o cierra el túnel |
| `--key ~/.ssh/clave` | Si tu clave SSH no es la de por defecto |

`./adminvast.sh --help` muestra todos.

## System prompt

Todo lo que pongas en `prompts/*.md` se manda como instrucciones de sistema en
cada chat. Viene con un contexto base y una guía para escribir prompts de video
para MiniMax-H3: sube una foto y pide *"escribe un prompt I2VA de 5 segundos"*.
Si editas los archivos, corre `./adminvast.sh --restart` para subirlos.

## Con un agente (Claude Code, Codex...)

`AGENTS.md` explica a tu agente cómo manejar el script, verificarlo y diagnosticar
problemas. Abre el agente en esta carpeta y pídele, por ejemplo: *"levanta gemma
en mi VM: ssh -p 30043 root@1.2.3.4"*.

## Licencias

Este kit es MIT (ver `LICENSE`). Gemma 4 es Apache 2.0 (según su ficha en Hugging Face). llama.cpp es MIT.
