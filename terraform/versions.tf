terraform {
  # Pino exato do CLI, não faixa. A versão do Terraform fica gravada no state e
  # uma versão mais nova reescreve o formato do arquivo: depois disso a máquina
  # que ficou para trás não consegue mais ler o state. Com uma pessoa só isso
  # aparece no dia em que o CI roda uma versão diferente da do notebook.
  required_version = "1.9.8"

  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
      # Versão exata. "~>" deixa um patch novo do provider entrar sozinho entre
      # o plan que eu revisei e o apply que roda depois, e mudança de provider
      # já virou diff de infraestrutura mais de uma vez.
      version = "1.51.0"
    }

    cloudflare = {
      source = "cloudflare/cloudflare"
      # Fico no ramo 4.x de propósito. O 5.x é uma reescrita gerada a partir da
      # API: renomeia recursos (cloudflare_record virou cloudflare_dns_record) e
      # muda atributos. Migrar é trabalho de verdade, com import e movimentação
      # de state, e não é o trabalho deste repositório agora.
      version = "4.52.0"
    }
  }

  # Backend remoto: ainda não.
  #
  # Hoje o state é local, em terraform.tfstate, e isso é uma escolha consciente
  # de um cluster de um nó só, aplicado de uma máquina só, por uma pessoa só.
  # Nesse cenário o backend remoto não resolve nenhum problema que eu tenha: o
  # bloqueio protege contra dois applies simultâneos, e não existem dois.
  #
  # O que muda quando deixa de ser assim, em ordem de urgência:
  #
  # 1. Uma segunda máquina aplica (o CI, ou um segundo notebook). A partir daí
  #    existem dois arquivos de state divergentes e o próximo apply destrói ou
  #    duplica recurso. Esse é o ponto em que o backend remoto vira obrigatório,
  #    não antes.
  # 2. Duas pessoas aplicam. Aí o bloqueio (state locking) passa a valer.
  # 3. A máquina morre. O state local não tem cópia; recuperar significa
  #    reimportar recurso por recurso.
  #
  # O state guarda o token da Hetzner e o da Cloudflare em texto claro. Backend
  # remoto sem criptografia em repouso e sem controle de acesso piora isso em
  # vez de melhorar: sai de um arquivo em disco cifrado para um bucket que mais
  # gente alcança. Quando eu migrar, vai ser com criptografia e acesso restrito.
  #
  # backend "s3" {
  #   bucket         = "rigo-tfstate"
  #   key            = "homelab/terraform.tfstate"
  #   region         = "eu-central-1"
  #   encrypt        = true
  #   dynamodb_table = "rigo-tfstate-lock"
  # }
}
