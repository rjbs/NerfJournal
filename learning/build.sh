#!/bin/sh
# Builds or serves the booklet with Zensical, run in Docker so that nothing
# need be installed locally beyond Docker itself.
#
#   learning/build.sh          # builds into learning/site/
#   learning/build.sh serve    # serves at http://localhost:8000 with reload
#
# The version here and the one in requirements.txt, which the Pages workflow
# installs, should be the same.
set -e
cd "$(dirname "$0")"

image=zensical/zensical:0.1.3

case "${1:-build}" in
  build)
    exec docker run --rm -v "$PWD":/docs "$image" build --clean --strict
    ;;
  serve)
    exec docker run --rm -it -p 8000:8000 -v "$PWD":/docs "$image" serve --dev-addr 0.0.0.0:8000
    ;;
  *)
    echo "usage: $0 [build|serve]" >&2
    exit 1
    ;;
esac
