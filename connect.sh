#!/usr/bin/env bash
# anddev — PC→폰 접속. 로직은 단일 파일 anddev.sh 로 통합됨 (이건 하위호환 shim).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${DIR}/anddev.sh" connect "$@"
