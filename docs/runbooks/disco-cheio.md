# Runbook: disco cheio

## O que o alerta quer dizer

O sistema de arquivos do nó passou do limite. Num cluster de um nó só isso não é
aviso: quando o kubelet cruza `nodefs.available<10%` ou `imagefs.available<15%`
ele põe o taint `node.kubernetes.io/disk-pressure:NoSchedule` no nó, para de
aceitar Pod novo e começa a despejar os que já estão rodando. Antes disso, o
sqlite do k3s para de escrever e a API passa a responder 500 em tudo que grava.

O alerta dispara com folga em relação a esses limites. A folga existe para você
resolver com calma, não para ignorar.

## Primeiro comando

No nó, por SSH:

```
df -h / /var /var/lib/rancher
```

Anote qual sistema de arquivos encheu antes de mexer em qualquer coisa. Em k3s
quase sempre é o que contém `/var/lib/rancher`.

## Causas, em ordem de probabilidade

### 1. Imagens velhas do containerd

De longe a mais comum. Cada `helm upgrade` e cada tag nova deixa a camada antiga
para trás, e o k3s não faz GC agressivo enquanto sobra espaço.

Confirmar:

```
du -sh /var/lib/rancher/k3s/agent/containerd
k3s crictl images | wc -l
k3s crictl images | sort -k3 -h | tail -20
```

Corrigir:

```
k3s crictl rmi --prune
```

Remove só imagem sem container usando. É seguro rodar em produção. O que ele
apaga volta a ser baixado se algum Pod precisar.

### 2. journald sem teto

Instalação padrão de várias distros deixa o journal crescer até 10% do disco. Num
disco de 120 GB isso é 12 GB de log.

Confirmar:

```
journalctl --disk-usage
```

Corrigir agora e depois para sempre:

```
journalctl --vacuum-time=7d
```

```
# /etc/systemd/journald.conf
SystemMaxUse=1G
```

```
systemctl restart systemd-journald
```

### 3. Retenção do Prometheus ou do Loki maior que o disco

O local-path provisioner do k3s não impõe cota: o PVC diz 50Gi, o provisioner
cria um diretório e pronto. O Prometheus enche até a retenção configurada, não
até o tamanho do PVC.

Confirmar:

```
du -sh /var/lib/rancher/k3s/storage/* | sort -h | tail
kubectl -n observabilidade get pvc
```

Corrigir: baixar `--storage.tsdb.retention.time` (ou `retentionSize`, que é o que
de fato protege o disco). É mudança de manifesto — vai por PR, não por
`kubectl edit`, senão o Argo CD desfaz no próximo sync.

### 4. Log de container de um Pod em crashloop

Um Pod reiniciando a cada 5 s e cuspindo stack trace enche `/var/log/pods` mais
rápido do que parece.

```
du -sh /var/log/pods/* | sort -h | tail
```

Se for isso, o problema não é disco: veja `crashloop.md`. Limpar o log sem parar
o Pod só compra alguns minutos.

### 5. Espaço que sumiu e não aparece em lugar nenhum

`df` diz cheio, `du` não acha. É arquivo apagado com processo ainda segurando o
descritor — clássico depois de alguém ter feito `rm` num log grande.

```
lsof +L1 | sort -k7 -h | tail
```

Reiniciar o processo dono libera. Não adianta procurar mais no `du`.

## Como saber que passou

```
df -h /var/lib/rancher
kubectl describe node | grep -A3 Taints
kubectl get nodes
```

O taint `disk-pressure` tem que ter sumido e o nó estar `Ready`. O taint sai
sozinho, mas com histerese: o kubelet espera o uso ficar abaixo do limite por um
tempo antes de remover. Se o `df` já está bom e o taint continua há mais de cinco
minutos, olhe o log do kubelet:

```
journalctl -u k3s -n 100 --no-pager | grep -i evict
```

Pods despejados não voltam sozinhos se eram de Deployment com o nó ainda tainted.
Depois que o taint sai, confira:

```
kubectl get pods -A --field-selector=status.phase!=Running
```

## Depois

Encher o disco duas vezes pelo mesmo motivo é falha de acompanhamento, não
incidente. Se foi imagem, agende o prune. Se foi retenção, corrija a retenção no
Git. Se foi a terceira vez, abra um postmortem — `docs/postmortems/MOLDE.md`.
