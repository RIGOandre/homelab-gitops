provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  # Rótulos iguais em todo recurso da Hetzner. Servem para achar o que é deste
  # cluster no painel quando o projeto tiver mais de uma coisa dentro.
  rotulos = {
    projeto    = "homelab-gitops"
    ambiente   = "producao"
    gerenciado = "terraform"
  }

  # O cloud-init é template, não arquivo estático: usuário, chave e versão do
  # k3s são variáveis daqui. Dentro do YAML, expansão de shell precisa aparecer
  # escapada como $${...} para o Terraform não tentar resolver.
  cloud_init = templatefile("${path.module}/../bootstrap/cloud-init.yaml", {
    nome_servidor     = var.nome_servidor
    dominio           = var.dominio
    usuario_admin     = var.usuario_admin
    chave_ssh_publica = trimspace(var.chave_ssh_publica)
    versao_k3s        = var.versao_k3s
  })
}

# A Hetzner recusa cadastrar duas chaves com a mesma impressão digital no mesmo
# projeto. Se este apply falhar dizendo que a chave já existe, ela foi subida
# antes pelo painel: importe com `terraform import` em vez de gerar outra.
resource "hcloud_ssh_key" "admin" {
  name       = "${var.nome_servidor}-admin"
  public_key = trimspace(var.chave_ssh_publica)
  labels     = local.rotulos
}

# IP primário separado do servidor. Esse é o ponto: mudar o cloud-init, o tipo
# de servidor ou a imagem recria a máquina, e um IP que nasce junto com ela
# some junto. Com o IP como recurso próprio, o registro A continua válido e o
# certificado não precisa ser reemitido depois de cada recriação.
#
# auto_delete = false e delete_protection = true fazem o IP sobreviver ao
# `terraform destroy` do servidor. O preço disso é que destruir o projeto
# inteiro exige desligar a proteção antes, em dois applies.
resource "hcloud_primary_ip" "k3s" {
  name              = "${var.nome_servidor}-ipv4"
  type              = "ipv4"
  datacenter        = var.datacenter
  assignee_type     = "server"
  auto_delete       = false
  delete_protection = true
  labels            = local.rotulos
}

resource "hcloud_server" "k3s" {
  name        = var.nome_servidor
  image       = var.imagem
  server_type = var.tipo_servidor

  # Datacenter e não localização: a localização (nbg1) deixa a Hetzner escolher
  # o datacenter, e o IP primário acima vive em um datacenter específico. Se os
  # dois não baterem, a criação do servidor falha.
  datacenter = var.datacenter

  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.k3s.id]
  backups      = var.ativar_backups
  labels       = local.rotulos

  # Mudar este arquivo recria o servidor e o disco vai junto. É proposital: o
  # cloud-init só cuida do dia 1 (usuário, SSH, k3s). Tudo que muda depois é
  # manifesto no Git reconciliado pelo Argo CD, e nada aqui deveria precisar de
  # edição em máquina viva.
  user_data = local.cloud_init

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.k3s.id

    # IPv6 desligado. A Hetzner entrega um /64 de graça, mas ligar significa
    # manter duas pilhas de regra de firewall e dois caminhos de saída para
    # auditar. Nada neste cluster precisa de IPv6 hoje.
    ipv6_enabled = false
  }

  # Sem provisioner de propósito. `remote-exec` faria o apply depender de um
  # agente SSH carregado na máquina que aplica, e transformaria "o cloud-init
  # demorou" em "o apply falhou e metade do state está pela metade". O tempo de
  # espera do dia 1 está documentado nos outputs.
}

# rDNS apontando para o domínio. Sem isso o PTR do IP fica no reverso genérico
# da Hetzner, o que aparece como origem suspeita em log de terceiro e em
# qualquer coisa que mande e-mail de saída.
resource "hcloud_rdns" "k3s" {
  server_id  = hcloud_server.k3s.id
  ip_address = hcloud_server.k3s.ipv4_address
  dns_ptr    = var.dominio
}
