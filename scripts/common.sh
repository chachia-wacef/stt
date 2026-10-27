#!/usr/bin/env bash
# Fonctions et valeurs communes du POC. À sourcer depuis les autres scripts (pas à exécuter directement).
#
# Variables modifiables (environnement) :
#   PREFIX        préfixe des noms de ressources (défaut : stt-poc)
#   AWS_REGION    région (défaut : région du profil AWS CLI, sinon eu-central-1)
#   POC_BUCKET    bucket S3 à utiliser (défaut : <PREFIX>-<compte>-<région>, créé s'il n'existe pas)
#   ALERT_EMAIL   adresse qui recevra les alertes SNS (obligatoire pour 01_storage.sh)
#   DRY_RUN=1     affiche les commandes sans les exécuter

POC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$POC_ROOT"

export AWS_PAGER=""
# Chemins relatifs à la racine du POC (le script s'y place) : les « file://... » restent valides pour l'AWS CLI sous Windows.
BUILD_DIR="build"
STATE_FILE=".state.env"
mkdir -p "$BUILD_DIR"
touch "$STATE_FILE"
set -a
# shellcheck disable=SC1090
source "$STATE_FILE"
set +a

# --- Python (python3 sous Linux/macOS, python sous Windows) ---
if [ -z "${PYTHON:-}" ]; then
  if command -v python3 >/dev/null 2>&1 && python3 -c "import sys" >/dev/null 2>&1; then PYTHON=python3
  elif command -v python >/dev/null 2>&1; then PYTHON=python
  else echo "ERREUR : Python 3 est requis." >&2; exit 1; fi
fi

log() { echo "==> $*" >&2; }

# DRY_RUN=1 : affiche les commandes au lieu de les exécuter.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then printf '+ %s\n' "$*" >&2; else "$@"; fi
}

# Comme run, mais renvoie la sortie (ou un texte de remplacement en simulation).
capture() {
  local placeholder="$1"; shift
  if [ "${DRY_RUN:-0}" = "1" ]; then printf '+ %s\n' "$*" >&2; echo "$placeholder"; else "$@"; fi
}

# Vrai si la commande réussit ; toujours faux en simulation (le chemin « création » est alors affiché).
resource_exists() {
  [ "${DRY_RUN:-0}" = "1" ] && return 1
  "$@" >/dev/null 2>&1
}

# aws sans conversion de chemins par Git Bash (noms commençant par « / », comme les groupes de logs).
awsnc() { MSYS_NO_PATHCONV=1 aws "$@"; }

retry() {
  local attempts="$1"; shift
  local i
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then return 0; fi
    log "tentative $i/$attempts échouée, nouvelle tentative dans 8 s"
    [ "${DRY_RUN:-0}" = "1" ] || sleep 8
  done
  return 1
}

