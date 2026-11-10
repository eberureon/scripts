#! /usr/bin/env python3

# Credits: https://github.com/lahwaacz

"""Remove junk files and folders that programs leave in the home directory.

Usage:
  python rmshit.py            ask for each item that was found
  python rmshit.py --yes      remove everything that was found
  python rmshit.py --dry-run  only list what was found
"""

import argparse
import os
import shutil
import sys


# Only things that are safe to lose: leftovers, logs and caches. Folders that
# hold configuration or data (~/Desktop, ~/.subversion, ~/.ansible, ~/.vnc,
# ~/.java, ~/.cmake, ~/.texlive) and /tmp are deliberately not listed.
shittyfiles = [
    "~/.adobe",  # Flash crap
    "~/.macromedia",  # Flash crap
    "~/.recently-used",
    "~/.local/share/recently-used.xbel",
    "~/.thumbnails",
    "~/.gconfd",
    "~/.gconf",
    "~/.local/share/gegl-0.2",
    "~/.FRD/log/app.log",  # FRD
    "~/.FRD/links.txt",  # FRD
    "~/.objectdb",  # FRD
    "~/.gstreamer-0.10",
    "~/.pulse",
    "~/.esd_auth",
    "~/.config/enchant",
    "~/.spicec",  # contains only log file; unconfigurable
    "~/.dropbox-dist",
    "~/.parallel",
    "~/.dbus",
    "~/ca2",  # WTF?
    "~/ca2~",  # WTF?
    "~/.distlib/",  # contains another empty dir, don't know which software creates it
    "~/.bazaar/",  # bzr insists on creating files holding default values
    "~/.bzr.log",
    "~/.nv/",
    # configured to be moved to ~/.cache/vim/viminfo, but it is still sometimes created...
    "~/.viminfo",
    "~/.npm/",  # npm cache
    "~/.oracle_jre_usage/",
    "~/.jssc/",
    "~/.tox/",  # cache directory for tox
    "~/.pylint.d/",
    "~/.qute_test/",
    "~/.QtWebEngineProcess/",
    "~/.qutebrowser/",  # created empty, only with webengine backend
    "~/.asy/",
    "~/.gnome/",
    "~/unison.log",
    "~/.w3m/",
    "~/nvvp_workspace/",  # created empty even when the path is set differently in nvvp
    "~/.fltk/",
    "~/.local/share/Trash/",  # VSCode puts deleted files here
]


def yesno(question, default="n"):
    """Asks the user for YES or NO, always case insensitive.
    Returns True for YES and False for NO.
    """
    prompt = "%s (y/[n]) " % question

    try:
        ans = input(prompt).strip().lower()
    except EOFError:
        ans = ""

    if not ans:
        ans = default

    return ans == "y"


def remove(path):
    """Removes a file, a symlink or a whole directory."""
    # A symlink is removed itself, never the thing it points to.
    if os.path.islink(path) or not os.path.isdir(path):
        os.remove(path)
    else:
        shutil.rmtree(path)


def rmshit(assume_yes=False, dry_run=False):
    found = []
    for f in shittyfiles:
        absf = os.path.expanduser(f).rstrip("/")
        if os.path.lexists(absf):
            found.append(absf)

    if len(found) == 0:
        print("No shitty files found :)")
        return 0

    print("Found shittyfiles:")
    for f in found:
        print("    %s" % f)

    if dry_run:
        print("Dry run, no file removed")
        return 0

    removed = 0
    failed = 0
    for f in found:
        if not assume_yes and not yesno("Remove %s?" % f):
            continue
        try:
            remove(f)
            removed += 1
        except OSError as e:
            failed += 1
            print("Could not remove %s: %s" % (f, e), file=sys.stderr)

    print("%d removed, %d kept, %d failed" % (removed, len(found) - removed - failed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Remove junk files from the home directory.")
    parser.add_argument("-y", "--yes", action="store_true", help="remove everything found without asking")
    parser.add_argument("-n", "--dry-run", action="store_true", help="only list what was found")
    args = parser.parse_args()
    sys.exit(rmshit(assume_yes=args.yes, dry_run=args.dry_run))
