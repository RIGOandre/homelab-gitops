#!/usr/bin/env bash
#
# Formatação e validação do Terraform.
#
# Mesmo motivo de hack/validar-manifestos.sh existir: o CI chama este script, não
# uma lista de comandos colada no ci.yml, para que dê para reproduzir o vermelho
# na estação.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -d terraform ]]; then
  echo "terraform/ não existe; nada a validar."
  exit 0
fi

echo "==> terraform fmt"
# -check não escreve nada; só reprova. Formatar dentro do CI mascararia o
# problema, porque o commit continuaria torto no Git.
terraform fmt -check -recursive terraform/

# Um `validate` por diretório com .tf, e não só na raiz: um módulo em
# terraform/modules/x que ninguém referencia ainda passaria despercebido se a
# validação fosse só do módulo raiz.
mapfile -t diretorios < <(
  find terraform -name '*.tf' -not -path '*/.terraform/*' -printf '%h\n' | sort -u
)

if [[ ${#diretorios[@]} -eq 0 ]]; then
  echo "nenhum .tf encontrado em terraform/."
  exit 0
fi

for dir in "${diretorios[@]}"; do
  echo "==> terraform validate ${dir}"
  # -backend=false porque validar não precisa (nem deve) falar com o backend de
  # estado. Com backend real, o CI precisaria de credencial só para conferir
  # sintaxe.
  terraform -chdir="${dir}" init -backend=false -input=false -no-color >/dev/null
  terraform -chdir="${dir}" validate -no-color
done
