#!/bin/sh
set -eu
umask 077
mkdir -p "$HOME/.mozilla/browser"
exec /usr/bin/python3 /opt/browser/session.py
