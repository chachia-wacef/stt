import json
import logging
import os
import time
from datetime import datetime, timezone
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

JOB_PREFIX = os.environ.get("TRANSCRIBE_JOB_PREFIX", "stt-")
OUTPUT_BUCKET = os.environ.get("OUTPUT_BUCKET", "stt-tests-wacef")
TRANSCRIPTS_PREFIX = os.environ.get("TRANSCRIPTS_PREFIX", "transcripts/")
ALLOWED_BUCKETS = {b.strip() for b in os.environ.get("ALLOWED_BUCKETS", OUTPUT_BUCKET).split(",") if b.strip()}
TASKS_TABLE = os.environ.get("TASKS_TABLE", "stt-tasks")
EXECUTIONS_TABLE = os.environ.get("EXECUTIONS_TABLE", "stt-executions")
TOKEN_TTL_S = int(os.environ.get("TOKEN_TTL_S", "86400"))
STAGE = "TRANSCRIBE"

transcribe = boto3.client("transcribe")
sfn = boto3.client("stepfunctions")
dynamodb = boto3.resource("dynamodb")
tasks_table = dynamodb.Table(TASKS_TABLE)
executions_table = dynamodb.Table(EXECUTIONS_TABLE)


class BusinessError(Exception):
    """Échec causé par la requête : signalé à Step Functions sans Retry ni alerte."""


class InvalidParameters(BusinessError):
    pass


class InputInvalid(BusinessError):
    pass


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _log(message, **fields):
    logger.info(json.dumps({"message": message, **fields}, default=str))


def _parse_media_uri(uri):
    parsed = urlparse(uri) if isinstance(uri, str) else None
    if not parsed or parsed.scheme != "s3" or not parsed.netloc or not parsed.path.lstrip("/"):
        raise InputInvalid(f"Invalid media URI: {uri!r}.")
    if parsed.netloc not in ALLOWED_BUCKETS:
        raise InputInvalid(f"Bucket '{parsed.netloc}' is not allowed.")
    return uri


def _build_request(execution_id, flac_uri, template, params):
    params = params or {}
    job_name = f"{JOB_PREFIX}{execution_id}"
    output_key = f"{TRANSCRIPTS_PREFIX}{execution_id}/transcript.json"

    request = {
        "TranscriptionJobName": job_name,
        "Media": {"MediaFileUri": flac_uri},
        "MediaFormat": "flac",
        "OutputBucketName": OUTPUT_BUCKET,
        "OutputKey": output_key,
    }

    language_code = params.get("language_code")
    identify = bool(params.get("identify_language"))
    if bool(language_code) == identify:
        raise InvalidParameters("Provide exactly one of 'language_code' or 'identify_language'.")
    if language_code:
        request["LanguageCode"] = language_code
    else:
        request["IdentifyLanguage"] = True
        if params.get("language_options"):
            request["LanguageOptions"] = list(params["language_options"])

    settings = {}
    speakers = params.get("max_speaker_labels")
    if template == "stereo-keep":
        if speakers is not None:
            raise InvalidParameters("'max_speaker_labels' cannot be used with channel identification (stereo-keep).")
        settings["ChannelIdentification"] = True
    elif speakers is not None:
        settings["ShowSpeakerLabels"] = True
        settings["MaxSpeakerLabels"] = int(speakers)
    if params.get("vocabulary_name"):
        settings["VocabularyName"] = params["vocabulary_name"]
    if settings:
        request["Settings"] = settings

    return request, job_name, f"s3://{OUTPUT_BUCKET}/{output_key}"


def _store_task_token(execution_id, task_token, **context):
    # Écrit AVANT le lancement du job : l'événement de fin ne peut pas arriver avant le token.
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


def lambda_handler(event, context):
    execution_id = event.get("execution_id")
    task_token = event.get("task_token")
    if not (execution_id and task_token and event.get("flac")):
        raise ValueError("Event must contain execution_id, task_token and flac.")

    try:
        flac_uri = _parse_media_uri(event["flac"])
        request, job_name, transcript_uri = _build_request(
            execution_id, flac_uri, event.get("template"), event.get("transcribe")
        )

        _store_task_token(execution_id, task_token, job_name=job_name, transcript_uri=transcript_uri)
        try:
            transcribe.start_transcription_job(**request)
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code == "ConflictException":
                # Le job existe déjà (nouvelle tentative après un démarrage réussi) : le token vient d'être mis à jour.
                _log("job already exists, reusing", execution_id=execution_id, job_name=job_name)
            elif code == "BadRequestException":
                _delete_task_token(execution_id)
                raise InvalidParameters(exc.response["Error"].get("Message", "Invalid Transcribe request.")) from exc
            else:
                _delete_task_token(execution_id)
                raise
        except Exception:
            _delete_task_token(execution_id)
            raise

        executions_table.update_item(
            Key={"execution_id": execution_id},
            UpdateExpression="SET transcribe_job_name = :n, updated_at = :u",
            ExpressionAttributeValues={":n": job_name, ":u": _now()},
        )
    except BusinessError as exc:
        _log("business failure", execution_id=execution_id, error=type(exc).__name__, cause=str(exc))
        sfn.send_task_failure(taskToken=task_token, error=type(exc).__name__, cause=str(exc)[:1000])
        return {"execution_id": execution_id, "error": type(exc).__name__}

    result = {
        "execution_id": execution_id,
        "job_name": job_name,
        "media": flac_uri,
        "transcript_uri": transcript_uri,
        "channel_identification": bool(request.get("Settings", {}).get("ChannelIdentification")),
    }
    _log("transcribe job submitted", **result)
    return result
