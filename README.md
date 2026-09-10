# homelab-gitops

Cluster **k3s de nó único** provisionado por Terraform e reconciliado por Argo
CD. Hospeda os produtos que eu mantenho, e é onde eu opero — não onde eu
instalo.

O repositório é a fonte da verdade: `terraform apply` cria o servidor, um
script coloca o Argo CD de pé uma única vez, e a partir daí **mudar o cluster é
abrir um pull request**. Nada aqui é aplicado na mão depois do dia 1.

```
terraform apply          servidor, firewall, DNS, k3s por cloud-init
      |
bootstrap/instalar.sh    Argo CD, uma vez, e o Application raiz
      |
      v
  Argo CD  <--- git push --- você
      |
      +--> ingress-nginx, cert-manager, external-secrets
      +--> Prometheus, Alertmanager, Grafana, Loki, Alloy
      +--> os produtos
```

---

## Por que não é só um `kubectl apply`

Um cluster mantido por comando some da memória em duas semanas. Não existe
resposta para "por que essa flag está aí" nem para "o que mudou entre ontem e
hoje", e a recuperação depende de alguém lembrar a ordem certa.

Com o estado no Git, três coisas passam a valer:

- **`selfHeal` desfaz o `kubectl edit` feito na pressa.** O que não está no Git
  não sobrevive ao próximo sync — inclusive o conserto de madrugada que
  ninguém anotou.
- **O histórico responde "o que mudou".** Toda alteração de infraestrutura tem
  autor, data e um diff revisável.
- **Recuperar é `terraform apply` mais um script.** Não é um domingo tentando
  lembrar a sequência.

O preço é real e está pago aqui: um `apply` na mão volta atrás sozinho, e
qualquer mudança urgente passa por commit.

---

## Do zero ao cluster

O caminho completo está em [`docs/bootstrap.md`](docs/bootstrap.md). Em resumo:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # e preencha
terraform init && terraform apply

# o kubeconfig sai por SSH; o output primeiro_acesso mostra o comando
export KUBECONFIG=~/.kube/homelab

