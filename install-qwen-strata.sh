#!/bin/bash
# Qwen3.8-Flash-Next + Strata installer for Ubuntu 26.04 LTS (Resolute Raccoon), x86_64, Server or Desktop.
#
#   bash install-qwen-strata.sh [options]     install or update in place
#   bash install-qwen-strata.sh --uninstall   uninstall
#
# Strata itself, its engine and the model are downloaded and configured by Strata's own
# install.sh and "strata launch".  This installer adds the systemd unit, the nginx site,
# ufw rules, GPU and network interface selection, the license confirmation and uninstall.
#
# See README.md or --help for the options.

set -euo pipefail
umask 022

readonly QWENSTRATAINS_APP_NAME="qwen-strata"
readonly QWENSTRATAINS_CONF_DIR="/etc/$QWENSTRATAINS_APP_NAME"
readonly QWENSTRATAINS_CONF_FILE="$QWENSTRATAINS_CONF_DIR/install.conf"
readonly QWENSTRATAINS_ENV_FILE="$QWENSTRATAINS_CONF_DIR/strata.env"
readonly QWENSTRATAINS_NGINX_KEY_FILE="$QWENSTRATAINS_CONF_DIR/nginx-key.conf"
readonly QWENSTRATAINS_UNIT="$QWENSTRATAINS_APP_NAME.service"
readonly QWENSTRATAINS_UNIT_DIR="/etc/systemd/system"
readonly QWENSTRATAINS_NGINX_SITE="/etc/nginx/sites-available/$QWENSTRATAINS_APP_NAME"
readonly QWENSTRATAINS_NGINX_LINK="/etc/nginx/sites-enabled/$QWENSTRATAINS_APP_NAME"
readonly QWENSTRATAINS_LOGROTATE_FILE="/etc/logrotate.d/$QWENSTRATAINS_APP_NAME"
readonly QWENSTRATAINS_MARKER=".$QWENSTRATAINS_APP_NAME-installation"
readonly QWENSTRATAINS_LICENSE_URL="https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/LICENSE"

# Strata release (pinned).  The release folder is used as install.sh's STRATA_FEED, as
# "strata launch --feed" and as STRATA_UPDATE_FEED of every strata process.
readonly QWENSTRATAINS_STRATA_VERSION="0.2.13"
readonly QWENSTRATAINS_STRATA_FEED="https://github.com/Niko1221/Strata/releases/download/v$QWENSTRATAINS_STRATA_VERSION"
readonly QWENSTRATAINS_STRATA_INSTALL_SHA256="d47754af1f74c95bf763e0b8d484232443466decd1a22d0be3208760a2f53822"
# Version of the Terminal (Control) in that release's install-manifest.txt; only used to
# skip install.sh when it is already installed.
readonly QWENSTRATAINS_STRATA_TERMINAL_VERSION="0.1.59.1"
# NVIDIA driver floors of the CUDA 12 and CUDA 13 engine packages of that release.
readonly QWENSTRATAINS_NVIDIA_MIN_DRIVER="575.51"
readonly QWENSTRATAINS_NVIDIA_CUDA13_DRIVER="580.65"
# Name of the "strata launch" preset; Strata derives the profile "launch-<preset>" from it.
readonly QWENSTRATAINS_PRESET="qwen-strata"
readonly QWENSTRATAINS_PROFILE="launch-$QWENSTRATAINS_PRESET"
# The units of deepseek-maya-installer-for-resolute and glm-maya-installer-for-resolute:
# never run together with this service.
readonly QWENSTRATAINS_EXCLUSIVE_UNITS="deepseek-maya.service glm-maya.service"
# The units of plamo-3-translate-installer-for-resolute: this service is started after them.
readonly QWENSTRATAINS_PLAMO_UNITS="plamo-3-translate-llama.service plamo-3-translate-uwsgi.service"

readonly QWENSTRATAINS_BASE_PACKAGES="nginx-full curl ca-certificates tar pciutils libgomp1 libatomic1 libnuma1 zlib1g"

readonly QWENSTRATAINS_MODELS="3.8-flash-next"
# Quantizations: "<Strata family> <Strata model> <provider> <download, 0.1 GB> <RAM for all
# experts, GiB> <RAM Strata requires (ram_gb), GiB> <Strata tag = folder under models/>".
# Figures from Strata 0.2.13 (setup.py MODELS, docs/MODELS.md, docs/QUANTS.md).
declare -A QWENSTRATAINS_QUANT=(
  [Q2_0]="qwen Q2_0 ISTA-DASLab 664 44 48 Q2_0"
  [IQ2_XS]="qwen IQ2_XS ISTA-DASLab 680 46 48 IQ2_XS"
  [IQ3_XXS]="qwen IQ3_XXS ISTA-DASLab 758 53 60 IQ3_XXS"
  [IQ3_S]="qwen IQ3_S ISTA-DASLab 836 60 62 IQ3_S"
  [UD-IQ4_XS]="unsloth UD-IQ4_XS Unsloth 937 72 48 unsloth-UD-IQ4_XS"
  [UD-Q4_K_XL]="unsloth UD-Q4_K_XL Unsloth 1113 88 48 unsloth-UD-Q4_K_XL"
  [UD-Q5_K_XL]="unsloth UD-Q5_K_XL Unsloth 1583 108 108 unsloth-UD-Q5_K_XL"
  [UD-Q6_K_XL]="unsloth UD-Q6_K_XL Unsloth 1692 118 118 unsloth-UD-Q6_K_XL"
  [Q8_0]="unsloth Q8_0 Unsloth 1882 136 136 unsloth-Q8_0"
)
readonly QWENSTRATAINS_QUANTS="Q2_0 IQ2_XS IQ3_XXS IQ3_S UD-IQ4_XS UD-Q4_K_XL UD-Q5_K_XL UD-Q6_K_XL Q8_0"
# Disk space needed besides the model files: draft layer, drafter, picture reader, engine,
# Terminal, llama.cpp source (bytes).
readonly QWENSTRATAINS_EXTRA_DISK=$((10 * 1000 * 1000 * 1000))
# Trained context length of Qwen3.8-Flash-Next; Strata accepts 1024 or more.
readonly QWENSTRATAINS_MAX_CTX=262144
readonly QWENSTRATAINS_MIN_CTX=1024
readonly QWENSTRATAINS_BACKENDS="auto nvidia amd"
readonly QWENSTRATAINS_KV_MODES="int8 k8v4 q4_0 fp16"
readonly QWENSTRATAINS_TUNE_MODES="skip quick thorough"
# Seconds to wait for the service to load the model.
readonly QWENSTRATAINS_HEALTH_TIMEOUT=1800

# Settings: KEY -> default.  Values come from options > environment > install.conf > default.
# GPUS: empty = choose one GPU automatically (see gpu_default).
readonly QWENSTRATAINS_KEYS="DESTDIR USER MODEL QUANT BACKEND GPUS CTX_SIZE KV TUNE WEB_PORT STRATA_PORT INTERFACES WEB_API_KEY AGENT_API_KEY"
declare -A QWENSTRATAINS_DEFAULT=(
  [DESTDIR]=/opt/qwen-strata [USER]=qwenstrata [MODEL]=3.8-flash-next [QUANT]=UD-Q4_K_XL [BACKEND]=auto
  [GPUS]="" [CTX_SIZE]=262144 [KV]=int8 [TUNE]=skip [WEB_PORT]=38080 [STRATA_PORT]=38081 [INTERFACES]=all
  [WEB_API_KEY]=no [AGENT_API_KEY]=no
)
declare -A QWENSTRATAINS_ARG=() QWENSTRATAINS_VAL=() QWENSTRATAINS_SAVED=() QWENSTRATAINS_FROM_USER=()
QWENSTRATAINS_ACTION=install
QWENSTRATAINS_ASSUME_YES=no
QWENSTRATAINS_ACCEPT_LICENSE=no
QWENSTRATAINS_OPEN_PORTS=""   # yes/no: open the port in ufw; empty: ask when ufw is active
QWENSTRATAINS_INTERACTIVE=no
[[ -t 0 ]] && QWENSTRATAINS_INTERACTIVE=yes
QWENSTRATAINS_UFW_RULES=""    # ufw rules added by the installer: PORT (any interface) or PORT@INTERFACE
QWENSTRATAINS_GPU_VENDOR=""   # nvidia or amd: maker of the selected GPUs (set by validate_gpus)
QWENSTRATAINS_API_KEY=""
QWENSTRATAINS_TMP=""
QWENSTRATAINS_MODEL_ID=""
QWENSTRATAINS_N_CTX=""

# ---------------------------------------------------------------- utilities

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: bash $(basename "$0") [options]

Installs Qwen3.8-Flash-Next with the Strata $QWENSTRATAINS_STRATA_VERSION inference engine as a
systemd service behind nginx (web chat page and OpenAI/Anthropic-compatible API).
Values that are not given are asked interactively; when standard input is
not a terminal, defaults are used.  Re-running updates the installation.

Options asked interactively when not given (environment variable in brackets):
  --destdir DIR            install directory and home of the service user
                           [QWENSTRATA_DESTDIR] (default ${QWENSTRATAINS_DEFAULT[DESTDIR]})
  --user NAME              service user [QWENSTRATA_USER] (default ${QWENSTRATAINS_DEFAULT[USER]})
  --quant TYPE             Q2_0, IQ2_XS, IQ3_XXS, IQ3_S (ISTA-DASLab), UD-IQ4_XS,
                           UD-Q4_K_XL, UD-Q5_K_XL, UD-Q6_K_XL or Q8_0 (Unsloth)
                           [QWENSTRATA_QUANT] (default ${QWENSTRATAINS_DEFAULT[QUANT]})
  --gpus PCI[,PCI...]|all  GPUs used by Strata, by PCI address such as 0000:03:00.0
                           [QWENSTRATA_GPUS] (default: one GPU, NVIDIA first, then the
                           largest memory, then the most free memory; asked when two
                           or more GPUs are usable)
  --ctx-size N             context size in tokens, $QWENSTRATAINS_MIN_CTX-$QWENSTRATAINS_MAX_CTX [QWENSTRATA_CTX_SIZE]
                           (default ${QWENSTRATAINS_DEFAULT[CTX_SIZE]}, the model maximum)
  --tune skip|quick|thorough
                           let Strata measure engine settings on this machine: quick
                           takes about 20 minutes, thorough up to 2 hours
                           [QWENSTRATA_TUNE] (default ${QWENSTRATAINS_DEFAULT[TUNE]})
  --web-port PORT          web server (nginx) port [QWENSTRATA_WEB_PORT] (default ${QWENSTRATAINS_DEFAULT[WEB_PORT]})
  --interfaces all|IF[,IF...]
                           network interfaces on which the web server accepts
                           connections from other hosts [QWENSTRATA_INTERFACES] (default
                           all; asked when two or more interfaces have addresses);
                           127.0.0.1 always works
  --web-api-key            require the API key for the web chat page
  --no-web-api-key         do not require it (default) [QWENSTRATA_WEB_API_KEY=yes|no]
  --agent-api-key          require the API key for the API used by coding agents
  --no-agent-api-key       do not require it (default) [QWENSTRATA_AGENT_API_KEY=yes|no]
                           The management paths always require the API key.
  --open-ports             open the web server port in ufw when ufw is active
  --no-open-ports          do not open ports in ufw [QWENSTRATA_OPEN_PORTS=yes|no]
                           (default: ask when ufw is active)
  --accept-license         accept the Qwen Community License 1.0
                           [QWENSTRATA_ACCEPT_LICENSE=yes]

Options that are never asked:
  --model NAME             model [QWENSTRATA_MODEL] (default and only choice: ${QWENSTRATAINS_DEFAULT[MODEL]})
  --backend auto|nvidia|amd
                           limit the GPU candidates to one maker [QWENSTRATA_BACKEND]
                           (default ${QWENSTRATAINS_DEFAULT[BACKEND]})
  --kv int8|k8v4|q4_0|fp16 conversation memory (KV) format [QWENSTRATA_KV] (default ${QWENSTRATAINS_DEFAULT[KV]})
  --strata-port PORT       port of Strata on 127.0.0.1 [QWENSTRATA_STRATA_PORT] (default ${QWENSTRATAINS_DEFAULT[STRATA_PORT]})

Actions:
  --yes                    answer yes to warnings, opening ufw ports and uninstalling
  --uninstall              uninstall
  -h, --help               show this help
EOF
}

yesno() {  # normalize yes/no; prints "yes", "no" or nothing
  case "${1,,}" in
    y|yes|true|1|on) echo yes ;;
    n|no|false|0|off) echo no ;;
  esac
}

trim() {  # print $1 without leading and trailing whitespace
  local QWENSTRATAINS_s=$1
  QWENSTRATAINS_s="${QWENSTRATAINS_s#"${QWENSTRATAINS_s%%[![:space:]]*}"}"
  QWENSTRATAINS_s="${QWENSTRATAINS_s%"${QWENSTRATAINS_s##*[![:space:]]}"}"
  printf '%s' "$QWENSTRATAINS_s"
}

# ask_yn "question" y|n -> returns 0 for yes.  Invalid input is asked again.
ask_yn() {
  local QWENSTRATAINS_answer QWENSTRATAINS_hint="[y/N]"
  [[ $2 != y ]] || QWENSTRATAINS_hint="[Y/n]"
  while :; do
    read -r -p "$1 $QWENSTRATAINS_hint " QWENSTRATAINS_answer || die "no input"
    QWENSTRATAINS_answer=$(trim "$QWENSTRATAINS_answer")
    [[ -n $QWENSTRATAINS_answer ]] || QWENSTRATAINS_answer=$2
    case $(yesno "$QWENSTRATAINS_answer") in
      yes) return 0 ;;
      no) return 1 ;;
    esac
    warn "answer yes or no"
  done
}

# confirm "question" -> returns 0 for yes.  --yes answers yes; non-interactive answers no.
confirm() {
  [[ $QWENSTRATAINS_ASSUME_YES == yes ]] && return 0
  [[ $QWENSTRATAINS_INTERACTIVE == yes ]] || return 1
  ask_yn "$1" n
}

# Warn about a problem and ask whether to continue.
warn_continue() {
  warn "$1"
  confirm "Continue anyway?" || die "aborted (use --yes to continue despite warnings)"
}

ask() {  # ask KEY "prompt" [extra help]: sets VAL[KEY] unless given by option/env
  local QWENSTRATAINS_key=$1 QWENSTRATAINS_prompt=$2 QWENSTRATAINS_answer
  [[ -n ${QWENSTRATAINS_FROM_USER[$QWENSTRATAINS_key]:-} || $QWENSTRATAINS_INTERACTIVE != yes ]] && return 0
  [[ -n ${3:-} ]] && printf '%s\n' "$3"
  read -r -p "$QWENSTRATAINS_prompt [${QWENSTRATAINS_VAL[$QWENSTRATAINS_key]}]: " QWENSTRATAINS_answer || die "no input"
  QWENSTRATAINS_answer=$(trim "$QWENSTRATAINS_answer")
  [[ -n $QWENSTRATAINS_answer ]] && QWENSTRATAINS_VAL[$QWENSTRATAINS_key]=$QWENSTRATAINS_answer
  return 0
}

