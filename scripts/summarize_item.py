"""Résume une entrée de la table de suivi (JSON DynamoDB lu sur l'entrée standard).

Usage : aws dynamodb get-item ... --output json | python summarize_item.py
Sortie : lignes « clé=valeur » (status, error_code, error_message, flac, playback, transcript).
"""
import json
import sys


def text(attribute):
    return next(iter(attribute.values())) if attribute else ""


def main():
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    document = json.load(sys.stdin)
    item = document.get("Item") or {}
    outputs = (item.get("outputs") or {}).get("M", {})
    error = (item.get("error") or {}).get("M", {})
    rows = {
        "status": text(item.get("status")),
        "error_code": text(error.get("code")),
        "error_message": text(error.get("message")),
        "flac": text(outputs.get("flac")),
        "playback": text(outputs.get("playback")),
        "transcript": text(outputs.get("transcript")),
    }
    for key, value in rows.items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
