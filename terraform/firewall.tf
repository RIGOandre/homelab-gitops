# Firewall da Hetzner, aplicado na borda da rede e não dentro da máquina.
#
# Não existe ufw nem firewalld no servidor de propósito: o k3s cria e reescreve
# regras de iptables o tempo todo (kube-proxy, flannel, as regras de NodePort),
# e um segundo firewall gerenciando a mesma tabela produz bloqueio intermitente
# que ninguém consegue explicar. Filtragem fica aqui, uma camada acima.
resource "hcloud_firewall" "k3s" {
  name   = "${var.nome_servidor}-borda"
  labels = local.rotulos

  # ---------------------------------------------------------------------
  # Entrada
  # ---------------------------------------------------------------------

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.ips_ssh_liberados
    description = "SSH restrito aos CIDRs de var.ips_ssh_liberados"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTP: entra no ingress-nginx e serve o desafio HTTP-01 do cert-manager"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTPS: entra no ingress-nginx"
  }

  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP: sem ele o descobrimento de MTU quebra e conexão grande trava sem erro"
  }

  # 6443 não aparece aqui, e a ausência é a decisão.
  #
  # A API do k3s aceita o token de nó como credencial válida. Esse token está no
  # disco do servidor, é o mesmo que qualquer agente novo usaria para entrar no
  # cluster, e não tem segundo fator. Token vazado com a porta 6443 aberta na
  # internet é o cluster inteiro nas mãos de quem achou, incluindo todo Secret
  # que o Argo CD administra.
  #
  # Como eu chego na API: túnel SSH. A porta 22 já está restrita por IP e exige
  # chave, então o acesso administrativo herda esse controle em vez de criar um
  # segundo caminho para proteger.
  #
  #   ssh -N -L 6443:127.0.0.1:6443 usuario@servidor
  #
  # O kubeconfig que o k3s gera já aponta para https://127.0.0.1:6443 e o
  # certificado do servidor já traz 127.0.0.1 como SAN, então nada precisa ser
  # reescrito do outro lado do túnel.
  #
  # A alternativa seria abrir 6443 para a mesma lista de IPs da porta 22. Não
  # faço porque duplicaria a superfície sem ganhar nada: o túnel já resolve, e
  # todo IP que entra na lista passaria a valer para dois serviços em vez de um.

  # ---------------------------------------------------------------------
  # Saída
  # ---------------------------------------------------------------------
  #
  # Cuidado ao mexer: o firewall da Hetzner libera toda a saída enquanto não
  # existir nenhuma regra de saída. Na primeira que aparece, o padrão vira negar
  # e só o que estiver escrito abaixo sai. Apagar uma destas regras não afrouxa
  # nada, quebra o servidor.

  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "443"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "Saída HTTPS: imagens de contêiner, repositórios Git do Argo CD, ACME do cert-manager"
  }

  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "80"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "Saída HTTP: repositórios apt do Ubuntu e redirecionamento de registry antigo"
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "53"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "Saída DNS. Sem isso o CoreDNS não resolve nada externo e o cluster parece quebrado sem log de rede"
  }

  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "53"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "Saída DNS por TCP: resposta acima de 512 bytes cai para TCP, o que acontece com DNSSEC"
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "123"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "NTP. Relógio fora de hora invalida certificado e token do Kubernetes"
  }

  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "ICMP de saída: descobrimento de MTU e diagnóstico"
  }
}
