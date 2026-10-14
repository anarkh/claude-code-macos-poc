#!/bin/sh
# The root fixed native broker owns UID/profile/cgroup binding and lifecycle.
set -eu
if [ "$#" != 1 ]; then echo 'fixed isolation or contract mode required' >&2; exit 2; fi
case "$1" in isolation|contract) ;; *) exit 2 ;; esac
if [ "$(uname -s)" != Linux ] || [ "$(id -u)" != 0 ]; then echo 'root disposable Linux guest required' >&2; exit 2; fi
exec /bin/sh /opt/claude-code-poc/native/bootstrap.sh "$1"
