# gemma-vast

**Gemma 4 26B-A4B con visión** (chat + imágenes) en una GPU alquilada de 16GB,
manejado desde tu PC con un solo script. Lo usas en tu navegador, todo privado
por túnel SSH y sin API keys.

- Modelo: `gemma-4-26B-A4B-it` (MoE, 4B activos por token), cuantizado UD-IQ4_XS por
  [unsloth](https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF). Son 13.6GB, más 1.2GB de visión.
- Motor: [llama.cpp](https://github.com/ggml-org/llama.cpp), compilado con CUDA en la VM.
- Probado en una RTX A4000 16GB: ~49 tokens/s, ~15GB de VRAM, contexto de 32k.

## Qué necesitas

- **Tu PC**: cualquier Linux con `bash`, `ssh`, `tar` y `procps` (vienen en casi todas las distros).
- **La VM**: GPU NVIDIA de 16GB o más, imagen con CUDA *devel*, es decir con `nvcc`
  (probado con la imagen base de Vast, CUDA 13.0; el script avisa si falta), unos
  20GB de disco y tu clave SSH cargada en el proveedor.

## Uso rápido

```bash
chmod +x adminvast.sh
./adminvast.sh --connect 'ssh -p PUERTO root@IP' --setup --test --open
```

Pega el comando SSH tal como te lo da Vast. La primera vez compila y descarga
(unos 15 min); después se abre `http://localhost:8082` en tu navegador.

Sin argumentos, `./adminvast.sh` abre un menú. Recuerda la última VM.

| Comando | Qué hace |
|---|---|
| `--setup` | Compila + descarga + lanza + abre el túnel |
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

Gemma 4 es Apache 2.0 (según su ficha en Hugging Face). llama.cpp es MIT.
