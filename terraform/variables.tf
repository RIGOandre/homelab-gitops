# ---------------------------------------------------------------------------
# Credenciais
# ---------------------------------------------------------------------------

variable "hcloud_token" {
  description = "Token da API da Hetzner Cloud, com permissão de leitura e escrita no projeto. Vem do ambiente (TF_VAR_hcloud_token), não do tfvars."
  type        = string
  sensitive   = true

  validation {
    # O token da Hetzner tem 64 caracteres alfanuméricos. A checagem existe para
    # o erro aparecer no plan e não como 401 no meio do apply, com metade dos
    # recursos criados.
    condition     = can(regex("^[A-Za-z0-9]{64}$", var.hcloud_token))
    error_message = "O token da Hetzner deve ter 64 caracteres alfanuméricos."
  }
}

variable "cloudflare_api_token" {
  description = "Token da API da Cloudflare com Zone:Read e DNS:Edit na zona do domínio. Escopo de zona, não Global API Key."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.cloudflare_api_token) >= 40
    error_message = "Token da Cloudflare curto demais. Provavelmente foi colada a Global API Key (37 caracteres) no lugar de um token de escopo."
  }
}

# ---------------------------------------------------------------------------
# Servidor
# ---------------------------------------------------------------------------

variable "nome_servidor" {
  description = "Nome do servidor na Hetzner. Vira também o hostname da máquina e o prefixo dos outros recursos."
  type        = string
  default     = "k3s-homelab"

  validation {
    # Vira hostname, então vale a regra de rótulo DNS: minúscula, dígito e
    # hífen, sem começar ou terminar com hífen.
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.nome_servidor))
    error_message = "O nome do servidor precisa ser um rótulo DNS válido: minúsculas, dígitos e hífen, sem hífen nas pontas."
  }
}

variable "tipo_servidor" {
  description = "Tipo de servidor da Hetzner. Os ARM (cax*) custam menos pela mesma memória; todas as imagens usadas neste cluster são multiarquitetura."
  type        = string
  default     = "cax21"

  validation {
    condition     = can(regex("^(cx|cpx|cax|ccx)[0-9]{2}$", var.tipo_servidor))
    error_message = "Tipo inválido. Use uma família da Hetzner: cx, cpx, cax ou ccx seguida de dois dígitos (ex.: cax21)."
  }

  validation {
    # Abaixo disso o cluster sobe e depois passa o dia matando pod por OOM: só
    # k3s, ingress-nginx, cert-manager e Argo CD já ocupam perto de 2 GB, e o
    # servidor do Argo CD é o primeiro a morrer.
    condition     = !contains(["cx22", "cpx11", "cax11"], var.tipo_servidor)
    error_message = "Tipo com 4 GB ou menos. O conjunto k3s + Argo CD + ingress-nginx + cert-manager não cabe; use cax21, cpx21 ou maior."
  }
}

variable "datacenter" {
  description = "Datacenter da Hetzner (ex.: nbg1-dc3). É datacenter e não localização porque o IP primário nasce preso a um datacenter e o servidor precisa nascer no mesmo."
  type        = string
  default     = "nbg1-dc3"

  validation {
    condition     = can(regex("^[a-z]{3}[0-9]-dc[0-9]+$", var.datacenter))
    error_message = "Formato de datacenter inválido. Esperado algo como nbg1-dc3, fsn1-dc14, hel1-dc2 ou ash-dc1."
  }
}

variable "imagem" {
  description = "Imagem base do servidor. LTS porque o nó é gado de estimação: recriar significa esperar o Argo CD reconciliar tudo de novo."
  type        = string
  default     = "ubuntu-24.04"
}

