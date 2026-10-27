import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TASKS_TABLE = os.environ.get("TASKS_TABLE", "stt-tasks")
TRANSCRIBE_JOB_PREFIX = os.environ.get("TRANSCRIBE_JOB_PREFIX", "stt-")

MEDIACONVERT_FINAL = {"COMPLETE", "ERROR", "CANCELED"}
TRANSCRIBE_FINAL = {"COMPLETED", "FAILED"}
# Le token est déjà consommé, expiré ou l'exécution terminée : rien à rejouer.
STALE_TOKEN_ERRORS = {"TaskDoesNotExist", "TaskTimedOut", "InvalidToken"}

sfn = boto3.client("stepfunctions")
tasks_table = boto3.resource("dynamodb").Table(TASKS_TABLE)


def _log(message, **fields):
    logger.info(json.dumps({"message": message, **fields}, default=str))


def _parse_event(event):
    """Retourne (stage, execution_id, final?, succeeded?, detail) ou None si l'événement est à ignorer."""
    source = event.get("source")
    detail = event.get("detail") or {}

    if source == "aws.mediaconvert":
        execution_id = (detail.get("userMetadata") or {}).get("execution_id")
        status = detail.get("status")
        return "MEDIACONVERT", execution_id, status in MEDIACONVERT_FINAL, status == "COMPLETE", detail

    if source == "aws.transcribe":
        name = detail.get("TranscriptionJobName") or ""
        execution_id = name[len(TRANSCRIBE_JOB_PREFIX):] if name.startswith(TRANSCRIBE_JOB_PREFIX) else None
        status = detail.get("TranscriptionJobStatus")
        return "TRANSCRIBE", execution_id, status in TRANSCRIBE_FINAL, status == "COMPLETED", detail

    return None


def _mediaconvert_outputs(detail):
    paths = [
        path
        for group in detail.get("outputGroupDetails") or []
        for output in group.get("outputDetails") or []
        for path in output.get("outputFilePaths") or []
    ]
    outputs = {}
    for path in paths:
        lowered = path.lower()
        if lowered.endswith(".flac"):
            outputs["flac"] = path
        elif lowered.endswith(".mp4"):
            outputs["playback"] = path
    return outputs


def _failure(stage, detail):
    if stage == "MEDIACONVERT":
        status = detail.get("status")
        error = "MediaConvertJobCanceled" if status == "CANCELED" else "MediaConvertJobFailed"
        code, message = detail.get("errorCode"), detail.get("errorMessage")
        cause = f"{code}: {message}" if code is not None else (message or status or "unknown")
        return error, cause
    return "TranscribeJobFailed", detail.get("FailureReason") or "unknown"


def _success_payload(stage, execution_id, item, detail):
    if stage == "MEDIACONVERT":
        outputs = _mediaconvert_outputs(detail)
        if "flac" not in outputs:
            return None
        return {
            "execution_id": execution_id,
            "channels": int(item["channels"]) if item.get("channels") is not None else None,
            "template": item.get("template"),
            "stereo_mode": item.get("stereo_mode"),
            "job_id": detail.get("jobId"),
            **outputs,
        }
    return {
        "execution_id": execution_id,
        "job_name": detail.get("TranscriptionJobName"),
        "transcript": item.get("transcript_uri"),
    }


def lambda_handler(event, context):
    parsed = _parse_event(event)
    if parsed is None:
        _log("unsupported event ignored", source=event.get("source"))
        return {"status": "ignored", "reason": "unsupported event"}

    stage, execution_id, is_final, succeeded, detail = parsed
    if not execution_id:
        _log("event without execution_id ignored", stage=stage)
        return {"status": "ignored", "reason": "no execution_id"}
    if not is_final:
        _log("non-final event ignored", stage=stage, execution_id=execution_id)
        return {"status": "ignored", "reason": "not final"}

    key = {"execution_id": execution_id, "stage": stage}
    item = tasks_table.get_item(Key=key, ConsistentRead=True).get("Item")
    if not item:
        _log("no pending task (duplicate or foreign event)", stage=stage, execution_id=execution_id)
        return {"status": "ignored", "reason": "no pending task"}

    token = item["task_token"]
    payload = _success_payload(stage, execution_id, item, detail) if succeeded else None

    try:
        if succeeded and payload is not None:
            sfn.send_task_success(taskToken=token, output=json.dumps(payload))
            outcome = "success"
        else:
            if succeeded:
                error, cause = "OutputMissing", "Job completed but no FLAC output file was reported."
            else:
                error, cause = _failure(stage, detail)
            sfn.send_task_failure(taskToken=token, error=error[:256], cause=str(cause)[:32000])
            outcome = "failure"
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code not in STALE_TOKEN_ERRORS:
            raise  # laissé à la relance asynchrone puis à la DLQ
        _log("stale task token", stage=stage, execution_id=execution_id, code=code)
        outcome = "stale"

    tasks_table.delete_item(Key=key)
    _log("task completed", stage=stage, execution_id=execution_id, outcome=outcome)
    return {"status": outcome, "stage": stage, "execution_id": execution_id}
