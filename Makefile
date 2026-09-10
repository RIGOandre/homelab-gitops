# Atalhos para operar o cluster. Nada aqui é mágico: cada alvo é o comando que
# você rodaria à mão, com os caminhos já certos e as travas que se esquece de pôr
# às 2h da manhã.
#
# Os alvos de validação são os mesmos que o CI roda - .github/workflows/ci.yml
# chama estes scripts, não uma cópia dos comandos. CI vermelho tem que dar para
# reproduzir aqui com uma linha.

SHELL := bash
# -e para parar no primeiro erro, pipefail para que erro no meio de um pipe não
# vire sucesso. Sem os dois, `make` fica verde com passo quebrado no meio.
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := ajuda

DIR_TERRAFORM := terraform
DIR_SEGREDOS  := clusters/homelab/platform/secrets
DIR_CMP       := $(DIR_SEGREDOS)/argocd-cmp
PLANO         := $(DIR_TERRAFORM)/plano.tfplan
NS_ARGOCD     := argocd

.PHONY: ajuda validar validar-terraform validar-manifestos validar-scripts \
        validar-segredos validar-dashboards conferir-versoes conferir-imagens \
        dashboards plano aplicar bootstrap senha-argocd cifrar decifrar

ajuda: ## Lista os alvos
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) \
	  | sed -e 's/:.*##/	/' \
	  | sort \
	  | awk -F'	' '{printf "  %-20s %s\n", $$1, $$2}'

# --------------------------------------------------------------------------
# Validação
# --------------------------------------------------------------------------

validar: validar-terraform validar-manifestos validar-scripts validar-segredos validar-dashboards ## Roda tudo que o CI roda sem rede

validar-terraform: ## terraform fmt -check e validate
	@./hack/validar-terraform.sh

validar-manifestos: ## kubeconform estrito em clusters/
	@./hack/validar-manifestos.sh

validar-scripts: ## bash -n e shellcheck nos scripts
	@./hack/validar-scripts.sh

validar-segredos: ## Confere que nenhum segredo entrou em claro
	@python3 hack/verificar-segredos.py .

# O ConfigMap do dashboard é gerado do .json ao lado. Editar um sem regerar o
# outro faz o painel do cluster divergir do painel do repositório, e nenhuma
# validação de schema percebe: os dois arquivos continuam válidos, só param de
# concordar.
validar-dashboards: dashboards ## Falha se o ConfigMap do dashboard estiver defasado
	@git diff --exit-code -- 'clusters/homelab/platform/observabilidade/*.configmap.yaml' \
	  || { echo "dashboard gerado fora de dia: rode 'make dashboards' e commite"; exit 1; }

dashboards: ## Regera os ConfigMap dos dashboards a partir dos .json
	@python3 hack/gerar-configmap-dashboard.py

# Estes dois precisam de rede aberta e por isso não entram no `validar`: quem
# roda na máquina de casa não deve levar CI vermelho por causa do provedor.
conferir-versoes: ## Confere que as versões de chart fixadas existem (precisa de rede)
	@python3 hack/conferir-versoes-de-chart.py

conferir-imagens: ## Confere que as tags de imagem existem (precisa de rede)
	@./hack/conferir-imagens.sh

# --------------------------------------------------------------------------
# Infraestrutura
# --------------------------------------------------------------------------

plano: ## Gera o plano do Terraform em terraform/plano.tfplan
	@terraform -chdir=$(DIR_TERRAFORM) init -input=false
	@terraform -chdir=$(DIR_TERRAFORM) plan -out=plano.tfplan
	@echo
	@echo "Leia o plano acima. Procure por 'destroy' e por 'forces replacement'."
	@echo "Depois: make aplicar"

# Aplica o plano gravado, nunca replaneja na hora: `terraform apply` sozinho
# aplica algo que ninguém leu. E apaga o plano no fim, porque plano velho
# aplicado depois de o mundo ter mudado é a forma mais fácil de destruir
# recurso sem querer.
aplicar: ## Aplica o plano gerado por `make plano`
	@test -f $(PLANO) || { echo "Não existe $(PLANO). Rode 'make plano' primeiro."; exit 1; }
	@terraform -chdir=$(DIR_TERRAFORM) apply plano.tfplan
	@rm -f $(PLANO)

# --------------------------------------------------------------------------
# Cluster
# --------------------------------------------------------------------------

# O patch do repo-server entra aqui e não em bootstrap/instalar.sh porque o
# script instala o Argo CD e o Secret da chave age; o sidecar sops é a peça que
# liga esta parte do repositório à instalação. Sem ele o Argo CD sobe inteiro e
# só o Application platform-secrets falha - com erro que fala de manifesto e não
# de plugin. Ver docs/segredos.md.
bootstrap: ## Instala o Argo CD e o sidecar sops (uma vez, em cluster novo)
	@bootstrap/instalar.sh
	@kubectl apply -f $(DIR_CMP)/cmp-plugin-sops.yaml
	@kubectl -n $(NS_ARGOCD) patch deployment argocd-repo-server \
	  --patch-file $(DIR_CMP)/repo-server-sidecar-patch.yaml
	@kubectl -n $(NS_ARGOCD) rollout status deployment/argocd-repo-server --timeout=300s

senha-argocd: ## Mostra a senha inicial do admin do Argo CD
	@kubectl -n $(NS_ARGOCD) get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d
	@echo
	@echo "(troque a senha e apague o Secret argocd-initial-admin-secret depois)"

# --------------------------------------------------------------------------
# Segredos
# --------------------------------------------------------------------------

# Exige o sufixo .enc.yaml: é ele que faz o sops cifrar (path_regex do
# .sops.yaml) e o sidecar decifrar. Cifrar um arquivo com outro nome produz um
# arquivo cifrado que o Argo CD aplica cru.
cifrar: ## Cifra um arquivo. Uso: make cifrar ARQUIVO=caminho/nome.enc.yaml
	@test -n "$(ARQUIVO)" || { echo "Uso: make cifrar ARQUIVO=caminho/nome.enc.yaml"; exit 1; }
	@case "$(ARQUIVO)" in *.enc.yaml) : ;; *) echo "O arquivo tem que terminar em .enc.yaml."; exit 1 ;; esac
	@sops --config .sops.yaml --encrypt --in-place "$(ARQUIVO)"
	@python3 hack/verificar-segredos.py . >/dev/null && echo "cifrado: $(ARQUIVO)"

# Só para a tela, nunca in-place: gravar a versão em claro dentro do repositório
# é exatamente como o segredo acaba commitado. Para editar, use `sops ARQUIVO`,
# que abre o $EDITOR e recifra ao salvar.
decifrar: ## Mostra um arquivo decifrado na tela. Uso: make decifrar ARQUIVO=...
	@test -n "$(ARQUIVO)" || { echo "Uso: make decifrar ARQUIVO=caminho/nome.enc.yaml"; exit 1; }
	@sops --config .sops.yaml --decrypt "$(ARQUIVO)"
