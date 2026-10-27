"""Crée une archive zip pour une Lambda, sans dépendre de l'outil `zip` (absent sous Windows).

Usage : python -I deploy/make_zip.py SORTIE.zip [--dir DOSSIER]... [SOURCE=NOM_DANS_LE_ZIP]...

  --dir DOSSIER        ajoute tout le contenu du dossier à la racine du zip
  SOURCE=NOM           ajoute le fichier SOURCE sous le nom NOM
"""
import os
import sys
import zipfile


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    output, args = argv[1], argv[2:]
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    count = 0
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        index = 0
        while index < len(args):
            if args[index] == "--dir":
                root = args[index + 1]
                index += 2
                for folder, dirs, files in os.walk(root):
                    dirs[:] = [d for d in dirs if d != "__pycache__"]
                    for name in files:
                        path = os.path.join(folder, name)
                        archive.write(path, os.path.relpath(path, root))
                        count += 1
            else:
                source, _, name = args[index].partition("=")
                archive.write(source, name or os.path.basename(source))
                count += 1
                index += 1
    print(f"{output}: {count} fichier(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
