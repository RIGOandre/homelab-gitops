# Segredos: onde vive a chave e quem decifra o quê

## O desenho em uma frase

O Git guarda um segredo só, cifrado com age; o Argo CD o decifra num sidecar na
hora de renderizar; esse segredo abre o Vault; o External Secrets tira do Vault
tudo o mais.

    .enc.yaml no Git
        |
        | sidecar sops no argocd-repo-server (decifra no render)
        v
    Secret vault-approle no cluster
        |
        | ClusterSecretStore autentica via AppRole
        v
    Vault  ---- ExternalSecret ---->  Secrets dos apps

## Por que sidecar CMP e não o operator lendo a chave

As duas opções resolvem o problema. Escolhi o sidecar:

1. **Superfície da chave.** No sidecar, a chave privada está montada em um
   container que não escuta porta, não fala com a rede e não roda mais nada.
   Um operator que decifra precisa da chave no processo que também reconcilia
   tudo o que existe no cluster.
2. **O segredo decifrado não vira artefato.** Ele sai do sidecar como manifesto
   renderizado e vai direto para o apply. Não existe passo intermediário em que
   um Secret decifrado fica escrito em disco ou num objeto temporário.
3. **Diff que significa alguma coisa.** O Argo CD compara o objeto já decifrado
   com o que está no cluster. Com o arquivo cifrado aplicado cru, todo sync
   compararia base64 novo com base64 velho e o `OutOfSync` seria ruído — o sops
   regrava o MAC e o IV a cada save, então o arquivo muda mesmo quando o valor
   não muda.
4. **Não é só Secret.** Cobre um ConfigMap com senha dentro, um `values.yaml` de
   Helm com token. Um operator de Secret só cobre Secret.

O que se paga por isso: o `argocd-repo-server` ganha um sidecar e um init
container, e o bootstrap ganha um passo manual. Vale — o passo manual é uma vez
por vida do cluster.

## Onde vive a chave privada

Em dois lugares, nenhum deles no Git:

| Onde | Para quê | Como chega lá |
| --- | --- | --- |
| `~/.config/sops/age/keys.txt` na estação | Editar segredo, rodar `make cifrar` | `age-keygen -o ~/.config/sops/age/keys.txt` |
| Secret `sops-age` no namespace `argocd` | O sidecar decifrar no render | `bootstrap/instalar.sh`, a partir do arquivo acima |
| Cópia offline (papel ou pendrive no cofre) | Recuperar depois de perder a estação | Cópia manual, uma vez |

A terceira linha não é firula. Sem a chave privada, todo `.enc.yaml` do repositório
vira lixo permanente: não existe recuperação, não existe reset de senha. O age não
tem backdoor e é isso que o torna útil.

O `bootstrap/instalar.sh` cria esse Secret sozinho, lendo a chave da estação. O
comando abaixo é o mesmo que ele roda, e serve para quando o script foi executado
antes de a chave existir:

    kubectl -n argocd create secret generic sops-age \
      --from-file=keys.txt=$HOME/.config/sops/age/keys.txt

O que o `instalar.sh` **não** faz é instalar o plugin: o ConfigMap e o patch de
sidecar em `clusters/homelab/platform/secrets/argocd-cmp/` são aplicados pelo
alvo `make bootstrap`. As duas metades andam juntas, e é por isso que o caminho
recomendado de instalação é `make bootstrap`, não o script direto. Rodar só o
script deixa o Argo CD de pé sem quem decifre, e o único Application que falha é
`platform-secrets`.

Confirmar que só o sidecar enxerga:

    kubectl -n argocd get secret sops-age -o jsonpath='{.metadata.name}{"\n"}'
    kubectl -n argocd exec deploy/argocd-repo-server -c sops -- \
      test -r /etc/sops/age/keys.txt && echo "sidecar le a chave"

## O que o `.sops.yaml` decide

Só `data` e `stringData` são cifrados (`encrypted_regex`). `metadata`, `kind` e
os comentários ficam em claro. É proposital: o revisor do PR precisa ver que o
commit mexeu no segredo do Grafana no namespace `observabilidade`, e não numa
parede de base64 sem nome.

A regra casa por sufixo (`\.enc\.yaml$`), não por diretório, porque o sidecar usa
o mesmo glob para decidir o que decifrar. Regras diferentes nas duas pontas dão
um erro que só aparece no sync, com o manifesto errado já no log do repo-server.

## Rotação

Rotacionar a chave age é o procedimento caro; rotacionar um segredo do Vault é
barato de propósito. Por isso quase nada mora no Git.

Trocar a chave age (só se ela vazar ou se alguém com acesso sair):

    age-keygen -o ~/.config/sops/age/nova.txt
    # 1. adicionar a chave pública NOVA ao .sops.yaml, mantendo a velha
    # 2. recifrar tudo para os dois destinatarios:
    for f in $(find clusters -name '*.enc.yaml'); do sops updatekeys -y "$f"; done
    # 3. trocar o Secret sops-age, reiniciar o repo-server, confirmar sync
    # 4. só então remover a chave velha do .sops.yaml e rodar updatekeys de novo

Manter as duas chaves durante a troca não é excesso de cuidado: se você remover a
velha e o Secret novo não pegar, o Argo CD para de renderizar tudo que tem
segredo e você não tem como decifrar para conferir.

Rotacionar um segredo comum não passa por aqui:

    vault kv put kv/observabilidade/grafana usuario=admin senha=...

O ESO reescreve o Secret no próximo `refreshInterval`. Para não esperar:

    kubectl -n observabilidade annotate externalsecret grafana-admin \
      force-sync=$(date +%s) --overwrite

## Um segundo destinatário no `.sops.yaml`

Hoje há uma chave só. O certo é ter duas: a do operador e uma offline, guardada
fora da estação. Enquanto for uma, perder a estação e a cópia offline ao mesmo
tempo custa o repositório inteiro de segredos. Está aqui como dívida assumida, não
como coisa que passou despercebida.

## O que o CI garante

`hack/verificar-segredos.py`, rodado no CI, reprova o PR se:

- um `*.enc.yaml` não tiver bloco `sops:` ou tiver valor em claro dentro de `data`;
- existir `kind: Secret` com `data`/`stringData` preenchido fora do padrão cifrado;
- um arquivo cifrado tiver nome que o sidecar não reconhece (sem `.enc.yaml`) — o
  Argo CD aplicaria o blob cru e o erro não diria o motivo;
- uma chave privada age (`AGE-SECRET-KEY-1`) aparecer em qualquer arquivo.

Isso pega o erro comum, que é `kubectl create secret --dry-run -o yaml >` num
arquivo do repositório e esquecer de cifrar. Não pega segredo colado dentro de um
ConfigMap ou de um `values.yaml` de Helm — para isso não há verificador que
substitua revisão.
