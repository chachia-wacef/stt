import json
import logging
import os
import time
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ALLOWED_BUCKETS = {b.strip() for b in os.environ.get("ALLOWED_BUCKETS", "stt-tests-wacef").split(",") if b.strip()}
ALLOWED_EXTENSIONS = {
    e.strip().lower().lstrip(".")
    for e in os.environ.get(
        "ALLOWED_EXTENSIONS",
        "mp3,wav,flac,m4a,aac,ogg,opus,wma,amr,mp4,m4v,mov,mkv,webm,avi,mpg,mpeg,3gp,ts",
    ).split(",")
    if e.strip()
}
MAX_SIZE_BYTES = int(os.environ.get("MAX_SIZE_BYTES", "0"))  # 0 = pas de limite
NOT_FOUND_RETRIES = int(os.environ.get("NOT_FOUND_RETRIES", "0"))
NOT_FOUND_DELAY_S = float(os.environ.get("NOT_FOUND_DELAY_S", "2"))

s3 = boto3.client("s3")


class InputNotFound(Exception):
    """Fichier d'entrée absent : échec métier, non rejouable."""


class InputInvalid(Exception):
    """Entrée refusée (URI, bucket, extension, taille, accès) : échec métier, non rejouable."""


def _log(level, message, **fields):
    logger.log(level, json.dumps({"message": message, **fields}))


def _parse_s3_uri(uri):
    if not isinstance(uri, str):
        raise InputInvalid("'input' must be an S3 URI string.")
    parsed = urlparse(uri)
    bucket, key = parsed.netloc, parsed.path.lstrip("/")
    if parsed.scheme != "s3" or not bucket or not key or key.endswith("/"):
        raise InputInvalid(f"Invalid S3 URI: expected s3://<bucket>/<key>, got '{uri}'.")
    return bucket, key


def _head_object(bucket, key):
    attempt = 0
    while True:
        try:
            return s3.head_object(Bucket=bucket, Key=key)
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code in ("404", "NoSuchKey", "NotFound"):
                if attempt < NOT_FOUND_RETRIES:
                    attempt += 1
                    time.sleep(NOT_FOUND_DELAY_S)
                    continue
                raise InputNotFound(f"s3://{bucket}/{key} does not exist.") from exc
            if code in ("403", "AccessDenied", "Forbidden"):
                raise InputInvalid(f"Access denied to s3://{bucket}/{key}.") from exc
            raise  # erreur transitoire ou inattendue : laissée au Retry / Catch de Step Functions


def lambda_handler(event, context):
    execution_id = event.get("execution_id")
    bucket, key = _parse_s3_uri(event.get("input"))

    if bucket not in ALLOWED_BUCKETS:
        raise InputInvalid(f"Bucket '{bucket}' is not allowed.")

    extension = key.rsplit(".", 1)[-1].lower() if "." in key.rsplit("/", 1)[-1] else ""
    if extension not in ALLOWED_EXTENSIONS:
        raise InputInvalid(f"Extension '{extension}' is not supported.")

    head = _head_object(bucket, key)
    size = head["ContentLength"]
    if size == 0:
        raise InputInvalid("Input file is empty.")
    if MAX_SIZE_BYTES and size > MAX_SIZE_BYTES:
        raise InputInvalid(f"Input file is too large ({size} bytes, max {MAX_SIZE_BYTES}).")

    result = {
        "bucket": bucket,
        "key": key,
        "input": f"s3://{bucket}/{key}",
        "extension": extension,
        "size_bytes": size,
        "content_type": head.get("ContentType"),
    }
    _log(logging.INFO, "input validated", execution_id=execution_id, **result)
    return result
