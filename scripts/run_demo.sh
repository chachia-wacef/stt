#!/usr/bin/env bash
# Lance un traitement de démonstration : envoie un fichier audio/vidéo (ou utilise un fichier déjà dans S3),
# démarre la state machine, suit l'avancement et affiche le résultat.
#
# Usage : scripts/run_demo.sh <fichier local | s3://bucket/chemin> [options]
#   Fichier S3 : s'il est dans le bucket du POC, il est utilisé tel quel ; sinon il est copié dans ce bucket
#   (copie côté S3, sans téléchargement). Le POC ne lit que son propre bucket.
#   --lang CODE        langue (défaut fr-FR) ; « auto » pour la détection automatique
#   --stereo MODE      downmix (défaut) ou keep ; ne concerne que les fichiers stéréo
#   --speakers N       nombre maximal de locuteurs (2 à 30) : active la diarisation (non compatible avec --stereo keep)
#   --vocab NOM        vocabulaire personnalisé Transcribe existant
#   --download DOSSIER copie les fichiers produits dans ce dossier
#   --no-wait          démarre sans attendre la fin
set -euo pipefail
source "$(dirname "$0")/common.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

FILE=""; LANG_CODE="fr-FR"; STEREO="downmix"; SPEAKERS=""; VOCAB=""; DOWNLOAD=""; WAIT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --lang) LANG_CODE="$2"; shift 2 ;;
    --stereo) STEREO="$2"; shift 2 ;;
    --speakers) SPEAKERS="$2"; shift 2 ;;
    --vocab) VOCAB="$2"; shift 2 ;;
    --download) DOWNLOAD="$2"; shift 2 ;;
    --no-wait) WAIT=0; shift ;;
    -h|--help) usage ;;
    -*) echo "Option inconnue : $1" >&2; usage ;;
    *) FILE="$1"; shift ;;
  esac
done
[ -n "$FILE" ] || usage

EXEC_ID="$("$PYTHON" -c "import uuid; print(uuid.uuid4())")"
stamp="$(date +%Y%m%d-%H%M%S)"

# --- Fichier d'entrée : local (envoyé), ou déjà dans S3 ---
case "$FILE" in
  s3://*)
    src_path="${FILE#s3://}"
    src_bucket="${src_path%%/*}"
    src_key="${src_path#*/}"
    if [ -z "$src_bucket" ] || [ "$src_bucket" = "$src_path" ] || [ -z "$src_key" ]; then
      echo "ERREUR : adresse S3 invalide : $FILE (attendu : s3://bucket/chemin/fichier)" >&2; exit 1
    fi
    if [ "$src_bucket" = "$BUCKET" ]; then
      KEY="$src_key"
      log "Fichier déjà dans le bucket du POC : s3://$BUCKET/$KEY"
    else
      # Le POC ne lit que son propre bucket (variable ALLOWED_BUCKETS des Lambdas, politiques IAM) : copie côté S3, sans téléchargement local.
      safe_name="$(basename "$src_key" | tr -c 'A-Za-z0-9._\n-' '_')"
      KEY="input/demo/$stamp-$safe_name"
      log "Copie de $FILE vers s3://$BUCKET/$KEY"
      run aws s3 cp "$FILE" "s3://$BUCKET/$KEY" --only-show-errors
    fi
    if [ "${DRY_RUN:-0}" != "1" ]; then
      aws s3api head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1 \
        || { echo "ERREUR : s3://$BUCKET/$KEY est introuvable ou inaccessible." >&2; exit 1; }
    fi ;;
  *)
    [ -f "$FILE" ] || { echo "ERREUR : fichier introuvable : $FILE" >&2; exit 1; }
    safe_name="$(basename "$FILE" | tr -c 'A-Za-z0-9._\n-' '_')"
    KEY="input/demo/$stamp-$safe_name"
    log "Envoi de $FILE vers s3://$BUCKET/$KEY"
    run aws s3 cp "$FILE" "s3://$BUCKET/$KEY" --only-show-errors ;;
esac

"$PYTHON" - "$EXEC_ID" "$BUCKET" "$KEY" "$STEREO" "$LANG_CODE" "$SPEAKERS" "$VOCAB" "$BUILD_DIR" <<'PYEOF'
import datetime
import json
import os
import sys

