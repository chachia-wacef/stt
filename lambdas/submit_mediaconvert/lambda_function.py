import json
import logging
import os
import subprocess
import time
from datetime import datetime, timezone

import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

FFPROBE_PATH = os.environ.get("FFPROBE_PATH", "/opt/bin/ffprobe")
PROBE_TIMEOUT_S = int(os.environ.get("PROBE_TIMEOUT_S", "60"))
PRESIGNED_TTL_S = 300

TEMPLATES_BUCKET = os.environ.get("TEMPLATES_BUCKET", "stt-tests-wacef")
TEMPLATES_PREFIX = os.environ.get("TEMPLATES_PREFIX", "templates/")
OUTPUT_BUCKET = os.environ.get("OUTPUT_BUCKET", TEMPLATES_BUCKET)
OUTPUT_PREFIX = os.environ.get("OUTPUT_PREFIX", "output/")
MEDIACONVERT_ROLE_ARN = os.environ.get("MEDIACONVERT_ROLE_ARN")  # sinon valeur du template
MEDIACONVERT_QUEUE_ARN = os.environ.get("MEDIACONVERT_QUEUE_ARN")  # sinon valeur du template

TASKS_TABLE = os.environ.get("TASKS_TABLE", "stt-tasks")
EXECUTIONS_TABLE = os.environ.get("EXECUTIONS_TABLE", "stt-executions")
TOKEN_TTL_S = int(os.environ.get("TOKEN_TTL_S", "86400"))
STAGE = "MEDIACONVERT"

TEMPLATES = {
    "mono": "job-mono.json",
    "stereo-keep": "job-stereo-keep.json",
    "stereo-downmix": "job-stereo-downmix.json",
}

s3 = boto3.client(
    "s3",
    config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
)
mediaconvert = boto3.client("mediaconvert")
sfn = boto3.client("stepfunctions")
dynamodb = boto3.resource("dynamodb")
tasks_table = dynamodb.Table(TASKS_TABLE)
executions_table = dynamodb.Table(EXECUTIONS_TABLE)


class BusinessError(Exception):
    """Échec causé par l'entrée : signalé à Step Functions sans Retry ni alerte."""


class InvalidParameters(BusinessError):
    pass


class InputInvalid(BusinessError):
    pass


class NoAudioStream(BusinessError):
    pass


class UnsupportedChannels(BusinessError):
    pass


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _log(message, **fields):
    logger.info(json.dumps({"message": message, **fields}))


def _probe_audio_streams(bucket, key):
    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=PRESIGNED_TTL_S,
    )
    cmd = [
        FFPROBE_PATH,
        "-v", "error",
        "-select_streams", "a",
        "-show_entries", "stream=index,codec_name,channels,channel_layout,sample_rate",
        "-of", "json",
        url,
    ]
    # Une expiration (subprocess.TimeoutExpired) est une erreur technique : elle remonte telle quelle.
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=PROBE_TIMEOUT_S, check=False)
    if proc.returncode != 0:
        raise InputInvalid(f"Media file could not be read: {proc.stderr.strip()[:300]}")
    return json.loads(proc.stdout).get("streams", [])


def _choose_template(channels, stereo_mode):
    if channels == 1:
        return "mono"
    if channels == 2:
        return f"stereo-{stereo_mode}"
    raise UnsupportedChannels(f"Unsupported channel count: {channels} (expected 1 or 2).")


def _check_transcribe_compatibility(template_key, transcribe):
    if template_key == "stereo-keep" and (transcribe or {}).get("max_speaker_labels") is not None:
        raise InvalidParameters(
            "'max_speaker_labels' cannot be used with stereo_mode 'keep' on a stereo input "
            "(channel identification is used instead)."
        )


def _load_template(template_file):
    obj = s3.get_object(Bucket=TEMPLATES_BUCKET, Key=f"{TEMPLATES_PREFIX}{template_file}")
    return json.loads(obj["Body"].read())


