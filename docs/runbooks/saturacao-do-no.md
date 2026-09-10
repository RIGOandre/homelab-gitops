# Runbook: nó saturado (memória, OOM kill, CPU)

Cobre três alertas que têm a mesma origem e correções diferentes:

| Alerta | O que já aconteceu |
| --- | --- |
| `MemoriaDoNoSaturada` | Mais de 90% da memória comprometida há 10 min. Ainda não morreu ninguém. |
| `NoSofreuOomKill` | O kernel já matou processo. Não é aviso. |
| `CpuDoNoSaturada` | CPU em platô há 20 min. Fila, não pico. |

Se os três dispararam juntos, atenda o `NoSofreuOomKill` primeiro: ele diz o que
de fato quebrou, e é ele que explica o `crashloop.md` que vai chegar em seguida.

## Primeiro comando

```
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -20
```

Se o `kubectl top` responder `Metrics API not available`, o metrics-server está
fora — provavelmente vítima da mesma saturação. Vá direto ao nó:

```
free -h
ps -eo pid,ppid,rss,comm --sort=-rss | head -15
```

## MemoriaDoNoSaturada

O alerta usa `MemAvailable`, não `MemFree`. Isso importa na hora de conferir: um
`free -h` com `free` perto de zero e `available` folgado é o kernel usando a RAM
como cache, e está tudo certo. A coluna que corresponde ao alerta é `available`.

### Causas, em ordem

**1. Pod sem `limits.memory`.** Num nó só, um app com vazamento cresce até o
kernel intervir. É a causa mais comum e a mais fácil de confirmar:

```
kubectl get pods -A -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    for c in p['spec']['containers']:
        if not (c.get('resources') or {}).get('limits', {}).get('memory'):
            print(p['metadata']['namespace'], p['metadata']['name'], c['name'])
"
```

**2. Retenção do Prometheus.** O TSDB usa memória proporcional ao número de
séries ativas, não ao tamanho do disco. ServiceMonitor novo com label de alta
cardinalidade dobra o consumo sem mudar nada visível.

```
kubectl -n observabilidade top pods
```

E, no Prometheus, quantas séries existem (a consulta responde ao ponto):

```
count({__name__=~".+"})
```

**3. Page cache preso por I/O.** Menos comum, e a pista é `CpuDoNoSaturada` junto
com `iowait` alto:

```
vmstat 1 5
```

### Corrigir

Curto prazo, o que devolve memória agora: reiniciar o maior consumidor.

```
kubectl -n NAMESPACE rollout restart deploy/NOME
```

Longo prazo é sempre `limits` no manifesto, via PR. `kubectl edit` some no
próximo sync do Argo CD.

## NoSofreuOomKill

O contador `node_vmstat_oom_kill` subiu. Alguma coisa já morreu; a pergunta é o
quê, e o Kubernetes nem sempre sabe (se o kernel matou um processo dentro do
container sem derrubar o PID 1, o Pod continua `Running` e estranho).

```
dmesg -T | grep -i -E 'killed process|out of memory' | tail -20
```

A linha do `dmesg` traz o nome do processo e o `total-vm`. Para ligar ao Pod:

```
kubectl get pods -A -o wide | grep -i NOME_DO_PROCESSO
kubectl get pods -A -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    for s in p.get('status',{}).get('containerStatuses') or []:
        if (s.get('lastState',{}).get('terminated') or {}).get('reason')=='OOMKilled':
            print(p['metadata']['namespace'], p['metadata']['name'], s['name'],
                  s['restartCount'])
"
```

**A armadilha:** aumentar o `limit` do container que apareceu. Se o nó já está a
90%, subir o limite só move o OOM para o vizinho — e o kernel escolhe a vítima,
não você. Antes de aumentar qualquer limite, confira se a soma dos `requests`
cabe no nó:

```
kubectl describe node | grep -A8 'Allocated resources'
```

Se a soma passou de 100%, o cluster está com overcommit e a correção é reduzir
alguém, não aumentar mais um.

## CpuDoNoSaturada

O alerta é de platô: 90% por 20 minutos. Pico de build não dispara, e é assim que
foi calibrado.

```
kubectl top pods -A --sort-by=cpu | head -15
uptime
```

O `load average` do `uptime` comparado ao número de núcleos (`nproc`) diz se é
CPU mesmo ou fila de I/O: load muito acima dos núcleos com CPU ociosa é I/O.

```
vmstat 1 5   # coluna wa
```

Suspeitos recorrentes num homelab, em ordem: compactação do Prometheus, indexação
do Loki, sync em laço do Argo CD (`argocd-degradado.md`, causa 4) e um
`CrashLoopBackOff` reiniciando a cada 5 s.

```
kubectl get pods -A --sort-by=.status.containerStatuses[0].restartCount | tail -10
```

Um Pod com centenas de restarts consome CPU só de subir e morrer.

## Como saber que passou

```
kubectl top nodes
free -h
dmesg -T | grep -i 'killed process' | tail -3
```

Para o OOM: nenhuma linha nova no `dmesg` depois do horário da correção. O alerta
usa `increase(...[10m])`, então ele só se resolve 10 minutos depois do último
kill — esperar isso é normal, não é sinal de que não funcionou.

Para memória e CPU, confirme que ficou: os dois alertas têm `for` longo (10 e
20 min) justamente porque a métrica oscila. Um valor bom em uma leitura não
significa nada; olhe o gráfico da última hora antes de fechar.

## Depois

Nó saturado num cluster de um nó só é sempre a mesma pergunta: cabe mais alguma
coisa aqui? Se a resposta virou "não" de forma estável, a ação não é ajustar
limite — é tirar carga ou aumentar a máquina, e isso vale um registro em
`docs/postmortems/`.