exec_id, bucket, key, stereo, lang, speakers, vocab, build = sys.argv[1:9]
transcribe = {"identify_language": True} if lang == "auto" else {"language_code": lang}
if speakers:
    transcribe["max_speaker_labels"] = int(speakers)
if vocab:
    transcribe["vocabulary_name"] = vocab
uri = f"s3://{bucket}/{key}"
with open(os.path.join(build, "execution-input.json"), "w", encoding="utf-8") as handle:
    json.dump({"execution_id": exec_id, "owner": "poc", "input": uri, "stereo_mode": stereo,
               "transcribe": transcribe}, handle)
with open(os.path.join(build, "execution-item.json"), "w", encoding="utf-8") as handle:
    json.dump({"execution_id": {"S": exec_id}, "owner": {"S": "poc"}, "input": {"S": uri},
               "status": {"S": "PENDING"},
               "created_at": {"S": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}}, handle)
PYEOF

run aws dynamodb put-item --table-name "$T_EXECUTIONS" --item "file://$BUILD_DIR/execution-item.json"
EXEC_ARN=$(capture "arn:aws:states:$REGION:$ACCOUNT_ID:execution:$SM_NAME:$EXEC_ID" \
  aws stepfunctions start-execution --state-machine-arn "$SM_ARN" --name "$EXEC_ID" \
  --input "file://$BUILD_DIR/execution-input.json" --query executionArn --output text)

echo
echo "Exécution  : $EXEC_ID"
echo "Console    : https://$REGION.console.aws.amazon.com/states/home?region=$REGION#/v2/executions/details/$EXEC_ARN"
echo

[ "$WAIT" = "1" ] || exit 0
[ "${DRY_RUN:-0}" = "1" ] && exit 0

# --- Suivi ---
KEY_JSON="{\"execution_id\":{\"S\":\"$EXEC_ID\"}}"
last=""
started=$(date +%s)
while true; do
  sm_status=$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query status --output text)
  step=$(aws dynamodb get-item --table-name "$T_EXECUTIONS" --key "$KEY_JSON" --query "Item.status.S" --output text 2>/dev/null || echo "-")
  current="$sm_status | $step"
  if [ "$current" != "$last" ]; then
    printf '[%3ds] état de la state machine : %-10s | statut métier : %s\n' "$(( $(date +%s) - started ))" "$sm_status" "$step"
    last="$current"
  fi
  [ "$sm_status" != "RUNNING" ] && break
  if [ $(( $(date +%s) - started )) -gt 2400 ]; then echo "Arrêt du suivi après 40 minutes (l'exécution continue)."; exit 0; fi
  sleep 5
done

summary=$(aws dynamodb get-item --table-name "$T_EXECUTIONS" --key "$KEY_JSON" --output json | "$PYTHON" scripts/summarize_item.py)
field() { echo "$summary" | sed -n "s/^$1=//p"; }
echo

if [ "$(field status)" = "DONE" ]; then
  echo "Terminé avec succès."
  echo "  FLAC (entrée de Transcribe) : $(field flac)"
  echo "  MP4 (lecture)               : $(field playback)"
  echo "  Transcription (JSON)        : $(field transcript)"
  echo
  echo "----- Transcription -----"
  aws s3 cp "$(field transcript)" - | "$PYTHON" scripts/show_transcript.py
  echo "-------------------------"
  if [ -n "$DOWNLOAD" ]; then
    mkdir -p "$DOWNLOAD"
    aws s3 cp "s3://$BUCKET/output/$EXEC_ID/" "$DOWNLOAD/" --recursive --only-show-errors
    aws s3 cp "$(field transcript)" "$DOWNLOAD/transcript.json" --only-show-errors
    echo "Fichiers copiés dans $DOWNLOAD"
  fi
elif [ "$(field status)" = "FAILED" ] && [ "$sm_status" = "SUCCEEDED" ]; then
  echo "Échec métier (aucune alerte envoyée) : $(field error_code)"
  echo "  $(field error_message)"
else
  echo "Échec technique : l'exécution est en état $sm_status (une alerte a été publiée sur le topic SNS)."
  echo "  Détail : $(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query '[error,cause]' --output text)"
fi
