#!/bin/sh
SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$SELF/animalwell/diagnose.sh" --full