ask_bool() {  # ask_bool KEY "question": sets VAL[KEY] to yes/no unless given by option/env
  local QWENSTRATAINS_key=$1 QWENSTRATAINS_default=n
  [[ -n ${QWENSTRATAINS_FROM_USER[$QWENSTRATAINS_key]:-} || $QWENSTRATAINS_INTERACTIVE != yes ]] && return 0
  [[ ${QWENSTRATAINS_VAL[$QWENSTRATAINS_key]} != yes ]] || QWENSTRATAINS_default=y
  if ask_yn "$2" "$QWENSTRATAINS_default"; then
    QWENSTRATAINS_VAL[$QWENSTRATAINS_key]=yes
  else
    QWENSTRATAINS_VAL[$QWENSTRATAINS_key]=no
  fi
}

human() { numfmt --to=iec --suffix=B "$1"; }

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

service_exists() { [[ -f $QWENSTRATAINS_UNIT_DIR/$1 ]]; }

# version_ge A B: is version A >= B (dotted numbers)?
version_ge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$2" ]]; }

# quant_field N: field N (1 family, 2 model, 3 provider, 4 download in 0.1 GB, 5 RAM for all
# experts, 6 RAM Strata requires, 7 tag) of the selected quantization.
quant_field() {
  local QWENSTRATAINS_fields
  read -r -a QWENSTRATAINS_fields <<<"${QWENSTRATAINS_QUANT[${QWENSTRATAINS_VAL[QUANT]}]}"
  echo "${QWENSTRATAINS_fields[$(($1 - 1))]}"
}

cleanup_tmp() {
  [[ -z $QWENSTRATAINS_TMP ]] || rm -rf "$QWENSTRATAINS_TMP"
}

# ------------------------------------------------------------------ options

parse_args() {
  local QWENSTRATAINS_opt QWENSTRATAINS_key
  while (($#)); do
    QWENSTRATAINS_opt=$1
    case $QWENSTRATAINS_opt in
      --destdir|--user|--model|--quant|--backend|--gpus|--ctx-size|--kv|--tune|--web-port|--strata-port|--interfaces)
        (($# >= 2)) || die "$QWENSTRATAINS_opt requires a value"
        QWENSTRATAINS_key=${QWENSTRATAINS_opt#--}; QWENSTRATAINS_key=${QWENSTRATAINS_key//-/_}; QWENSTRATAINS_key=${QWENSTRATAINS_key^^}
        QWENSTRATAINS_ARG[$QWENSTRATAINS_key]=$2; shift 2 ;;
      --destdir=*|--user=*|--model=*|--quant=*|--backend=*|--gpus=*|--ctx-size=*|--kv=*|--tune=*|--web-port=*|--strata-port=*|--interfaces=*)
        QWENSTRATAINS_key=${QWENSTRATAINS_opt%%=*}; QWENSTRATAINS_key=${QWENSTRATAINS_key#--}; QWENSTRATAINS_key=${QWENSTRATAINS_key//-/_}; QWENSTRATAINS_key=${QWENSTRATAINS_key^^}
        QWENSTRATAINS_ARG[$QWENSTRATAINS_key]=${QWENSTRATAINS_opt#*=}; shift ;;
      --web-api-key) QWENSTRATAINS_ARG[WEB_API_KEY]=yes; shift ;;
      --no-web-api-key) QWENSTRATAINS_ARG[WEB_API_KEY]=no; shift ;;
      --agent-api-key) QWENSTRATAINS_ARG[AGENT_API_KEY]=yes; shift ;;
      --no-agent-api-key) QWENSTRATAINS_ARG[AGENT_API_KEY]=no; shift ;;
      --accept-license) QWENSTRATAINS_ACCEPT_LICENSE=yes; shift ;;
      --open-ports) QWENSTRATAINS_OPEN_PORTS=yes; shift ;;
      --no-open-ports) QWENSTRATAINS_OPEN_PORTS=no; shift ;;
      --yes|-y) QWENSTRATAINS_ASSUME_YES=yes; shift ;;
      --uninstall) QWENSTRATAINS_ACTION=uninstall; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $QWENSTRATAINS_opt" ;;
    esac
  done
}

