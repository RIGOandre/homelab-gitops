# Runbook: Pod em CrashLoopBackOff

## O que o alerta quer dizer

Um container morreu, o kubelet subiu de novo, morreu de novo. O `BackOff` é o
kubelet esperando cada vez mais entre as tentativas (5 s, 10 s, 20 s... até
5 min). Isso importa na hora de conferir a correção: depois de um tempo em laço,
o Pod pode levar cinco minutos para tentar de novo mesmo já estando consertado.

`CrashLoopBackOff` quer dizer que o container **iniciou e saiu**. Se ele nem
chegou a iniciar, o estado é outro (`ImagePullBackOff`,
`CreateContainerConfigError`) e o caminho é diferente.

## Primeiro comando

```
kubectl -n NAMESPACE logs POD --previous --tail=100
```

`--previous` é o que importa: sem ele você lê o log do container atual, que
provavelmente ainda nem escreveu nada. Se der `previous terminated container not
found`, o Pod acabou de ser recriado — espere o próximo crash e repita.

Em seguida, sempre:

```
kubectl -n NAMESPACE describe pod POD
```

O bloco `Last State: Terminated` e a seção `Events` dizem quase tudo.

## Causas, em ordem de probabilidade

### 1. Configuração faltando ou errada (exit code 1 ou 2)

O app sobe, não acha uma variável, uma URL ou uma credencial, e sai. O log
`--previous` mostra a mensagem do próprio app. É a maioria dos casos.

Confirmar qual valor chegou:

```
kubectl -n NAMESPACE get pod POD -o jsonpath='{.spec.containers[0].env}' | tr ',' '\n'
kubectl -n NAMESPACE exec POD -- env 2>/dev/null | sort
```

O `exec` só funciona se o container ficar vivo tempo bastante; em laço rápido,
use o `jsonpath`.

### 2. Segredo existe mas está vazio, porque o ExternalSecret não sincronizou

Caso específico deste cluster e fácil de diagnosticar errado, porque o Secret
existe — só que sem as chaves. O app reclama de senha vazia e você procura no
lugar errado.

```
kubectl -n NAMESPACE get externalsecret
kubectl -n NAMESPACE describe externalsecret NOME | tail -20
kubectl -n NAMESPACE get secret NOME -o jsonpath='{.data}' | head -c 200
```

`SecretSyncedError` no status aponta para o ESO. As causas de sempre: Vault
selado depois de reinício do nó, caminho errado no `remoteRef`, ou o AppRole com
`secret-id` vencido. Veja `clusters/homelab/platform/secrets/README.md`.

### 3. OOMKilled (exit code 137)

```
kubectl -n NAMESPACE get pod POD \
  -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.lastState.terminated.reason}{"\t"}{.lastState.terminated.exitCode}{"\n"}{end}'
```

`OOMKilled` é o container estourando o próprio `limits.memory`. Se o limite
parece razoável e o app estoura mesmo assim, a JVM ou o Node dentro dele
provavelmente não enxergam o cgroup e dimensionam heap pela RAM do nó inteiro.

Cuidado com o 137 sem `OOMKilled`: aí foi `SIGKILL` de fora — em geral liveness
probe (causa 4) ou o OOM killer do kernel matando por pressão do nó, que aparece
no `dmesg -T | grep -i killed` e não no status do Pod.

### 4. Liveness probe matando o app antes de ele terminar de subir

O sintoma típico: log `--previous` sem erro nenhum, aplicação aparentemente
saudável, e mesmo assim reinício a cada N segundos.

```
kubectl -n NAMESPACE describe pod POD | grep -E 'Liveness|Readiness|Startup|Killing'
```

`Liveness probe failed` nos eventos confirma. A correção certa é `startupProbe`,
não aumentar `initialDelaySeconds` no liveness — com `startupProbe` o app ganha
uma janela longa para subir e continua com detecção rápida depois.

### 5. Dependência fora do ar

Banco, Vault ou outro serviço que o app exige no boot. O log mostra timeout de
conexão.

```
kubectl -n NAMESPACE run diag --rm -it --restart=Never \
  --image=busybox:1.36 -- nc -zv postgres.dados.svc.cluster.local 5432
```

Se a dependência estiver mesmo fora, este Pod é sintoma. Trate a dependência.

### 6. Arquitetura errada da imagem

`exec format error` no log. Imagem `amd64` num nó `arm64` ou o contrário —
acontece ao trocar de hardware ou ao usar uma tag que perdeu o multi-arch.

```
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}{"\n"}'
```

## Como saber que passou

```
kubectl -n NAMESPACE get pod POD -w
```

O que confirma não é o Pod aparecer `Running`: é o `RESTARTS` parar de subir. Um
Pod em laço fica `Running` por alguns segundos a cada ciclo.

Espere pelo menos o dobro do maior intervalo de backoff que você viu. Se estava
no teto (5 min), dez minutos sem reinício novo é o mínimo para chamar de
resolvido. Para não esperar, force o ciclo:

```
kubectl -n NAMESPACE delete pod POD
```

Depois:

```
kubectl -n NAMESPACE get pods
kubectl -n NAMESPACE get events --sort-by=.lastTimestamp | tail -20
```

## Se a correção foi por `kubectl edit`

O Argo CD desfaz no próximo sync. Serve para confirmar a hipótese, não para
encerrar. A correção só está feita quando está no Git e o Application voltou a
`Synced`.
