#!/usr/bin/env bash
#
# Bootstrap do Argo CD no cluster k3s do homelab.
#
# Roda uma vez, na mão, num cluster recém-provisionado pelo Terraform. Tudo que
# ele faz é colocar o Argo CD de pé e entregar a ele o Application raiz; a partir
# do sync seguinte o Argo CD passa a se reconciliar pelo Git (clusters/homelab/apps/argocd.yaml
# aponta para a mesma versão fixada aqui embaixo). Ou seja: depois deste script,
# atualizar o Argo CD é editar o YAML e dar push, nunca rodar este script de novo
# com outra versão - se as duas fontes divergirem, o Argo CD reverte o kubectl
# no primeiro selfHeal e a atualização "some" sem erro nenhum.
#
# É idempotente: rodar de novo na mesma versão não muda nada.

set -euo pipefail

# Versão fixada e não "stable": o Argo CD que se auto-gerencia num cluster de nó
# único não pode se atualizar sozinho no meio de um sync e perder o próprio
# deployment. Ao subir aqui, subir junto em clusters/homelab/apps/argocd.yaml.
readonly ARGOCD_VERSAO="v2.13.3"
readonly ARGOCD_NAMESPACE="argocd"
readonly ESPERA="300s"

# Chave privada age usada pelo sidecar sops do repo-server para decifrar os
# arquivos *.enc.yaml do repositório (ver .sops.yaml na raiz). Fica na estação do
# operador e nunca no Git; o bootstrap só a copia para dentro do cluster.
readonly ARQUIVO_CHAVE_AGE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"

# Caminho resolvido a partir do próprio arquivo: o script é chamado tanto da raiz
# do repositório quanto de dentro de bootstrap/, e caminho relativo quebraria num
# dos dois casos.
# Declarado e atribuído em linhas separadas: com `readonly X="$(cmd)"` o status
# de saída do subshell é o do readonly, sempre zero, e um cd que falhou passaria
# despercebido levando o script a operar no diretório errado.
DIRETORIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIRETORIO

log() {
  printf '==> %s\n' "$*"
}

erro() {
  printf 'ERRO: %s\n' "$*" >&2
  exit 1
}

command -v kubectl >/dev/null 2>&1 || erro "kubectl não encontrado no PATH."

# Falha cedo e com mensagem clara: sem esta checagem, o primeiro apply morre com
# um erro de conexão do client-go que não diz nada sobre o kubeconfig errado.
kubectl cluster-info >/dev/null 2>&1 \
  || erro "cluster inacessível. Confira o KUBECONFIG apontado para o k3s do homelab."

log "Namespace ${ARGOCD_NAMESPACE}"
kubectl apply -f "${DIRETORIO}/argocd/namespace.yaml"

log "Argo CD ${ARGOCD_VERSAO}"
# --server-side porque as CRDs do Argo CD passam dos 256 KB da anotação
# last-applied-configuration usada pelo apply client-side, e o apply falha com
# "metadata.annotations: Too long". --force-conflicts porque, numa reexecução, os
# campos já pertencem ao application-controller (o Argo CD gerenciando a si
# mesmo) e o kubectl recusaria o apply; a posse volta para o Argo no sync seguinte.
kubectl apply \
  --namespace "${ARGOCD_NAMESPACE}" \
  --server-side \
  --force-conflicts \
  --filename "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSAO}/manifests/install.yaml"

# O apply retorna antes da CRD ficar registrada no api-server. Aplicar o root-app
# nessa janela dá "no matches for kind Application" e derruba o bootstrap inteiro.
log "Aguardando a CRD Application ser estabelecida"
kubectl wait --for=condition=Established --timeout="${ESPERA}" crd/applications.argoproj.io

log "Aguardando os componentes do Argo CD"
# Só o server e o repo-server: são os dois que o root-app precisa (API para
# receber o objeto, repo-server para clonar o Git). O application-controller é
# StatefulSet e sobe junto; esperar por ele aqui só alongaria o bootstrap.
kubectl rollout status --namespace "${ARGOCD_NAMESPACE}" deployment/argocd-server --timeout="${ESPERA}"
kubectl rollout status --namespace "${ARGOCD_NAMESPACE}" deployment/argocd-repo-server --timeout="${ESPERA}"

log "Chave age do sops"
if [[ -f "${ARQUIVO_CHAVE_AGE}" ]]; then
  # create --dry-run | apply em vez de create direto: create falha com AlreadyExists
  # na segunda execução e o set -e derrubaria o bootstrap inteiro por causa disso.
  kubectl create secret generic sops-age \
    --namespace "${ARGOCD_NAMESPACE}" \
    --from-file=keys.txt="${ARQUIVO_CHAVE_AGE}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  # Aviso e segue: quem só quer subir o Argo CD e olhar a interface não precisa
  # da chave. O custo de não ter é o Application platform-secrets falhar o sync
  # até alguém criar este Secret - falha visível, não silenciosa.
  printf 'AVISO: %s não existe. O Secret sops-age não foi criado e o Application\n' "${ARQUIVO_CHAVE_AGE}" >&2
  printf '       platform-secrets vai falhar o sync até a chave entrar no cluster.\n' >&2
fi

log "Application raiz (app-of-apps)"
kubectl apply -f "${DIRETORIO}/argocd/root-app.yaml"

cat <<'MENSAGEM'

Bootstrap concluído. O Argo CD agora se gerencia pelo Git.

Senha inicial do usuário admin:

  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d; echo

Acesso à interface enquanto o Ingress ainda não subiu:

  kubectl -n argocd port-forward svc/argocd-server 8080:443

O Secret argocd-initial-admin-secret é descartável: depois de trocar a senha,
apagar o Secret. Ele é recriado só se o Argo CD for reinstalado do zero.
MENSAGEM
