#!/usr/bin/env bash
#
# Valida os manifestos de clusters/ contra o schema do Kubernetes.
#
# Existe como script, e não como uma linha dentro do ci.yml, para que CI vermelho
# seja reproduzível na estação com o mesmo comando. Verificação que só roda no CI
# vira verificação que ninguém consegue depurar.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Versão lida do Terraform em vez de fixada aqui: validar contra 1.31 um cluster
# que subiu 1.33 dá o pior tipo de verde - o que passa e não quer dizer nada.
# O padrão do fallback é só para o caso de a variável mudar de nome.
VERSAO_K8S="$(sed -n 's/.*"v\([0-9]\+\.[0-9]\+\.[0-9]\+\)+k3s[0-9]\+".*/\1/p' \
  terraform/variables.tf | head -1)"
VERSAO_K8S="${VERSAO_K8S:-1.31.5}"

# Kinds que o kubeconform vai pular por não achar schema, e que a gente aceita
# pular. Vêm de CRD (Argo CD, Prometheus Operator, cert-manager, External
# Secrets) e não estão no store público de schemas.
#
# A lista existe porque -ignore-missing-schemas sozinho é perigoso: ele pula
# qualquer kind desconhecido, inclusive `kind: Sercret` digitado errado. Com a
# lista, kind desconhecido que não esteja aqui reprova.
#
# O preço: CRD nova exige uma linha aqui. É de propósito - a linha é a revisão.
KINDS_SEM_SCHEMA=(
  Application
  ApplicationSet
  AppProject
  Certificate
  ClusterIssuer
  ClusterSecretStore
  ExternalSecret
  Issuer
  PodMonitor
  Probe
  PrometheusRule
  SecretStore
  ServiceMonitor
)

# Catálogo público de schemas de CRD. Sem ele, todo Application, PrometheusRule
# e ExternalSecret sai "skipped" — e um manifesto pulado passa no CI parecendo
# aprovado. É a diferença entre "o YAML é válido" e "o campo existe no CRD".
#
# Depende de rede. Quando não dá para alcançar, o script diz e continua sem o
# catálogo em vez de reprovar: quem valida no avião não deve levar vermelho por
# causa do wi-fi. No CI a rede é aberta, e EXIGIR_CATALOGO=1 torna a ausência
# do catálogo uma falha.
CATALOGO='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
EXIGIR_CATALOGO="${EXIGIR_CATALOGO:-0}"

locais=(-schema-location default)
if curl -fsS --max-time 15 -o /dev/null \
     "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/argoproj.io/application_v1alpha1.json" 2>/dev/null; then
  locais+=(-schema-location "${CATALOGO}")
  echo "catálogo de CRDs acessível: os kinds de CRD vão ser validados de verdade"
else
  if [[ "${EXIGIR_CATALOGO}" == "1" ]]; then
    echo "REPROVADO: EXIGIR_CATALOGO=1 mas o catálogo de CRDs não respondeu." >&2
    exit 1
  fi
  echo "aviso: catálogo de CRDs inacessível; os kinds de CRD vão sair pulados."
fi

echo "kubeconform contra Kubernetes ${VERSAO_K8S}"

# -ignore-filename-pattern, um a um e por quê:
#   *.enc.yaml   - cifrado pelo sops, que acrescenta o bloco 'sops' no topo. Em
#                  -strict isso é 'additionalProperties not allowed'. Quem
#                  confere estes é hack/verificar-segredos.py.
#   *.values.yaml - values de chart Helm, não manifesto. Não tem kind.
#   *.json        - dashboard de Grafana.
saida="$(kubeconform \
  -strict \
  -verbose \
  -summary \
  -kubernetes-version "${VERSAO_K8S}" \
  "${locais[@]}" \
  -ignore-missing-schemas \
  -ignore-filename-pattern '\.enc\.yaml$' \
  -ignore-filename-pattern '\.values\.yaml$' \
  -ignore-filename-pattern '\.json$' \
  clusters/ 2>&1)"

echo "${saida}"

# Kinds efetivamente pulados nesta rodada.
mapfile -t pulados < <(
  printf '%s\n' "${saida}" \
    | sed -n 's/.* \([A-Za-z0-9]\+\) skipped$/\1/p' \
    | sort -u
)

inesperados=()
for kind in "${pulados[@]}"; do
  conhecido=""
  for esperado in "${KINDS_SEM_SCHEMA[@]}"; do
    [[ "${kind}" == "${esperado}" ]] && conhecido=1 && break
  done
  [[ -n "${conhecido}" ]] || inesperados+=("${kind}")
done

if [[ ${#inesperados[@]} -gt 0 ]]; then
  echo
  echo "REPROVADO: kind sem schema e fora da lista conhecida: ${inesperados[*]}" >&2
  echo "Ou é CRD nova (acrescente em KINDS_SEM_SCHEMA neste arquivo)," >&2
  echo "ou é kind escrito errado - que é justamente o que a lista pega." >&2
  exit 1
fi

echo
if [[ ${#pulados[@]} -eq 0 ]]; then
  echo "Nenhum kind pulado: todo manifesto foi validado contra um schema."
else
  echo "Kinds pulados por falta de schema (não foram validados): ${pulados[*]}"
  echo "Os demais foram validados contra o schema da API ou do catálogo de CRDs."
fi
