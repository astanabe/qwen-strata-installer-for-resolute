# qwen-strata-installer-for-resolute

Qwen3.8-Flash-Next installer script for Ubuntu 26.04 LTS Resolute Raccoon (Server or Desktop), using the [Strata](https://github.com/Niko1221/Strata) inference engine

The installer sets up Strata 0.2.13 and Qwen3.8-Flash-Next as a systemd service behind nginx, for web browsers (PC and phone) and coding agents on an intranet. Downloading and configuring Strata, its engine and the model is left to Strata's own `install.sh` and `strata launch`; this installer adds the systemd unit, the nginx site, ufw rules, the selection of GPUs and network interfaces, the license confirmation and an uninstaller.

> **Status**: the installer has not been run on real hardware yet. Only a syntax check and tests of the parts that need neither root, a GPU nor the downloads have been done. See [Verification](#verification).

## Prerequisites

- Ubuntu 26.04 LTS (Resolute Raccoon), x86_64, Server or Desktop. Ubuntu on WSL is not supported (the installer detects it and stops).
  - On Desktop, the display also uses GPU memory, and the service stops while the machine is suspended.
- A CPU with AVX2
- Root privileges (`sudo`)
- Internet access to GitHub (Strata, llama.cpp source), Hugging Face (models) and the Ubuntu apt repositories
- An NVIDIA or AMD GPU that Strata supports. Strata has no CPU-only engine. 12 GB of GPU memory or more is recommended. Intel Arc is not supported by this installer.
- Enough disk space and memory for the selected quantization (see [Quantization](#quantization)); the installer checks them and warns if they look insufficient
- **GPU driver installed in advance**. The installer never installs GPU drivers. The CUDA and ROCm runtime libraries come with Strata's engine package.
  - NVIDIA: install the NVIDIA driver and reboot (e.g. `sudo ubuntu-drivers install`), so that `nvidia-smi` works. Driver 575.51 or later is required; the installer stops with an older driver. Strata uses its CUDA 13 engine with driver 580.65 or later and its CUDA 12 engine otherwise.
  - AMD: the in-kernel `amdgpu` driver must be loaded (`/dev/kfd` and `/dev/dri` exist). **AMD has not been tested on real hardware.**

## Usage

```
sudo bash install-qwen-strata.sh                            # interactive install
sudo bash install-qwen-strata.sh --accept-license \
    --destdir /opt/qwen-strata --quant UD-Q4_K_XL ...       # non-interactive install
sudo bash install-qwen-strata.sh --uninstall                # uninstall
```

- Run as root. The installer is a single file and needs nothing else from this repository.
- Every prompt has a corresponding command-line option and environment variable. Only values that are not given are asked. When standard input is not a terminal, the defaults are used without prompting.
- Values are taken in this order: command-line option, environment variable, the previous installation (`/etc/qwen-strata/install.conf`), default.
- Re-running the installer updates the existing installation in place: the systemd unit, the nginx site and the other generated files are overwritten; the Strata Terminal is reused when the pinned version is already installed; the engine and the model files already downloaded are checked and reused by Strata; the generated API key is kept. If the quantization changed, the installer offers to delete the model files of the other quantizations (only when run interactively).
- `--uninstall` stops and disables the service and removes the systemd unit, the nginx site configuration, the logrotate configuration, `/etc/qwen-strata`, the ufw rules added by the installer and destdir (with Strata and all downloaded files). apt packages, nginx itself and the service user are kept. Other services are not touched (see [Coexistence with other services](#coexistence-with-other-services)).

### Options

Asked interactively when not given:

| Option | Environment variable | Default |
|---|---|---|
| `--destdir DIR` | `QWENSTRATA_DESTDIR` | `/opt/qwen-strata` |
| `--user NAME` | `QWENSTRATA_USER` | `qwenstrata` |
| `--quant Q2_0\|IQ2_XS\|IQ3_XXS\|IQ3_S\|UD-IQ4_XS\|UD-Q4_K_XL\|UD-Q5_K_XL\|UD-Q6_K_XL\|Q8_0` | `QWENSTRATA_QUANT` | `UD-Q4_K_XL` |
| `--gpus PCI[,PCI...]\|all` | `QWENSTRATA_GPUS` | one GPU, chosen as described below (asked when two or more GPUs are usable) |
| `--ctx-size N` | `QWENSTRATA_CTX_SIZE` | `262144` (the model maximum; 1024 to 262144) |
| `--tune skip\|quick\|thorough` | `QWENSTRATA_TUNE` | `skip` |
| `--web-port PORT` | `QWENSTRATA_WEB_PORT` | `38080` |
| `--interfaces all\|IF[,IF...]` | `QWENSTRATA_INTERFACES` | `all` (asked when two or more interfaces have addresses) |
| `--web-api-key` / `--no-web-api-key` | `QWENSTRATA_WEB_API_KEY` (`yes`/`no`) | `no` |
| `--agent-api-key` / `--no-agent-api-key` | `QWENSTRATA_AGENT_API_KEY` (`yes`/`no`) | `no` |
| `--open-ports` / `--no-open-ports` | `QWENSTRATA_OPEN_PORTS` (`yes`/`no`) | ask when ufw is active |
| `--accept-license` | `QWENSTRATA_ACCEPT_LICENSE` (`yes`) | — |

Never asked (option or environment variable only):

| Option | Environment variable | Default |
|---|---|---|
| `--model 3.8-flash-next` | `QWENSTRATA_MODEL` | `3.8-flash-next` (the only model for now) |
| `--backend auto\|nvidia\|amd` | `QWENSTRATA_BACKEND` | `auto` |
| `--kv int8\|k8v4\|q4_0\|fp16` | `QWENSTRATA_KV` | `int8` |
| `--strata-port PORT` | `QWENSTRATA_STRATA_PORT` | `38081` |

Actions:

| Option | |
|---|---|
| `--yes` | answer yes to warnings, opening ufw ports and uninstalling |
| `--uninstall` | uninstall |
| `--help` | show the help |

GPU selection: the installer lists the GPUs that Strata can use, NVIDIA GPUs that answer to `nvidia-smi` and AMD GPUs known to the `amdgpu` driver (KFD), with their PCI addresses, total memory and memory in use, and asks which to use (numbers such as `1` or `1,2`, or `all`) when there are two or more. `--gpus` takes PCI addresses as shown by `lspci -D` (e.g. `0000:03:00.0`). The default is one GPU: NVIDIA before AMD, then the largest memory, then the most free memory, then the lowest PCI address. So when another service (e.g. the llama-server of plamo-3-translate-installer-for-resolute) already uses one of two identical GPUs, the free one is the default. One Strata engine drives the GPUs of one maker only, so NVIDIA and AMD GPUs cannot be selected together. `--backend nvidia|amd` limits the candidates to one maker; the backend passed to Strata follows from the selected GPUs. With `all`, all GPUs of one maker are used (NVIDIA if both are present and `--backend` is `auto`). With two or more GPUs, Strata assigns the roles (main, helper) itself; note that Strata's default drafter (DFlash2) needs a single GPU. The PCI addresses are converted to the numbers Strata takes (`nvidia-smi` index for NVIDIA, KFD GPU node order for AMD) at installation.

Context size: `--ctx-size` is passed to Strata as is. Strata does not reduce it automatically; when it does not fit, the start fails or is slow. The default is the model's trained length, 262144 tokens. On a 12 GB GPU a shorter context is faster, because the conversation memory (KV) takes GPU memory from the expert cache.

Tuning: `--tune quick` (about 20 minutes) or `--tune thorough` (up to 2 hours) lets Strata measure engine settings (CPU threads and others) on this machine during the installation and keep the faster ones. Results are stored by Strata and reused by later runs. The default `skip` uses Strata's standard values. A typical use is to install with `skip` first and to re-run with `--tune quick` later.

KV format: `--kv` selects the format of the conversation memory. `int8` is Strata's default and the format of almost all of its measurements. `k8v4` and `q4_0` are smaller, with some loss of accuracy on long contexts (`q4_0` more than `k8v4`); `fp16` is twice as large.

Network interfaces: when two or more network interfaces have global addresses (container/VM bridges such as `docker0`, `virbr0` and `lxdbr0` are ignored), the installer asks on which of them the web server accepts connections from other hosts (`all` or numbers). With selected interfaces, nginx listens on their current addresses plus `127.0.0.1` (and `::1`), and the ufw rules are limited to them (`ufw allow in on IF to any port PORT proto tcp`). The interface names are saved and the addresses are looked up at installation, so re-run the installer if an address changes. ufw rules added by an earlier run that are no longer wanted are removed.

API key: see [API key](#api-key).

### Files

```
<destdir>/                                  default /opt/qwen-strata; home directory of the service user
  .qwen-strata-installation                 marker checked by --uninstall
  .local/bin/strata                         link to the Strata Terminal
  .local/share/strata/terminal/<version>/   Strata Terminal (CLI with its own Python)
  .local/share/strata/components/           engine for the GPU, update state
  .local/share/strata/install/              run configurations written by Strata's setup
  .local/share/strata/Strata-data/          models/, packs/, mtp/, dflash2/
  .config/strata/                           settings, profile launch-qwen-strata, preset qwen-strata, tuning results
  .local/state/strata/launch/               run configuration and engine log qwen-strata.engine.log
/etc/qwen-strata/
  install.conf                              settings of the installation
  strata.env                                API key (STRATA_API_KEY; root and the service user only)
  nginx-key.conf                            the same key for nginx (root only)
/etc/systemd/system/qwen-strata.service     strata serve (127.0.0.1:38081)
/etc/nginx/sites-available/qwen-strata      (linked from sites-enabled)
/etc/logrotate.d/qwen-strata                rotation of the engine log
```

Strata's `install.sh` is downloaded from the pinned release and verified with a SHA-256 checksum built into the installer. Everything else is downloaded and verified by Strata: the Terminal by `install.sh` (checksum from the release and the signed feed), the engine by `strata launch` from the same signed feed, the model files from pinned Hugging Face revisions with fixed SHA-256 checksums.

## Models

- Qwen3.8-Flash-Next
  - https://huggingface.co/Qwen/Qwen3.8-Flash-Next
  - Quantized by ISTA-DASLab: https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF
  - Quantized by Unsloth: https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF
- DFlash2 drafter for Qwen3.8-Flash-Next (fetched by Strata when it selects this drafter)
  - https://huggingface.co/incoai/Qwen3.8-Flash-Next-DFlash2

Support for newer Qwen models is planned when Qwen releases them and Strata supports them.

## License

### License of this repository

The files in this repository (the installer and the documentation) are distributed under the MIT License. See [LICENSE](LICENSE).

### License of Qwen3.8-Flash-Next

The model files downloaded through the installer are not part of this repository. Qwen3.8-Flash-Next is distributed by Qwen under the Qwen Community License 1.0, not under the MIT License.

- https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/LICENSE

In short: use, modification and redistribution are permitted, including commercial use, with the copyright and permission notice kept. A licensee (or an affiliate) that conducts a "Model as a Service" or "AI Work Assistant" business must obtain a separate license from Qwen before any commercial use; internal use that does not make the model, its outputs or its capabilities available to third parties is exempt. Products or services with more than 100 million monthly active users or US$ 20 million of monthly revenue must display the model name prominently. Read the full license text before using the model. The installer shows this summary for every quantization and aborts unless the user types `yes`. In non-interactive mode, `--accept-license` is required.

- The Unsloth files are published under the same Qwen Community License 1.0.
- The ISTA-DASLab repository is labelled Apache-2.0 on Hugging Face, but the files are quantizations of Qwen3.8-Flash-Next, so the installer asks for the acceptance of the Qwen Community License for them too.
- The DFlash2 drafter (incoai) is distributed under the Apache License 2.0.
- Strata itself is distributed under the MIT License.

## Engine

- Strata 0.2.13 (Terminal/Control 0.1.59.1, engine 0.1.59)
  - https://github.com/Niko1221/Strata/releases/tag/v0.2.13
- The version is pinned: the installer points Strata's `install.sh` (`STRATA_FEED`), `strata launch --feed` and the service (`STRATA_UPDATE_FEED`) to the release folder of v0.2.13 and disables Strata's update check and hand-over to a newer Control (`STRATA_UPDATE_CHECK=0`, `STRATA_NO_HANDOVER=1`, `STRATA_FEED_MODELS=0`). Updating Strata means updating this installer and re-running it.
- Engine package: chosen by Strata from the GPU and its driver (CUDA 13 or CUDA 12 for NVIDIA; `rx9070`, `rx7900`, `rx6000` or `halo` HIP builds for AMD).
- `strata` is always run as the service user, with destdir as its home directory.
- Strata's defaults are kept for the number of parallel requests (fit to the GPU; 1 for 12 GB), the drafter (`auto`) and picture reading (on).
  - With `auto`, Strata is expected to select the DFlash2 drafter for these models. For the RTX 30 series (`sm_86`) Strata's own code classifies DFlash2 as "slower than MTP on this generation", but `auto` does not take that into account.
- The first installation loads the model twice: once by `strata launch`, which starts the model to check it and is stopped again by the installer, and once by the systemd service. With a large quantization each load takes minutes.

## Quantization

Selected with `--quant`. The installer derives Strata's `--family` and `--model` from the name.

| `--quant` | Provider | Strata family | Download | RAM for all experts | Same top token as Q8_0 |
|---|---|---|---:|---:|---:|
| `Q2_0` | ISTA-DASLab | `qwen` | 66.4 GB | about 44 GB | 80.6% |
| `IQ2_XS` | ISTA-DASLab | `qwen` | 68.0 GB | about 46 GB | not measured |
| `IQ3_XXS` | ISTA-DASLab | `qwen` | 75.8 GB | about 53 GB | 84.5% |
| `IQ3_S` | ISTA-DASLab | `qwen` | 83.6 GB | about 60 GB | 87.7% |
| `UD-IQ4_XS` | Unsloth | `unsloth` | 93.7 GB | about 72 GB | 88.9% |
| `UD-Q4_K_XL` (default) | Unsloth | `unsloth` | 111.3 GB | about 88 GB | 93.1% |
| `UD-Q5_K_XL` | Unsloth | `unsloth` | 158.3 GB | about 108 GB | 94.6% |
| `UD-Q6_K_XL` | Unsloth | `unsloth` | 169.2 GB | about 118 GB | 94.6% |
| `Q8_0` | Unsloth | `unsloth` | 188.2 GB | about 136 GB | 100% (the reference) |

- The figures are from the Strata 0.2.13 documentation (`docs/MODELS.md`, `docs/QUANTS.md`).
- Download: the model files only. Strata also fetches the draft layer (about 5 to 6 GB to download), the DFlash2 drafter (up to 1.2 GB), the picture reader (0.9 GB) and the engine. The installer checks for the download size plus about 10 GB of free disk space.
- RAM for all experts: the RAM that holds every expert, so that none is read from the SSD (ISTA-DASLab: the experts plus about 10 GB; Unsloth: the experts plus 16 GiB). With less RAM, Strata keeps as many experts as fit and reads the rest from the SSD, which is much slower. The installer says so when the machine has less. It warns and asks whether to continue when the machine has less than the RAM Strata itself requires for the model (48 GB for `Q2_0`, `IQ2_XS`, `UD-IQ4_XS` and `UD-Q4_K_XL`, 60 GB for `IQ3_XXS`, 62 GB for `IQ3_S`, and the figure in the table for the larger ones).
- Same top token as Q8_0: how often the most likely next token is the same as with Q8_0, measured by the Strata project on about 5,000 token positions on one machine.

## Architecture

```
web browser / coding agent
  → nginx (TCP 38080, on the selected network interfaces)
    → strata serve (127.0.0.1:38081; systemd unit qwen-strata.service, service user)
      → Strata engine (child process of strata serve; GPU)
```

- Strata's server provides the web chat page (`/`), the OpenAI-compatible API (`/v1/chat/completions`, `/v1/responses`, `/v1/models`) and the Anthropic-compatible API (`/v1/messages`, `/v1/messages/count_tokens`) on one port. There is no `/v1/completions` and no embeddings endpoint.
- nginx (`nginx-full` from apt) is the only part reachable from other hosts. The site `qwen-strata` does not use `default_server`, so it can live beside other sites (e.g. plamo-3-translate-installer-for-resolute on TCP 18080 and 28080, glm-maya-installer-for-resolute on TCP 48080, deepseek-maya-installer-for-resolute on TCP 58080). Responses are not buffered (streaming), the timeouts are 3660 seconds and request bodies may be up to 256 MiB (pictures are sent inline).
- The service runs as the user given at installation (default `qwenstrata`). If the user does not exist, it is created as a system user without login and with destdir as its home directory. An existing user is used only if its home directory is destdir.
- systemd unit: `Type=simple`, `strata serve --profile launch-qwen-strata --host 127.0.0.1 --port 38081`, `LimitMEMLOCK=infinity` (the engine pins the model in RAM), `LimitRTTIME=infinity`, `TimeoutStartSec=infinity`, `TimeoutStopSec=150`, `Restart=on-failure`, supplementary groups `video` and `render`, `After=plamo-3-translate-llama.service plamo-3-translate-uwsgi.service` and `Conflicts=deepseek-maya.service glm-maya.service` (see [Coexistence with other services](#coexistence-with-other-services)). Sandboxing is light (`NoNewPrivileges`, `ProtectSystem=full`) until the service has been tested on real hardware.
- Logs: `journalctl -u qwen-strata` (server) and `<destdir>/.local/state/strata/launch/qwen-strata.engine.log` (engine; rotated weekly by logrotate with `copytruncate`).
- A model started by `strata serve` under systemd is not listed by `strata launch --status`; use `systemctl status qwen-strata`.
- TLS is out of scope.

### Coexistence with other services

The installer is meant to share one host with the services of three other installers. Their ports, nginx sites, service users and directories do not overlap. Nothing below has an effect when the other service is not installed.

- **[deepseek-maya-installer-for-resolute](https://github.com/astanabe/deepseek-maya-installer-for-resolute)** (`deepseek-maya.service`, TCP 58080 and 58081) and **[glm-maya-installer-for-resolute](https://github.com/astanabe/glm-maya-installer-for-resolute)** (`glm-maya.service`, TCP 48080 and 48081): all three can be installed on one host, but only one of them runs at a time, because each needs a GPU and most of the RAM.
  - The unit declares `Conflicts=deepseek-maya.service glm-maya.service` and the units of the other two installers name `qwen-strata.service` in the same way, so starting one stops the one that is running.
  - If `deepseek-maya.service` or `glm-maya.service` is running or enabled, the installer stops and disables it before `strata launch` (the summary shown before the installation says so). `strata launch` is not a unit start, so `Conflicts=` alone would leave the other service holding its GPU and RAM at that point. The service installed or re-installed last is therefore the one that runs and that starts at boot.
  - Switch by hand with `sudo systemctl disable --now deepseek-maya glm-maya && sudo systemctl enable --now qwen-strata`, or likewise for one of the others. Keep only one of the three enabled: with more than one enabled, systemd starts only one of them at boot, and which one is not defined.
  - `--uninstall` does not enable `deepseek-maya.service` or `glm-maya.service` again; it prints the commands to do so.
  - While `deepseek-maya` or `glm-maya` is running, its GPU counts as in use for the default GPU selection, so on a first installation give `--gpus` (or answer the question) if they are meant to use the same GPU.
- **[plamo-3-translate-installer-for-resolute](https://github.com/astanabe/plamo-3-translate-installer-for-resolute)** (`plamo-3-translate-llama.service`, `plamo-3-translate-uwsgi.service`, TCP 18080 and 28080): can run at the same time, on another GPU. Because Strata's engine pins the model in the RAM that is free when it starts, the unit is ordered after the two plamo services.
  - `plamo-3-translate-llama.service` counts as started only when its model is loaded (it waits for the `/health` of its llama-server), so at boot Strata starts after llama-server has taken its memory.
  - The same wait applies to `systemctl start qwen-strata` or `restart`, and to the start at the end of this installer, while `plamo-3-translate-llama.service` is still loading its model: the command returns when Strata has been started after that. There is no time limit on the plamo side.
  - If llama-server exits while it loads its model, `qwen-strata` is started when that first attempt has failed; it does not wait for the retries.
  - Restarting the plamo services while Strata runs leaves them only the RAM Strata left free; restart `qwen-strata` afterwards in that case.

### API key

Strata has a single API key that is either required for everything except the web page itself and `/health`, or not set at all. The installer always sets a key in Strata (generated at the first installation, kept afterwards) and lets nginx add it to the requests that are meant to work without one. The key is never written into the nginx site file; nginx reads it from `/etc/qwen-strata/nginx-key.conf`.

| Path | Default | Key required with |
|---|---|---|
| `/`, `/web/`, `/fonts/`, `/health` | passed on as is (Strata needs no key for them) | — |
| `/metrics` (read every second by the web page) | nginx adds the key | `--web-api-key` |
| `/v1/chat/completions` (used by the web page and by agents) | nginx adds the key | `--web-api-key` for the web page, `--agent-api-key` for other clients |
| `/v1/messages`, `/v1/messages/count_tokens`, `/v1/responses`, `/v1/models`, `/models`, `/v1/v1/messages`, `/v1/v1/messages/count_tokens` | nginx adds the key | `--agent-api-key` |
| everything else: management (`/config`, `/settings`, `/load`, `/unload`, `/v1/load`, `/v1/unload`, `/v1/vram`, `/slots`, `/mcp`, `/status`, `/v1/status`, `/props`, ...) | passed on as is: **the key is always required** | — |

- Where nginx adds the key, it replaces the client's `Authorization` header and removes `x-api-key`, so that the placeholder key that SDKs and agents insist on sending does not cause a 401. With the defaults, coding agents can be configured with any non-empty string as the API key.
- With `--web-api-key`, enter the key in the web page under About > Settings. The same is needed to use the management functions of the page (settings card, load/unload); without the key they are hidden or fail, while chatting works.
- `/v1/chat/completions` is shared by the web page and the agents. When `--web-api-key` and `--agent-api-key` differ, nginx decides whether a request comes from the web page by the headers browsers add: `Sec-Fetch-Site: same-origin`, or, where the browser does not send `Sec-Fetch-Site` (browsers send it only to HTTPS and localhost origins, and this site is plain HTTP), an `Origin` header that equals the `Host` header. **Other clients can forge these headers**, so requiring the key on one side only guards against mistakes, not against users who want to get around it. Require it on both sides when that matters.
- Anyone who holds the key can change some of Strata's settings, unload the model and, because picture reading is on, make the server read pictures from local files or URLs readable by the service user.
- Show the key: `sudo sed -n 's/^STRATA_API_KEY=//p' /etc/qwen-strata/strata.env`

## Client

- Web browser (PC and phone): `http://<server>:38080/`
- Coding agent, OpenAI-compatible: base URL `http://<server>:38080/v1`
- Coding agent, Anthropic-compatible: base URL `http://<server>:38080`

The model name is reported by `/v1/models`. Strata can print the settings for several coding agents (OpenCode, Codex CLI, Claude Code and others): `sudo -u qwenstrata -H /opt/qwen-strata/.local/bin/strata connect <agent> --url http://<server>:38080`. Agents usually need to be told the context size; see Strata's `docs/TERMINAL_LAUNCH.md`.

## Procedure

1. Ask the user for destdir (default `/opt/qwen-strata`), user name (default `qwenstrata`), quantization (default `UD-Q4_K_XL`), GPUs (only if two or more are usable), context size (default 262144), tuning (default `skip`), web server port (default 38080), network interfaces to listen on (only if two or more have addresses), whether the web page and the agents need the API key (default no for both), whether to open the port in ufw (only if ufw is active and the port is not allowed yet), and license acceptance; show a summary
2. Check prerequisites: the ports are not in use, destdir is empty or a previous installation, the service user's home directory, free disk space and memory (warn and ask to continue if insufficient), GPU driver
3. Install missing dependencies via apt: `nginx-full curl ca-certificates tar pciutils libgomp1 libatomic1 libnuma1 zlib1g`
4. Create the service user if needed and prepare destdir
5. Stop the existing service (`strata launch` fails unless the port and the GPU are free); stop and disable `deepseek-maya.service` and `glm-maya.service` if they are running or enabled
6. Download Strata's `install.sh` from the pinned release, verify it and run it as the service user (skipped when the pinned Terminal is already installed)
7. Generate the API key, or reuse the existing one
8. Run `strata launch` once as the service user to download the engine and the model, write the configuration, tune (if selected) and test-start the model; then stop it with `strata launch --stop`
9. Write the systemd unit, the nginx site and the logrotate configuration, test the nginx configuration (on failure the site is disabled again so that other sites are not affected), enable and start the service
10. Configure ufw as answered in step 1 (if ufw became active after step 1, ask here) and save `install.conf`
11. Test: wait until `/health` of Strata answers 200 with the model loaded (up to 30 minutes), then check through nginx that `/health` works, that the management path `/config` is refused without the key and accepted with it, that the key requirement of `/metrics` and `/v1/models` matches the settings, and that a short chat completion is answered

## Known limitations

- Not yet run on real hardware (see below). AMD GPUs are untested even after that.
- Intel Arc and WSL are not supported.
- Requiring the API key for only one of the web page and the agents depends on request headers and can be circumvented on purpose.
- With the default settings anyone on the networks the web server listens on can use the model without a key; only the management paths are protected.
- The first installation loads the model twice.
- Does not run at the same time as the services of deepseek-maya-installer-for-resolute and glm-maya-installer-for-resolute; installing one of the three stops and disables the other two.
- TLS is out of scope.

## Verification

Done so far, without the target hardware: `bash -n`; the option parsing, value precedence, validation and prompts with stubbed GPU and network detection; the generated systemd unit (with `systemd-analyze verify`), logrotate configuration and `install.conf`; the handling of `deepseek-maya.service` and `glm-maya.service` with a stand-in for `systemctl`; that the start of a unit waits for a unit it is ordered after while that one is still starting (with stand-in units); and the generated nginx configuration with `nginx -t` and a dummy upstream (which requests get the key for the four combinations of `--web-api-key` and `--agent-api-key`). `shellcheck` (0.11.0) reports nothing.

To be done on real hardware (planned machine: Ryzen Threadripper PRO 3995WX, 512 GB RAM, 2 x GeForce RTX 3060 12 GB, one of them for Strata):

- A complete installation, a re-run, and `--uninstall`
- `systemctl status qwen-strata` and `curl http://127.0.0.1:38080/health`
- Through nginx: a reply in the web chat, replies from `/v1/chat/completions` and `/v1/messages`, 401 for `/config` without the key and 200 with it
  ```
  KEY=$(sudo sed -n 's/^STRATA_API_KEY=//p' /etc/qwen-strata/strata.env)
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:38080/config                                  # 401
  curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $KEY" http://127.0.0.1:38080/config  # 200
  ```
- Start-up and speed with context 262144 and `UD-Q4_K_XL`, the drafter Strata actually selects, and that the selected PCI address is the GPU Strata uses
- Both services working side by side with plamo-3-translate-installer-for-resolute, each on its own GPU, and after a reboot Strata started only when the llama-server of plamo-3-translate has loaded its model
- With deepseek-maya-installer-for-resolute and glm-maya-installer-for-resolute installed: installing any one of the three stops and disables the other two, `systemctl start` of one stops the one that is running, and only the enabled one starts at boot
