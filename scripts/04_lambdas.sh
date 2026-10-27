#!/usr/bin/env bash
# Étape 4 : empaquette et déploie (création ou mise à jour) les quatre Lambdas du POC.
# Prérequis : 02_iam.sh et 03_layer.sh.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [ -z "${LAYER_ARN:-}" ]; then
  if [ "${DRY_RUN:-0}" = "1" ]; then LAYER_ARN="<LAYER_ARN>"
  else echo "ERREUR : LAYER_ARN absent. Exécuter d'abord scripts/03_layer.sh (ou définir FFPROBE_LAYER_ARN)." >&2; exit 1; fi
fi

package() { # NOM_DOSSIER
  "$PYTHON" scripts/make_zip.py "$BUILD_DIR/$1.zip" "lambdas/$1/lambda_function.py=lambda_function.py" >/dev/null
}
for dir in validate_input submit_mediaconvert submit_transcribe callback; do package "$dir"; done

deploy_lambda "$PREFIX-validate-input"      "$BUILD_DIR/validate_input.zip"      "$PREFIX-lambda-validate-input"      30 128 "$(lambda_env validate)"
deploy_lambda "$PREFIX-submit-mediaconvert" "$BUILD_DIR/submit_mediaconvert.zip" "$PREFIX-lambda-submit-mediaconvert" 90 512 "$(lambda_env mediaconvert)" "$LAYER_ARN"
deploy_lambda "$PREFIX-submit-transcribe"   "$BUILD_DIR/submit_transcribe.zip"   "$PREFIX-lambda-submit-transcribe"   30 128 "$(lambda_env transcribe)"
deploy_lambda "$PREFIX-callback"            "$BUILD_DIR/callback.zip"            "$PREFIX-lambda-callback"            30 128 "$(lambda_env callback)"

# Conservation des journaux : 14 jours.
for fn in validate-input submit-mediaconvert submit-transcribe callback; do
  if [ "${DRY_RUN:-0}" = "1" ]; then
    run awsnc logs put-retention-policy --log-group-name "/aws/lambda/$PREFIX-$fn" --retention-in-days 14
  else
    awsnc logs create-log-group --log-group-name "/aws/lambda/$PREFIX-$fn" >/dev/null 2>&1 || true
    awsnc logs put-retention-policy --log-group-name "/aws/lambda/$PREFIX-$fn" --retention-in-days 14
  fi
done

log "Terminé. Contrôle rapide de la première Lambda :"
log "  aws lambda invoke --function-name $PREFIX-validate-input --cli-binary-format raw-in-base64-out \\"
log "    --payload '{\"execution_id\":\"t1\",\"input\":\"s3://$BUCKET/input/inexistant.mp3\"}' /tmp/out.json ; cat /tmp/out.json"
log "  (résultat attendu : une erreur InputNotFound)"
