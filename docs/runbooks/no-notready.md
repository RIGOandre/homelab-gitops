# Runbook: nó NotReady

## O que o alerta quer dizer

O kubelet parou de renovar o status do nó, ou renovou dizendo que não está bem.
Como o cluster tem um nó só, "nó NotReady" e "cluster fora" são a mesma frase.
Não existe drenar e deixar para amanhã.

Detalhe importante: se o alerta chegou, o Prometheus ainda estava vivo para
mandá-lo. Se nem o alerta chegou e você descobriu porque um serviço caiu, comece
pelo passo 0.

## Primeiro comando

Da estação:

```
kubectl get nodes -o wide
```

Três respostas possíveis, e elas mandam para lugares diferentes:

- **Responde `NotReady`** — a API está viva, o kubelet não. Vá para as causas.
- **Trava ou dá `connection refused`** — o `k3s server` caiu inteiro. SSH no nó.
- **`Unable to connect ... certificate has expired`** — vá para
  `certificado-expirando.md`, seção de certificados internos do k3s.

## Passo 0: o nó está de pé?

```
ping -c3 homelab
ssh homelab uptime
```

Se não responde ao ping, o problema é energia, rede de casa ou kernel travado, e
nada de `kubectl` vai ajudar. Se o `uptime` mostra poucos minutos, o nó reiniciou:
pule direto para a causa 4.

## Causas, em ordem de probabilidade

### 1. Disco cheio

O kubelet reporta `NotReady` com `KubeletHasDiskPressure` antes de qualquer outra
coisa quebrar. É a causa mais comum e a mais fácil de confundir com "o k3s
bugou".

```
df -h /var/lib/rancher
kubectl describe node | grep -A10 Conditions
```

Se `DiskPressure` for `True`, o runbook é `disco-cheio.md`. Não reinicie o k3s
antes de liberar espaço: ele volta e fica `NotReady` de novo em segundos, e você
perde o histórico do journal na confusão.

### 2. O serviço k3s morreu ou está reiniciando em laço

```
systemctl status k3s
journalctl -u k3s -n 200 --no-pager
```

O que procurar no log, nesta ordem: `panic`, `failed to start`, `database is
locked`, `bind: address already in use`. Se o `systemctl status` mostrar contador
de restart subindo, é laço — o log da última tentativa é o que interessa:

```
journalctl -u k3s --since "10 min ago" --no-pager | tail -100
```

### 3. O nó ficou sem memória e o OOM killer escolheu o k3s

Um nó só, sem `limits` em algum app, e o kernel mata o processo maior. Às vezes é
o próprio k3s.

```
dmesg -T | grep -i -E 'killed process|out of memory' | tail -20
free -h
```

Se o k3s foi morto por OOM, reiniciar resolve o sintoma e não a causa. Ache quem
comeu a memória (`crashloop.md` cobre o caso de container sem limite) antes de
considerar encerrado.

### 4. Relógio fora de hora depois de reinício

Nó sem RTC confiável ou sem NTP volta de uma queda com data errada. TLS interno
para de validar e o kubelet não consegue autenticar na API. O sintoma engana:
parece problema de certificado.

```
timedatectl
```

`System clock synchronized: no` com hora visivelmente errada é isso.

```
timedatectl set-ntp true
systemctl restart k3s
```

### 5. containerd não sobe

O containerd é embutido no k3s, mas pode falhar sozinho — em geral por estado
corrompido depois de desligamento sujo.

```
k3s crictl info
k3s crictl ps 2>&1 | head
```

Erro de conexão no socket com o k3s rodando aponta para containerd. O log está no
mesmo journal (`journalctl -u k3s | grep containerd`).

### 6. Rede do flannel

Menos provável num nó só, mas acontece depois de mexer em firewall.

```
ip -br a show flannel.1
ip -br a show cni0
kubectl get pods -A --field-selector=status.phase=Pending
```

Pod parado em `ContainerCreating` com evento de `failed to set up sandbox` é CNI.

## Corrigir: o reinício e o que ele custa

Depois de identificada a causa (não antes):

```
systemctl restart k3s
```

Em nó único isso derruba a API por 20 a 60 s e reinicia os containers de sistema.
Os containers de aplicação sobrevivem: o k3s reconecta ao containerd.

Não use `k3s-killall.sh` para "reiniciar melhor". Ele mata todo container e toda
interface de rede do cluster, e o tempo de volta passa de segundos para minutos.
Ele serve para desmontar o nó, não para consertá-lo.

Nunca rode `k3s-uninstall.sh` num incidente.

## Como saber que passou

```
kubectl get nodes
kubectl get --raw='/readyz?verbose'
kubectl get pods -n kube-system
kubectl get pods -A --field-selector=status.phase!=Running
```

O nó tem que estar `Ready`, o `readyz` terminando em `readyz check passed`, e
kube-system inteiro `Running`. Depois confira o Argo CD, que costuma acordar
`Unknown` porque perdeu a conexão com a API durante a queda:

```
kubectl -n argocd get applications.argoproj.io
```

Se ficar `Unknown` por mais de dois minutos, vá para `argocd-degradado.md`.