variable "ativar_backups" {
  description = "Backup automático da Hetzner. Custa 20% do preço do servidor e só serve para o disco: o que importa aqui está no Git e nos volumes, então fica desligado por padrão."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Acesso
# ---------------------------------------------------------------------------

variable "usuario_admin" {
  description = "Usuário não-root criado pelo cloud-init. É o único que o SSH aceita."
  type        = string
  default     = "andre"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.usuario_admin))
    error_message = "Nome de usuário inválido para Linux: comece com letra minúscula ou sublinhado, até 32 caracteres."
  }

  validation {
    condition     = var.usuario_admin != "root"
    error_message = "O usuário administrativo não pode ser root: o cloud-init desliga o login de root no SSH."
  }
}

variable "chave_ssh_publica" {
  description = "Conteúdo da chave pública SSH que entra no servidor. É a única forma de entrar na máquina depois do boot."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\\.com) AAAA", var.chave_ssh_publica))
    error_message = "Isso não parece uma chave pública OpenSSH. O valor esperado é a linha inteira do arquivo .pub."
  }

  validation {
    # Colar a chave privada aqui é um erro de uma linha e mandaria a chave para
    # o state e para a API da Hetzner. Barrar custa nada.
    condition     = !can(regex("PRIVATE KEY", var.chave_ssh_publica))
    error_message = "Foi passada uma chave privada. Use o arquivo .pub."
  }
}

variable "ips_ssh_liberados" {
  description = "CIDRs que podem falar na porta 22. Lista curta: IP fixo de casa, faixa da VPN. Sem isso a porta 22 fica exposta ao mundo inteiro."
  type        = list(string)

  validation {
    condition     = length(var.ips_ssh_liberados) > 0
    error_message = "Informe pelo menos um CIDR. Lista vazia no firewall da Hetzner não bloqueia nada, ela apaga a regra."
  }

  validation {
    # cidrhost() aceita IPv4 e IPv6 e recusa endereço solto sem máscara, que é o
    # erro comum aqui (escrever 189.0.0.1 em vez de 189.0.0.1/32).
    condition     = alltrue([for cidr in var.ips_ssh_liberados : can(cidrhost(cidr, 0))])
    error_message = "Todo item precisa ser um CIDR com máscara, por exemplo 189.0.0.1/32 ou 2804:abc::/64."
  }

  validation {
    condition     = !contains(var.ips_ssh_liberados, "0.0.0.0/0") && !contains(var.ips_ssh_liberados, "::/0")
    error_message = "0.0.0.0/0 na porta 22 anula o motivo de existir esta variável. Se o IP de origem é dinâmico, use uma VPN com IP fixo de saída."
  }
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

variable "versao_k3s" {
  description = "Versão exata do k3s instalada pelo cloud-init. Versão, não canal: 'stable' muda embaixo do pé e a versão do control plane é a primeira coisa que se pergunta quando algo quebra."
  type        = string
  default     = "v1.31.5+k3s1"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.versao_k3s))
    error_message = "Formato esperado: vX.Y.Z+k3sN, por exemplo v1.31.5+k3s1."
  }
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

variable "dominio" {
  description = "Domínio raiz gerenciado na Cloudflare. A zona precisa já existir na conta; este código cria registros dentro dela, não a zona."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.dominio))
    error_message = "Domínio inválido. Use o apex em minúsculas, por exemplo rigo.dev.br, sem protocolo e sem barra."
  }
}

variable "ttl_dns" {
  description = "TTL dos registros A, em segundos. Baixo de propósito: se o servidor for recriado com outro IP, o tempo de espera é este."
  type        = number
  default     = 300

  validation {
    condition     = var.ttl_dns >= 60 && var.ttl_dns <= 86400
    error_message = "TTL fora da faixa aceita pela Cloudflare para registro não-proxiado (60 a 86400)."
  }
}

variable "proxy_cloudflare" {
  description = "Passar o tráfego pelo proxy da Cloudflare (nuvem laranja). Desligado: com o proxy ligado a Cloudflare termina o TLS e o certificado que o cert-manager emite no cluster deixa de ser o que o navegador vê, o que atrapalha na hora de depurar."
  type        = bool
  default     = false
}
