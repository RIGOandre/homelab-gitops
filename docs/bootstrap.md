# Do zero ao cluster no ar

Ordem fixa. Cada passo depende do anterior ter dado certo de verdade, não de ter
terminado sem erro na tela.

O caminho todo leva entre 15 e 25 minutos, quase todos esperando imagem baixar.

## Antes de começar

Na estação:

- `terraform`, `kubectl`, `sops`, `age`, `git`
- chave privada age em `~/.config/sops/age/keys.txt`, modo `0600`

Se você está montando o cluster pela primeira vez e ainda não existe chave:

```
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

A pública que ele imprime vai para o `.sops.yaml`. Guarde a privada fora da
estação também — sem ela, todo `.enc.yaml` do repositório é irrecuperável. Ver
`docs/segredos.md`.

No alvo:

- máquina ou VM com Debian/Ubuntu, SSH por chave, `sudo` sem senha
- IP fixo (por DHCP reservado ou estático). O kubeconfig vai gravar esse IP; se
  ele mudar depois, nada funciona e a mensagem de erro não diz por quê.

## 1. Terraform: provisionar a máquina e instalar o k3s

```
cd terraform/
terraform init
terraform plan -out=plano.tfplan
terraform apply plano.tfplan
```

`plan` num arquivo e `apply` nesse arquivo, sempre. `terraform apply` direto
replaneja na hora e aplica algo que ninguém leu.

Leia o plano de verdade. Em cluster que já existe, procure por `destroy` e por
`forces replacement` antes de digitar `yes`.

Confirmar que passou:

```
terraform output
ssh USUARIO@IP 'sudo systemctl is-active k3s'
```

Tem que responder `active`. Se responder `activating`, espere 30 s e repita — o
k3s demora a subir na primeira vez porque está baixando as imagens de sistema.

## 2. Pegar o kubeconfig

```
scp USUARIO@IP:/etc/rancher/k3s/k3s.yaml ~/.kube/homelab.yaml
sed -i "s|127.0.0.1|IP|" ~/.kube/homelab.yaml
chmod 600 ~/.kube/homelab.yaml
export KUBECONFIG=~/.kube/homelab.yaml
```

O `sed` não é detalhe: o k3s escreve `server: https://127.0.0.1:6443` no arquivo,
que é verdade dentro do nó e mentira em qualquer outro lugar. Sem trocar, todo
`kubectl` da estação tenta falar consigo mesmo e dá `connection refused`.

Confirmar:

```
kubectl get nodes
```

Um nó, `Ready`. Se aparecer `NotReady`, pare aqui — ver `docs/runbooks/no-notready.md`.
Seguir com o nó `NotReady` só produz um bootstrap pela metade, difícil de
desfazer.

## 3. Confirmar que a chave age está na estação

O `bootstrap/instalar.sh` procura a chave em `$SOPS_AGE_KEY_FILE` ou, na falta,
em `~/.config/sops/age/keys.txt`, e cria o Secret `sops-age` no namespace
`argocd` a partir dela. Você não precisa criar o Secret à mão — precisa garantir
que o arquivo existe antes de rodar o script.

```
test -f ~/.config/sops/age/keys.txt && echo "chave no lugar"
age-keygen -y ~/.config/sops/age/keys.txt
grep 'age:' .sops.yaml
```

As duas últimas linhas têm que imprimir a mesma chave pública. Se não baterem, o
Argo CD instala normalmente e falha só na primeira Application que tem segredo,
com uma mensagem que fala de manifesto e não de chave.

Se o script avisar que não achou a chave, ele segue mesmo assim e o Secret fica
faltando. Para criar depois:

```
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
kubectl -n argocd rollout restart deployment/argocd-repo-server
```

## 4. Instalar o Argo CD e o sidecar que decifra

```
make bootstrap
```

São duas metades que precisam andar juntas:

