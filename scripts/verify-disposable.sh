#!/bin/sh
# Allocate and verify resources in the shared version-checked Python owner.
set -eu
exec "${EGI_PYTHON:-python3}" "$(dirname "$0")/sqitch_disposable.py"