# Mémorise une valeur pour les scripts suivants (.state.env).
save_state() {
  local key="$1" value="$2"
  export "$key=$value"
  if [ "${DRY_RUN:-0}" = "1" ]; then echo "+ état : $key=$value" >&2; return; fi
  grep -v "^$key=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
  echo "$key=$value" >> "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

forget_state() {
  local key="$1"
  unset "$key" || true
  [ "${DRY_RUN:-0}" = "1" ] && return
  grep -v "^$key=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# --- Paramètres du compte ---
export PREFIX="${PREFIX:-stt-poc}"

if [ -z "${AWS_REGION:-}" ]; then
  AWS_REGION="${AWS_DEFAULT_REGION:-}"
fi
if [ -z "${AWS_REGION:-}" ] && command -v aws >/dev/null 2>&1; then
  AWS_REGION="$(aws configure get region 2>/dev/null || true)"
fi
export AWS_REGION="${AWS_REGION:-eu-central-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export REGION="$AWS_REGION"

if [ -z "${ACCOUNT_ID:-}" ]; then
  if [ "${DRY_RUN:-0}" = "1" ]; then
    ACCOUNT_ID="123456789012"
  else
    ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || {
      echo "ERREUR : impossible de lire l'identité AWS. Configurer l'AWS CLI (aws configure / aws configure sso)." >&2; exit 1; }
  fi
fi
export ACCOUNT_ID

export BUCKET="${POC_BUCKET:-${BUCKET:-$PREFIX-$ACCOUNT_ID-$REGION}}"

# Noms des ressources
export T_TASKS="$PREFIX-tasks"
export T_EXECUTIONS="$PREFIX-executions"
export TOPIC_NAME="$PREFIX-alerts"
export TOPIC_ARN="arn:aws:sns:$REGION:$ACCOUNT_ID:$TOPIC_NAME"
export SM_NAME="$PREFIX-pipeline"
export SM_ARN="arn:aws:states:$REGION:$ACCOUNT_ID:stateMachine:$SM_NAME"
export SM_LOG_GROUP="/aws/vendedlogs/states/$SM_NAME"
export MC_ROLE_NAME="$PREFIX-mediaconvert"
export MC_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$MC_ROLE_NAME"
export MC_QUEUE_ARN="arn:aws:mediaconvert:$REGION:$ACCOUNT_ID:queues/Default"
export JOB_PREFIX="$PREFIX-"

# Remplace les marqueurs __X__ d'un modèle et vérifie qu'il n'en reste aucun.
render() { # ENTRÉE SORTIE
  sed -e "s|__PREFIX__|$PREFIX|g" -e "s|__REGION__|$REGION|g" -e "s|__ACCOUNT_ID__|$ACCOUNT_ID|g" \
      -e "s|__BUCKET__|$BUCKET|g" -e "s|__MEDIACONVERT_ROLE_ARN__|$MC_ROLE_ARN|g" "$1" > "$2"
  if grep -q "__[A-Z_]*__" "$2"; then
    echo "ERREUR : marqueur non remplacé dans $2" >&2
    grep -n "__[A-Z_]*__" "$2" >&2
    exit 1
  fi
}

# Variables d'environnement JSON d'une Lambda : env_json CLÉ=VALEUR ...
env_json() {
  "$PYTHON" -c "import json,sys; print(json.dumps({'Variables': dict(a.split('=', 1) for a in sys.argv[1:])}))" "$@"
}

# Environnement de chaque Lambda (utilisé au déploiement et par demo_failure.sh).
lambda_env() { # validate | mediaconvert | transcribe | callback
  case "$1" in
    validate)
      env_json "ALLOWED_BUCKETS=$BUCKET" ;;
    mediaconvert)
      env_json "TEMPLATES_BUCKET=$BUCKET" "OUTPUT_BUCKET=$BUCKET" "TASKS_TABLE=$T_TASKS" \
               "EXECUTIONS_TABLE=$T_EXECUTIONS" "MEDIACONVERT_ROLE_ARN=$MC_ROLE_ARN" "MEDIACONVERT_QUEUE_ARN=$MC_QUEUE_ARN" ;;
    transcribe)
      env_json "OUTPUT_BUCKET=$BUCKET" "ALLOWED_BUCKETS=$BUCKET" "TASKS_TABLE=$T_TASKS" \
               "EXECUTIONS_TABLE=$T_EXECUTIONS" "TRANSCRIBE_JOB_PREFIX=$JOB_PREFIX" ;;
    callback)
      env_json "TASKS_TABLE=$T_TASKS" "TRANSCRIBE_JOB_PREFIX=$JOB_PREFIX" ;;
    *) echo "lambda_env : fonction inconnue $1" >&2; return 1 ;;
  esac
}

# deploy_lambda NOM ZIP RÔLE TIMEOUT MÉMOIRE ENV_JSON [LAYER_ARN]
deploy_lambda() {
  local name="$1" zip="$2" role="$3" timeout="$4" memory="$5" env="$6" layer="${7:-}"
  local role_arn="arn:aws:iam::$ACCOUNT_ID:role/$role"
  local extra=()
  [ -n "$layer" ] && extra+=(--layers "$layer")

  if resource_exists aws lambda get-function --function-name "$name"; then
    log "Lambda $name : mise à jour"
    run aws lambda update-function-code --function-name "$name" --zip-file "fileb://$zip" >/dev/null
    run aws lambda wait function-updated --function-name "$name"
    run aws lambda update-function-configuration --function-name "$name" --handler lambda_function.lambda_handler \
      --role "$role_arn" --timeout "$timeout" --memory-size "$memory" --environment "$env" "${extra[@]}" >/dev/null
  else
    log "Lambda $name : création"
    retry 6 run aws lambda create-function --function-name "$name" --runtime python3.12 \
      --handler lambda_function.lambda_handler --role "$role_arn" --timeout "$timeout" --memory-size "$memory" \
      --zip-file "fileb://$zip" --environment "$env" --tags project=stt-poc "${extra[@]}" >/dev/null
  fi
  run aws lambda wait function-active --function-name "$name"
  run aws lambda wait function-updated --function-name "$name"
}
