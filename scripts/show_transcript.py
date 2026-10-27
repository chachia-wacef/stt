"""Affiche une transcription AWS Transcribe (fichier JSON) de façon lisible.

Usage :
  python show_transcript.py transcript.json
  aws s3 cp s3://bucket/transcripts/<id>/transcript.json - | python show_transcript.py

Selon les options de la transcription, l'affichage est regroupé par locuteur (diarisation)
ou par canal (identification de canaux). Sans option, seul le texte complet est affiché.
"""
import json
import sys


def plain_text(data):
    transcripts = data.get("results", {}).get("transcripts") or []
    return transcripts[0].get("transcript", "") if transcripts else ""


def _join(parts):
    """Assemble des mots et de la ponctuation (la ponctuation se colle au mot précédent)."""
    text = ""
    for content, kind in parts:
        text += content if kind == "punctuation" or not text else " " + content
    return text


def by_speaker(data):
    results = data.get("results", {})
    segments = (results.get("speaker_labels") or {}).get("segments") or []
    if not segments:
        return None
    speaker_at = {}
    for segment in segments:
        for item in segment.get("items", []):
            speaker_at[item.get("start_time")] = item.get("speaker_label") or segment.get("speaker_label")

    lines, current, parts = [], None, []
    for item in results.get("items", []):
        content = item["alternatives"][0]["content"]
        if item.get("type") == "punctuation":
            if parts:
                parts.append((content, "punctuation"))
            continue
        speaker = speaker_at.get(item.get("start_time"), current)
        if speaker != current and parts:
            lines.append((current, _join(parts)))
            parts = []
        current = speaker
        parts.append((content, "pronunciation"))
    if parts:
        lines.append((current, _join(parts)))
    return lines


def by_channel(data):
    channels = (data.get("results", {}).get("channel_labels") or {}).get("channels") or []
    if not channels:
        return None
    words = []
    for channel in channels:
        label = channel.get("channel_label")
        last_index = None
        for item in channel.get("items", []):
            content = item["alternatives"][0]["content"]
            if item.get("type") == "punctuation":
                if last_index is not None:
                    words[last_index]["punct"] += content
                continue
            words.append({"channel": label, "start": float(item.get("start_time", 0)), "text": content, "punct": ""})
            last_index = len(words) - 1
    words.sort(key=lambda w: w["start"])

    lines, current, parts = [], None, []
    for word in words:
        if word["channel"] != current and parts:
            lines.append((current, " ".join(parts)))
            parts = []
        current = word["channel"]
        parts.append(word["text"] + word["punct"])
    if parts:
        lines.append((current, " ".join(parts)))
    return lines


def render(data):
    out = []
    structured = by_speaker(data) or by_channel(data)
    if structured:
        out.extend(f"[{label}] {text}" for label, text in structured)
    else:
        out.append(plain_text(data))
    return "\n".join(out)


def main():
    for stream in (sys.stdin, sys.stdout):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    source = open(sys.argv[1], encoding="utf-8") if len(sys.argv) > 1 else sys.stdin
    data = json.load(source)
    print(render(data))


if __name__ == "__main__":
    main()
