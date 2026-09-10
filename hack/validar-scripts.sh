#!/usr/bin/env bash
#
# Confere os scripts de shell do repositório.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mapfile -t scripts < <(find bootstrap hack -name '*.sh' -type f 2>/dev/null | sort)

if [[ ${#scripts[@]} -eq 0 ]]; then
  echo "nenhum script .sh encontrado."
  exit 0
fi

# bash -n antes do shellcheck: pega erro de sintaxe sem depender de ferramenta
# externa, então funciona na estação de quem não instalou nada.
echo "==> bash -n"
for script in "${scripts[@]}"; do
  bash -n "${script}"
  echo "    ok ${script}"
done

if ! command -v shellcheck >/dev/null 2>&1; then
  # No CI, shellcheck ausente é falha: um job verde sem shellcheck é pior do que
  # job nenhum, porque dá a impressão de que foi conferido. Na estação, é aviso.
  if [[ "${EXIGIR_SHELLCHECK:-}" == "1" ]]; then
    echo "shellcheck não está no PATH e EXIGIR_SHELLCHECK=1." >&2
    exit 1
  fi
  echo "aviso: shellcheck não está instalado; só bash -n foi rodado."
  exit 0
fi

echo "==> shellcheck"
# -x segue os `source`; sem isso o shellcheck ignora o que vem de arquivo
# externo e some com metade dos avisos úteis.
shellcheck -x --severity=style "${scripts[@]}"
echo "    ok"