1. `bootstrap/instalar.sh` — instala o Argo CD numa versão fixada, cria o Secret
   `sops-age` e entrega a Application raiz.
2. O alvo do Makefile — aplica o ConfigMap do plugin e o patch de sidecar em
   `clusters/homelab/platform/secrets/argocd-cmp/`, e espera o rollout.

Rodar só o script deixa o Argo CD de pé sem o sidecar sops; tudo sincroniza
menos `platform-secrets`. Ver `docs/segredos.md`.

Este passo existe fora do GitOps por um motivo circular: o Argo CD não consegue
sincronizar o plugin de que ele próprio precisa para sincronizar. Depois daqui,
nada mais é aplicado à mão.

Confirmar:

```
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server \
  -o jsonpath='{range .items[*].status.containerStatuses[*]}{.name}{"\t"}{.ready}{"\n"}{end}'
```

Tem que aparecer o container `sops` com `true`. Se ele não estiver na lista, o
patch não foi aplicado e o passo 5 vai falhar de um jeito confuso.

## 5. O Argo CD assume

A partir daqui você observa. A Application raiz descobre as outras e o cluster se
monta sozinho, em ondas.

```
kubectl -n argocd get applications.argoproj.io -w
```

De 5 a 15 min, dependendo da internet. A ordem esperada: rede e cert-manager
primeiro, depois External Secrets, depois observabilidade, depois os apps.

É normal ver `Degraded` e `OutOfSync` durante a subida — um app que depende de
CRD que ainda não existe erra na primeira tentativa e acerta na segunda. O que
não é normal é continuar assim depois de 15 min.

Senha inicial do admin:

```
make senha-argocd
```

Terminou quando:

```
kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NOME:.metadata.name,SYNC:.status.sync.status,SAUDE:.status.health.status
kubectl get pods -A --field-selector=status.phase!=Running
```

Tudo `Synced`/`Healthy` e a segunda lista vazia (ou só com `Completed` de Job).

## E quando dá errado

Os três primeiros lugares para olhar, nesta ordem. Resistir à vontade de pular
para o quarto economiza tempo.

### 1. O nó, antes de qualquer coisa do Kubernetes

```
kubectl get nodes
ssh USUARIO@IP 'df -h /var/lib/rancher; systemctl status k3s --no-pager | head -20'
```

Metade dos bootstraps que "falham no Argo CD" são disco cheio ou k3s reiniciando.
Nenhum log de Argo CD vai dizer isso. Runbooks: `no-notready.md`,
`disco-cheio.md`.

### 2. O repo-server do Argo CD, com o sidecar sops

É onde o desenho deste repositório tem sua parte mais frágil, então é onde se
olha antes dos apps.

```
kubectl -n argocd logs deploy/argocd-repo-server -c sops --tail=100
kubectl -n argocd logs deploy/argocd-repo-server -c argocd-repo-server --tail=100
```

`no key could decrypt the data` quer dizer que o passo 3 não foi feito, ou foi
feito com a chave errada. Confira que a pública do `.sops.yaml` é a mesma da
chave que virou o Secret:

```
age-keygen -y ~/.config/sops/age/keys.txt
grep 'age:' .sops.yaml
```

As duas linhas têm que terminar igual.

### 3. Eventos do cluster, ordenados por tempo

```
kubectl get events -A --sort-by=.lastTimestamp | tail -40
```

`Failed to pull image` (internet ou rate limit do registry), `FailedScheduling`
(taint de disk-pressure), `FailedMount` (Secret que o ESO ainda não criou). Os
três aparecem aqui em uma linha e em nenhum outro lugar de forma tão direta.

### Recomeçar

Se o passo 1 der errado no meio, `terraform destroy` e recomeçar é mais rápido do
que consertar. Do passo 3 em diante, não: refazer só o passo que falhou é sempre
melhor, porque o estado do cluster é reconstruível pelo Argo CD e o do Terraform
não.
