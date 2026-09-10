# Runbook: Application do Argo CD degradado

## O que o alerta quer dizer

Um `Application` está em `Degraded`, ou parado em `OutOfSync` por tempo demais,
ou em `Unknown`. Os três são coisas diferentes:

- **Degraded** — o Argo CD aplicou os manifestos e o que nasceu deles não está
  saudável. O problema está no app, não no Argo CD.
- **OutOfSync** que não resolve — o Argo CD sabe o que fazer e não consegue, ou
  está configurado para não fazer.
- **Unknown** — o Argo CD não conseguiu nem calcular o estado desejado. Aqui o
  problema é do próprio Argo CD, quase sempre no `repo-server`.

Ler a coluna certa poupa meia hora.

## Primeiro comando

```
kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NOME:.metadata.name,SYNC:.status.sync.status,SAUDE:.status.health.status,MSG:.status.conditions[0].message
```

Com a CLI logada, o mais direto é:

```
argocd app get NOME
```

A lista de recursos no fim da saída marca exatamente qual filho está ruim. É por
ele que se continua.

## Causas, em ordem de probabilidade

### 1. Degraded: um recurso filho não sobe

O `Application` é só o mensageiro.

```
argocd app get NOME | grep -v Healthy
kubectl -n NAMESPACE get pods
```

Achado o Pod ruim, o runbook é `crashloop.md`. Não mexa no `Application`.

### 2. Unknown ou sync falhando: o plugin sops não decifrou

Específico deste repositório e a causa que mais engana, porque a mensagem no
`Application` fala de manifesto e não de chave.

```
kubectl -n argocd logs deploy/argocd-repo-server -c sops --tail=100
kubectl -n argocd logs deploy/argocd-repo-server -c argocd-repo-server --tail=100 | grep -i -E 'plugin|sops|generate'
```

O que aparece e o que quer dizer:

- `no matching creation rules found` — o arquivo não casa com o `path_regex` do
  `.sops.yaml`. Em geral alguém salvou como `segredo.yaml` em vez de
  `segredo.enc.yaml`.
- `no key could decrypt the data` — o Secret `sops-age` tem a chave errada, ou o
  arquivo foi cifrado para outro destinatário. Confira a pública do arquivo
  contra a do `.sops.yaml`:

```
grep -A1 'recipient:' clusters/homelab/platform/secrets/*.enc.yaml
grep 'age:' .sops.yaml
```

- `MAC mismatch` — alguém editou o `.enc.yaml` na mão. O arquivo tem que voltar a
  ser escrito por `sops`, não por editor.
- Sidecar em `CrashLoopBackOff` ou ausente:

```
kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server \
  -o jsonpath='{range .items[*].status.containerStatuses[*]}{.name}{"\t"}{.ready}{"\n"}{end}'
```

Se o container `sops` não existe, o patch do repo-server não foi aplicado — veja
`docs/segredos.md`.

### 3. Sync falhando por ordem de criação

CRD que ainda não existe quando o CR é aplicado, ou namespace ausente. A
mensagem é `no matches for kind` ou `namespaces "x" not found`.

```
argocd app get NOME | grep -i -E 'SyncError|no matches|not found'
kubectl get crd | grep -i EXEMPLO
```

Correção estrutural: `sync-wave` no objeto que precisa vir antes, ou
`CreateNamespace=true` nas `syncOptions`. Um `argocd app sync` repetido também
resolve na segunda tentativa — e é por isso que esse erro passa despercebido
durante meses.

### 4. OutOfSync eterno com auto-sync ligado

O Argo CD está aplicando e alguma coisa reverte logo depois. Suspeitos de sempre:
um webhook mutante, um operator que é dono do mesmo campo, ou um `kubectl edit`
que alguém fez e o cluster mantém porque `prune` está desligado.

```
argocd app diff NOME
kubectl -n NAMESPACE get RECURSO NOME -o jsonpath='{.metadata.managedFields[*].manager}{"\n"}'
```

Mais de um `manager` no campo em disputa confirma. A saída é `ignoreDifferences`
no `Application` para o campo específico, não desligar o auto-sync.

### 5. Dois Applications donos do mesmo objeto

`SharedResourceWarning` nas condições. Um sincroniza, o outro reverte, para
sempre.

```
kubectl -n argocd get applications.argoproj.io -o json \
  | python3 -c "import json,sys; [print(a['metadata']['name'], c.get('type'), c.get('message')) for a in json.load(sys.stdin)['items'] for c in (a['status'].get('conditions') or [])]"
```

### 6. Repositório inacessível

```
kubectl -n argocd logs deploy/argocd-repo-server -c argocd-repo-server --tail=50 | grep -i -E 'auth|denied|dial'
argocd repo list
```

### 7. repo-server sem memória

Repositório grande, ou vários renders simultâneos, e o container morre por OOM. O
sintoma é `Unknown` intermitente, que volta sozinho — o que faz o alerta parecer
falso positivo.

```
kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server \
  -o jsonpath='{range .items[*].status.containerStatuses[*]}{.name}{"\t"}{.restartCount}{"\t"}{.lastState.terminated.reason}{"\n"}{end}'
```

## Ferramenta grossa, e quando usar

Forçar recomparação (barato, sem risco):

```
argocd app get NOME --refresh
```

Recomparação ignorando cache (usar quando o repo-server parece estar com estado
velho):

```
argocd app get NOME --hard-refresh
```

Reiniciar o repo-server (derruba render por ~30 s, nenhum app cai):

```
kubectl -n argocd rollout restart deploy/argocd-repo-server
kubectl -n argocd rollout status deploy/argocd-repo-server
```

Não rode `argocd app sync --force` para "destravar". Ele apaga e recria o
recurso; num StatefulSet com dado isso é perda de dados, não destravamento.

## Como saber que passou

```
kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NOME:.metadata.name,SYNC:.status.sync.status,SAUDE:.status.health.status
```

Tudo `Synced` e `Healthy`. Depois confirme que ficou:

```
argocd app get NOME | grep -E 'Sync Status|Health Status|Repeat'
```

Um app que passa por `Synced` e volta para `OutOfSync` em poucos minutos é a
causa 4, não conserto. Deixe rodando dois ciclos de reconciliação (o padrão é
3 min) antes de fechar o alerta.
