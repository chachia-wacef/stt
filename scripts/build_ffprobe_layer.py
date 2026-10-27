"""Construit le zip de la layer ffprobe, sans l'outil `zip` (fonctionne sous Windows, Linux et macOS).

Le binaire ffprobe doit être exécutable dans la Lambda : ce script écrit explicitement les droits Unix (755)
dans l'archive, ce que ne fait pas un zip créé avec l'explorateur Windows.

Usage :
  python build_ffprobe_layer.py SORTIE.zip [--arch x86_64|arm64] [--binary CHEMIN_VERS_FFPROBE]

Sans --binary, le script télécharge une build statique publique (ffmpeg-release-*-static de johnvansickle.com)
et vérifie son empreinte MD5. Vérifier la licence de ce binaire (GPL) avec votre équipe avant tout usage
au-delà du POC, ou fournir votre propre binaire avec --binary.
"""
import argparse
import hashlib
import os
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile

BASE_URL = "https://johnvansickle.com/ffmpeg/releases"
ARCHIVES = {
    "x86_64": "ffmpeg-release-amd64-static.tar.xz",
    "arm64": "ffmpeg-release-arm64-static.tar.xz",
}


def download(url, destination):
    print(f"Téléchargement : {url}", file=sys.stderr)
    with urllib.request.urlopen(url, timeout=60) as response, open(destination, "wb") as out:
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
            done += len(chunk)
            if total:
                print(f"\r  {done // (1024 * 1024)} / {total // (1024 * 1024)} Mo", end="", file=sys.stderr)
    print(file=sys.stderr)


def md5_of(path):
    digest = hashlib.md5()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch_ffprobe(arch):
    archive = ARCHIVES[arch]
    with tempfile.TemporaryDirectory() as work:
        archive_path = os.path.join(work, archive)
        md5_path = archive_path + ".md5"
        download(f"{BASE_URL}/{archive}", archive_path)
        download(f"{BASE_URL}/{archive}.md5", md5_path)

        expected = open(md5_path, encoding="utf-8").read().split()[0].lower()
        actual = md5_of(archive_path)
        if expected != actual:
            raise SystemExit(f"ERREUR : empreinte MD5 différente (attendue {expected}, obtenue {actual}).")
        print("Empreinte MD5 vérifiée.", file=sys.stderr)

        with tarfile.open(archive_path, "r:xz") as tar:
            for member in tar:
                if member.isfile() and member.name.rsplit("/", 1)[-1] == "ffprobe":
                    return tar.extractfile(member).read()
    raise SystemExit("ERREUR : ffprobe introuvable dans l'archive téléchargée.")


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output")
    parser.add_argument("--arch", choices=sorted(ARCHIVES), default="x86_64")
    parser.add_argument("--binary", help="utiliser ce binaire ffprobe au lieu de télécharger")
    args = parser.parse_args()

    if args.binary:
        with open(args.binary, "rb") as handle:
            data = handle.read()
    else:
        data = fetch_ffprobe(args.arch)

    info = zipfile.ZipInfo("bin/ffprobe", date_time=time.localtime()[:6])
    info.create_system = 3  # Unix : les droits sont lus par Lambda
    info.external_attr = 0o100755 << 16
    info.compress_type = zipfile.ZIP_DEFLATED

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with zipfile.ZipFile(args.output, "w") as archive:
        archive.writestr(info, data)

    with zipfile.ZipFile(args.output) as archive:
        entry = archive.getinfo("bin/ffprobe")
        mode = (entry.external_attr >> 16) & 0o777
    print(f"{args.output} : bin/ffprobe, {len(data) // (1024 * 1024)} Mo, droits {oct(mode)}, "
          f"zip {os.path.getsize(args.output) // (1024 * 1024)} Mo")
    if mode != 0o755:
        raise SystemExit("ERREUR : droits d'exécution absents de l'archive.")


if __name__ == "__main__":
    main()