def _build_job(template_file, bucket, key, execution_id, template_key):
    job = _load_template(template_file)
    job["Settings"]["Inputs"][0]["FileInput"] = f"s3://{bucket}/{key}"
    destination = f"s3://{OUTPUT_BUCKET}/{OUTPUT_PREFIX}{execution_id}/"
    job["Settings"]["OutputGroups"][0]["OutputGroupSettings"]["FileGroupSettings"]["Destination"] = destination
    if MEDIACONVERT_ROLE_ARN:
        job["Role"] = MEDIACONVERT_ROLE_ARN
    if MEDIACONVERT_QUEUE_ARN:
        job["Queue"] = MEDIACONVERT_QUEUE_ARN
    job.setdefault("UserMetadata", {}).update(
        {"execution_id": execution_id, "template": template_key, "source_key": key[:256]}
    )
    return job, destination


def _store_task_token(execution_id, task_token, **context):
    # Écrit AVANT la création du job : l'événement de fin ne peut pas arriver avant le token.
    tasks_table.put_item(
        Item={
            "execution_id": execution_id,
            "stage": STAGE,
            "task_token": task_token,
            "created_at": _now(),
            "ttl": int(time.time()) + TOKEN_TTL_S,
            **context,
        }
    )


def _delete_task_token(execution_id):
    try:
        tasks_table.delete_item(Key={"execution_id": execution_id, "stage": STAGE})
    except Exception:
        logger.exception("could not delete task token")


def _validate_event(event):
    execution_id = event.get("execution_id")
    task_token = event.get("task_token")
    bucket, key = event.get("bucket"), event.get("key")
    stereo_mode = event.get("stereo_mode") or "downmix"
    if not (execution_id and task_token and bucket and key):
        raise ValueError("Event must contain execution_id, task_token, bucket and key.")
    return execution_id, task_token, bucket, key, stereo_mode


def lambda_handler(event, context):
    execution_id, task_token, bucket, key, stereo_mode = _validate_event(event)

    try:
        if stereo_mode not in ("keep", "downmix"):
            raise InvalidParameters("stereo_mode must be 'keep' or 'downmix'.")
        streams = _probe_audio_streams(bucket, key)
        if not streams:
            raise NoAudioStream("No audio stream found in input.")

        first = streams[0]  # le sélecteur par défaut de MediaConvert prend la première piste
        channels = int(first["channels"])
        template_key = _choose_template(channels, stereo_mode)
        _check_transcribe_compatibility(template_key, event.get("transcribe"))

        job, destination = _build_job(TEMPLATES[template_key], bucket, key, execution_id, template_key)

        _store_task_token(
            execution_id,
            task_token,
            channels=channels,
            template=template_key,
            stereo_mode=stereo_mode if channels == 2 else None,
            output_destination=destination,
        )
        try:
            created = mediaconvert.create_job(**job)["Job"]
        except Exception:
            _delete_task_token(execution_id)
            raise

        executions_table.update_item(
            Key={"execution_id": execution_id},
            UpdateExpression="SET mediaconvert_job_id = :j, updated_at = :u",
            ExpressionAttributeValues={":j": created["Id"], ":u": _now()},
        )
    except BusinessError as exc:
        # Échec métier : on le signale explicitement à Step Functions (pas de Retry, pas d'alerte).
        _log("business failure", execution_id=execution_id, error=type(exc).__name__, cause=str(exc))
        sfn.send_task_failure(taskToken=task_token, error=type(exc).__name__, cause=str(exc)[:1000])
        return {"execution_id": execution_id, "error": type(exc).__name__}

    result = {
        "execution_id": execution_id,
        "job_id": created["Id"],
        "job_status": created["Status"],
        "channels": channels,
        "channel_layout": first.get("channel_layout"),
        "codec": first.get("codec_name"),
        "sample_rate": int(first["sample_rate"]) if first.get("sample_rate") else None,
        "template": template_key,
        "audio_streams": len(streams),
        "output_destination": destination,
    }
    if len(streams) > 1:
        result["warning"] = "Multiple audio streams; only the first one will be processed."
    _log("mediaconvert job submitted", **result)
    return result
