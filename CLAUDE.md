# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

`install-qwen-strata.sh` is implemented but **has never been run on real hardware** (no supported GPU on the development machine; the target machine, Threadripper PRO 3995WX / 512 GB RAM / 2 x RTX 3060 12 GB, is not available yet). Everything after the prompts (apt, user, Strata's `install.sh`, `strata launch`, systemd, the final tests) is untested. `README.md` is the source of truth for behavior, options, defaults, file layout and procedure — keep it in sync when the implementation changes, including its "Verification" section.

Much of what the installer assumes about Strata comes from reading the Strata 0.2.13 source, not from running it. Treat these as unverified until the first real installation: that `strata serve` works under systemd as written, the paths of the profile and run configuration checked after `strata launch`, the `/health` body (`"loaded": true`), HTTP 200 for `GET /config` with the key, the request body of the chat test, the model folder names used by `cleanup_old_models`, and the GPU numbering.

## Purpose

A single-file bash installer that sets up Qwen3.8-Flash-Next with Strata 0.2.13 (https://github.com/Niko1221/Strata/releases/tag/v0.2.13) as a service on **Ubuntu 26.04 LTS (Resolute Raccoon)**, x86_64, Server or Desktop (WSL is detected and refused). Clients are web browsers and coding agents on an intranet. It is modelled on plamo-3-translate-installer-for-resolute and must coexist with it on one host (plamo uses TCP 18080/28080 and its own nginx site).

There is no Python server, uWSGI or client in this repository: downloading and configuring is delegated to Strata's `install.sh` and `strata launch`. This repository adds systemd, nginx, ufw, GPU/NIC selection, the license confirmation and uninstall.

```
sudo bash install-qwen-strata.sh                       # interactive
sudo bash install-qwen-strata.sh --accept-license ...  # non-interactive
sudo bash install-qwen-strata.sh --uninstall
```

## Architecture (request path)

```
browser / coding agent
  → nginx (TCP 38080, selected interfaces; site qwen-strata, no default_server)
    → strata serve (127.0.0.1:48080; qwen-strata.service, service user)
      → Strata engine (child process)
```

destdir (default `/opt/qwen-strata`) is the **home directory of the service user** (default `qwenstrata`) and entirely owned by it; Strata keeps everything in the XDG default locations under HOME. `strata` must always run as that user with a clean environment (`run_as`: `runuser -u`, HOME=destdir, the pinning variables); running it as root writes into root's home, and Strata refuses folders owned by another account.

## Design decisions (agreed with the user; don't change without asking)

- **Strata is pinned to v0.2.13**: `STRATA_FEED` / `--feed` / `STRATA_UPDATE_FEED` point to the release folder, with `STRATA_UPDATE_CHECK=0`, `STRATA_NO_HANDOVER=1`, `STRATA_FEED_MODELS=0` for every `strata` call and in the unit. `install.sh` is verified with the SHA-256 built into the installer. Bumping Strata means updating `QWENSTRATAINS_STRATA_*`, the NVIDIA driver floors and the quantization table together. Strata's signed feed refuses a lower `sequence` than the last one it accepted.
- **Two-step start**: `strata launch ... --save-preset qwen-strata --no-tui` downloads, configures and test-starts the model as a background process; the installer stops it (`strata launch --stop --preset qwen-strata`) and systemd runs `strata serve --profile launch-qwen-strata` in the foreground. The model is therefore loaded twice at installation. `strata launch` does not see a `strata serve` process and fails if the port or the GPU is busy, so **the unit is stopped before every launch**. `--output json` is not used (it hides the progress); `strata launch` also exits 0 when it found no engine, so the profile and run configuration files are checked afterwards.
- **Options**: asked: `--destdir --user --quant --gpus --ctx-size --tune --web-port --interfaces --web-api-key --agent-api-key --open-ports --accept-license`; never asked: `--model --backend --kv --strata-port`. Number of parallel requests, drafter and picture reading are left to Strata's defaults; the model location is fixed under destdir.
- **Quantization**: nine choices (ISTA-DASLab `qwen` family: `Q2_0 IQ2_XS IQ3_XXS IQ3_S`; Unsloth `unsloth` family: `UD-IQ4_XS UD-Q4_K_XL UD-Q5_K_XL UD-Q6_K_XL Q8_0`), default `UD-Q4_K_XL`. The Coder, Swift, Gyro, NVFP4 and Unsloth v3.1 sets are deliberately not offered.
- **Context**: default 262144 (the trained length, also the maximum accepted); there is no `auto` because Strata never shrinks the context.
- **GPUs**: NVIDIA and AMD only (AMD untested; Intel Arc out of scope). Selected by PCI address; `--backend auto|nvidia|amd` is only a filter on the candidates, the backend given to Strata follows from the selected GPUs, and makers cannot be mixed. Default: one GPU — NVIDIA first, largest memory, most free memory, lowest PCI address. PCI addresses are converted to Strata's numbers at launch time (`gpu_indices`: `nvidia-smi` index, or KFD GPU node order).
- **API key**: Strata's key is all-or-nothing, so Strata always has a key (generated once, kept on re-run, in `/etc/qwen-strata/strata.env`) and nginx adds it per path (`nginx_site`): `/metrics` unless `--web-api-key`; the agent API paths unless `--agent-api-key`; `/v1/chat/completions` by both, distinguishing the web page by `Sec-Fetch-Site: same-origin` or, because browsers do not send `Sec-Fetch-*` over plain HTTP to non-localhost hosts, by `Origin` equal to `Host` (forgeable; documented in the README). **Management paths never get the key added and there is no option to change that**; any path not listed falls into `location /` and is passed with the client's own headers, so unknown paths fail safe. Keep it that way when adding paths. The key is never written into the site file (`include /etc/qwen-strata/nginx-key.conf`, root 0600).
- **nginx details that matter**: `proxy_set_header Host $http_host` (Strata compares the Origin of management POSTs with Host including the port; `$host` would break them); where the key is added, the client's `Authorization` is replaced and `x-api-key` removed (SDKs send placeholder keys); exact-match locations use a fixed URI in `proxy_pass` so that Strata sees exactly the path nginx matched; if `nginx -t` fails, the site link is removed before aborting so that other sites (plamo) are not affected.
- **License**: the Qwen Community License 1.0 must be accepted for every quantization (`yes` interactively, `--accept-license` otherwise).
- **Re-run**: value precedence is option > environment (`QWENSTRATA_*`) > `/etc/qwen-strata/install.conf` > default; the Terminal is reused when the pinned version is installed; Strata verifies and reuses engine and model files. Deleting model files of other quantizations is offered only interactively (`--yes` never deletes downloads).
- **Uninstall** removes the unit, the nginx site, the logrotate file, `/etc/qwen-strata`, the installer's ufw rules and destdir (only if the marker `.qwen-strata-installation` is present); apt packages, nginx and the service user stay.
- **systemd**: sandboxing is intentionally light (`NoNewPrivileges`, `ProtectSystem=full`) until tested on real hardware; `LimitMEMLOCK=infinity`, `LimitRTTIME=infinity`, `TimeoutStartSec=infinity`, `TimeoutStopSec=150`, `KillMode=mixed`.
- TLS is out of scope.

## Code conventions

- Every shell variable — globals, arrays and `local`s — is prefixed with `QWENSTRATAINS_` to avoid clashes (e.g. with `/etc/os-release` or the environment). Exceptions: bash builtins (`BASH_REMATCH`, `EUID`, `SECONDS`, ...), the user-facing `QWENSTRATA_*` environment variables, `DEBIAN_FRONTEND`, the variables exported for Strata inside `run_as`, and the key names inside `install.conf` and associative arrays (`DESTDIR`, `UFW_RULES`, ...). Do not source external files into the installer's shell (`install.conf` and `os-release` are parsed).
- The API key is passed to `strata` in the environment, never on a command line.
- Yes/no questions ask again on invalid input (`ask_yn`); other invalid answers stop the installer in `validate`.
- The structure and many functions (settings resolution, interface selection, ufw handling, uninstall) are ported from `install-plamo-3-translate.sh`; keep the two recognisably parallel.

## Installer procedure (order matters)

1. Resolve values, stop early if no usable GPU (`require_gpu`), prompts, `validate`, GPU / interface / ufw prompts, license, summary
2. `preflight`: ports (allowed to be held only by our own unit, or by nginx for a web port that was ours), destdir, home directory of an existing user, AVX2, disk, RAM, GPU driver (NVIDIA below 575.51 stops)
3. apt (missing packages only) → 4. service user, destdir (marker, `chown -R`) → 5. stop the unit → 6. Strata's `install.sh` → 7. API key files → 8. `strata launch`, then `strata launch --stop`
9. Unit, logrotate, nginx site (`nginx -t`), enable and start → 10. ufw, `install.conf` (saved before the tests on purpose) → 11. `/health` wait (up to 30 minutes), tests through nginx, offer to delete other quantizations

## Testing

There is no test suite. The file is not executed when sourced (`main` runs only if `BASH_SOURCE[0] == $0`), so functions can be exercised from a test script as a normal user:

- `bash -n install-qwen-strata.sh`; `shellcheck install-qwen-strata.sh` (not installed on the development machine and not run so far — run it when available and fix what it reports)
- Settings and GPU logic: source the script, set `QWENSTRATAINS_INTERACTIVE`, put a fake `nvidia-smi` in `PATH` (answering the `--query-gpu=...` forms used), override `rocm_devices`, `net_interfaces` and `ufw_active`, then call `parse_args` → `resolve_values` → `require_gpu` → `prompt_values` → `validate` → `prompt_gpus` → `prompt_interfaces`.
- nginx: fill `QWENSTRATAINS_VAL`, print `nginx_site` (replace the key include path), run a private nginx (`nginx -c <conf>` with `pid` and temp paths in a scratch directory) in front of a small Python server that enforces the key like Strata and echoes the headers it received; check the four `--web-api-key` / `--agent-api-key` combinations per path class. This was done for the current `nginx_site`; repeat it after any change to the site.
- The checks to run on real hardware are listed in README.md ("Verification").

## Handover for the next sessions

State at the end of the first implementation session (2026-11-14): the installer, README.md and this file are committed and pushed (`main`; `git push` goes to both GitHub and GitLab). Nothing below has been done yet.

### Before the hardware is available

- Run `shellcheck install-qwen-strata.sh` and fix what it reports. It was not available on the development machine (no package, and downloading the release binary was not permitted in that session). `# shellcheck disable=` lines were written without being able to check them: SC2016 on `write_key_files` and `nginx_location`, and SC2086/SC2046 in the ufw functions (ported from the plamo installer).
- The test scripts of the first session lived in a temporary directory and are gone. Recreate them as described under "Testing" when `nginx_site`, the settings code or the GPU selection change. What they covered: 140 HTTP checks (4 key settings x 35 requests: no key, placeholder key in `Authorization` and in `x-api-key`, the real key, page-like requests with `Origin` or `Sec-Fetch-Site`, foreign `Origin`, trailing slash, `..` in the path), all passing.

### First run on real hardware

The user plans to set up Claude Code on the target machine so that the installation can be run and checked there. Planned machines:

- Ryzen Threadripper PRO 3995WX, 512 GB DDR4, 2 x GeForce RTX 3060 12 GB (one GPU for Strata; the plamo-3-translate service may use the other). Default `UD-Q4_K_XL`.
- Possibly also Ryzen 9 9950X, 192 GB DDR5-5600, 1 x RTX 3060 12 GB, where the user would like `Q8_0` even if it is slower. From the Strata source: all experts fit in RAM there (needs about 136 GiB); the 50.7 GiB n-gram table stays on the SSD (keeping it in RAM would need about 206 GB); the GPU-side dense part is about 4.8 GB for every Unsloth file, so a larger quantization costs speed, not start-up. No measurement of `Q8_0` on an RTX 3060 exists in Strata's documents.

Run in this order and record the results (the README "Verification" section lists the same checks for users; update it and the "Status" note at the top of the README with what was actually confirmed):

1. `sudo bash install-qwen-strata.sh` interactively with the defaults. It downloads more than 110 GB and loads the model twice; expect hours. If it stops, the message of `die` names the step; re-running resumes the downloads.
2. After it finishes: `systemctl status qwen-strata`, `journalctl -u qwen-strata`, the engine log under `<destdir>/.local/state/strata/launch/`, `curl http://127.0.0.1:38080/health`.
3. From another host: the web chat in a browser (PC and phone), a coding agent through `/v1/chat/completions` (OpenAI-compatible) and `/v1/messages` (Anthropic-compatible) with a placeholder key.
4. Re-run with the same settings (in-place update; the API key must stay the same), then with `--web-api-key` and `--agent-api-key` in the four combinations, then with another `--quant` (offer to delete the old files), then `--uninstall` and a fresh install.
5. With the plamo-3-translate service installed on the same host: both web pages work, and each service uses its own GPU.

### Assumptions to confirm on the first run (taken from reading the Strata source)

If one of them is wrong, the installer most likely stops in `launch_model` or `smoke_test`; fix the installer and the README, not the symptom.

- `strata launch ... --no-tui` without a terminal: prints progress, asks nothing (stdin is `/dev/null`), returns 0 after a successful test start, and writes `<destdir>/.config/strata/profiles/launch-qwen-strata.json` and `<destdir>/.local/state/strata/launch/qwen-strata.json` (checked by `launch_model`).
- `--access local` together with `--api-key-env STRATA_API_KEY` keeps the key, and `STRATA_API_KEY` from the unit's `EnvironmentFile` is what `strata serve` enforces.
- `strata launch --stop --preset qwen-strata` frees the port within 200 seconds.
- `strata serve --profile launch-qwen-strata --host 127.0.0.1 --port 48080` runs under the unit as written: `runuser`/systemd with a `nologin` shell, `ProtectSystem=full`, `KillMode=mixed`, stop within `TimeoutStopSec=150`. Check `systemctl stop` and `restart` timings, and whether `LimitMEMLOCK`/`LimitRTTIME` warnings disappear from the logs. Sandboxing can be tightened only after this works.
- `strata --version` exists and succeeds (used to decide whether the Terminal is reused); the Terminal version in the release's `install-manifest.txt` is `0.1.59.1` (`QWENSTRATAINS_STRATA_TERMINAL_VERSION`).
- `/health` answers only when the model is loaded and contains `"loaded": true`, `"model": "..."` and `"max_context": N` (parsed with `sed` in `wait_health`).
- Through nginx: `GET /config` is 401 without the key and 200 with it; `GET /metrics` and `GET /v1/models` are 200 with the key; the chat test body (`model`, `messages`, `max_tokens: 32`) is accepted. A thinking model may return an empty `content` with 32 tokens, which is why only the HTTP status is checked.
- The web page really uses only `health`, `metrics`, `v1/chat/completions` (plus management paths) — watch the browser's network tab. With `--web-api-key` off, no "API key needed" pill or toast may appear during normal chatting; management requests (`config`, `settings`, `mcp`) are expected to fail quietly until the key is entered under About > Settings.
- With `--web-api-key` and `--agent-api-key` set differently, real browsers over plain HTTP send `Origin` on the chat POST so that the `map` in `nginx_site` recognises the page (Chrome, Firefox, Safari on a phone).
- Management POSTs from the page work once the key is entered (this depends on `proxy_set_header Host $http_host`).
- GPU numbering: the PCI address selected in the installer is the GPU that Strata loads (compare `nvidia-smi` memory use per GPU with the selection). AMD numbering (KFD node order) cannot be checked on the planned machines.
- Model folders are `<destdir>/.local/share/strata/Strata-data/models/<tag>` with the tags in `QWENSTRATAINS_QUANT` (used by `cleanup_old_models`), and shards shared between quantizations are hard links.
- The logrotate rule works with Strata's 0700 state directories (`su <user> <user>`): test with `logrotate -d /etc/logrotate.d/qwen-strata`.
- ufw rule handling and interface selection are ported unchanged from the plamo installer but untested here.

### Things to measure and report to the user

- Speed (tokens per second for output and for reading a prompt) with context 262144 and `UD-Q4_K_XL` on one RTX 3060, and how much a shorter `--ctx-size` gains.
- Which drafter `auto` selects (expected: DFlash2) and whether `mtp` is faster on the RTX 3060 (`sm_86` is marked "slower" for DFlash2 in Strata's code). The installer has no option for the drafter; if `mtp` is clearly faster, propose adding one.
- Whether `--tune quick` helps on the 64-core Threadripper (Strata's standard values were measured on a 6-core CPU).
- On the 9950X machine, `Q8_0` against `UD-Q6_K_XL`.

### Open points to raise with the user when relevant

- AMD GPUs remain untested, and the installer does not install `libdrm`/`libelf` packages that Strata's HIP engines may need on a minimal server.
- The local git identity (`user.name`, `user.email`) is not configured on the development machine, so a plain `git commit` fails. Never choose or guess an author identity (for example from an earlier commit): the user decides it. Ask before changing git configuration.
