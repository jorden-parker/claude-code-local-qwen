# Claude Code + local Qwen3.8-27B on an M4 Pro 48 GB

Runs **Qwen3.8-27B** (4-bit GGUF, 128K context) locally with **llama.cpp**'s `llama-server` and connects Claude Code to it through a separate profile. Your normal Claude Code settings are not touched.

## Why this model and runtime

- **Qwen3.8-27B** is a dense 27B model and the best coding model that fits 48 GB here. Vendor-reported scores vs Qwen3.6-27B ([model card](https://huggingface.co/Qwen/Qwen3.8-27B)):
  - SWE-bench Pro (Claude Code harness): 61.7 vs 53.5
  - Terminal-Bench 2.1: 73.0 vs 63.4
  - IFBench: 79.5 vs 69.1
- **Trade-off: speed.** Dense means every token reads all 27B weights. Expect roughly 8–11 tok/s on an M4 Pro. The 13–16 tok/s bandwidth estimate assumed 100% of the M4 Pro's 273 GB/s, but llama.cpp's [Apple Silicon benchmarks](https://github.com/ggml-org/llama.cpp/discussions/4167) show the M4 Pro using ~71% of bandwidth, and the [DFlash2 PR](https://github.com/ggml-org/llama.cpp/pull/27342) measured 10.4 tok/s for this model on a faster M5 Pro. Still an estimate, not measured. The 3B-active MoE is much faster. See the [fallback](#fallback-speed-over-smarts).
- **Memory fits.** 17.7 GB of weights plus ~4 GB of KV cache at 128K (q8_0) is ~22 GB, under macOS's default ~36 GB GPU limit.
- **Hybrid attention.** Only 16 of 64 layers keep a growing KV cache, so long context stays cheap.
- **Too big:** Qwen3.8-Flash-Next (125B MoE) does not fit 48 GB. Its smallest build is ~66 GB.
- **No proxy.** `llama-server` serves the Anthropic Messages API at `/v1/messages` natively. Prompt (prefix) caching is on by default.

The server runs with:

```sh
llama-server -c 131072 -ngl 99 -fa on --cache-type-k q8_0 --cache-type-v q8_0 \
  --jinja --chat-template-file ~/.config/local-qwen/qwen3.8-27b-chat-template.jinja \
  --parallel 1 --cache-ram 16384 --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0
```

`--cache-ram 16384` sets the RAM cache size in MiB. When another request arrives, llama-server saves the single slot's state to that cache and reloads it later. The default 8192 can be too small for a ~100K-token conversation.

Sampling is Qwen's thinking-mode recommendation. The script sets it, so there is no manual admin step.

**Chat template:** `qwen3.8-27b-chat-template.jinja` is the GGUF's own template with one change. Claude Code sends hook output as a `system` message after the first user message, and the stock template rejects that with `Jinja Exception: System message must be at the beginning.` The patched copy renders it as a normal system turn instead. If you change `MODEL_REPO`, check this template still fits the new model.

## Requirements

- Apple Silicon Mac, 48 GB memory, macOS 15+, 30 GB free disk
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
| `profile` | Writes `~/.claude/local-qwen.json`, `~/.config/crush-local/crushrc` and the `claude-local` and `crush-local` launchers |
| `preflight` | Checks chip (arm64), memory, disk |
| `install` | Installs or upgrades `llama.cpp`, `hf` and `jq`, updates Claude Code |
| `download` | Downloads the GGUF (~17.7 GB) to `~/models/Qwen3.8-27B-GGUF` |
| `start` | Writes the LaunchAgent `local.qwen.llama-server`, starts it, waits for `/health` |

Run one stage with `./setup.sh <stage>`. `launch-agent` writes only the plist.

Options (environment variables):

| Variable | Default | Why |
|---|---|---|
| `MODEL_QUANT` | `UD-Q4_K_XL` | Quant to download. `UD-Q5_K_XL` (21 GB) or `UD-Q6_K_XL` for more quality |
| `CONTEXT_TOKENS` | `131072` | Server context window. `262144` is the native max |
| `SPEC_DECODING` | `none` | `none`, `mtp` (uses heads already in the GGUF, no download) or `dflash` (adds a 1.1 GB drafter). See step 5 |
| `SERVER_PORT` / `SERVER_URL` | `8080` / `http://127.0.0.1:8080` | Where the server listens |
| `MODEL_REPO`, `MODEL_ALIAS` | `unsloth/Qwen3.8-27B-GGUF`, `qwen3.8-27b` | Model source and the name Claude Code sees |
| `MODELS_DIR` | `$HOME/models` | Where GGUFs are stored |
| `MODEL_ID` | `$MODEL_ALIAS` | Override the model ID the profile uses |

### 2. Make sure `claude-local` is on your PATH

`./setup.sh` writes the launcher `~/.local/bin/claude-local` first, before any checks, so it exists even if a later stage fails. If setup printed a PATH note, add the folder and reload:

- zsh: `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc`
- fish: `fish_add_path ~/.local/bin`

Check it: `zsh -ic 'command -v claude-local'` should print the launcher path. To rewrite only the launcher and profile, run `./setup.sh profile`.

If `claude-local` is found but says it cannot connect, the server is not running. Most often preflight failed (for example, a Mac with less than 48 GB). Read setup's `ERROR:` line.

### 3. Optional: raise the GPU memory cap

> **Heads up:** changes a system setting with `sudo`. It resets on reboot. Undo with `./gpu-limit.sh reset`.

The default ~22 GB fits under macOS's ~36 GB GPU limit, so you probably don't need this. Raise it only for a bigger quant or context, such as `MODEL_QUANT=UD-Q6_K_XL` or `CONTEXT_TOKENS=262144`:

```sh
./gpu-limit.sh          # sets 40960 MB, asks first
./gpu-limit.sh reset    # back to the macOS default
```

### 4. Smoke test

```sh
./smoke-test.sh
```

It calls the server directly, then runs `claude-local -p`. The first call reads the full system prompt, so it is slow. The profile sets `API_TIMEOUT_MS` to 30 minutes for this.

Then run `claude-local` in a real repo:

- Run `/context` to see how big the prompt is.
- Send two messages. The second should start much faster. If every turn is slow, the prompt cache is not hitting: check `~/Library/Logs/qwen-llama-server.log`.

### 5. A/B test: DFlash and MTP speed-up, and quant

Two speculative decoding options can speed up generation. Neither is verified for Claude Code on a Mac.

- **DFlash** uses a 1.1 GB drafter (z-lab's Qwen3.8-27B-DFlash2-GGUF) that proposes ~5 tokens per step on its card. [PR #27342](https://github.com/ggml-org/llama.cpp/pull/27342) measured 10.42 → 18.89 tok/s (1.8x) with the Q4_K_M drafter on an Apple M5 Pro 64 GB, but on 8 short GSM8K prompts only. Claude Code prompts are 20K–100K tokens. In the PR thread, a 5090 tester saw DFlash2 slower than MTP at ~23K tokens, with acceptance falling to 31–36% at long context, and a 3090 tester saw prompt processing drop from 454 to 272 tok/s on coding prompts. The gain at Claude Code context lengths is unverified.
- **MTP** (`SPEC_DECODING=mtp`) uses multi-token-prediction heads already inside the main GGUF. A PR #27342 commenter ran `--spec-type draft-mtp` on this exact Unsloth UD-Q4_K_XL file, so there is no extra download. Speed on a Mac is unverified.
- **Draft length:** the DFlash drafter's block size is 8, so the default `--spec-draft-n-max 7` uses the full block. One 3090 tester got better results with 4. Worth trying.

1. For DFlash only: `SPEC_DECODING=dflash ./setup.sh download start`. MTP needs no download.
2. Run the same 5–10 real tool-heavy tasks with long context on each setting:
   - Default: `./setup.sh start`
   - MTP: `SPEC_DECODING=mtp ./setup.sh start`
   - DFlash: `SPEC_DECODING=dflash ./setup.sh start`
3. Keep the fastest one with zero failed tool calls.

Optional quant test: `MODEL_QUANT=UD-Q5_K_XL ./setup.sh download start profile` (21 GB, still under the default GPU limit), then compare with `UD-Q4_K_XL`.

## Migrating from the oMLX setup

The old setup used oMLX on port 8000 with the 6-bit Qwen3.6-35B-A3B. To switch:

```sh
brew services stop omlx && brew uninstall omlx
rm -rf ~/.omlx          # optional: frees ~29 GB of old model files
./setup.sh
```

## Tips

- `./logs.sh` shows whether the server is running, then streams its log (last 50 lines first) until you press Ctrl-C. If the server is not loaded, it also shows recent macOS `launchd` messages about it, which is where errors like `Bootstrap failed: 5` end up.
- `claude-local --bare` loads only the Bash, read and edit tools and skips CLAUDE.md, MCP, skills and hooks. The prompt gets much smaller, so replies come faster.
- Use plain `claude` for your normal Anthropic setup. Nothing else changes.
- Thinking is on. Qwen's card says lower reasoning effort "does not always reduce overall task completion time" in multi-turn agentic tasks, because it can cause more failures and retries. Leave it on unless you measure a gain.
- Remote Control is disabled while `ANTHROPIC_BASE_URL` points at a local server ([docs](https://code.claude.com/docs/en/env-vars)).

## Crush

`./setup.sh profile` also sets up [Crush](https://github.com/charmbracelet/crush) against the same server. Run `crush-local` in a repo.

- **Config:** `~/.config/crush-local/crushrc`. It uses Crush's `llamacpp` provider type, sets the context window to match the server, and uses the local model for both the large and small slots.
- **Separate from plain `crush`:** the launcher sets `CRUSH_GLOBAL_CONFIG`, `CRUSH_GLOBAL_DATA` and `CRUSH_DISABLE_DEFAULT_PROVIDERS=1`, so only the local model shows up and your normal Crush setup is not touched.
- **Skills in the `ctrl+p` palette:** Crush only lists skills marked `user-invocable: true`. On each start the launcher copies the skills from `~/.config/crush/skills`, `~/.config/agents/skills`, `~/.agents/skills` and `~/.claude/skills` to `~/.local/share/crush-local/skills`, adds that line unless the skill already sets it, and points `CRUSH_SKILLS_DIR` there. Supporting files are symlinked and the originals are not changed. Project skills (`.claude/skills` and others) load as before, without the line.
- **Prompt size:** Crush's first request is about 49K characters (26 tools). Claude Code with plugins and MCP was about 105K (32 tools), and `claude-local --bare` about 4K. A smaller prompt means a faster first reply on a local server.

## What the profile sets

| Variable | Why |
|---|---|
| `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN=local` | Point Claude Code at `llama-server`. The token overrides any login |
| `ANTHROPIC_*_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL` | Every alias, background task and subagent uses the local model |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS=131072` | Claude Code assumes 200K for unknown models; this matches the server |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000` | Compacts before the server window fills. 100K is the minimum allowed |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS=24576` | A hard cap: a longer reply fails with "exceeded the output token maximum". Qwen thinking plus a full file (e.g. a big markdown file) blows past 8192. 24576 still fits under the 131072 window after the 100K compact point |
| `API_TIMEOUT_MS=1800000` | Slow local prefill on the first call |
| `CLAUDE_CODE_ATTRIBUTION_HEADER=0` | Keeps the prompt prefix stable so the KV cache hits |
| `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` | Strips Claude-only beta fields like `context_management` and `defer_loading`. Also turns off MCP tool search |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | No telemetry or update checks |
| `promptSuggestionEnabled: false` | Top-level setting, not an env var. No background prompt-suggestion request, which would queue behind the single llama-server slot |
| `idleCompaction: false` | Top-level setting, not an env var. No background compaction while idle, which would occupy the single slot |

Docs: [model config](https://code.claude.com/docs/en/model-config), [env vars](https://code.claude.com/docs/en/env-vars), [LLM gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol).

## Fallback: speed over smarts

If the 27B is too slow for you, switch to the MoE. It has 3B active parameters, so it writes much faster but scores lower:

```sh
MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF MODEL_QUANT=UD-Q4_K_XL MODEL_ALIAS=qwen3.6-35b-a3b ./setup.sh download start profile
```

To go back to Qwen3.8-27B: `./setup.sh start profile`.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/local.qwen.llama-server
rm ~/Library/LaunchAgents/local.qwen.llama-server.plist
rm -rf ~/models/Qwen3.8-27B-GGUF ~/.claude/local-qwen.json ~/.local/bin/claude-local
brew uninstall llama.cpp   # optional
```

## Tests

```sh
./test.sh
```

Checks the generated profile and launch-agent plist in a temporary home folder, the `gpu-limit.sh` input guards, and shellcheck.

## Caveats

- Speeds are estimates (the 8–11 tok/s figure is a bandwidth-based estimate), not measured on your machine.
- Benchmark scores are vendor-reported.
- DFlash and MTP on Mac are unverified. A/B them before relying on either.
- Anthropic does not officially support non-Claude models behind `ANTHROPIC_BASE_URL`. Claude Code may change how it talks to them.
- llama.cpp flags, model IDs and the `/v1/models` response may change. If requests fail with an unknown model, run `curl -s localhost:8080/v1/models` and pass `MODEL_ID=<id>` to `./setup.sh profile`.
