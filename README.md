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
  --chat-template-kwargs '{"reasoning_effort":"low"}' \
  --parallel 1 --cache-ram 16384 --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 0
```

`--cache-ram 16384` sets the RAM cache size in MiB. When another request arrives, llama-server saves the single slot's state to that cache and reloads it later. The default 8192 can be too small for a ~100K-token conversation.

Sampling is Qwen's thinking-mode recommendation. The script sets it, so there is no manual admin step.

**Thinking effort is `low`.** The model thinks before every reply, and at ~10 tok/s that thinking is most of the wait. Checked on llama-server 0.6.0 by replaying Claude Code's requests: the server ignores Claude Code's effort setting, so the chat template fell back to its default, `xhigh`, for every request, background ones included. `/effort` inside Claude Code changes nothing. Setup now passes `low` to the template, which tells the model to keep its thinking brief. Qwen's card warns that lower effort can cause more failed steps and retries on hard tasks. To go back: `REASONING_EFFORT=xhigh ./setup.sh start profile` (or `medium`).

**Chat template:** `qwen3.8-27b-chat-template.jinja` is the GGUF's own template with one change. Claude Code sends hook output as a `system` message after the first user message, and the stock template rejects that with `Jinja Exception: System message must be at the beginning.` The patched copy renders it as a normal system turn instead. Setup applies it only when `MODEL_REPO` contains `qwen`. Any other model uses its GGUF's own template.

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
| `profile` | Writes `~/.claude/local-qwen.json`, `~/.config/crush-local/crushrc` and the `claude-local` and `crush-local` launchers. `claude-local` loads only the core tools (see [Tips](#tips)) |
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
| `REASONING_EFFORT` | `low` | How long Qwen thinks before each reply: `low`, `medium` or `xhigh`. Lower is faster. Pass it to both `start` and `profile` |
| `SPEC_DECODING` | `none` | `none`, `mtp` (uses heads already in the GGUF, no download) or `dflash` (adds a 1.1 GB drafter). See step 5 |
| `ENGINE` | `llama` | `llama` (llama-server) or `splash` (faster on vendor numbers, not run here). See step 6 |
| `SPLASH_DRAFT_REPO` | `incoai/Qwen3.8-27B-DFlash2` | The DFlash2 draft `ENGINE=splash` downloads for the model. Change it with `MODEL_REPO` |
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
- **MTP** (`SPEC_DECODING=mtp`) uses multi-token-prediction heads already inside the main GGUF. A PR #27342 commenter ran `--spec-type draft-mtp` on this exact Unsloth UD-Q4_K_XL file, so there is no extra download. One Mac data point: [Splash's README](https://github.com/incoai/splash#gguf-against-llamacpp) measured llama.cpp on the 27B UD-Q4_K_M at 16 tok/s plain and 27 tok/s with MTP on an M5 Pro (17 and 20 on an M3 Max), on short prompts. Try MTP first: it costs no download. Speed at Claude Code context lengths is unverified.
- **Draft length:** the DFlash drafter's block size is 8, so the default `--spec-draft-n-max 7` uses the full block. One 3090 tester got better results with 4. Worth trying.

1. For DFlash only: `SPEC_DECODING=dflash ./setup.sh download start`. MTP needs no download.
2. Run the same 5–10 real tool-heavy tasks with long context on each setting:
   - Default: `./setup.sh start`
   - MTP: `SPEC_DECODING=mtp ./setup.sh start`
   - DFlash: `SPEC_DECODING=dflash ./setup.sh start`
3. Keep the fastest one with zero failed tool calls.

Optional quant test: `MODEL_QUANT=UD-Q5_K_XL ./setup.sh download start profile` (21 GB, still under the default GPU limit), then compare with `UD-Q4_K_XL`.

### 6. Optional: serve with Splash instead of llama-server

> **Heads up:** not run on the Mac this repo was written on. The flags come from Splash's docs, and `./test.sh` checks only the LaunchAgent that setup writes. Treat it as an A/B test, like step 5.

[Splash](https://github.com/incoai/splash) is a Metal engine built around DFlash2 drafting. It serves the same GGUF and the same Anthropic Messages API, so `claude-local` and the profile do not change.

```sh
ENGINE=splash ./setup.sh install download start
./smoke-test.sh
```

- **Why try it:** on the same Unsloth UD-Q4_K_M weights, [Splash's README](https://github.com/incoai/splash#gguf-against-llamacpp) reports 74 tok/s for the 27B against llama.cpp's 16 (27 with MTP) on an M5 Pro, and 175 against 69 for Qwen3.6-35B-A3B. Vendor numbers, short prompts.
- **Needs:** an M3 or newer and macOS 26.4 or later.
- **What setup does:** `install` adds `brew install incoai/tap/splash`. `download` also fetches the draft (`incoai/Qwen3.8-27B-DFlash2`, 3.8 GB) into the Hugging Face cache, because Splash never downloads a draft for a local GGUF. `start` writes the same LaunchAgent with `splash serve --model-dir <the GGUF> --served-model-name qwen3.8-27b --max-context 131072 --default-reasoning-effort low`.
- **What no longer applies:** the patched chat template (Splash renders later system messages itself), `SPEC_DECODING`, the KV cache flags and `--cache-ram`. `./logs.sh speed` greps llama-server's timing lines, so it prints nothing; read `./logs.sh` instead.
- **Unverified:** `crush-local` against Splash, and how Claude Code's effort setting reaches it. Splash's docs say an Anthropic request thinks only when it asks to.
- **Idle:** Splash frees the model after 10 minutes without a request and reloads it on the next one.
- **Back to llama-server:** `./setup.sh start`.

## Migrating from the oMLX setup

The old setup used oMLX on port 8000 with the 6-bit Qwen3.6-35B-A3B. To switch:

```sh
brew services stop omlx && brew uninstall omlx
rm -rf ~/.omlx          # optional: frees ~29 GB of old model files
./setup.sh
```

## Tips

- `./logs.sh` shows whether the server is running, then streams its log (last 50 lines first) until you press Ctrl-C. If the server is not loaded, it also shows recent macOS `launchd` messages about it, which is where errors like `Bootstrap failed: 5` end up.
- **`claude-local` is lean by default.** The launcher passes `--strict-mcp-config --tools=Bash,Read,Edit,Write,Skill,ExitPlanMode`: skills still work, but there are no MCP servers, no subagents and no web tools. A local model reads the whole prompt before its first word, and tool definitions were 70% of it. Measured on one Mac with plugins: the first request went from 97,751 to 39,224 characters, so the first reply starts in about 40% of the time. The skills tool and its list of skills are 8,668 of those characters.
- **Everything back:** `claude --settings ~/.claude/local-qwen.json` loads every tool, MCP server and skill, at the full prompt size.
- **Smallest prompt:** `claude-local --bare` also skips CLAUDE.md, hooks and plugins. Measured: 4,058 characters.
- What is left in the lean prompt is mostly your own plugin hooks and CLAUDE.md rules. Run `/context` to see them.
- Use plain `claude` for your normal Anthropic setup. Nothing else changes.
- Long local runs: `caffeinate -dims claude-local` stops the Mac from sleeping while the agent works, and `-s` only applies on the charger. Keep the lid open: some MacBook Pros cool through the keyboard.
- `./logs.sh speed` prints the last 50 cache and timing lines and exits. `task.n_tokens` is the size of the whole prompt, and the token count on the `prompt eval time` line is how much of it the server had to read again. If those two stay close on every turn, the prompt cache is not hitting.
- Thinking is on at `low` effort. See [the note above](#why-this-model-and-runtime) for why and how to raise it.
- **Sudden slowdown:** one [report](https://x.com/heyvictortorres/status/2112558446872596767) on an M2 Max saw the same model run about 40% slower while an animated Aerial wallpaper was playing. Not checked here. If speed drops for no reason, switch to a still wallpaper and compare.
- Remote Control is disabled while `ANTHROPIC_BASE_URL` points at a local server ([docs](https://code.claude.com/docs/en/env-vars)).

## Crush

`./setup.sh profile` also sets up [Crush](https://github.com/charmbracelet/crush) against the same server. Run `crush-local` in a repo.

- **Config:** `~/.config/crush-local/crushrc`. It uses Crush's `llamacpp` provider type, sets the context window to match the server, and uses the local model for both the large and small slots.
- **Separate from plain `crush`:** the launcher sets `CRUSH_GLOBAL_CONFIG`, `CRUSH_GLOBAL_DATA` and `CRUSH_DISABLE_DEFAULT_PROVIDERS=1`, so only the local model shows up and your normal Crush setup is not touched.
- **Skills in the `ctrl+p` palette:** Crush only lists skills marked `user-invocable: true`. On each start the launcher copies the skills from `~/.config/crush/skills`, `~/.config/agents/skills`, `~/.agents/skills` and `~/.claude/skills` to `~/.local/share/crush-local/skills`, adds that line unless the skill already sets it, and points `CRUSH_SKILLS_DIR` there. Supporting files are symlinked and the originals are not changed. Project skills (`.claude/skills` and others) load as before, without the line.
- **Prompt size:** Crush's first request is about 49K characters (26 tools). Claude Code with every tool, plugins and MCP was about 98K (32 tools), the lean `claude-local` default is about 39K, and `claude-local --bare` about 4K. A smaller prompt means a faster first reply on a local server.

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
| `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` | No background request to write a session title. It would queue on the single llama-server slot next to your first message |
| `CLAUDE_CODE_EFFORT_LEVEL=low` | Matches the server's `REASONING_EFFORT`. llama-server 0.6.0 ignores it, but a version that starts reading it would otherwise get Claude Code's default, `high` |
| `promptSuggestionEnabled: false` | Top-level setting, not an env var. No background prompt-suggestion request, which would queue behind the single llama-server slot |
| `idleCompaction: false` | Top-level setting, not an env var. No background compaction while idle, which would occupy the single slot |
| `apiKeyHelper: ""` | Top-level setting. Overrides any `apiKeyHelper` from your normal settings so `claude-local` uses the local token |

Docs: [model config](https://code.claude.com/docs/en/model-config), [env vars](https://code.claude.com/docs/en/env-vars), [LLM gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol).

## Fallback: speed over smarts

If the 27B is too slow for you, switch to [Recursive Flint](https://huggingface.co/RecursiveSI/flint) (Apache 2.0, released 21 October 2026). It is a 40B mixture-of-experts coding model with ~2.5B parameters active per token, so it writes about 10x faster than the dense 27B:

```sh
MODEL_REPO=unsloth/flint-GGUF MODEL_QUANT=UD-Q4_K_XL MODEL_ALIAS=flint ./setup.sh install download start profile
```

- **Speed:** Recursive reports 125+ tok/s at short context on a 48 GB M4 Pro (MLX). That is a vendor number, not measured here, and llama.cpp may be slower than MLX.
- **Smarts:** it scores lower. Its card gives 54.9 on Terminal-Bench 2.1, against Qwen3.8-27B's 73.0. Flint's own run counts answers found through web retrieval as failures, so the gap may be smaller than it looks.
- **Memory:** the GGUF is 25.1 GB. Only 14 of 49 layers keep a full KV cache (the other 35 use a 512-token sliding window), so the cache at 128K is ~2 GB. That makes ~27 GB in total, under the default GPU limit.
- **llama.cpp:** Flint needs llama.cpp 0.8.0 or newer ([PR #30928](https://github.com/ggml-org/llama.cpp/pull/30928)). The `install` stage in the command above upgrades it.
- **Chat template:** setup uses the GGUF's own template for any non-Qwen `MODEL_REPO`. Flint's template accepts system messages at any position, so it needs no patch.
- **Output budget:** Flint's card asks for at least 32768 output tokens on hard problems. The profile caps output at 24576 so it fits the 131072 window. If long replies get cut off, raise `CONTEXT_TOKENS`.
- **No MTP:** the GGUF has no MTP heads, so `SPEC_DECODING=mtp` does nothing. A DFlash2 draft exists (`SPEC_DECODING=dflash DRAFT_REPO=incoai/Flint-DFlash2-GGUF`, 240 MB), but its card has no GGUF numbers yet and it is untested here.
- **Splash:** it lists this exact GGUF as supported. Add `ENGINE=splash SPLASH_DRAFT_REPO=incoai/Flint-DFlash2` to the command above (see step 6). For Qwen3.6-35B-A3B the draft is `incoai/Qwen3.6-35B-A3B-DFlash2`.

The older Qwen3.6-35B-A3B MoE (3B active) still works: `MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF MODEL_ALIAS=qwen3.6-35b-a3b ./setup.sh download start profile`.

To go back to Qwen3.8-27B: `./setup.sh start profile`.

## Macs with less than 48 GB

Preflight stops before starting `llama-server`, but `claude-local` is already written and points at `:8080`. Every request then hangs while Claude Code retries a server that is not there.

On a 16 GB M1, point the profile at Ollama's 9B instead. Its KV cache at 128K is ~2 GB (8 of 32 layers keep one), so it loads fully on the GPU at 8.4 GB:

```sh
printf 'FROM qwen3.5-9b-plain-cc\nPARAMETER num_ctx 131072\n' > /tmp/Modelfile
ollama create qwen3.5-9b-cc-128k -f /tmp/Modelfile
SERVER_URL=http://127.0.0.1:11434 MODEL_ID=qwen3.5-9b-cc-128k ./setup.sh profile
```

Measured with `claude-local -p`: the first call takes ~4 min (full system-prompt prefill), the next one ~7 s (prompt cache hit). `claude-local --bare` cuts the first call a lot.

## Stopping the server

`./setup.sh stop` unloads `llama-server` from launchd and frees its memory. Use this, not `kill`: the LaunchAgent has `KeepAlive`, so a killed server restarts at once. It starts again at your next login, or with `./setup.sh start`.

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
- `ENGINE=splash` is unverified end to end. Its speed figures are Splash's own.
- Anthropic does not officially support non-Claude models behind `ANTHROPIC_BASE_URL`. Claude Code may change how it talks to them.
- llama.cpp flags, model IDs and the `/v1/models` response may change. If requests fail with an unknown model, run `curl -s localhost:8080/v1/models` and pass `MODEL_ID=<id>` to `./setup.sh profile`.
