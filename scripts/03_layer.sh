#!/usr/bin/env bash
# Étape 3 : layer ffprobe (utilisée par la Lambda de transcodage pour détecter mono / stéréo).
#
# Variables facultatives :
#   FFPROBE_LAYER_ARN    ARN d'une layer ffprobe existante : rien n'est construit
#   FFPROBE_BINARY       chemin d'un binaire ffprobe statique Linux à utiliser au lieu du téléchargement
#   ARCH                 x86_64 (défaut) ou arm64 ; doit correspondre à l'architecture des Lambdas (x86_64)
#   FORCE=1              reconstruire même si une layer est déjà enregistrée
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [ -n "${FFPROBE_LAYER_ARN:-}" ]; then
  save_state LAYER_ARN "$FFPROBE_LAYER_ARN"
  log "Layer fournie : $FFPROBE_LAYER_ARN"
  exit 0
fi
if [ -n "${LAYER_ARN:-}" ] && [ "${FORCE:-0}" != "1" ]; then
  log "Layer déjà publiée ($LAYER_ARN). FORCE=1 pour la reconstruire."
  exit 0
fi

ARCH="${ARCH:-x86_64}"
ZIP="$BUILD_DIR/ffprobe-layer.zip"
args=("$ZIP" --arch "$ARCH")
[ -n "${FFPROBE_BINARY:-}" ] && args+=(--binary "$FFPROBE_BINARY")

log "Construction de l'archive (téléchargement d'environ 40 Mo si aucun binaire n'est fourni)"
run "$PYTHON" scripts/build_ffprobe_layer.py "${args[@]}"

# Envoi via S3 : l'envoi direct est limité à 50 Mo.
run aws s3 cp "$ZIP" "s3://$BUCKET/layers/ffprobe-layer.zip" --only-show-errors

arn=$(capture "<LAYER_ARN>" aws lambda publish-layer-version --layer-name "$PREFIX-ffprobe" \
  --content "S3Bucket=$BUCKET,S3Key=layers/ffprobe-layer.zip" \
  --compatible-runtimes python3.12 --compatible-architectures "$ARCH" \
  --query LayerVersionArn --output text)
save_state LAYER_ARN "$arn"
log "Terminé. Layer : $arn"