# install.conf is parsed, never sourced.
load_saved_config() {
  local QWENSTRATAINS_line QWENSTRATAINS_key QWENSTRATAINS_value
  [[ -f $QWENSTRATAINS_CONF_FILE ]] || return 0
  while IFS= read -r QWENSTRATAINS_line || [[ -n $QWENSTRATAINS_line ]]; do
    [[ $QWENSTRATAINS_line =~ ^([A-Z_]+)=(.*)$ ]] || continue
    QWENSTRATAINS_key=${BASH_REMATCH[1]}; QWENSTRATAINS_value=${BASH_REMATCH[2]}
    QWENSTRATAINS_value=${QWENSTRATAINS_value#\'}; QWENSTRATAINS_value=${QWENSTRATAINS_value%\'}
    QWENSTRATAINS_SAVED[$QWENSTRATAINS_key]=$QWENSTRATAINS_value
  done < "$QWENSTRATAINS_CONF_FILE"
}

# Merge options > environment > install.conf > default into VAL.
resolve_values() {
  local QWENSTRATAINS_key QWENSTRATAINS_env QWENSTRATAINS_b
  for QWENSTRATAINS_key in $QWENSTRATAINS_KEYS; do
    QWENSTRATAINS_env="QWENSTRATA_$QWENSTRATAINS_key"
    if [[ -n ${QWENSTRATAINS_ARG[$QWENSTRATAINS_key]:-} ]]; then
      QWENSTRATAINS_VAL[$QWENSTRATAINS_key]=${QWENSTRATAINS_ARG[$QWENSTRATAINS_key]}; QWENSTRATAINS_FROM_USER[$QWENSTRATAINS_key]=1
    elif [[ -n ${!QWENSTRATAINS_env:-} ]]; then
      QWENSTRATAINS_VAL[$QWENSTRATAINS_key]=${!QWENSTRATAINS_env}; QWENSTRATAINS_FROM_USER[$QWENSTRATAINS_key]=1
    elif [[ -n ${QWENSTRATAINS_SAVED[$QWENSTRATAINS_key]:-} ]]; then
      QWENSTRATAINS_VAL[$QWENSTRATAINS_key]=${QWENSTRATAINS_SAVED[$QWENSTRATAINS_key]}
    else
      QWENSTRATAINS_VAL[$QWENSTRATAINS_key]=${QWENSTRATAINS_DEFAULT[$QWENSTRATAINS_key]}
    fi
  done
  [[ $(yesno "${QWENSTRATA_ACCEPT_LICENSE:-}") == yes ]] && QWENSTRATAINS_ACCEPT_LICENSE=yes
  if [[ -z $QWENSTRATAINS_OPEN_PORTS && -n ${QWENSTRATA_OPEN_PORTS:-} ]]; then
    QWENSTRATAINS_OPEN_PORTS=$(yesno "$QWENSTRATA_OPEN_PORTS")
    [[ -n $QWENSTRATAINS_OPEN_PORTS ]] || die "invalid value for QWENSTRATA_OPEN_PORTS: $QWENSTRATA_OPEN_PORTS (use yes or no)"
  fi
  for QWENSTRATAINS_key in WEB_API_KEY AGENT_API_KEY; do
    QWENSTRATAINS_b=$(yesno "${QWENSTRATAINS_VAL[$QWENSTRATAINS_key]}")
    [[ -n $QWENSTRATAINS_b ]] || die "invalid value for QWENSTRATA_$QWENSTRATAINS_key: ${QWENSTRATAINS_VAL[$QWENSTRATAINS_key]} (use yes or no)"
    QWENSTRATAINS_VAL[$QWENSTRATAINS_key]=$QWENSTRATAINS_b
  done
  QWENSTRATAINS_VAL[BACKEND]=${QWENSTRATAINS_VAL[BACKEND],,}
  [[ " $QWENSTRATAINS_BACKENDS " == *" ${QWENSTRATAINS_VAL[BACKEND]} "* ]] || die "backend must be one of: $QWENSTRATAINS_BACKENDS"
  return 0
}

# ------------------------------------------------------------- GPU selection
#
# GPUs are selected by PCI address (stable across reboots) and converted to the numbers
# "strata launch --gpu" takes when Strata is configured:
#   NVIDIA  the nvidia-smi index (Strata sets CUDA_DEVICE_ORDER=PCI_BUS_ID itself)
#   AMD     the position among the GPU nodes of the KFD topology (HIP's order)
# One Strata engine drives the GPUs of one maker, so a selection never mixes makers.

# Print the makers of display controllers (nvidia, amd, intel) found on PCI.
gpu_vendors() {
  local QWENSTRATAINS_dev QWENSTRATAINS_class QWENSTRATAINS_vendor
  for QWENSTRATAINS_dev in /sys/bus/pci/devices/*; do
    [[ -r $QWENSTRATAINS_dev/class && -r $QWENSTRATAINS_dev/vendor ]] || continue
    QWENSTRATAINS_class=$(<"$QWENSTRATAINS_dev/class"); QWENSTRATAINS_vendor=$(<"$QWENSTRATAINS_dev/vendor")
    [[ $QWENSTRATAINS_class == 0x03* ]] || continue
    case $QWENSTRATAINS_vendor in
      0x10de) echo nvidia ;;
      0x1002) echo amd ;;
      0x8086) echo intel ;;
    esac
  done | sort -u
}

# normalize_pci ADDRESS: print a PCI address as dddd:bb:dd.f (lower case), or nothing if invalid.
normalize_pci() {
  local QWENSTRATAINS_a=${1,,}
  [[ $QWENSTRATAINS_a =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] && QWENSTRATAINS_a="0000:$QWENSTRATAINS_a"
  [[ $QWENSTRATAINS_a =~ ^([0-9a-f]{4,8}):([0-9a-f]{2}:[0-9a-f]{2}\.[0-7])$ ]] || return 0
  printf '%04x:%s\n' "$((16#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}"
}

# Print "index<TAB>PCI address" for each NVIDIA GPU that answers to nvidia-smi.
nvidia_devices() {
  local QWENSTRATAINS_out QWENSTRATAINS_idx QWENSTRATAINS_bus
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  QWENSTRATAINS_out=$(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null) || return 0
  while IFS=, read -r QWENSTRATAINS_idx QWENSTRATAINS_bus; do
    QWENSTRATAINS_idx=$(trim "$QWENSTRATAINS_idx"); QWENSTRATAINS_bus=$(normalize_pci "$(trim "$QWENSTRATAINS_bus")")
    [[ $QWENSTRATAINS_idx =~ ^[0-9]+$ && -n $QWENSTRATAINS_bus ]] && printf '%s\t%s\n' "$QWENSTRATAINS_idx" "$QWENSTRATAINS_bus"
  done <<<"$QWENSTRATAINS_out"
  return 0
}

# Print "index<TAB>PCI address" for each AMD GPU known to the amdgpu driver, in the order
# of the GPU nodes of the KFD topology (CPU nodes skipped).
rocm_devices() {
  local QWENSTRATAINS_nodes=/sys/class/kfd/kfd/topology/nodes QWENSTRATAINS_n=0 QWENSTRATAINS_idx=0 QWENSTRATAINS_props QWENSTRATAINS_domain QWENSTRATAINS_loc QWENSTRATAINS_id
  while [[ -d $QWENSTRATAINS_nodes/$QWENSTRATAINS_n ]]; do
    QWENSTRATAINS_id=$(cat "$QWENSTRATAINS_nodes/$QWENSTRATAINS_n/gpu_id" 2>/dev/null || echo 0)
    if [[ $QWENSTRATAINS_id != 0 ]]; then
      QWENSTRATAINS_props=$(cat "$QWENSTRATAINS_nodes/$QWENSTRATAINS_n/properties" 2>/dev/null || true)
      QWENSTRATAINS_domain=$(awk '$1 == "domain" {print $2}' <<<"$QWENSTRATAINS_props")
      QWENSTRATAINS_loc=$(awk '$1 == "location_id" {print $2}' <<<"$QWENSTRATAINS_props")
      if [[ $QWENSTRATAINS_loc =~ ^[0-9]+$ ]]; then
        printf '%d\t%04x:%02x:%02x.%x\n' "$QWENSTRATAINS_idx" "${QWENSTRATAINS_domain:-0}" $((QWENSTRATAINS_loc >> 8)) $(((QWENSTRATAINS_loc >> 3) & 31)) $((QWENSTRATAINS_loc & 7))
      fi
      QWENSTRATAINS_idx=$((QWENSTRATAINS_idx + 1))
    fi
    QWENSTRATAINS_n=$((QWENSTRATAINS_n + 1))
  done
}

# Print "maker<TAB>PCI address<TAB>total MiB<TAB>used MiB<TAB>name" for each GPU Strata can
# use, limited to one maker by --backend.
gpu_candidates() {
  local QWENSTRATAINS_b=${QWENSTRATAINS_VAL[BACKEND]} QWENSTRATAINS_out QWENSTRATAINS_pci QWENSTRATAINS_total QWENSTRATAINS_used QWENSTRATAINS_name QWENSTRATAINS_dev
  if [[ $QWENSTRATAINS_b != amd ]] && command -v nvidia-smi >/dev/null 2>&1; then
    QWENSTRATAINS_out=$(nvidia-smi --query-gpu=pci.bus_id,memory.total,memory.used,name --format=csv,noheader,nounits 2>/dev/null) || QWENSTRATAINS_out=""
    while IFS=, read -r QWENSTRATAINS_pci QWENSTRATAINS_total QWENSTRATAINS_used QWENSTRATAINS_name; do
      QWENSTRATAINS_pci=$(normalize_pci "$(trim "$QWENSTRATAINS_pci")")
      QWENSTRATAINS_total=$(trim "$QWENSTRATAINS_total"); QWENSTRATAINS_used=$(trim "$QWENSTRATAINS_used")
      [[ -n $QWENSTRATAINS_pci && $QWENSTRATAINS_total =~ ^[0-9]+$ ]] || continue
      [[ $QWENSTRATAINS_used =~ ^[0-9]+$ ]] || QWENSTRATAINS_used=0
      printf 'nvidia\t%s\t%s\t%s\t%s\n' "$QWENSTRATAINS_pci" "$QWENSTRATAINS_total" "$QWENSTRATAINS_used" "$(trim "$QWENSTRATAINS_name")"
    done <<<"$QWENSTRATAINS_out"
  fi
  if [[ $QWENSTRATAINS_b != nvidia ]]; then
    while IFS=$'\t' read -r _ QWENSTRATAINS_pci; do
      [[ -n $QWENSTRATAINS_pci ]] || continue
      QWENSTRATAINS_dev=/sys/bus/pci/devices/$QWENSTRATAINS_pci
      QWENSTRATAINS_total=$(cat "$QWENSTRATAINS_dev/mem_info_vram_total" 2>/dev/null || echo 0)
      QWENSTRATAINS_used=$(cat "$QWENSTRATAINS_dev/mem_info_vram_used" 2>/dev/null || echo 0)
      [[ $QWENSTRATAINS_total =~ ^[0-9]+$ ]] || QWENSTRATAINS_total=0
      [[ $QWENSTRATAINS_used =~ ^[0-9]+$ ]] || QWENSTRATAINS_used=0
      QWENSTRATAINS_name=""
      command -v lspci >/dev/null 2>&1 && QWENSTRATAINS_name=$(lspci -vmm -s "$QWENSTRATAINS_pci" 2>/dev/null | sed -n 's/^Device:[[:space:]]*//p;T;q' || true)
      [[ -n $QWENSTRATAINS_name ]] || QWENSTRATAINS_name="AMD $(sed 's/^0x//' "$QWENSTRATAINS_dev/device" 2>/dev/null || echo GPU)"
      printf 'amd\t%s\t%s\t%s\t%s\n' "$QWENSTRATAINS_pci" $((QWENSTRATAINS_total / 1048576)) $((QWENSTRATAINS_used / 1048576)) "$QWENSTRATAINS_name"
    done <<<"$(rocm_devices)"
  fi
  return 0
}

# gpu_ranked CANDIDATES: sort the candidates by preference: NVIDIA first, then the largest
# memory, then the most free memory, then the PCI address.
gpu_ranked() {
  [[ -n $1 ]] || return 0
  awk -F '\t' -v OFS='\t' '{print $0, $3 - $4}' <<<"$1" \
    | LC_ALL=C sort -t $'\t' -k1,1r -k3,3nr -k6,6nr -k2,2 | cut -f1-5
}

# gpu_selected CANDIDATES: print the candidate lines of the selection in VAL[GPUS] ("all":
# every GPU of the preferred maker).
gpu_selected() {
  local QWENSTRATAINS_ranked QWENSTRATAINS_vendor QWENSTRATAINS_p
  if [[ ${QWENSTRATAINS_VAL[GPUS]} == all ]]; then
    QWENSTRATAINS_ranked=$(gpu_ranked "$1")
    QWENSTRATAINS_vendor=${QWENSTRATAINS_ranked%%$'\t'*}
    awk -F '\t' -v v="$QWENSTRATAINS_vendor" '$1 == v' <<<"$1"
  else
    for QWENSTRATAINS_p in ${QWENSTRATAINS_VAL[GPUS]//,/ }; do
      awk -F '\t' -v p="$QWENSTRATAINS_p" '$2 == p' <<<"$1"
    done
  fi
}

# Stop early when Strata has nothing to run on: it has no CPU-only engine.
require_gpu() {
  local QWENSTRATAINS_vendors
  [[ -z $(gpu_candidates) ]] || return 0
  QWENSTRATAINS_vendors=$(gpu_vendors | paste -sd, -)
  if [[ ${QWENSTRATAINS_VAL[BACKEND]} != amd && $QWENSTRATAINS_vendors == *nvidia* ]]; then
    die "an NVIDIA GPU was found but nvidia-smi does not work; install the NVIDIA driver first (e.g. sudo ubuntu-drivers install), reboot and re-run"
  fi
  if [[ ${QWENSTRATAINS_VAL[BACKEND]} != nvidia && $QWENSTRATAINS_vendors == *amd* ]]; then
    die "an AMD GPU was found but the amdgpu driver does not report it (no GPU in /sys/class/kfd/kfd/topology); Strata cannot use it"
  fi
  die "no GPU that Strata can use was found (detected: ${QWENSTRATAINS_vendors:-none}, --backend ${QWENSTRATAINS_VAL[BACKEND]}); Strata needs an NVIDIA or AMD GPU"
}

validate_gpus() {
  local QWENSTRATAINS_v=${QWENSTRATAINS_VAL[GPUS],,} QWENSTRATAINS_cands QWENSTRATAINS_list QWENSTRATAINS_p QWENSTRATAINS_a QWENSTRATAINS_out=() QWENSTRATAINS_vendors
  QWENSTRATAINS_cands=$(gpu_candidates)
  [[ -n $QWENSTRATAINS_cands ]] || die "no GPU that Strata can use was found"
  QWENSTRATAINS_list=$(cut -f2 <<<"$QWENSTRATAINS_cands")
  if [[ -n $QWENSTRATAINS_v && $QWENSTRATAINS_v != all ]]; then
    for QWENSTRATAINS_p in ${QWENSTRATAINS_v//,/ }; do
      QWENSTRATAINS_a=$(normalize_pci "$QWENSTRATAINS_p")
      [[ -n $QWENSTRATAINS_a ]] || die "invalid PCI address in --gpus: $QWENSTRATAINS_p (use e.g. 0000:03:00.0, or all)"
      if ! grep -qx "$QWENSTRATAINS_a" <<<"$QWENSTRATAINS_list"; then
        if [[ -n ${QWENSTRATAINS_FROM_USER[GPUS]:-} ]]; then
          die "GPU $QWENSTRATAINS_a is not usable by Strata with --backend ${QWENSTRATAINS_VAL[BACKEND]} (usable: $(paste -sd' ' <<<"$QWENSTRATAINS_list"))"
        fi
        warn "the saved GPU selection ($QWENSTRATAINS_v) does not match this machine; choosing a GPU again"
        QWENSTRATAINS_out=(); QWENSTRATAINS_v=""
        break
      fi
      [[ " ${QWENSTRATAINS_out[*]} " == *" $QWENSTRATAINS_a "* ]] || QWENSTRATAINS_out+=("$QWENSTRATAINS_a")
    done
  fi
  if [[ $QWENSTRATAINS_v == all ]]; then
    QWENSTRATAINS_VAL[GPUS]=all
  elif ((${#QWENSTRATAINS_out[@]} > 0)); then
    QWENSTRATAINS_VAL[GPUS]=$(IFS=,; echo "${QWENSTRATAINS_out[*]}")
  else
    QWENSTRATAINS_VAL[GPUS]=$(gpu_ranked "$QWENSTRATAINS_cands" | sed -n '1p' | cut -f2)
  fi
  QWENSTRATAINS_vendors=$(gpu_selected "$QWENSTRATAINS_cands" | cut -f1 | sort -u | paste -sd, -)
  case $QWENSTRATAINS_vendors in
    nvidia|amd) QWENSTRATAINS_GPU_VENDOR=$QWENSTRATAINS_vendors ;;
    *) die "NVIDIA and AMD GPUs cannot be used together (one Strata engine drives the GPUs of one maker): ${QWENSTRATAINS_VAL[GPUS]}" ;;
  esac
}

# Ask which GPUs to use when two or more are usable.
prompt_gpus() {
  local QWENSTRATAINS_cands QWENSTRATAINS_pcis=() QWENSTRATAINS_vendors=() QWENSTRATAINS_vendor QWENSTRATAINS_pci QWENSTRATAINS_total QWENSTRATAINS_used QWENSTRATAINS_name QWENSTRATAINS_i QWENSTRATAINS_default="" QWENSTRATAINS_answer QWENSTRATAINS_tok QWENSTRATAINS_sel=() QWENSTRATAINS_selv QWENSTRATAINS_ok
  [[ -z ${QWENSTRATAINS_FROM_USER[GPUS]:-} && $QWENSTRATAINS_INTERACTIVE == yes ]] || return 0
  QWENSTRATAINS_cands=$(gpu_candidates)
  while IFS=$'\t' read -r QWENSTRATAINS_vendor QWENSTRATAINS_pci _; do
    [[ -n $QWENSTRATAINS_pci ]] || continue
    QWENSTRATAINS_pcis+=("$QWENSTRATAINS_pci"); QWENSTRATAINS_vendors+=("$QWENSTRATAINS_vendor")
  done <<<"$QWENSTRATAINS_cands"
  ((${#QWENSTRATAINS_pcis[@]} >= 2)) || return 0
  echo "GPUs that Strata can use (GPUs of different makers cannot be used together):"
  QWENSTRATAINS_i=0
  while IFS=$'\t' read -r QWENSTRATAINS_vendor QWENSTRATAINS_pci QWENSTRATAINS_total QWENSTRATAINS_used QWENSTRATAINS_name; do
    [[ -n $QWENSTRATAINS_pci ]] || continue
    QWENSTRATAINS_i=$((QWENSTRATAINS_i + 1))
    printf '  %d) %s  %-6s %s (%s MiB, %s MiB in use)\n' "$QWENSTRATAINS_i" "$QWENSTRATAINS_pci" "$QWENSTRATAINS_vendor" "$QWENSTRATAINS_name" "$QWENSTRATAINS_total" "$QWENSTRATAINS_used"
  done <<<"$QWENSTRATAINS_cands"
  if [[ ${QWENSTRATAINS_VAL[GPUS]} == all ]]; then
    QWENSTRATAINS_default=all
  else
    for QWENSTRATAINS_i in "${!QWENSTRATAINS_pcis[@]}"; do
      [[ ",${QWENSTRATAINS_VAL[GPUS]}," == *",${QWENSTRATAINS_pcis[$QWENSTRATAINS_i]},"* ]] && QWENSTRATAINS_default+="${QWENSTRATAINS_default:+,}$((QWENSTRATAINS_i + 1))"
    done
  fi
  while :; do
    read -r -p "GPUs to use (numbers such as 1 or 1,2; or all) [$QWENSTRATAINS_default]: " QWENSTRATAINS_answer || die "no input"
    QWENSTRATAINS_answer=$(trim "$QWENSTRATAINS_answer")
    QWENSTRATAINS_answer=${QWENSTRATAINS_answer:-$QWENSTRATAINS_default}
    if [[ ${QWENSTRATAINS_answer,,} == all ]]; then QWENSTRATAINS_VAL[GPUS]=all; break; fi
    QWENSTRATAINS_sel=(); QWENSTRATAINS_selv=""; QWENSTRATAINS_ok=yes
    for QWENSTRATAINS_tok in ${QWENSTRATAINS_answer//,/ }; do
      if [[ $QWENSTRATAINS_tok =~ ^[0-9]+$ ]] && ((QWENSTRATAINS_tok >= 1 && QWENSTRATAINS_tok <= ${#QWENSTRATAINS_pcis[@]})); then
        QWENSTRATAINS_pci=${QWENSTRATAINS_pcis[$((QWENSTRATAINS_tok - 1))]}
        [[ " ${QWENSTRATAINS_sel[*]} " == *" $QWENSTRATAINS_pci "* ]] || QWENSTRATAINS_sel+=("$QWENSTRATAINS_pci")
        [[ " $QWENSTRATAINS_selv " == *" ${QWENSTRATAINS_vendors[$((QWENSTRATAINS_tok - 1))]} "* ]] || QWENSTRATAINS_selv+=" ${QWENSTRATAINS_vendors[$((QWENSTRATAINS_tok - 1))]} "
      else
        QWENSTRATAINS_ok=no
      fi
    done
    if [[ $QWENSTRATAINS_ok != yes || ${#QWENSTRATAINS_sel[@]} -eq 0 ]]; then
      warn "answer all, or numbers between 1 and ${#QWENSTRATAINS_pcis[@]} separated by commas"
    elif [[ $QWENSTRATAINS_selv == *nvidia* && $QWENSTRATAINS_selv == *amd* ]]; then
      warn "NVIDIA and AMD GPUs cannot be used together; select GPUs of one maker"
    else
      QWENSTRATAINS_VAL[GPUS]=$(IFS=,; echo "${QWENSTRATAINS_sel[*]}")
      break
    fi
  done
  validate_gpus
}

gpu_label() {
  local QWENSTRATAINS_sel QWENSTRATAINS_n QWENSTRATAINS_text
  QWENSTRATAINS_sel=$(gpu_selected "$(gpu_candidates)")
  QWENSTRATAINS_n=$(grep -c . <<<"$QWENSTRATAINS_sel" || true)
  QWENSTRATAINS_text=$(awk -F '\t' '{printf "%s%s (%s, %s MiB)", (NR > 1 ? "; " : ""), $2, $5, $3}' <<<"$QWENSTRATAINS_sel")
  if [[ ${QWENSTRATAINS_VAL[GPUS]} == all ]]; then
    echo "all $QWENSTRATAINS_n $QWENSTRATAINS_GPU_VENDOR GPU(s): $QWENSTRATAINS_text"
  else
    echo "$QWENSTRATAINS_text"
  fi
}

# Print the numbers of the selected GPUs as "strata launch --gpu" takes them (e.g. "0,1").
gpu_indices() {
  local QWENSTRATAINS_map QWENSTRATAINS_pci QWENSTRATAINS_id QWENSTRATAINS_ids=()
  if [[ $QWENSTRATAINS_GPU_VENDOR == nvidia ]]; then QWENSTRATAINS_map=$(nvidia_devices); else QWENSTRATAINS_map=$(rocm_devices); fi
  while IFS=$'\t' read -r _ QWENSTRATAINS_pci _; do
    [[ -n $QWENSTRATAINS_pci ]] || continue
    QWENSTRATAINS_id=$(awk -F '\t' -v p="$QWENSTRATAINS_pci" '$2 == p {print $1; exit}' <<<"$QWENSTRATAINS_map")
    [[ -n $QWENSTRATAINS_id ]] || die "GPU $QWENSTRATAINS_pci was not found among the $QWENSTRATAINS_GPU_VENDOR GPUs; re-run the installer and select the GPUs again"
    QWENSTRATAINS_ids+=("$QWENSTRATAINS_id")
  done <<<"$(gpu_selected "$(gpu_candidates)")"
  ((${#QWENSTRATAINS_ids[@]} > 0)) || die "no GPU is selected"
  printf '%s\n' "${QWENSTRATAINS_ids[@]}" | sort -n | paste -sd, -
}

# Print the NVIDIA driver version (the oldest if the GPUs disagree), or nothing.
nvidia_driver_version() {
  local QWENSTRATAINS_v
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  QWENSTRATAINS_v=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null) || return 0
  QWENSTRATAINS_v=$(grep -E '^[0-9]+(\.[0-9]+)*$' <<<"$QWENSTRATAINS_v" | sort -V | head -n1 || true)
  echo "$QWENSTRATAINS_v"
}

# ------------------------------------------------------- network interfaces
#
# nginx cannot bind to an interface, so the selected interfaces are turned into their
# current addresses when the configuration is written (re-run the installer if an address
# changes).  127.0.0.1 (and ::1) are always included so that local clients and the test at
# the end keep working.  ufw rules are limited with "in on IF".

# Print "interface<TAB>address address ..." for each interface with a global address
# (container and VM bridges excluded; temporary/deprecated IPv6 addresses skipped).
net_interfaces() {
  local QWENSTRATAINS_out QWENSTRATAINS_ifc QWENSTRATAINS_fam QWENSTRATAINS_addr QWENSTRATAINS_rest QWENSTRATAINS_order=()
  local -A QWENSTRATAINS_addrs=()
  QWENSTRATAINS_out=$(ip -o addr show scope global 2>/dev/null || true)
  while read -r _ QWENSTRATAINS_ifc QWENSTRATAINS_fam QWENSTRATAINS_addr QWENSTRATAINS_rest; do
    [[ -n $QWENSTRATAINS_ifc && ( $QWENSTRATAINS_fam == inet || $QWENSTRATAINS_fam == inet6 ) ]] || continue
    [[ $QWENSTRATAINS_rest == *temporary* || $QWENSTRATAINS_rest == *deprecated* || $QWENSTRATAINS_rest == *tentative* ]] && continue
    QWENSTRATAINS_ifc=${QWENSTRATAINS_ifc%%@*}
    case $QWENSTRATAINS_ifc in lo|docker*|br-*|veth*|virbr*|lxdbr*|cni*) continue ;; esac
    [[ -n ${QWENSTRATAINS_addrs[$QWENSTRATAINS_ifc]+x} ]] || QWENSTRATAINS_order+=("$QWENSTRATAINS_ifc")
    QWENSTRATAINS_addrs[$QWENSTRATAINS_ifc]+="${QWENSTRATAINS_addrs[$QWENSTRATAINS_ifc]:+ }${QWENSTRATAINS_addr%/*}"
  done <<<"$QWENSTRATAINS_out"
  for QWENSTRATAINS_ifc in "${QWENSTRATAINS_order[@]}"; do
    printf '%s\t%s\n' "$QWENSTRATAINS_ifc" "${QWENSTRATAINS_addrs[$QWENSTRATAINS_ifc]}"
  done
}

# Print the addresses of the selected interfaces, one per line (nothing for "all").
listen_addresses() {
  local QWENSTRATAINS_list QWENSTRATAINS_ifc QWENSTRATAINS_addr_list=()
  [[ ${QWENSTRATAINS_VAL[INTERFACES]} != all ]] || return 0
  QWENSTRATAINS_list=$(net_interfaces)
  for QWENSTRATAINS_ifc in ${QWENSTRATAINS_VAL[INTERFACES]//,/ }; do
    read -r -a QWENSTRATAINS_addr_list <<<"$(awk -F '\t' -v i="$QWENSTRATAINS_ifc" '$1 == i {print $2}' <<<"$QWENSTRATAINS_list")"
    ((${#QWENSTRATAINS_addr_list[@]} == 0)) || printf '%s\n' "${QWENSTRATAINS_addr_list[@]}"
  done
}

interfaces_label() {
  local QWENSTRATAINS_list QWENSTRATAINS_ifc QWENSTRATAINS_out=""
  if [[ ${QWENSTRATAINS_VAL[INTERFACES]} == all ]]; then echo "all"; return 0; fi
  QWENSTRATAINS_list=$(net_interfaces)
  for QWENSTRATAINS_ifc in ${QWENSTRATAINS_VAL[INTERFACES]//,/ }; do
    QWENSTRATAINS_out+="${QWENSTRATAINS_out:+, }$QWENSTRATAINS_ifc ($(awk -F '\t' -v i="$QWENSTRATAINS_ifc" '$1 == i {gsub(/ /, ", ", $2); print $2}' <<<"$QWENSTRATAINS_list"))"
  done
  echo "$QWENSTRATAINS_out (and 127.0.0.1)"
}

validate_interfaces() {
  local QWENSTRATAINS_v=${QWENSTRATAINS_VAL[INTERFACES]} QWENSTRATAINS_list QWENSTRATAINS_ifc QWENSTRATAINS_out=()
  if [[ -z $QWENSTRATAINS_v || ${QWENSTRATAINS_v,,} == all ]]; then QWENSTRATAINS_VAL[INTERFACES]=all; return 0; fi
  QWENSTRATAINS_list=$(net_interfaces | cut -f1)
  for QWENSTRATAINS_ifc in ${QWENSTRATAINS_v//,/ }; do
    [[ $QWENSTRATAINS_ifc =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || die "invalid interface name: $QWENSTRATAINS_ifc"
    if ! grep -qxF "$QWENSTRATAINS_ifc" <<<"$QWENSTRATAINS_list"; then
      if [[ -n ${QWENSTRATAINS_FROM_USER[INTERFACES]:-} ]]; then
        die "interface $QWENSTRATAINS_ifc has no global address (available: $(paste -sd' ' <<<"$QWENSTRATAINS_list"))"
      fi
      warn "the saved interface selection ($QWENSTRATAINS_v) does not match this machine; listening on all interfaces"
      QWENSTRATAINS_VAL[INTERFACES]=all; return 0
    fi
    [[ " ${QWENSTRATAINS_out[*]} " == *" $QWENSTRATAINS_ifc "* ]] || QWENSTRATAINS_out+=("$QWENSTRATAINS_ifc")
  done
  QWENSTRATAINS_VAL[INTERFACES]=$(IFS=,; echo "${QWENSTRATAINS_out[*]}")
}

# Ask on which interfaces to accept connections when two or more have addresses.
prompt_interfaces() {
  local QWENSTRATAINS_list QWENSTRATAINS_names=() QWENSTRATAINS_ifc QWENSTRATAINS_addrs QWENSTRATAINS_i QWENSTRATAINS_default="" QWENSTRATAINS_answer QWENSTRATAINS_tok QWENSTRATAINS_sel=() QWENSTRATAINS_ok
  [[ -z ${QWENSTRATAINS_FROM_USER[INTERFACES]:-} && $QWENSTRATAINS_INTERACTIVE == yes ]] || return 0
  QWENSTRATAINS_list=$(net_interfaces)
  [[ -n $QWENSTRATAINS_list ]] || return 0
  while IFS=$'\t' read -r QWENSTRATAINS_ifc QWENSTRATAINS_addrs; do QWENSTRATAINS_names+=("$QWENSTRATAINS_ifc"); done <<<"$QWENSTRATAINS_list"
  ((${#QWENSTRATAINS_names[@]} >= 2)) || return 0
  echo "Network interfaces on which the web server accepts connections from other hosts"
  echo "(127.0.0.1 is always available on this machine):"
  QWENSTRATAINS_i=0
  while IFS=$'\t' read -r QWENSTRATAINS_ifc QWENSTRATAINS_addrs; do
    QWENSTRATAINS_i=$((QWENSTRATAINS_i + 1))
    printf '  %d) %-12s %s\n' "$QWENSTRATAINS_i" "$QWENSTRATAINS_ifc" "${QWENSTRATAINS_addrs// /, }"
  done <<<"$QWENSTRATAINS_list"
  if [[ ${QWENSTRATAINS_VAL[INTERFACES]} == all ]]; then
    QWENSTRATAINS_default=all
  else
    for QWENSTRATAINS_i in "${!QWENSTRATAINS_names[@]}"; do
      [[ ",${QWENSTRATAINS_VAL[INTERFACES]}," == *",${QWENSTRATAINS_names[$QWENSTRATAINS_i]},"* ]] && QWENSTRATAINS_default+="${QWENSTRATAINS_default:+,}$((QWENSTRATAINS_i + 1))"
    done
  fi
  while :; do
    read -r -p "Interfaces (all, or numbers such as 1,2) [$QWENSTRATAINS_default]: " QWENSTRATAINS_answer || die "no input"
    QWENSTRATAINS_answer=$(trim "$QWENSTRATAINS_answer")
    QWENSTRATAINS_answer=${QWENSTRATAINS_answer:-$QWENSTRATAINS_default}
    if [[ ${QWENSTRATAINS_answer,,} == all ]]; then QWENSTRATAINS_VAL[INTERFACES]=all; return 0; fi
    QWENSTRATAINS_sel=(); QWENSTRATAINS_ok=yes
    for QWENSTRATAINS_tok in ${QWENSTRATAINS_answer//,/ }; do
      if [[ $QWENSTRATAINS_tok =~ ^[0-9]+$ ]] && ((QWENSTRATAINS_tok >= 1 && QWENSTRATAINS_tok <= ${#QWENSTRATAINS_names[@]})); then
        QWENSTRATAINS_ifc=${QWENSTRATAINS_names[$((QWENSTRATAINS_tok - 1))]}
        [[ " ${QWENSTRATAINS_sel[*]} " == *" $QWENSTRATAINS_ifc "* ]] || QWENSTRATAINS_sel+=("$QWENSTRATAINS_ifc")
      else
        QWENSTRATAINS_ok=no
      fi
    done
    if [[ $QWENSTRATAINS_ok == yes && ${#QWENSTRATAINS_sel[@]} -gt 0 ]]; then
      QWENSTRATAINS_VAL[INTERFACES]=$(IFS=,; echo "${QWENSTRATAINS_sel[*]}")
      return 0
    fi
    warn "answer all, or numbers between 1 and ${#QWENSTRATAINS_names[@]} separated by commas"
  done
}

# ------------------------------------------------------------------ prompts

prompt_values() {
  local QWENSTRATAINS_q QWENSTRATAINS_list="" QWENSTRATAINS_f
  [[ $QWENSTRATAINS_INTERACTIVE == yes ]] || return 0
  ask DESTDIR "Install directory (becomes the home directory of the service user)"
  ask USER "Service user"
  for QWENSTRATAINS_q in $QWENSTRATAINS_QUANTS; do
    read -r -a QWENSTRATAINS_f <<<"${QWENSTRATAINS_QUANT[$QWENSTRATAINS_q]}"
    QWENSTRATAINS_list+=$(printf '  %-11s %-12s download %5s GB, RAM for all experts about %3s GB' "$QWENSTRATAINS_q" "${QWENSTRATAINS_f[2]}" "$((QWENSTRATAINS_f[3] / 10)).$((QWENSTRATAINS_f[3] % 10))" "${QWENSTRATAINS_f[4]}")$'\n'
  done
  ask QUANT "Quantization" "Quantizations of Qwen3.8-Flash-Next (larger is closer to the original and slower):"$'\n'"${QWENSTRATAINS_list%$'\n'}"
  ask CTX_SIZE "Context size in tokens ($QWENSTRATAINS_MIN_CTX-$QWENSTRATAINS_MAX_CTX; on a 12 GB GPU a shorter context is faster)"
  ask TUNE "Tuning by Strata (skip; quick: about 20 minutes; thorough: up to 2 hours)"
  ask WEB_PORT "Web server port"
  ask_bool WEB_API_KEY "Require the API key for the web chat page?"
  ask_bool AGENT_API_KEY "Require the API key for the API used by coding agents?"
}

validate() {
  local QWENSTRATAINS_d=${QWENSTRATAINS_VAL[DESTDIR]} QWENSTRATAINS_p QWENSTRATAINS_q QWENSTRATAINS_found=""
  [[ $QWENSTRATAINS_d == /* ]] || die "destdir must be an absolute path: $QWENSTRATAINS_d"
  [[ $QWENSTRATAINS_d =~ ^/[A-Za-z0-9._/-]+$ && $QWENSTRATAINS_d != *//* && $QWENSTRATAINS_d != */./* && $QWENSTRATAINS_d != */../* && $QWENSTRATAINS_d != */. && $QWENSTRATAINS_d != */.. ]] \
    || die "destdir may contain only letters, digits and . _ - / : $QWENSTRATAINS_d"
  QWENSTRATAINS_d=${QWENSTRATAINS_d%/}; QWENSTRATAINS_VAL[DESTDIR]=$QWENSTRATAINS_d
  # Strata refuses data folders under most system directories unless they are inside the
  # user's own home; destdir is that home, but system directories themselves are refused here.
  case $QWENSTRATAINS_d in
    ""|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/*|/var|/var/lib|/etc/*|/proc/*|/sys/*|/dev/*|/run/*|/boot/*|/root/*)
      die "destdir must not be a system directory: $QWENSTRATAINS_d" ;;
  esac
  [[ ${QWENSTRATAINS_VAL[USER]} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: ${QWENSTRATAINS_VAL[USER]}"
  [[ ${QWENSTRATAINS_VAL[USER]} != root ]] || die "the service user must not be root"
  QWENSTRATAINS_VAL[MODEL]=${QWENSTRATAINS_VAL[MODEL],,}
  [[ " $QWENSTRATAINS_MODELS " == *" ${QWENSTRATAINS_VAL[MODEL]} "* ]] || die "model must be one of: $QWENSTRATAINS_MODELS"
  for QWENSTRATAINS_q in $QWENSTRATAINS_QUANTS; do
    [[ ${QWENSTRATAINS_q,,} != "${QWENSTRATAINS_VAL[QUANT],,}" ]] || QWENSTRATAINS_found=$QWENSTRATAINS_q
  done
  [[ -n $QWENSTRATAINS_found ]] || die "quantization must be one of: $QWENSTRATAINS_QUANTS"
  QWENSTRATAINS_VAL[QUANT]=$QWENSTRATAINS_found
  [[ ${QWENSTRATAINS_VAL[CTX_SIZE]} =~ ^[0-9]{1,7}$ ]] || die "context size must be an integer: ${QWENSTRATAINS_VAL[CTX_SIZE]}"
  QWENSTRATAINS_VAL[CTX_SIZE]=$((10#${QWENSTRATAINS_VAL[CTX_SIZE]}))
  ((QWENSTRATAINS_VAL[CTX_SIZE] >= QWENSTRATAINS_MIN_CTX && QWENSTRATAINS_VAL[CTX_SIZE] <= QWENSTRATAINS_MAX_CTX)) \
    || die "context size must be between $QWENSTRATAINS_MIN_CTX and $QWENSTRATAINS_MAX_CTX"
  QWENSTRATAINS_VAL[KV]=${QWENSTRATAINS_VAL[KV],,}
  [[ " $QWENSTRATAINS_KV_MODES " == *" ${QWENSTRATAINS_VAL[KV]} "* ]] || die "KV format must be one of: $QWENSTRATAINS_KV_MODES"
  QWENSTRATAINS_VAL[TUNE]=${QWENSTRATAINS_VAL[TUNE],,}
  [[ " $QWENSTRATAINS_TUNE_MODES " == *" ${QWENSTRATAINS_VAL[TUNE]} "* ]] || die "tuning must be one of: $QWENSTRATAINS_TUNE_MODES"
  for QWENSTRATAINS_p in WEB_PORT STRATA_PORT; do
    [[ ${QWENSTRATAINS_VAL[$QWENSTRATAINS_p]} =~ ^[0-9]{1,5}$ ]] || die "invalid port number: ${QWENSTRATAINS_VAL[$QWENSTRATAINS_p]}"
    QWENSTRATAINS_VAL[$QWENSTRATAINS_p]=$((10#${QWENSTRATAINS_VAL[$QWENSTRATAINS_p]}))
    ((QWENSTRATAINS_VAL[$QWENSTRATAINS_p] >= 1 && QWENSTRATAINS_VAL[$QWENSTRATAINS_p] <= 65535)) || die "invalid port number: ${QWENSTRATAINS_VAL[$QWENSTRATAINS_p]}"
  done
  ((QWENSTRATAINS_VAL[WEB_PORT] != QWENSTRATAINS_VAL[STRATA_PORT])) || die "the web server port and the Strata port must differ"
  validate_gpus
  validate_interfaces
}

confirm_license() {
  [[ $QWENSTRATAINS_ACCEPT_LICENSE == yes ]] && { info "Qwen Community License 1.0 accepted (--accept-license)"; return 0; }
  [[ $QWENSTRATAINS_INTERACTIVE == yes ]] || die "non-interactive installation requires --accept-license (see $QWENSTRATAINS_LICENSE_URL)"
  cat <<EOF

Qwen3.8-Flash-Next (all quantizations offered here) is distributed under the
Qwen Community License 1.0.
  $QWENSTRATAINS_LICENSE_URL

  - Use, modification and redistribution are permitted, including commercial
    use; the copyright and permission notice must be kept.
  - If you or an affiliate conduct a "Model as a Service" or "AI Work Assistant"
    business, you must obtain a separate license from Qwen before any
    commercial use.  Internal use that does not make the model, its outputs or
    its capabilities available to third parties is exempt.
  - Products or services with more than 100 million monthly active users or
    US\$ 20 million of monthly revenue must display the model name prominently.
  - Read the full license text at the URL above before using the model.

EOF
  local QWENSTRATAINS_answer
  read -r -p "Type 'yes' to accept the license: " QWENSTRATAINS_answer || die "no input"
  [[ $(trim "$QWENSTRATAINS_answer") == yes ]] || die "the license was not accepted"
}

key_label() { if [[ $1 == yes ]]; then echo "required"; else echo "not required"; fi; }

show_summary() {
  local QWENSTRATAINS_dl QWENSTRATAINS_others
  QWENSTRATAINS_dl=$(quant_field 4)
  cat <<EOF

Installation settings:
  Install directory    : ${QWENSTRATAINS_VAL[DESTDIR]}
  Service user         : ${QWENSTRATAINS_VAL[USER]}
  Model                : Qwen3.8-Flash-Next ${QWENSTRATAINS_VAL[QUANT]} ($(quant_field 3); download $((QWENSTRATAINS_dl / 10)).$((QWENSTRATAINS_dl % 10)) GB)
  Engine               : Strata $QWENSTRATAINS_STRATA_VERSION ($QWENSTRATAINS_GPU_VENDOR)
  GPUs                 : $(gpu_label)
  Context size         : ${QWENSTRATAINS_VAL[CTX_SIZE]} tokens
  KV format            : ${QWENSTRATAINS_VAL[KV]}
  Tuning               : ${QWENSTRATAINS_VAL[TUNE]}
  Web server           : port ${QWENSTRATAINS_VAL[WEB_PORT]} (nginx)
  Listen on            : $(interfaces_label)
  Open ports in ufw    : $(ufw_label)
  Strata               : 127.0.0.1:${QWENSTRATAINS_VAL[STRATA_PORT]}
  API key, web page    : $(key_label "${QWENSTRATAINS_VAL[WEB_API_KEY]}")
  API key, agents      : $(key_label "${QWENSTRATAINS_VAL[AGENT_API_KEY]}")
  API key, management  : required (always)
EOF
  QWENSTRATAINS_others=$(exclusive_units_in_use | paste -sd, -)
  if [[ -n $QWENSTRATAINS_others ]]; then
    echo "  Other services       : ${QWENSTRATAINS_others//,/, } will be stopped and disabled"
  fi
  echo
  if [[ $QWENSTRATAINS_INTERACTIVE == yes && $QWENSTRATAINS_ASSUME_YES != yes ]]; then
    confirm "Proceed with the installation?" || die "aborted"
  fi
}

# -------------------------------------------------------------- preflight

check_platform() {
  [[ $EUID -eq 0 ]] || die "run as root (e.g. sudo bash $0)"
  [[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported (found $(uname -m))"
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  local QWENSTRATAINS_id QWENSTRATAINS_version
  # Parse instead of sourcing, so that os-release cannot clash with our variables.
  QWENSTRATAINS_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
  QWENSTRATAINS_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
  [[ $QWENSTRATAINS_id == ubuntu && $QWENSTRATAINS_version == 26.04 ]] || die "only Ubuntu 26.04 is supported (found ${QWENSTRATAINS_id:-?} ${QWENSTRATAINS_version:-?})"
  if [[ -e /proc/sys/fs/binfmt_misc/WSLInterop || -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft /proc/version 2>/dev/null; then
    die "Ubuntu on WSL is not supported"
  fi
  command -v systemctl >/dev/null || die "systemd is required"
}

# port_in_use_by_others PORT [UNIT]: is TCP port PORT used by a process that does not
# belong to the systemd unit UNIT?
port_in_use_by_others() {
  local QWENSTRATAINS_port=$1 QWENSTRATAINS_unit=${2:-} QWENSTRATAINS_listeners QWENSTRATAINS_pids QWENSTRATAINS_pid
  QWENSTRATAINS_listeners=$(ss -Hltnp "sport = :$QWENSTRATAINS_port" 2>/dev/null) || QWENSTRATAINS_listeners=""
  [[ -n $QWENSTRATAINS_listeners ]] || return 1
  [[ -n $QWENSTRATAINS_unit ]] || return 0
  QWENSTRATAINS_pids=$(grep -o 'pid=[0-9]*' <<<"$QWENSTRATAINS_listeners" | cut -d= -f2 | sort -u || true)
  [[ -n $QWENSTRATAINS_pids ]] || return 0
  for QWENSTRATAINS_pid in $QWENSTRATAINS_pids; do
    grep -qsF "/$QWENSTRATAINS_unit" "/proc/$QWENSTRATAINS_pid/cgroup" || return 0
  done
  return 1
}

port_free() { [[ -z $(ss -Hltn "sport = :$1" 2>/dev/null || true) ]]; }

existing_dir() {  # nearest existing ancestor of $1
  local QWENSTRATAINS_d=$1
  while [[ ! -d $QWENSTRATAINS_d ]]; do QWENSTRATAINS_d=$(dirname "$QWENSTRATAINS_d"); done
  echo "$QWENSTRATAINS_d"
}

preflight() {
  local QWENSTRATAINS_d=${QWENSTRATAINS_VAL[DESTDIR]} QWENSTRATAINS_u=${QWENSTRATAINS_VAL[USER]} QWENSTRATAINS_unit="" QWENSTRATAINS_home QWENSTRATAINS_need QWENSTRATAINS_have QWENSTRATAINS_avail QWENSTRATAINS_mem QWENSTRATAINS_driver
  info "Checking prerequisites"

  # Ports.  The web port may be held by nginx only if it was ours before; the Strata port
  # only by our own service.
  [[ -f $QWENSTRATAINS_NGINX_LINK && ${QWENSTRATAINS_SAVED[WEB_PORT]:-} == "${QWENSTRATAINS_VAL[WEB_PORT]}" ]] && QWENSTRATAINS_unit=nginx.service
  if port_in_use_by_others "${QWENSTRATAINS_VAL[WEB_PORT]}" "$QWENSTRATAINS_unit"; then
    die "TCP port ${QWENSTRATAINS_VAL[WEB_PORT]} is already in use: $(ss -Hltnp "sport = :${QWENSTRATAINS_VAL[WEB_PORT]}" | head -n1)"
  fi
  if port_in_use_by_others "${QWENSTRATAINS_VAL[STRATA_PORT]}" "$QWENSTRATAINS_UNIT"; then
    die "TCP port ${QWENSTRATAINS_VAL[STRATA_PORT]} is already in use: $(ss -Hltnp "sport = :${QWENSTRATAINS_VAL[STRATA_PORT]}" | head -n1)"
  fi

  # Existing destdir must be empty or a previous installation (uninstall removes it).
  if [[ -d $QWENSTRATAINS_d && ! -e $QWENSTRATAINS_d/$QWENSTRATAINS_MARKER ]] && [[ -n $(ls -A "$QWENSTRATAINS_d") ]]; then
    die "$QWENSTRATAINS_d exists and is not empty; choose another directory"
  fi

  # Strata keeps everything under the home directory of the user that runs it.
  if id -u "$QWENSTRATAINS_u" >/dev/null 2>&1; then
    QWENSTRATAINS_home=$(getent passwd "$QWENSTRATAINS_u" | cut -d: -f6)
    [[ ${QWENSTRATAINS_home%/} == "$QWENSTRATAINS_d" ]] \
      || die "user $QWENSTRATAINS_u exists and its home directory is ${QWENSTRATAINS_home:-unset}, not $QWENSTRATAINS_d; choose another user name or destdir (or change it with: usermod -d $QWENSTRATAINS_d $QWENSTRATAINS_u)"
  fi

  grep -qw avx2 /proc/cpuinfo || warn_continue "this CPU does not report AVX2, which Strata needs"

  # Disk space: model files and the rest, minus what destdir already holds.
  QWENSTRATAINS_need=$(($(quant_field 4) * 100 * 1000 * 1000 + QWENSTRATAINS_EXTRA_DISK))
  QWENSTRATAINS_have=0
  [[ ! -d $QWENSTRATAINS_d ]] || QWENSTRATAINS_have=$(($(du -sk "$QWENSTRATAINS_d" 2>/dev/null | cut -f1) * 1024))
  QWENSTRATAINS_need=$((QWENSTRATAINS_need - QWENSTRATAINS_have))
  QWENSTRATAINS_avail=$(($(df --output=avail -k "$(existing_dir "$QWENSTRATAINS_d")" | tail -n1) * 1024))
  if ((QWENSTRATAINS_avail < QWENSTRATAINS_need)); then
    warn_continue "not enough free disk space in $(existing_dir "$QWENSTRATAINS_d"): $(human "$QWENSTRATAINS_avail") available, about $(human "$QWENSTRATAINS_need") more needed for ${QWENSTRATAINS_VAL[QUANT]}"
  fi

  # Memory (MiB), compared as Strata does (MemTotal in GiB against its ram_gb).
  QWENSTRATAINS_mem=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024))
  if ((QWENSTRATAINS_mem < $(quant_field 6) * 1024)); then
    warn_continue "${QWENSTRATAINS_VAL[QUANT]} needs $(quant_field 6) GB of RAM according to Strata, but this machine has $((QWENSTRATAINS_mem / 1024)) GB; it may not start or may be very slow"
  elif ((QWENSTRATAINS_mem < $(quant_field 5) * 1024)); then
    warn "this machine has $((QWENSTRATAINS_mem / 1024)) GB of RAM; ${QWENSTRATAINS_VAL[QUANT]} keeps all experts in RAM from about $(quant_field 5) GB. Strata will read part of them from the SSD, which is much slower."
  fi

  # GPU driver.  Drivers are never installed here.
  if [[ $QWENSTRATAINS_GPU_VENDOR == nvidia ]]; then
    QWENSTRATAINS_driver=$(nvidia_driver_version)
    [[ -n $QWENSTRATAINS_driver ]] || die "nvidia-smi does not work; install the NVIDIA driver first (e.g. sudo ubuntu-drivers install), reboot and re-run"
    version_ge "$QWENSTRATAINS_driver" "$QWENSTRATAINS_NVIDIA_MIN_DRIVER" \
      || die "NVIDIA driver $QWENSTRATAINS_driver is too old: Strata's engines need $QWENSTRATAINS_NVIDIA_MIN_DRIVER or later (CUDA 12) or $QWENSTRATAINS_NVIDIA_CUDA13_DRIVER or later (CUDA 13); update the driver (e.g. sudo ubuntu-drivers install), reboot and re-run"
    if version_ge "$QWENSTRATAINS_driver" "$QWENSTRATAINS_NVIDIA_CUDA13_DRIVER"; then
      info "NVIDIA driver $QWENSTRATAINS_driver: Strata will use its CUDA 13 engine"
    else
      info "NVIDIA driver $QWENSTRATAINS_driver is older than $QWENSTRATAINS_NVIDIA_CUDA13_DRIVER: Strata will use its CUDA 12 engine"
    fi
  else
    [[ -e /dev/kfd ]] || warn_continue "/dev/kfd not found; the amdgpu kernel driver is needed for Strata's AMD engine"
    [[ -e /dev/dri ]] || warn_continue "/dev/dri not found; the amdgpu kernel driver is needed for Strata's AMD engine"
    warn "AMD GPUs have not been tested with this installer"
  fi
}

# ---------------------------------------------------------------- install

install_packages() {
  local QWENSTRATAINS_missing=() QWENSTRATAINS_p
  for QWENSTRATAINS_p in $QWENSTRATAINS_BASE_PACKAGES; do
    [[ $(dpkg-query -W -f='${Status}' "$QWENSTRATAINS_p" 2>/dev/null || true) == "install ok installed" ]] || QWENSTRATAINS_missing+=("$QWENSTRATAINS_p")
  done
  if ((${#QWENSTRATAINS_missing[@]} == 0)); then
    info "Required packages are already installed"
    return 0
  fi
  info "Installing packages: ${QWENSTRATAINS_missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${QWENSTRATAINS_missing[@]}"
}

# The home directory of the service user is destdir: Strata keeps the Terminal, the engine,
# the models, its settings and its state under HOME (XDG default locations).
ensure_user() {
  local QWENSTRATAINS_u=${QWENSTRATAINS_VAL[USER]}
  if id -u "$QWENSTRATAINS_u" >/dev/null 2>&1; then
    info "Using existing user $QWENSTRATAINS_u"
  else
    info "Creating system user $QWENSTRATAINS_u"
    useradd --system --user-group --no-create-home --home-dir "${QWENSTRATAINS_VAL[DESTDIR]}" --shell /usr/sbin/nologin "$QWENSTRATAINS_u"
  fi
}

# Everything in destdir belongs to the service user: Strata refuses folders of other users.
prepare_destdir() {
  local QWENSTRATAINS_d=${QWENSTRATAINS_VAL[DESTDIR]} QWENSTRATAINS_u=${QWENSTRATAINS_VAL[USER]}
  install -d -m 0755 "$QWENSTRATAINS_d"
  touch "$QWENSTRATAINS_d/$QWENSTRATAINS_MARKER"
  chown -R "$QWENSTRATAINS_u:$QWENSTRATAINS_u" "$QWENSTRATAINS_d"
}

# run_as KEY USER HOME COMMAND [ARGS...]: run a command as the service user with a clean
# environment, HOME set to destdir and Strata pinned to the release.  KEY=yes also passes
# the API key as STRATA_API_KEY (in the environment, never on a command line).
run_as() {
  local QWENSTRATAINS_with_key=$1 QWENSTRATAINS_user=$2 QWENSTRATAINS_home=$3
  shift 3
  (
    cd "$QWENSTRATAINS_home" || exit 1
    QWENSTRATAINS_term=${TERM:-dumb}
    for QWENSTRATAINS_v in $(compgen -e); do unset "$QWENSTRATAINS_v" 2>/dev/null || true; done
    # Quoted as whole words: shellcheck otherwise takes this USER for the key USER of
    # QWENSTRATAINS_VAL used elsewhere (SC2030/SC2031).
    export "HOME=$QWENSTRATAINS_home" "USER=$QWENSTRATAINS_user" "LOGNAME=$QWENSTRATAINS_user"
    export PATH="$QWENSTRATAINS_home/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export LANG=C.UTF-8 TERM=$QWENSTRATAINS_term
    export STRATA_FEED=$QWENSTRATAINS_STRATA_FEED STRATA_UPDATE_FEED=$QWENSTRATAINS_STRATA_FEED
    export STRATA_UPDATE_CHECK=0 STRATA_NO_HANDOVER=1 STRATA_FEED_MODELS=0
    [[ $QWENSTRATAINS_with_key != yes ]] || export STRATA_API_KEY=$QWENSTRATAINS_API_KEY
    exec runuser -u "$QWENSTRATAINS_user" -- "$@"
  )
}

strata_bin() { echo "${QWENSTRATAINS_VAL[DESTDIR]}/.local/bin/strata"; }

# strata ARGS...: run the installed strata as the service user.
strata() { run_as no "${QWENSTRATAINS_VAL[USER]}" "${QWENSTRATAINS_VAL[DESTDIR]}" "$(strata_bin)" "$@"; }

# "strata launch" fails unless the port and the GPU are free, so the service must be stopped
# before it runs (a model started by "strata serve" is invisible to "strata launch").
stop_service() {
  service_exists "$QWENSTRATAINS_UNIT" || return 0
  # Always: a unit waiting for its automatic restart is neither active nor failed.
  info "Stopping $QWENSTRATAINS_UNIT"
  systemctl stop "$QWENSTRATAINS_UNIT" || die "cannot stop $QWENSTRATAINS_UNIT"
}

# unit_in_use UNIT: is a unit of another installer running, starting, waiting for its
# automatic restart, or enabled at boot?
unit_in_use() {
  service_exists "$1" || return 1
  if systemctl is-enabled --quiet "$1" 2>/dev/null; then return 0; fi
  case $(systemctl show -p ActiveState --value "$1" 2>/dev/null || true) in
    ""|inactive|failed) return 1 ;;
  esac
  return 0
}

# Print the units of the other installers that are in use, one per line.
exclusive_units_in_use() {
  local QWENSTRATAINS_x
  for QWENSTRATAINS_x in $QWENSTRATAINS_EXCLUSIVE_UNITS; do
    if unit_in_use "$QWENSTRATAINS_x"; then echo "$QWENSTRATAINS_x"; fi
  done
}

# deepseek-maya and glm-maya are not meant to run at the same time as this service: each
# needs a GPU and most of the RAM.  They are stopped and disabled before "strata launch"
# (which is not a unit start, so Conflicts= does not stop them); --uninstall prints how to
# enable them again.  Their files are never touched.
disable_exclusive_units() {
  local QWENSTRATAINS_x
  for QWENSTRATAINS_x in $QWENSTRATAINS_EXCLUSIVE_UNITS; do
    unit_in_use "$QWENSTRATAINS_x" || continue
    info "Stopping and disabling $QWENSTRATAINS_x (it does not run together with $QWENSTRATAINS_UNIT)"
    systemctl disable --now "$QWENSTRATAINS_x" || die "cannot stop $QWENSTRATAINS_x"
  done
}

# Install the Strata Terminal with Strata's own install.sh from the pinned release.
install_strata() {
  local QWENSTRATAINS_d=${QWENSTRATAINS_VAL[DESTDIR]} QWENSTRATAINS_term QWENSTRATAINS_sh QWENSTRATAINS_sum
  QWENSTRATAINS_term="$QWENSTRATAINS_d/.local/share/strata/terminal/$QWENSTRATAINS_STRATA_TERMINAL_VERSION/bin/strata"
  if [[ -x $QWENSTRATAINS_term && -e $(strata_bin) && $(readlink -f "$(strata_bin)") == "$(readlink -f "$QWENSTRATAINS_term")" ]] \
     && strata --version >/dev/null 2>&1 </dev/null; then
    info "Strata Terminal $QWENSTRATAINS_STRATA_TERMINAL_VERSION is already installed"
    return 0
  fi
  info "Downloading Strata's install.sh ($QWENSTRATAINS_STRATA_FEED)"
  QWENSTRATAINS_TMP=$(mktemp -d /tmp/qwen-strata-install.XXXXXX)
  chmod 0755 "$QWENSTRATAINS_TMP"
  QWENSTRATAINS_sh="$QWENSTRATAINS_TMP/install.sh"
  curl --fail --silent --show-error --location --retry 5 --retry-delay 5 --output "$QWENSTRATAINS_sh" "$QWENSTRATAINS_STRATA_FEED/install.sh" \
    || die "download failed: $QWENSTRATAINS_STRATA_FEED/install.sh"
  QWENSTRATAINS_sum=$(sha256_of "$QWENSTRATAINS_sh")
  [[ $QWENSTRATAINS_sum == "$QWENSTRATAINS_STRATA_INSTALL_SHA256" ]] \
    || die "checksum mismatch for Strata's install.sh (got $QWENSTRATAINS_sum, expected $QWENSTRATAINS_STRATA_INSTALL_SHA256); it was not run"
  chmod 0644 "$QWENSTRATAINS_sh"
  info "Running Strata's install.sh as ${QWENSTRATAINS_VAL[USER]}"
  run_as no "${QWENSTRATAINS_VAL[USER]}" "$QWENSTRATAINS_d" sh "$QWENSTRATAINS_sh" </dev/null \
    || die "Strata's install.sh failed"
  cleanup_tmp; QWENSTRATAINS_TMP=""
  [[ -x $(strata_bin) ]] || die "Strata's install.sh did not install $(strata_bin)"
}

# Keep the API key across re-runs so that clients keep working.  strata.env is read by
# systemd (EnvironmentFile) and may be read by the service user; nginx-key.conf is included
# by the nginx site and defines $qwenstrata_bearer.
# shellcheck disable=SC2016
write_key_files() {
  local QWENSTRATAINS_key=""
  install -d -m 0755 "$QWENSTRATAINS_CONF_DIR"
  [[ ! -f $QWENSTRATAINS_ENV_FILE ]] || QWENSTRATAINS_key=$(sed -n 's/^STRATA_API_KEY=//p;T;q' "$QWENSTRATAINS_ENV_FILE")
  if [[ $QWENSTRATAINS_key =~ ^[A-Za-z0-9_-]{24,128}$ ]]; then
    info "Keeping the existing API key"
  else
    info "Generating an API key"
    QWENSTRATAINS_key="sk-qwenstrata-$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
  fi
  QWENSTRATAINS_API_KEY=$QWENSTRATAINS_key
  ( umask 077
    printf 'STRATA_API_KEY=%s\n' "$QWENSTRATAINS_key" > "$QWENSTRATAINS_ENV_FILE.tmp"
    printf '# Generated by install-qwen-strata.sh; changes are overwritten on re-run.\nset $qwenstrata_bearer "Bearer %s";\n' "$QWENSTRATAINS_key" > "$QWENSTRATAINS_NGINX_KEY_FILE.tmp" )
  chown "root:${QWENSTRATAINS_VAL[USER]}" "$QWENSTRATAINS_ENV_FILE.tmp"
  chmod 0640 "$QWENSTRATAINS_ENV_FILE.tmp"
  chown root:root "$QWENSTRATAINS_NGINX_KEY_FILE.tmp"
  chmod 0600 "$QWENSTRATAINS_NGINX_KEY_FILE.tmp"
  mv -f "$QWENSTRATAINS_ENV_FILE.tmp" "$QWENSTRATAINS_ENV_FILE"
  mv -f "$QWENSTRATAINS_NGINX_KEY_FILE.tmp" "$QWENSTRATAINS_NGINX_KEY_FILE"
}

wait_port_free() {  # wait_port_free PORT SECONDS
  local QWENSTRATAINS_start=$SECONDS
  until port_free "$1"; do
    ((SECONDS - QWENSTRATAINS_start < $2)) || return 1
    sleep 1
  done
}

# Let "strata launch" download the engine and the model, write the configuration (run
# configuration, profile launch-qwen-strata, preset qwen-strata), tune if asked, and
# test-start the model; then stop that model again, because systemd runs "strata serve".
launch_model() {
  local QWENSTRATAINS_d=${QWENSTRATAINS_VAL[DESTDIR]} QWENSTRATAINS_port=${QWENSTRATAINS_VAL[STRATA_PORT]} QWENSTRATAINS_gpus QWENSTRATAINS_args QWENSTRATAINS_rc=0
  QWENSTRATAINS_gpus=$(gpu_indices)
  # A model left running by an interrupted earlier run would make the launch refuse.
  strata launch --stop --preset "$QWENSTRATAINS_PRESET" >/dev/null 2>&1 </dev/null || true
  wait_port_free "$QWENSTRATAINS_port" 60 || die "TCP port $QWENSTRATAINS_port is still in use: $(ss -Hltnp "sport = :$QWENSTRATAINS_port" | head -n1)"
  QWENSTRATAINS_args=(launch --family "$(quant_field 1)" --model "$(quant_field 2)"
    --context "${QWENSTRATAINS_VAL[CTX_SIZE]}" --kv "${QWENSTRATAINS_VAL[KV]}"
    --gpu "$QWENSTRATAINS_gpus" --backend "$QWENSTRATAINS_GPU_VENDOR" --tune "${QWENSTRATAINS_VAL[TUNE]}"
    --access local --port "$QWENSTRATAINS_port" --api-key-env STRATA_API_KEY
    --save-preset "$QWENSTRATAINS_PRESET" --feed "$QWENSTRATAINS_STRATA_FEED" --yes --no-tui)
  info "Running strata ${QWENSTRATAINS_args[*]}"
  info "This downloads the engine and the model (${QWENSTRATAINS_VAL[QUANT]}), prepares them and test-starts the model; it can take hours"
  run_as yes "${QWENSTRATAINS_VAL[USER]}" "$QWENSTRATAINS_d" "$(strata_bin)" "${QWENSTRATAINS_args[@]}" </dev/null || QWENSTRATAINS_rc=$?
  ((QWENSTRATAINS_rc == 0)) || die "strata launch failed (exit code $QWENSTRATAINS_rc); fix the problem reported above and re-run the installer (downloads are resumed)"
  # "strata launch" also exits 0 when it found no engine for this computer and started nothing.
  [[ -f $QWENSTRATAINS_d/.config/strata/profiles/$QWENSTRATAINS_PROFILE.json && -f $QWENSTRATAINS_d/.local/state/strata/launch/$QWENSTRATAINS_PRESET.json ]] \
    || die "strata launch did not write the profile $QWENSTRATAINS_PROFILE (see its messages above; is there an engine for this GPU?)"
  info "Stopping the model started by strata launch (the systemd service starts it again)"
  strata launch --stop --preset "$QWENSTRATAINS_PRESET" </dev/null || warn "strata launch --stop reported a problem"
  wait_port_free "$QWENSTRATAINS_port" 200 || die "the model started by strata launch still holds TCP port $QWENSTRATAINS_port"
}

write_unit() {
  local QWENSTRATAINS_u=${QWENSTRATAINS_VAL[USER]} QWENSTRATAINS_d=${QWENSTRATAINS_VAL[DESTDIR]} QWENSTRATAINS_groups="" QWENSTRATAINS_g
  for QWENSTRATAINS_g in video render; do
    if getent group "$QWENSTRATAINS_g" >/dev/null; then QWENSTRATAINS_groups+=" $QWENSTRATAINS_g"; fi
  done
  info "Writing the systemd unit"
  # KillMode=mixed: only "strata serve" gets SIGTERM; it drains the requests and ends its
  # engine itself.  TimeoutStopSec covers its drain (30 s) and its engine shutdown (up to
  # about 50 s more).
  # After= the plamo-3-translate services: the engine pins the model in the RAM that is free
  # at its start, so they come first.  The llama unit of plamo-3-translate stays "activating"
  # until its model is loaded, and a start of this unit waits for that.  Conflicts=
  # deepseek-maya and glm-maya: starting one stops the other.  Both are ignored when those
  # units are not installed.
  # Sandboxing is light on purpose until tested on real hardware.
  cat > "$QWENSTRATAINS_UNIT_DIR/$QWENSTRATAINS_UNIT" <<EOF
# Generated by install-qwen-strata.sh; changes are overwritten on re-run.
[Unit]
Description=Qwen3.8-Flash-Next on Strata (strata serve)
After=network-online.target $QWENSTRATAINS_PLAMO_UNITS
Wants=network-online.target
Conflicts=$QWENSTRATAINS_EXCLUSIVE_UNITS

[Service]
Type=simple
User=$QWENSTRATAINS_u
Group=$QWENSTRATAINS_u
${QWENSTRATAINS_groups:+SupplementaryGroups=${QWENSTRATAINS_groups# }
}WorkingDirectory=$QWENSTRATAINS_d
Environment=HOME=$QWENSTRATAINS_d
Environment=PATH=$QWENSTRATAINS_d/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LANG=C.UTF-8
Environment=STRATA_UPDATE_FEED=$QWENSTRATAINS_STRATA_FEED
Environment=STRATA_UPDATE_CHECK=0
Environment=STRATA_NO_HANDOVER=1
Environment=STRATA_FEED_MODELS=0
EnvironmentFile=$QWENSTRATAINS_ENV_FILE
ExecStart=$QWENSTRATAINS_d/.local/bin/strata serve --profile $QWENSTRATAINS_PROFILE --host 127.0.0.1 --port ${QWENSTRATAINS_VAL[STRATA_PORT]}
Restart=on-failure
RestartSec=10
TimeoutStartSec=infinity
TimeoutStopSec=150
KillMode=mixed
LimitMEMLOCK=infinity
LimitRTTIME=infinity
NoNewPrivileges=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$QWENSTRATAINS_UNIT_DIR/$QWENSTRATAINS_UNIT"
}

# Strata appends to the engine log for ever; rotate it in place.
write_logrotate() {
  cat > "$QWENSTRATAINS_LOGROTATE_FILE" <<EOF
# Generated by install-qwen-strata.sh; changes are overwritten on re-run.
${QWENSTRATAINS_VAL[DESTDIR]}/.local/state/strata/launch/$QWENSTRATAINS_PRESET.engine.log {
    su ${QWENSTRATAINS_VAL[USER]} ${QWENSTRATAINS_VAL[USER]}
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
  chmod 0644 "$QWENSTRATAINS_LOGROTATE_FILE"
}

# nginx_location PATH MODE: print a location for an exact path.  MODE: add (nginx adds the
# API key), chat (per request, see nginx_site) or pass (the client's own headers).  The
# fixed URI in proxy_pass makes Strata see exactly the path nginx matched.
# shellcheck disable=SC2016
nginx_location() {
  local QWENSTRATAINS_auth="" QWENSTRATAINS_up="http://127.0.0.1:${QWENSTRATAINS_VAL[STRATA_PORT]}"
  case $2 in
    add) QWENSTRATAINS_auth='        proxy_set_header Authorization $qwenstrata_bearer;
        proxy_set_header X-Api-Key "";' ;;
    chat) QWENSTRATAINS_auth='        proxy_set_header Authorization $qwenstrata_chat_auth;
        proxy_set_header X-Api-Key $qwenstrata_chat_xkey;' ;;
  esac
  if [[ -z $QWENSTRATAINS_auth ]]; then
    printf '    location = %s {\n        proxy_pass %s%s;\n    }\n' "$1" "$QWENSTRATAINS_up" "$1"
  else
    # proxy_set_header is inherited only as a whole, so the server-level ones are repeated.
    printf '    location = %s {\n        proxy_pass %s%s;\n        proxy_set_header Host $http_host;\n        proxy_set_header X-Forwarded-Proto $scheme;\n%s\n    }\n' \
      "$1" "$QWENSTRATAINS_up" "$1" "$QWENSTRATAINS_auth"
  fi
}

# Print the nginx site.  Strata always has an API key; nginx adds it to the requests that
# may be made without one:
#   web page (/metrics)                      unless --web-api-key
#   agents (/v1/messages, /v1/models, ...)   unless --agent-api-key
#   /v1/chat/completions (used by both)      by both settings; when they differ, a request
#       counts as the web page's if the browser says so: Sec-Fetch-Site: same-origin, or
#       (browsers send Sec-Fetch-* only to HTTPS and localhost) an Origin equal to the Host.
#       Other clients can forge these headers.
# Everything else, including all management paths, is passed on with the client's own
# headers, so Strata demands the key there.  Unknown paths therefore fail safe.
nginx_site() {
  local QWENSTRATAINS_port=${QWENSTRATAINS_VAL[WEB_PORT]} QWENSTRATAINS_web=${QWENSTRATAINS_VAL[WEB_API_KEY]} QWENSTRATAINS_agent=${QWENSTRATAINS_VAL[AGENT_API_KEY]}
  local QWENSTRATAINS_listen QWENSTRATAINS_a QWENSTRATAINS_web_mode=add QWENSTRATAINS_agent_mode=add QWENSTRATAINS_chat_mode QWENSTRATAINS_page QWENSTRATAINS_p
  if [[ ${QWENSTRATAINS_VAL[INTERFACES]} == all ]]; then
    QWENSTRATAINS_listen="    listen $QWENSTRATAINS_port;"
    [[ ! -e /proc/net/if_inet6 ]] || QWENSTRATAINS_listen+=$'\n'"    listen [::]:$QWENSTRATAINS_port;"
  else
    QWENSTRATAINS_listen="    listen 127.0.0.1:$QWENSTRATAINS_port;"
    [[ ! -e /proc/net/if_inet6 ]] || QWENSTRATAINS_listen+=$'\n'"    listen [::1]:$QWENSTRATAINS_port;"
    while read -r QWENSTRATAINS_a; do
      [[ -n $QWENSTRATAINS_a ]] || continue
      if [[ $QWENSTRATAINS_a == *:* ]]; then QWENSTRATAINS_listen+=$'\n'"    listen [$QWENSTRATAINS_a]:$QWENSTRATAINS_port;"
      else QWENSTRATAINS_listen+=$'\n'"    listen $QWENSTRATAINS_a:$QWENSTRATAINS_port;"; fi
    done <<<"$(listen_addresses)"
  fi
  [[ $QWENSTRATAINS_web != yes ]] || QWENSTRATAINS_web_mode=pass
  [[ $QWENSTRATAINS_agent != yes ]] || QWENSTRATAINS_agent_mode=pass
  if [[ $QWENSTRATAINS_web == "$QWENSTRATAINS_agent" ]]; then QWENSTRATAINS_chat_mode=$QWENSTRATAINS_web_mode; else QWENSTRATAINS_chat_mode=chat; fi

  echo "# Generated by install-qwen-strata.sh; changes are overwritten on re-run."
  echo "# API key: web page $(key_label "$QWENSTRATAINS_web"), agents $(key_label "$QWENSTRATAINS_agent"), management always required."
  if [[ $QWENSTRATAINS_chat_mode == chat ]]; then
    # 1 = the request comes from the web page; the key is added for that side only.
    QWENSTRATAINS_page=1
    [[ $QWENSTRATAINS_web != yes ]] || QWENSTRATAINS_page=0
    cat <<EOF

map "\$http_sec_fetch_site|\$http_origin|\$http_host" \$qwenstrata_from_page {
    default 0;
    "~^same-origin\\|" 1;
    "~^\\|https?://([^|]+)\\|\\1\$" 1;
}
map \$qwenstrata_from_page \$qwenstrata_chat_auth {
    default \$http_authorization;
    $QWENSTRATAINS_page \$qwenstrata_bearer;
}
map \$qwenstrata_from_page \$qwenstrata_chat_xkey {
    default \$http_x_api_key;
    $QWENSTRATAINS_page "";
}
EOF
  fi
  cat <<EOF

server {
$QWENSTRATAINS_listen
    server_name _;

    # Strata accepts request bodies up to 256 MiB (pictures are sent inline).
    client_max_body_size 256m;
    # Streamed answers; long generations and long waits for a free slot.
    proxy_buffering off;
    proxy_read_timeout 3660s;
    proxy_send_timeout 3660s;
    # Strata compares the Origin of management requests with the Host header, port included.
    proxy_set_header Host \$http_host;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Defines \$qwenstrata_bearer ("Bearer <API key>"); readable by root only.
    include $QWENSTRATAINS_NGINX_KEY_FILE;

    # The web page, /health and everything not listed below, with the client's own headers.
    location / {
        proxy_pass http://127.0.0.1:${QWENSTRATAINS_VAL[STRATA_PORT]};
    }

    # Read by the web page every second.
EOF
  nginx_location /metrics "$QWENSTRATAINS_web_mode"
  printf '\n    # Used by the web page and by agents.\n'
  nginx_location /v1/chat/completions "$QWENSTRATAINS_chat_mode"
  printf '\n    # Used by agents.\n'
  for QWENSTRATAINS_p in /v1/messages /v1/messages/count_tokens /v1/responses /v1/models /models /v1/v1/messages /v1/v1/messages/count_tokens; do
    nginx_location "$QWENSTRATAINS_p" "$QWENSTRATAINS_agent_mode"
  done
  echo "}"
}

write_nginx() {
  info "Writing nginx site configuration"
  nginx_site > "$QWENSTRATAINS_NGINX_SITE"
  chmod 0644 "$QWENSTRATAINS_NGINX_SITE"
  ln -sfn "$QWENSTRATAINS_NGINX_SITE" "$QWENSTRATAINS_NGINX_LINK"
  if ! nginx -t 2>&1; then
    # Do not leave a broken site enabled: it would stop other sites from being reloaded.
    rm -f "$QWENSTRATAINS_NGINX_LINK"
    die "nginx configuration test failed; the site $QWENSTRATAINS_APP_NAME was disabled again (see $QWENSTRATAINS_NGINX_SITE)"
  fi
}

start_services() {
  local QWENSTRATAINS_u
  info "Starting services"
  systemctl daemon-reload
  systemctl enable "$QWENSTRATAINS_UNIT" nginx.service
  systemctl reset-failed "$QWENSTRATAINS_UNIT" 2>/dev/null || true
  # The start waits for units this one is ordered after while they are being started.
  for QWENSTRATAINS_u in $QWENSTRATAINS_PLAMO_UNITS; do
    [[ $(systemctl show -p ActiveState --value "$QWENSTRATAINS_u" 2>/dev/null || true) != activating ]] \
      || info "$QWENSTRATAINS_u is still starting (loading its model); $QWENSTRATAINS_UNIT is started when it has finished"
  done
  systemctl restart "$QWENSTRATAINS_UNIT" || {
    journalctl -u "$QWENSTRATAINS_UNIT" -n 30 --no-pager >&2 || true
    die "failed to start $QWENSTRATAINS_UNIT"
  }
  if systemctl is-active --quiet nginx.service; then
    systemctl reload nginx.service
  else
    systemctl start nginx.service
  fi
}

# --------------------------------------------------------------------- ufw

ufw_active() {
  local QWENSTRATAINS_status
  command -v ufw >/dev/null 2>&1 || return 1
  QWENSTRATAINS_status=$(ufw status 2>/dev/null) || return 1
  grep -q '^Status: active$' <<<"$QWENSTRATAINS_status"
}

# Print the ufw rules needed for the web server: PORT, or PORT@INTERFACE when the
# interfaces are restricted.  Strata itself listens on 127.0.0.1 only.
ufw_wanted_rules() {
  local QWENSTRATAINS_ifc QWENSTRATAINS_p=${QWENSTRATAINS_VAL[WEB_PORT]}
  if [[ ${QWENSTRATAINS_VAL[INTERFACES]} == all ]]; then
    echo "$QWENSTRATAINS_p"
  else
    for QWENSTRATAINS_ifc in ${QWENSTRATAINS_VAL[INTERFACES]//,/ }; do echo "$QWENSTRATAINS_p@$QWENSTRATAINS_ifc"; done
  fi
}

# Print the wanted rules that ufw does not allow yet (a rule for all interfaces covers
# every interface).
ufw_closed_ports() {
  local QWENSTRATAINS_status QWENSTRATAINS_r QWENSTRATAINS_p QWENSTRATAINS_ifc
  QWENSTRATAINS_status=$(ufw status 2>/dev/null || true)
  while read -r QWENSTRATAINS_r; do
    [[ -n $QWENSTRATAINS_r ]] || continue
    QWENSTRATAINS_p=${QWENSTRATAINS_r%%@*}
    grep -Eq "^$QWENSTRATAINS_p(/tcp)?[[:space:]]+ALLOW" <<<"$QWENSTRATAINS_status" && continue
    if [[ $QWENSTRATAINS_r == *@* ]]; then
      QWENSTRATAINS_ifc=${QWENSTRATAINS_r#*@}
      grep -Eq "^$QWENSTRATAINS_p(/tcp)? on ${QWENSTRATAINS_ifc//./\\.}[[:space:]]+ALLOW" <<<"$QWENSTRATAINS_status" && continue
    fi
    echo "$QWENSTRATAINS_r"
  done <<<"$(ufw_wanted_rules)"
}

# Human-readable form of rules: "38080/tcp, 38080/tcp on bond0".
ufw_rules_text() {
  local QWENSTRATAINS_r QWENSTRATAINS_text=""
  for QWENSTRATAINS_r in "$@"; do
    if [[ $QWENSTRATAINS_r == *@* ]]; then QWENSTRATAINS_text+="${QWENSTRATAINS_text:+, }${QWENSTRATAINS_r%%@*}/tcp on ${QWENSTRATAINS_r#*@}"
    else QWENSTRATAINS_text+="${QWENSTRATAINS_text:+, }$QWENSTRATAINS_r/tcp"; fi
  done
  echo "$QWENSTRATAINS_text"
}

# ufw arguments for a rule (used with "ufw" and "ufw delete").
ufw_rule_args() {
  if [[ $1 == *@* ]]; then
    echo "allow in on ${1#*@} to any port ${1%%@*} proto tcp"
  else
    echo "allow ${1}/tcp"
  fi
}

# Ask about ufw together with the other questions.  configure_ufw asks again only if
# this was not answered (e.g. ufw was enabled after the questions).
prompt_ufw() {
  local QWENSTRATAINS_ports
  [[ -z $QWENSTRATAINS_OPEN_PORTS && $QWENSTRATAINS_INTERACTIVE == yes && $QWENSTRATAINS_ASSUME_YES != yes ]] || return 0
  ufw_active || return 0
  QWENSTRATAINS_ports=$(ufw_closed_ports | paste -sd' ' -)
  [[ -n $QWENSTRATAINS_ports ]] || return 0
  # shellcheck disable=SC2086
  if confirm "ufw is active. Allow incoming $(ufw_rules_text $QWENSTRATAINS_ports)?"; then
    QWENSTRATAINS_OPEN_PORTS=yes
  else
    QWENSTRATAINS_OPEN_PORTS=no
  fi
}

ufw_label() {
  local QWENSTRATAINS_ports
  if ! ufw_active; then echo "no (ufw is not active)"; return 0; fi
  QWENSTRATAINS_ports=$(ufw_closed_ports | paste -sd' ' -)
  # shellcheck disable=SC2086
  QWENSTRATAINS_ports=$(ufw_rules_text $QWENSTRATAINS_ports)
  if [[ -z $QWENSTRATAINS_ports ]]; then echo "no (already allowed)"
  elif [[ $QWENSTRATAINS_OPEN_PORTS == yes || ( -z $QWENSTRATAINS_OPEN_PORTS && $QWENSTRATAINS_ASSUME_YES == yes ) ]]; then echo "yes ($QWENSTRATAINS_ports)"
  elif [[ $QWENSTRATAINS_OPEN_PORTS == no ]]; then echo "no ($QWENSTRATAINS_ports stay closed)"
  else echo "ask later ($QWENSTRATAINS_ports)"
  fi
}

configure_ufw() {
  local QWENSTRATAINS_ports QWENSTRATAINS_p QWENSTRATAINS_wanted QWENSTRATAINS_kept=""
  QWENSTRATAINS_UFW_RULES=${QWENSTRATAINS_SAVED[UFW_RULES]:-}
  ufw_active || return 0
  # Remove rules this installer added earlier that are no longer wanted (another port,
  # or a rule for all interfaces after restricting the interfaces).
  QWENSTRATAINS_wanted=" $(ufw_wanted_rules | paste -sd' ' -) "
  for QWENSTRATAINS_p in $QWENSTRATAINS_UFW_RULES; do
    if [[ $QWENSTRATAINS_wanted == *" $QWENSTRATAINS_p "* ]]; then
      QWENSTRATAINS_kept+="${QWENSTRATAINS_kept:+ }$QWENSTRATAINS_p"
    else
      # shellcheck disable=SC2046
      ufw delete $(ufw_rule_args "$QWENSTRATAINS_p") >/dev/null 2>&1 || true
      info "Removed the ufw rule for $(ufw_rules_text "$QWENSTRATAINS_p") added by a previous installation"
    fi
  done
  QWENSTRATAINS_UFW_RULES=$QWENSTRATAINS_kept
  QWENSTRATAINS_ports=$(ufw_closed_ports | paste -sd' ' -)
  if [[ -z $QWENSTRATAINS_ports ]]; then
    info "ufw already allows the required port(s)"
    return 0
  fi
  # shellcheck disable=SC2086
  if [[ $QWENSTRATAINS_OPEN_PORTS == yes ]] ||
     { [[ -z $QWENSTRATAINS_OPEN_PORTS ]] && confirm "ufw is active. Allow incoming $(ufw_rules_text $QWENSTRATAINS_ports)?"; }; then
    for QWENSTRATAINS_p in $QWENSTRATAINS_ports; do
      # shellcheck disable=SC2046
      ufw $(ufw_rule_args "$QWENSTRATAINS_p") comment "$QWENSTRATAINS_APP_NAME" >/dev/null
      [[ " $QWENSTRATAINS_UFW_RULES " == *" $QWENSTRATAINS_p "* ]] || QWENSTRATAINS_UFW_RULES=${QWENSTRATAINS_UFW_RULES:+$QWENSTRATAINS_UFW_RULES }$QWENSTRATAINS_p
    done
    # shellcheck disable=SC2086
    info "Allowed $(ufw_rules_text $QWENSTRATAINS_ports) in ufw"
  else
    # shellcheck disable=SC2086
    warn "ufw is active and $(ufw_rules_text $QWENSTRATAINS_ports) were not allowed; other hosts cannot connect"
  fi
}

save_config() {
  local QWENSTRATAINS_key
  install -d -m 0755 "$QWENSTRATAINS_CONF_DIR"
  {
    echo "# Written by install-qwen-strata.sh; used as defaults on re-run and by --uninstall."
    for QWENSTRATAINS_key in $QWENSTRATAINS_KEYS; do printf "%s='%s'\n" "$QWENSTRATAINS_key" "${QWENSTRATAINS_VAL[$QWENSTRATAINS_key]}"; done
    printf "UFW_RULES='%s'\n" "$QWENSTRATAINS_UFW_RULES"
  } > "$QWENSTRATAINS_CONF_FILE.tmp"
  chmod 0644 "$QWENSTRATAINS_CONF_FILE.tmp"
  mv -f "$QWENSTRATAINS_CONF_FILE.tmp" "$QWENSTRATAINS_CONF_FILE"
}

# -------------------------------------------------------------------- tests

# http_code URL [curl options...]: print the HTTP status of a GET.
http_code() {
  local QWENSTRATAINS_url=$1
  shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@" "$QWENSTRATAINS_url" || true
}

# "strata serve" opens its port only after the engine has loaded the model.
wait_health() {
  local QWENSTRATAINS_url="http://127.0.0.1:${QWENSTRATAINS_VAL[STRATA_PORT]}/health" QWENSTRATAINS_start QWENSTRATAINS_body=""
  info "Waiting for Strata to load the model (up to ${QWENSTRATAINS_HEALTH_TIMEOUT}s)"
  QWENSTRATAINS_start=$SECONDS
  while :; do
    QWENSTRATAINS_body=$(curl -s --fail --max-time 5 "$QWENSTRATAINS_url" 2>/dev/null || true)
    [[ $QWENSTRATAINS_body =~ \"loaded\":\ *true ]] && break
    # Restart=on-failure would hide a crash; any restart or inactive state is a failure.
    if [[ $(systemctl show -p ActiveState --value "$QWENSTRATAINS_UNIT") != active ||
          $(systemctl show -p NRestarts --value "$QWENSTRATAINS_UNIT") != 0 ]]; then
      journalctl -u "$QWENSTRATAINS_UNIT" -n 40 --no-pager >&2 || true
      die "Strata is not running (see journalctl -u $QWENSTRATAINS_UNIT and ${QWENSTRATAINS_VAL[DESTDIR]}/.local/state/strata/launch/$QWENSTRATAINS_PRESET.engine.log)"
    fi
    if ((SECONDS - QWENSTRATAINS_start > QWENSTRATAINS_HEALTH_TIMEOUT)); then
      journalctl -u "$QWENSTRATAINS_UNIT" -n 40 --no-pager >&2 || true
      die "Strata did not become ready within ${QWENSTRATAINS_HEALTH_TIMEOUT}s"
    fi
    sleep 2
  done
  QWENSTRATAINS_MODEL_ID=$(sed -n 's/.*"model": *"\([^"]*\)".*/\1/p' <<<"$QWENSTRATAINS_body" | head -n1)
  QWENSTRATAINS_N_CTX=$(sed -n 's/.*"max_context": *\([0-9]*\).*/\1/p' <<<"$QWENSTRATAINS_body" | head -n1)
  info "Strata is ready ($((SECONDS - QWENSTRATAINS_start))s): model ${QWENSTRATAINS_MODEL_ID:-unknown}, context ${QWENSTRATAINS_N_CTX:-unknown}"
}

# expect_code DESCRIPTION EXPECTED URL [curl options...]
expect_code() {
  local QWENSTRATAINS_what=$1 QWENSTRATAINS_want=$2 QWENSTRATAINS_got
  shift 2
  QWENSTRATAINS_got=$(http_code "$@")
  [[ $QWENSTRATAINS_got == "$QWENSTRATAINS_want" ]] || die "test failed: $QWENSTRATAINS_what: HTTP ${QWENSTRATAINS_got:-none}, expected $QWENSTRATAINS_want"
  info "Test passed: $QWENSTRATAINS_what (HTTP $QWENSTRATAINS_got)"
}

smoke_test() {
  local QWENSTRATAINS_base="http://127.0.0.1:${QWENSTRATAINS_VAL[WEB_PORT]}" QWENSTRATAINS_auth QWENSTRATAINS_want QWENSTRATAINS_out QWENSTRATAINS_code
  wait_health
  QWENSTRATAINS_auth="Authorization: Bearer $QWENSTRATAINS_API_KEY"
  info "Testing through the web server (port ${QWENSTRATAINS_VAL[WEB_PORT]})"
  expect_code "/health" 200 "$QWENSTRATAINS_base/health"
  expect_code "web page" 200 "$QWENSTRATAINS_base/"
  expect_code "management path /config without the API key is refused" 401 "$QWENSTRATAINS_base/config"
  expect_code "management path /config with the API key" 200 "$QWENSTRATAINS_base/config" -H "$QWENSTRATAINS_auth"
  QWENSTRATAINS_want=200; [[ ${QWENSTRATAINS_VAL[WEB_API_KEY]} != yes ]] || QWENSTRATAINS_want=401
  expect_code "/metrics without the API key (web page: $(key_label "${QWENSTRATAINS_VAL[WEB_API_KEY]}"))" "$QWENSTRATAINS_want" "$QWENSTRATAINS_base/metrics"
  QWENSTRATAINS_want=200; [[ ${QWENSTRATAINS_VAL[AGENT_API_KEY]} != yes ]] || QWENSTRATAINS_want=401
  expect_code "/v1/models without the API key (agents: $(key_label "${QWENSTRATAINS_VAL[AGENT_API_KEY]}"))" "$QWENSTRATAINS_want" "$QWENSTRATAINS_base/v1/models"
  info "Requesting a short chat completion"
  QWENSTRATAINS_out=$(curl -s -w '\n%{http_code}' --max-time 600 -H 'Content-Type: application/json' -H "$QWENSTRATAINS_auth" \
    -d "{\"model\": \"${QWENSTRATAINS_MODEL_ID:-qwen3.8-flash-next}\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello.\"}], \"max_tokens\": 32}" \
    "$QWENSTRATAINS_base/v1/chat/completions") || die "cannot connect to the web server on port ${QWENSTRATAINS_VAL[WEB_PORT]}"
  QWENSTRATAINS_code=${QWENSTRATAINS_out##*$'\n'}; QWENSTRATAINS_out=${QWENSTRATAINS_out%$'\n'*}
  [[ $QWENSTRATAINS_code == 200 ]] || die "chat completion test failed (HTTP $QWENSTRATAINS_code): ${QWENSTRATAINS_out:0:500}"
  info "Test passed: chat completion (HTTP 200)"
}

# Offer to delete the model files of other quantizations.  Shards shared between
# quantizations are hard links, so deleting one folder does not break another.  Asked only
# interactively: --yes does not delete downloads.
cleanup_old_models() {
  local QWENSTRATAINS_share="${QWENSTRATAINS_VAL[DESTDIR]}/.local/share/strata" QWENSTRATAINS_q QWENSTRATAINS_f QWENSTRATAINS_tag QWENSTRATAINS_dir
  [[ $QWENSTRATAINS_INTERACTIVE == yes ]] || return 0
  for QWENSTRATAINS_q in $QWENSTRATAINS_QUANTS; do
    [[ $QWENSTRATAINS_q != "${QWENSTRATAINS_VAL[QUANT]}" ]] || continue
    read -r -a QWENSTRATAINS_f <<<"${QWENSTRATAINS_QUANT[$QWENSTRATAINS_q]}"
    QWENSTRATAINS_tag=${QWENSTRATAINS_f[6]}
    QWENSTRATAINS_dir="$QWENSTRATAINS_share/Strata-data/models/$QWENSTRATAINS_tag"
    [[ -d $QWENSTRATAINS_dir ]] || continue
    if ask_yn "Delete the unused model files of $QWENSTRATAINS_q ($(du -sh "$QWENSTRATAINS_dir" 2>/dev/null | cut -f1))?" n; then
      rm -rf --one-file-system "${QWENSTRATAINS_dir:?}" "${QWENSTRATAINS_share:?}/Strata-data/packs/${QWENSTRATAINS_tag,,}"
      rm -f "$QWENSTRATAINS_share/install/strata-${QWENSTRATAINS_tag,,}.json" "$QWENSTRATAINS_share/install/strata-${QWENSTRATAINS_tag,,}.log"
      info "Deleted the model files of $QWENSTRATAINS_q"
    fi
  done
}

finish() {
  local QWENSTRATAINS_ip QWENSTRATAINS_host
  QWENSTRATAINS_ip=$(listen_addresses | sed -n '1p')
  [[ -n $QWENSTRATAINS_ip ]] || QWENSTRATAINS_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ $QWENSTRATAINS_ip != *:* ]] || QWENSTRATAINS_ip="[$QWENSTRATAINS_ip]"
  QWENSTRATAINS_host="${QWENSTRATAINS_ip:-<this host>}:${QWENSTRATAINS_VAL[WEB_PORT]}"
  cat <<EOF

Qwen3.8-Flash-Next (${QWENSTRATAINS_VAL[QUANT]}) with Strata $QWENSTRATAINS_STRATA_VERSION is installed.
  Web chat        : http://$QWENSTRATAINS_host/
  OpenAI API      : http://$QWENSTRATAINS_host/v1     (/v1/chat/completions, /v1/responses, /v1/models)
  Anthropic API   : http://$QWENSTRATAINS_host        (/v1/messages)
  Model name      : ${QWENSTRATAINS_MODEL_ID:-see /v1/models}
  Context         : ${QWENSTRATAINS_N_CTX:-${QWENSTRATAINS_VAL[CTX_SIZE]}} tokens
  Services        : $QWENSTRATAINS_UNIT, nginx.service
  Logs            : journalctl -u $QWENSTRATAINS_UNIT
                    ${QWENSTRATAINS_VAL[DESTDIR]}/.local/state/strata/launch/$QWENSTRATAINS_PRESET.engine.log
  Settings        : $QWENSTRATAINS_CONF_FILE
  API key         : web page $(key_label "${QWENSTRATAINS_VAL[WEB_API_KEY]}"), agents $(key_label "${QWENSTRATAINS_VAL[AGENT_API_KEY]}"), management always required
                    sudo sed -n 's/^STRATA_API_KEY=//p' $QWENSTRATAINS_ENV_FILE
EOF
  if [[ ${QWENSTRATAINS_VAL[AGENT_API_KEY]} != yes ]]; then
    echo "                    (agents that insist on an API key can be given any non-empty string)"
  fi
  if [[ ${QWENSTRATAINS_VAL[WEB_API_KEY]} == yes ]]; then
    echo "                    (enter the key in the web page under About > Settings)"
  fi
  echo
}

do_install() {
  load_saved_config
  resolve_values
  require_gpu
  prompt_values
  validate
  prompt_gpus
  prompt_interfaces
  prompt_ufw
  confirm_license
  show_summary
  preflight
  install_packages
  ensure_user
  prepare_destdir
  stop_service
  disable_exclusive_units
  install_strata
  write_key_files
  launch_model
  write_unit
  write_logrotate
  write_nginx
  [[ -n ${QWENSTRATAINS_SAVED[DESTDIR]:-} && ${QWENSTRATAINS_SAVED[DESTDIR]} != "${QWENSTRATAINS_VAL[DESTDIR]}" ]] \
    && warn "the previous installation directory ${QWENSTRATAINS_SAVED[DESTDIR]} is no longer used; remove it manually if not needed"
  start_services
  configure_ufw
  save_config
  smoke_test
  cleanup_old_models
  finish
}

# -------------------------------------------------------------- uninstall

do_uninstall() {
  local QWENSTRATAINS_destdir QWENSTRATAINS_user QWENSTRATAINS_p QWENSTRATAINS_rules QWENSTRATAINS_uid
  local QWENSTRATAINS_x QWENSTRATAINS_n=0
  load_saved_config
  QWENSTRATAINS_destdir=${QWENSTRATAINS_ARG[DESTDIR]:-${QWENSTRATA_DESTDIR:-${QWENSTRATAINS_SAVED[DESTDIR]:-${QWENSTRATAINS_DEFAULT[DESTDIR]}}}}
  QWENSTRATAINS_destdir=${QWENSTRATAINS_destdir%/}
  QWENSTRATAINS_user=${QWENSTRATAINS_ARG[USER]:-${QWENSTRATA_USER:-${QWENSTRATAINS_SAVED[USER]:-${QWENSTRATAINS_DEFAULT[USER]}}}}
  cat <<EOF
This will stop and remove the Qwen3.8-Flash-Next / Strata service and delete:
  $QWENSTRATAINS_UNIT_DIR/$QWENSTRATAINS_UNIT
  $QWENSTRATAINS_NGINX_SITE (and the link in sites-enabled)
  $QWENSTRATAINS_LOGROTATE_FILE
  $QWENSTRATAINS_CONF_DIR (including the API key)
  $QWENSTRATAINS_destdir (Strata, its engine and all downloaded model files)
EOF
  confirm "Uninstall Qwen3.8-Flash-Next / Strata?" || die "aborted (use --yes to uninstall non-interactively)"

  info "Stopping the service"
  if service_exists "$QWENSTRATAINS_UNIT"; then
    systemctl disable --now "$QWENSTRATAINS_UNIT" 2>/dev/null || true
    rm -f "${QWENSTRATAINS_UNIT_DIR:?}/$QWENSTRATAINS_UNIT"
  fi
  systemctl daemon-reload
  systemctl reset-failed "$QWENSTRATAINS_UNIT" 2>/dev/null || true
  # A model left running by an interrupted "strata launch" is not part of the unit.
  if [[ -e $QWENSTRATAINS_destdir/$QWENSTRATAINS_MARKER && -x $QWENSTRATAINS_destdir/.local/bin/strata ]] && id -u "$QWENSTRATAINS_user" >/dev/null 2>&1; then
    run_as no "$QWENSTRATAINS_user" "$QWENSTRATAINS_destdir" "$QWENSTRATAINS_destdir/.local/bin/strata" launch --stop >/dev/null 2>&1 </dev/null || true
  fi

  info "Removing nginx site"
  rm -f "$QWENSTRATAINS_NGINX_LINK" "$QWENSTRATAINS_NGINX_SITE"
  if command -v nginx >/dev/null && systemctl is-active --quiet nginx.service; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx.service
    else
      warn "nginx configuration test failed; nginx was not reloaded"
    fi
  fi
  rm -f "$QWENSTRATAINS_LOGROTATE_FILE"

  QWENSTRATAINS_rules=${QWENSTRATAINS_SAVED[UFW_RULES]:-}
  if [[ -n $QWENSTRATAINS_rules ]] && command -v ufw >/dev/null; then
    for QWENSTRATAINS_p in $QWENSTRATAINS_rules; do
      # shellcheck disable=SC2046
      if ufw delete $(ufw_rule_args "$QWENSTRATAINS_p") >/dev/null 2>&1; then
        info "Removed the ufw rule for $(ufw_rules_text "$QWENSTRATAINS_p")"
      fi
    done
  fi

  if [[ -d $QWENSTRATAINS_destdir ]]; then
    if [[ -e $QWENSTRATAINS_destdir/$QWENSTRATAINS_MARKER ]]; then
      info "Removing $QWENSTRATAINS_destdir"
      rm -rf --one-file-system "${QWENSTRATAINS_destdir:?}"
    else
      warn "$QWENSTRATAINS_destdir does not look like a $QWENSTRATAINS_APP_NAME installation; not removed"
    fi
  fi
  # Strata's control sockets when their path under the home directory would be too long.
  if QWENSTRATAINS_uid=$(id -u "$QWENSTRATAINS_user" 2>/dev/null); then
    rm -f /tmp/strata-"$QWENSTRATAINS_uid"-*.sock
  fi
  rm -rf "${QWENSTRATAINS_CONF_DIR:?}"

  cat <<EOF

Qwen3.8-Flash-Next / Strata was uninstalled.
The apt packages (nginx-full, ...) and the service user $QWENSTRATAINS_user were kept.
Remove them manually if they are no longer needed, e.g.:
  sudo userdel $QWENSTRATAINS_user
EOF
  for QWENSTRATAINS_x in $QWENSTRATAINS_EXCLUSIVE_UNITS; do
    service_exists "$QWENSTRATAINS_x" || continue
    if systemctl is-enabled --quiet "$QWENSTRATAINS_x" 2>/dev/null; then continue; fi
    QWENSTRATAINS_n=$((QWENSTRATAINS_n + 1))
    cat <<EOF
$QWENSTRATAINS_x is installed but not enabled (installing $QWENSTRATAINS_APP_NAME stops and disables it).  To use it again:
  sudo systemctl enable --now ${QWENSTRATAINS_x%.service}
EOF
  done
  ((QWENSTRATAINS_n < 2)) || echo "Enable only one of them: they do not run at the same time."
}

main() {
  parse_args "$@"
  check_platform
  trap cleanup_tmp EXIT
  if [[ $QWENSTRATAINS_ACTION == uninstall ]]; then
    do_uninstall
  else
    do_install
  fi
}

# Not run when the file is sourced (for tests).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