../bootstrap/instalar.sh        # Argo CD + Application raiz. Roda uma vez.
```

Depois disso o Argo CD se auto-gerencia pelo Git. Atualizar qualquer coisa é
editar YAML e dar push — rodar o script de novo com outra versão faria o
`selfHeal` reverter a mudança sem erro nenhum.

> O `.terraform.lock.hcl` **não** está versionado ainda porque não pude gerá-lo
> com acesso ao registry. Rode `terraform init` uma vez e comite o arquivo que
> sair: é ele que garante que a próxima máquina baixe o mesmo binário de
> provider, com a mesma soma.

---

## O que roda

| Componente | Wave | Para quê |
|---|---|---|
| Argo CD | 0 | Reconcilia o resto, inclusive a si mesmo |
| cert-manager | 1 | TLS por Let's Encrypt, staging e produção |
| external-secrets | 1 | Traz do Vault os segredos que os apps usam |
| kube-prometheus-stack | 1 | Prometheus, Alertmanager, Grafana |
| ingress-nginx | 2 | Entrada HTTP; DaemonSet com `hostPort` |
| platform-rede, platform-secrets | 3 | ClusterIssuer, SecretStore, ExternalSecret |
| Loki | 4 | Destino dos logs |
| Alloy | 5 | Coleta de log dos pods |

A ordem das waves não é estética. As waves 1 são as donas de CRD que as waves
seguintes consomem: sem elas primeiro, um `ServiceMonitor` declarado na wave 2
falha no dry-run porque o tipo ainda não existe no apiserver.

`ingress-nginx` é DaemonSet com `hostPort` e Service `ClusterIP` porque o k3s
sobe com `--disable=servicelb`. Um `type: LoadBalancer` ficaria `<pending>`
para sempre.

---

## Alertar é a parte que importa

Instalar Prometheus é a parte fácil. O que separa um cluster observado de um
cluster com Grafana instalado são **15 regras de alerta**, cada uma com o
runbook linkado na própria anotação — quem recebe o aviso às 3h já abre com o
primeiro comando na mão.

Dois exemplos do critério usado:

**Disco.** Dois alertas, não um. O primeiro usa `predict_linear` sobre 6h:
disco a 80% parado há semanas não é incidente, e disco a 60% subindo rápido é —
o que interessa é a inclinação. O segundo é limiar fixo em 10%, porque abaixo
disso o kubelet começa a despejar pod por pressão de disco e a inclinação
deixou de importar. A previsão diz "vai dar problema"; o limiar diz "já está
dando".

**Silêncio derivado.** Um `inhibit_rule` cala os alertas de pod quando o nó
está `NotReady`. Com o nó fora, quarenta avisos de CrashLoop não informam nada
que o primeiro alerta já não tenha dito — e um canal que dispara quarenta vezes
por incidente é um canal que se aprende a ignorar.

O roteamento sai por webhook para o **ntfy**, no celular. Runbooks em
[`docs/runbooks/`](docs/runbooks/); molde de postmortem em
[`docs/postmortems/`](docs/postmortems/) — vazio de propósito, porque
postmortem de queda que não aconteceu é ficção.

---

## Segredos

O Git guarda **um** segredo, cifrado com age. Ele abre o Vault, e o External
Secrets tira do Vault todo o resto. O detalhe está em
[`docs/segredos.md`](docs/segredos.md); o resumo das duas decisões:

**Sidecar CMP com sops, e não o operator lendo a chave.** No sidecar, a chave
privada fica num container que não escuta porta e não faz mais nada. Um
operator que decifra precisa da mesma chave no processo que reconcilia o
cluster inteiro. Além disso o Argo CD compara o objeto já decifrado com o que
está no cluster — com o arquivo cifrado aplicado cru, todo sync compararia
base64 novo com base64 velho, porque o sops regrava MAC e IV a cada save, e o
`OutOfSync` viraria ruído permanente.

**`encrypted_regex` no `data`, não o arquivo inteiro.** Com só o `data`
cifrado, o diff do pull request ainda mostra qual secret mudou e em qual
namespace. Cifrando tudo, todo commit vira uma parede de base64 e a revisão
deixa de existir.

A chave privada não está aqui. Ela vive na estação do operador e num Secret
criado à mão no bootstrap — uma vez por vida do cluster.

---

## O que está verificado, e o que não está

Um repositório de infraestrutura mente com facilidade: YAML bonito não prova
que o cluster sobe. O que dá para afirmar:

| | |
|---|---|
| `terraform validate` contra o schema real dos providers | passa |
| `terraform fmt -check -recursive` | passa |
| `kubeconform` estrito em `clusters/` | 26 de 26 recursos, **zero pulados** |
| `promtool check rules` nas 15 regras de alerta | passa |
| `promtool test rules` — as expressões dão o resultado que o comentário promete | passa |
| `amtool check-config` e roteamento por severidade conferido alerta a alerta | passa |
| `shellcheck` e `bash -n` nos scripts | passa |
| Verificador de segredo em claro (`hack/verificar-segredos.py`) | passa, e reprova o caso negativo |
| ConfigMap do dashboard em dia com o `.json` que o gera | passa |
| `cloud-init.yaml` renderizado por `templatefile()` e reparseado | passa |

O "zero pulados" é o número que mais custou. `kubeconform` só conhece os tipos
nativos: `Application`, `PrometheusRule`, `ExternalSecret` e `ClusterIssuer`
saíam todos como *skipped* — e recurso pulado passa no CI parecendo aprovado.
`hack/validar-manifestos.sh` agora resolve os schemas de CRD no catálogo
público, então "o YAML é válido" virou "o campo existe no CRD". Sem rede ele
degrada e avisa; no CI, `EXIGIR_CATALOGO=1` torna a degradação uma falha.

O que **não** está verificado, e você deve conferir antes do primeiro apply:

- **As versões de chart e as tags de imagem.** Foram escritas à mão sem acesso
  aos índices de chart nem aos registries. `hack/conferir-versoes-de-chart.py` e
  `hack/conferir-imagens.sh` conferem as duas coisas e rodam no CI. O segundo
  distingue "a tag não existe" de "não consegui falar com o registry": tratar os
  dois como falha é como se ensina a ignorar o CI, e tratar os dois como sucesso
  é como o erro passa.
- **O Vault não é instalado por este repositório.** O `ClusterSecretStore`
  aponta para `vault.vault.svc.cluster.local`, que precisa existir antes de
  qualquer `ExternalSecret` funcionar.
- **Nada disto passou por um cluster de verdade ainda.** Sintaxe e schema estão
  validados; o primeiro `apply` é o primeiro teste real.

---

## O que falta

- Instalar o Vault pelo próprio app-of-apps, ou trocar a cadeia por sops puro e
  aceitar que rotacionar senha vira commit.
- Backup do etcd do k3s para fora do servidor. Hoje o nó é o único lugar onde o
  estado do cluster existe.
- Um segundo nó. Nó único torna toda manutenção uma janela de indisponibilidade.
- `NetworkPolicy` padrão-nega entre namespaces.

## Licença

MIT.
