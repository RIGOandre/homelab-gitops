# Runbook: certificado expirando

## O que o alerta quer dizer

Algum certificado vence em menos do que a janela do alerta. Há duas famílias no
cluster, com causas e correções que não se parecem:

- **Certificados de borda**, emitidos pelo cert-manager via Let's Encrypt, usados
  pelos Ingress. Vencem em 90 dias e deveriam renovar sozinhos aos 60.
- **Certificados internos do k3s** (apiserver, kubelet, service account). Valem
  12 meses e rotacionam sozinhos quando o k3s reinicia dentro dos 90 dias finais.

O alerta diz qual é. Se não disser, o primeiro comando resolve a dúvida.

## Primeiro comando

```
kubectl get certificate -A
```

Coluna `READY=False` ou um `NOT AFTER` próximo aponta cert-manager. Se a lista
estiver toda saudável, o problema é interno do k3s:

```
for f in /var/lib/rancher/k3s/server/tls/*.crt; do
  printf '%-52s ' "$(basename "$f")"
  openssl x509 -noout -enddate -in "$f"
done
```

## Família 1: cert-manager e Let's Encrypt

### Descer a cadeia

O cert-manager encadeia quatro objetos. O erro real quase nunca está no primeiro.

```
kubectl -n NAMESPACE describe certificate NOME
kubectl -n NAMESPACE get certificaterequest
kubectl -n NAMESPACE describe order
kubectl -n NAMESPACE describe challenge
```

O `describe challenge` é o que dá a mensagem de verdade. Os três de cima só
repetem "pendente".

### Causas, em ordem

**1. HTTP-01 não fecha porque a porta 80 não chega de fora.**
Mais comum em homelab: o roteador deixou de encaminhar, o IP dinâmico mudou, ou o
provedor bloqueou a 80. O challenge fica em `pending` com erro de conexão.

```
kubectl -n NAMESPACE get challenge -o wide
curl -sS -o /dev/null -w '%{http_code}\n' \
  "http://SEU.DOMINIO/.well-known/acme-challenge/teste"
```

Rode o `curl` de fora da rede de casa. De dentro, o hairpin do roteador mascara o
problema e você conclui que está tudo bem.

**2. DNS-01 sem propagação ou com token de API vencido.**

```
dig +short TXT _acme-challenge.SEU.DOMINIO @1.1.1.1
kubectl -n cert-manager logs deploy/cert-manager --tail=100 | grep -i -E 'dns|presented'
```

Registro ausente com o challenge ativo aponta credencial do provedor de DNS. No
`describe challenge` isso costuma aparecer como `403` do provedor.

**3. Registro A apontando para o lugar errado.**
Depois de trocar de IP, o DNS ainda aponta para o antigo.

```
dig +short A SEU.DOMINIO
curl -sS https://ifconfig.me; echo
```

**4. Rate limit do Let's Encrypt.**
Cinco certificados iguais por semana. Quem deletou e recriou o Certificate várias
vezes tentando consertar chega aqui, e aí a espera é obrigatória.

```
kubectl -n NAMESPACE describe order | grep -i -E 'rate|too many'
```

Enquanto durar o bloqueio, use o `ClusterIssuer` de staging para validar o
caminho todo sem gastar cota.

**5. O cert-manager não está rodando.**

```
kubectl -n cert-manager get pods
kubectl -n cert-manager logs deploy/cert-manager --tail=50
```

### Forçar a renovação

Depois de corrigida a causa:

```
kubectl -n NAMESPACE delete certificaterequest --all
kubectl cert-manager renew NOME -n NAMESPACE
```

Sem o plugin `cert-manager` no kubectl, o equivalente é remover o Secret que
guarda o certificado; o cert-manager reemite. Só faça isso com a causa já
resolvida — se o challenge continuar falhando, você derrubou o certificado antigo
que ainda estava funcionando e transformou "vence em 10 dias" em "fora do ar
agora".

## Família 2: certificados internos do k3s

O k3s rotaciona sozinho no start, se faltarem menos de 90 dias. Quem tem nó que
nunca reinicia passa dos 12 meses e descobre da pior forma: `kubectl` para de
falar com o cluster com `certificate has expired`.

Verificar:

```
for f in /var/lib/rancher/k3s/server/tls/*.crt; do
  printf '%-52s ' "$(basename "$f")"
  openssl x509 -noout -enddate -in "$f"
done
```

Rotacionar:

```
systemctl stop k3s
k3s certificate rotate
systemctl start k3s
```

Isso derruba a API por cerca de um minuto. Depois, o kubeconfig da estação
continua válido (o client cert também é rotacionado, mas o CA não muda). Se der
erro de TLS na estação depois disso, copie o kubeconfig de novo:

```
scp homelab:/etc/rancher/k3s/k3s.yaml ~/.kube/homelab.yaml
```

E lembre de trocar `127.0.0.1` pelo IP do nó dentro do arquivo copiado.

**Antes de rotacionar, confira o relógio.** Certificado "expirado" em nó com data
errada não é certificado expirado. Ver `no-notready.md`, causa 4.

```
timedatectl
```

## Como saber que passou

Borda, de fora da rede:

```
echo | openssl s_client -connect SEU.DOMINIO:443 -servername SEU.DOMINIO 2>/dev/null \
  | openssl x509 -noout -dates -issuer
```

`notAfter` uns 90 dias à frente e o issuer sendo Let's Encrypt (não o staging, e
não o certificado autoassinado padrão do Traefik — esse é o sinal de que o
Ingress não achou o Secret).

Interno:

```
kubectl get --raw='/readyz'
kubectl get nodes
```

E o objeto:

```
kubectl get certificate -A
```

`READY=True` em tudo. O alerta some no próximo ciclo de scrape, não na hora.
