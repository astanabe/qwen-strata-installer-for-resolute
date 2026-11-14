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
