#!/usr/bin/env bash
#
# Confere que toda imagem fixada nos manifestos existe no registry.
#
# Tag de imagem escrita à mão é irmã da versão de chart escrita à mão: o erro
# não aparece na validação de schema, aparece como ImagePullBackOff num pod que
# devia estar entregando alerta no celular. E aparece de madrugada, porque foi
# de madrugada que o alerta tentou sair.
#
# A distinção que este script faz questão de manter: "a tag não existe" e "não
# consegui falar com o registry" são resultados diferentes. Tratar os dois como
# falha é como se ensina a ignorar o CI; tratar os dois como sucesso é como o
# erro passa. Por padrão o inconclusivo avisa e não reprova; com
# EXIGIR_CONFERENCIA=1 (o caso do CI, onde a rede é aberta) ele reprova.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

EXIGIR_CONFERENCIA="${EXIGIR_CONFERENCIA:-0}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker não está no PATH; sem ele não há como consultar o registry." >&2
  [[ "$EXIGIR_CONFERENCIA" == "1" ]] && exit 1
  exit 0
fi

# Só o que é imagem de verdade: linhas `image: algo` em manifesto. Values de
# Helm ficam de fora porque lá a tag costuma vir separada do repositório, e
# meia tag não dá para consultar.
mapfile -t imagens < <(
  grep -rhoE '^[[:space:]]*image:[[:space:]]*"?[A-Za-z0-9][^"[:space:]]*"?' \
    --include='*.yaml' clusters/ bootstrap/ 2>/dev/null |
    sed -E 's/^[[:space:]]*image:[[:space:]]*"?//; s/"$//' |
    grep -v '{{' |
    sort -u
)

if [[ ${#imagens[@]} -eq 0 ]]; then
  echo "nenhuma imagem encontrada nos manifestos." >&2
  exit 1
fi

# Quando a tag não existe, dizer só "não existe" obriga quem lê a ir procurar as
# tags à mão — e chutar de novo. Aqui o registry é consultado direto (v2 API,
# com o fluxo de token anônimo que ghcr, quay, Docker Hub e Gitea usam) e as
# últimas tags publicadas saem no log, ao lado do erro.
listar_tags() {
  local imagem="$1"
  local sem_tag="${imagem%:*}"
  local registro="${sem_tag%%/*}"
  local repo="${sem_tag#*/}"
  local desafio realm servico token

  desafio=$(curl -sSI --max-time 20 "https://${registro}/v2/" 2>/dev/null | tr -d '\r' | grep -i '^www-authenticate:' || true)
  if [[ -n "${desafio}" ]]; then
    realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"${desafio}")
    servico=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"${desafio}")
    if [[ -n "${realm}" ]]; then
      token=$(curl -sS --max-time 20 "${realm}?service=${servico}&scope=repository:${repo}:pull" 2>/dev/null |
                python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token") or d.get("access_token") or "")' 2>/dev/null || true)
    fi
  fi

  # Nem todo caminho até o registry devolve o desafio 401: proxy corporativo
  # costuma responder 405 ao GET em /v2/ e engolir o www-authenticate. O
  # endpoint /token com escopo de pull é a convenção que ghcr, quay e Docker Hub
  # seguem, então vale tentar mesmo sem o desafio.
  if [[ -z "${token:-}" ]]; then
    token=$(curl -sS --max-time 20 "https://${registro}/token?service=${registro}&scope=repository:${repo}:pull" 2>/dev/null |
              python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token") or d.get("access_token") or "")' 2>/dev/null || true)
  fi

  local resposta
  if [[ -n "${token:-}" ]]; then
    resposta=$(curl -sS --max-time 25 -H "Authorization: Bearer ${token}" "https://${registro}/v2/${repo}/tags/list" 2>/dev/null || true)
  else
    resposta=$(curl -sS --max-time 25 "https://${registro}/v2/${repo}/tags/list" 2>/dev/null || true)
  fi

  python3 -c '
import json, sys
try:
    tags = json.loads(sys.argv[1]).get("tags") or []
except Exception:
    tags = []
if tags:
    print("               tags publicadas (últimas 12): " + ", ".join(tags[-12:]))
else:
    print("               não consegui listar as tags deste repositório.")
' "${resposta}" 2>/dev/null || echo "               não consegui listar as tags deste repositório."
}

falhas=0
inconclusivos=0

for imagem in "${imagens[@]}"; do
  # Sem tag explícita é :latest disfarçado, e :latest num cluster GitOps
  # significa que o mesmo commit sobe binários diferentes em dias diferentes.
  # Isso não depende de rede: é sempre reprovação.
  if [[ "$imagem" != *:* || "$imagem" == *:latest ]]; then
    printf 'SEM TAG FIXA   %s\n' "$imagem"
    falhas=$((falhas + 1))
    continue
  fi

  if erro=$(docker manifest inspect "$imagem" 2>&1 >/dev/null); then
    printf 'ok             %s\n' "$imagem"
    continue
  fi

  # O registry respondeu e disse que não tem: é erro de verdade.
  if grep -qiE 'manifest unknown|not found|no such manifest|manifest for .* not found' <<<"$erro"; then
    printf 'NÃO EXISTE     %s\n' "$imagem"
    listar_tags "$imagem"
    falhas=$((falhas + 1))
  else
    # Rede, proxy, autenticação, timeout. Não é sobre a tag.
    printf 'INCONCLUSIVO   %s  (%s)\n' "$imagem" "$(head -1 <<<"$erro" | cut -c1-90)"
    inconclusivos=$((inconclusivos + 1))
  fi
done

echo
if [[ $falhas -gt 0 ]]; then
  printf '%d imagem(ns) reprovada(s).\n' "$falhas" >&2
  exit 1
fi

if [[ $inconclusivos -gt 0 ]]; then
  printf '%d imagem(ns) não puderam ser conferidas (registry inacessível daqui).\n' "$inconclusivos" >&2
  if [[ "$EXIGIR_CONFERENCIA" == "1" ]]; then
    echo "EXIGIR_CONFERENCIA=1: inconclusivo conta como falha." >&2
    exit 1
  fi
  echo "Rode de novo com rede aberta antes de confiar neste resultado." >&2
  exit 0
fi

printf '%d imagens conferidas.\n' "${#imagens[@]}"
