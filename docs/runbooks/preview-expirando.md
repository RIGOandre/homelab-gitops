# Runbook: ambientes de preview do preview-operator

Cobre três alertas com causas separadas:

| Alerta | O que quer dizer |
| --- | --- |
| `PreviewAmbienteExpirando` | Um ambiente de PR vence em menos de 30 min. Funcionando como projetado. |
| `PreviewAmbienteVencidoNaoColetado` | Venceu há mais de 15 min e ainda existe. O operator não está coletando. |
| `PreviewOperatorReconciliacaoFalhando` | Mais de 20% dos reconciles em erro. PR novo provavelmente não ganha preview. |

Só o primeiro é sobre um ambiente. Os outros dois são sobre o operator.

## Onde as coisas moram

O operator roda no namespace `preview-system`; os ambientes ficam cada um no seu
namespace. As métricas são raspadas pelo ServiceMonitor em
`clusters/homelab/platform/observabilidade/servicemonitor-preview-operator.yaml`.

```
kubectl -n preview-system get deploy,pod
kubectl get crd | grep -i preview
```

**Detalhe que engana no Prometheus:** o ServiceMonitor usa `honorLabels: false`.
O label `namespace` das séries é o do *alvo* (`preview-system`), e o namespace do
ambiente de preview vem como `exported_namespace`. Procurar pelo ambiente com
`namespace="preview-pr-123"` não devolve nada e parece que a série sumiu.

## PreviewAmbienteExpirando

Não é falha. É o aviso combinado de 30 minutos para quem ainda está revisando.

Ver o que está para vencer:

```
(preview_environment_expires_at_seconds - time()) / 60
```

Quem é o PR e onde ele está: os labels `pr`, `repo` e `exported_namespace` da
série. Pelo cluster:

```
kubectl get ns -l app.kubernetes.io/part-of=preview --show-labels
```

**Corrigir** quer dizer decidir: se a revisão acabou, não faça nada e deixe o
ambiente ser coletado. Se não acabou, estenda o prazo — o mecanismo é o campo de
expiração no objeto do ambiente:

```
kubectl get <recurso-do-preview> -A
kubectl -n NAMESPACE describe <recurso-do-preview> NOME
```

O nome exato do recurso sai do `kubectl get crd | grep -i preview`. Descubra
antes de digitar; o repositório do operator é outro e o nome pode ter mudado.

Se o alerta está chegando cedo demais ou tarde demais de forma sistemática, o
problema é a janela de 30 min, e ela se ajusta em `alertas.yaml` — não neste
runbook.

## PreviewAmbienteVencidoNaoColetado

O prazo passou e a série continua existindo. Namespace órfão acumulando, que num
nó só vira o alerta de disco daqui a duas semanas (`disco-cheio.md`).

### Causas, em ordem

**1. O operator está fora ou em crashloop.**

```
kubectl -n preview-system get pods
kubectl -n preview-system logs deploy/preview-operator --tail=100
```

Se estiver reiniciando, o runbook é `crashloop.md`; volte aqui depois.

**2. O reconcile de coleta erra sempre no mesmo ambiente.** Um finalizer que não
sai é o caso clássico: o namespace fica em `Terminating` para sempre e o operator
tenta de novo a cada ciclo.

```
kubectl get ns | grep Terminating
kubectl get ns NAMESPACE -o jsonpath='{.spec.finalizers}{"\n"}'
kubectl -n preview-system logs deploy/preview-operator --tail=200 | grep -i -E 'finaliz|delete|reconcile.*error'
```

**3. Métrica velha de ambiente que já morreu.** O oposto: o namespace sumiu e só
a série ficou, porque o operator não removeu o gauge ao coletar. Confirme antes
de sair apagando:

```
kubectl get ns NAMESPACE
```

Se o namespace não existe e a série existe, o bug é no operator (gauge não
removido) e o cluster está limpo. Reiniciar o operator zera as séries:

```
kubectl -n preview-system rollout restart deploy/preview-operator
```

Se a série voltar depois do restart, o ambiente existe de verdade e o caso é o 2.

### Corrigir o namespace preso

Só depois de entender por que o finalizer não saiu. Remover finalizer na marra é
o último recurso, e deixa para trás o que quer que ele fosse limpar:

```
kubectl -n preview-system logs deploy/preview-operator | grep -i NAMESPACE
```

## PreviewOperatorReconciliacaoFalhando

Proporção de erro acima de 20% por 15 min. Como é proporção, um erro isolado no
meio de pouco tráfego pode disparar — confira o volume antes de tratar como
incidente:

```
sum(rate(preview_environment_reconcile_duration_seconds_count[10m])) * 600
```

Poucos reconciles na janela significa amostra pequena e alerta ruidoso, não
operator quebrado.

### Causas, em ordem

**1. Permissão.** RBAC do operator sem direito sobre algo que ele passou a criar.
A mensagem é `is forbidden: User "system:serviceaccount:preview-system:..."`.

```
kubectl -n preview-system logs deploy/preview-operator --tail=200 | grep -i forbidden
```

**2. Quota ou nó sem espaço.** Ambiente novo não agenda, o reconcile erra em
laço. Encadeia com `saturacao-do-no.md` e `disco-cheio.md`.

```
kubectl get events -A --sort-by=.lastTimestamp | grep -i -E 'FailedScheduling|exceeded quota' | tail
```

**3. Dependência do ambiente falhando.** Se o preview cria banco, Ingress ou
certificado, o erro vem de lá. Certificado é o mais provável e tem runbook
próprio: `certificado-expirando.md` (rate limit do Let's Encrypt aparece rápido
quando cada PR pede um certificado novo).

**4. Regressão do operator.** Só considere depois de descartar as três acima.

```
kubectl -n preview-system get deploy preview-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

## Como saber que passou

```
kubectl get ns | grep -i preview
kubectl -n preview-system get pods
```

E no Prometheus, a taxa de erro voltando a zero:

```
sum(rate(preview_environment_reconcile_duration_seconds_count{result="error"}[10m]))
```

Os três alertas têm `for` de 2 a 15 min, então nenhum se resolve na hora. Para o
`PreviewAmbienteVencidoNaoColetado`, o que confirma é o namespace ter sumido de
verdade — a série some junto no scrape seguinte.
