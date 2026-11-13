# Claude Code + local Qwen on an M4 Pro 48 GB

Runs **Qwen3.6-35B-A3B** locally on **oMLX** and connects Claude Code to it through a separate profile. Your normal Claude Code settings are not touched.

## Why this model and runtime

- **Qwen3.6-35B-A3B** is a mixture-of-experts model with 3B active parameters. On an M4 Pro 48 GB it reads prompts at ~680 tok/s and writes at ~55 tok/s ([oMLX benchmark](https://omlx.ai/benchmarks/5zxiqdh8)).
- **Qwen3.8-27B** is smarter (SWE-bench Pro 61.7 vs 49.5), but dense, so it is ~4–5× slower here. Claude Code sends a 16k–33k token prompt before your message, so reading speed decides the wait.
- **oMLX** has an Anthropic `/v1/messages` endpoint and an SSD prompt cache, so follow-up turns are fast.
- **6-bit** is the default because 4-bit builds lost tool calling after cache hits ([oMLX #825](https://github.com/jundot/omlx/issues/825)).

## Requirements

- Apple Silicon Mac, 48 GB memory, macOS 15+, 70 GB free disk
- [Homebrew](https://brew.sh) and [Claude Code](https://code.claude.com) installed

## Steps

### 1. Run the scripted setup

```sh
git clone https://github.com/jorden-parker/claude-code-local-qwen.git
cd claude-code-local-qwen
./setup.sh
```

This does, in order:

| Stage | What it does |
|---|---|
| `preflight` | Checks chip, memory, disk, macOS |
| `install` | Installs oMLX and `hf`, updates Claude Code |
| `download` | Downloads the 6-bit model (~29 GB) to `~/.omlx/models` |
| `start` | Starts oMLX as a Homebrew service on port 8000 |
| `profile` | Writes `~/.claude/local-qwen.json` and the `claude-local` launcher |

Run one stage with `./setup.sh <stage>`.

Options (environment variables):

- `WITH_4BIT=1 ./setup.sh` also downloads the 4-bit model for the A/B test in step 6.
- `MODEL_VARIANT=4bit ./setup.sh profile` points the profile at the 4-bit model.
- `OMLX_API_KEY=...` if you set an API key in oMLX.

### 2. Make sure `claude-local` is on your PATH

The launcher is `~/.local/bin/claude-local`. If setup printed a PATH note, add it:

- zsh: `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`
- fish: `fish_add_path ~/.local/bin`

### 3. Optional: raise the GPU memory cap

> ⚠️ Changes a system setting with `sudo`. It resets on reboot. Undo with `./gpu-limit.sh reset`.

macOS lets the GPU use about 75% of RAM by default (~36 GB on 48 GB). Only raise it if the 6-bit model fails to load:

```sh
./gpu-limit.sh          # sets 40960 MB, asks first
./gpu-limit.sh reset    # back to the macOS default
```

### 4. Manual: set context and sampling in oMLX

Open http://localhost:8000/admin, pick the Qwen3.6-35B-A3B model, and set:

| Setting | Value |
|---|---|
| Context length | `131072` |
| Sampling (non-thinking) | temp `0.7`, top_p `0.8`, top_k `20`, presence_penalty `1.5` |
| Sampling (thinking, precise coding) | temp `0.6`, top_p `0.95`, top_k `20`, presence_penalty `0` |

Values are from the [Qwen3.6-35B-A3B model card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B). Turning thinking off makes replies faster.

### 5. Smoke test

```sh
./smoke-test.sh
```

It calls the server directly, then runs `claude-local -p`. The first Claude Code call reads the full system prompt, so expect 30–60 s.

Then run `claude-local` in a real repo:

- Run `/context` to see how big the prompt is.
- Send two messages. The second should start in a few seconds. If every turn is slow, the prompt cache is not hitting: check the oMLX log.

### 6. A/B test 6-bit vs 4-bit

1. `WITH_4BIT=1 ./setup.sh download`
2. Run the same 5–10 tool-heavy tasks with each:
   - `MODEL_VARIANT=6bit ./setup.sh profile && claude-local`
   - `MODEL_VARIANT=4bit ./setup.sh profile && claude-local`
3. Keep the fastest one with zero failed tool calls.

## Tips

- `claude-local --bare` loads only the Bash, read and edit tools and skips CLAUDE.md, MCP, skills and hooks. The prompt gets much smaller, so replies come faster.
- Use plain `claude` for your normal Anthropic setup. Nothing else changes.
- Remote Control is disabled while `ANTHROPIC_BASE_URL` points at a local server ([docs](https://code.claude.com/docs/en/env-vars)).

## What the profile sets

| Variable | Why |
|---|---|
| `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` | Point Claude Code at oMLX |
| `ANTHROPIC_*_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL` | Every alias, background task and subagent uses the local model |
| `CLAUDE_CODE_ATTRIBUTION_HEADER=0` | Keeps the prompt prefix stable so the cache hits |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS=131072` | Claude Code assumes 200k for unknown models; this matches the server |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | No telemetry or update checks |

## Fallback: Ollama

If oMLX misbehaves, use Ollama 0.40.16 or later:

```sh
ollama launch claude --model qwen3.6:35b-a3b-nvfp4
```

Avoid the `mxfp8` tags: [ollama#17583](https://github.com/ollama/ollama/issues/17583) reports them running very slowly on Macs.

## Uninstall

```sh
brew services stop omlx && brew uninstall omlx
rm -rf ~/.omlx ~/.claude/local-qwen.json ~/.local/bin/claude-local
```

## Tests

```sh
./test.sh
```

Checks the generated profile and launcher in a temporary home folder, the `gpu-limit.sh` input guards, and shellcheck.

## Caveats

- Speed figures are community benchmarks, not measured on your machine.
- oMLX's API, model IDs and admin UI may change. If `setup.sh profile` cannot find the model, run `curl -s localhost:8000/v1/models` and pass `MODEL_ID=<id>`.
