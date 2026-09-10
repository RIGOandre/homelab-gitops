output "ip_publico" {
  description = "IPv4 do nó. É o IP primário, então sobrevive à recriação do servidor."
  value       = hcloud_primary_ip.k3s.ip_address
}

output "id_servidor" {
  description = "ID do servidor na Hetzner, para uso com a CLI hcloud (console, rescue, reboot)."
  value       = hcloud_server.k3s.id
}

output "comando_ssh" {
  description = "Entrada no nó. Só funciona a partir de um IP que esteja em var.ips_ssh_liberados."
  value       = "ssh ${var.usuario_admin}@${hcloud_primary_ip.k3s.ip_address}"
}

output "comando_tunel_api" {
  description = "Túnel para a API do k3s. A porta 6443 não está aberta na internet; este é o caminho de acesso. Deixe rodando em outro terminal."
  value       = "ssh -N -L 6443:127.0.0.1:6443 ${var.usuario_admin}@${hcloud_primary_ip.k3s.ip_address}"
}

# O kubeconfig do k3s carrega o certificado de cliente de cluster-admin. Se ele
# virasse output, estaria em texto claro no terraform.tfstate, no `terraform
# output -json` e em qualquer log de CI que capture a saída do apply. Marcar
# como sensitive esconde do terminal e não do state, então não resolve.
#
# O que sai daqui é o comando para buscar o arquivo. O segredo continua só no
# servidor e na máquina de quem tem SSH.
output "comando_kubeconfig" {
  description = "Copia o kubeconfig do nó para a máquina local. O conteúdo nunca passa pelo state do Terraform."
  value       = "ssh ${var.usuario_admin}@${hcloud_primary_ip.k3s.ip_address} 'cat ~/.kube/config' > ~/.kube/homelab.yaml && chmod 600 ~/.kube/homelab.yaml"
}

output "primeiro_acesso" {
  description = "Ordem do dia 1. O cloud-init leva de 3 a 5 minutos depois do apply; até terminar, o SSH pode recusar conexão e o kubeconfig não existe."
  value = join("\n", [
    "1. Espere o cloud-init: ssh ${var.usuario_admin}@${hcloud_primary_ip.k3s.ip_address} 'cloud-init status --wait'",
    "2. Traga o kubeconfig com o comando de comando_kubeconfig",
    "3. Abra o túnel de comando_tunel_api em outro terminal",
    "4. export KUBECONFIG=~/.kube/homelab.yaml && kubectl get nodes",
  ])
}

output "dominio_curinga" {
  description = "Padrão de hostname que já resolve para o nó sem mudar DNS. É o que os ambientes de preview por PR usam."
  value       = "*.${var.dominio}"
}

output "datacenter" {
  description = "Datacenter onde o servidor e o IP primário nasceram. Os dois precisam bater; guardar no output evita ter que conferir no painel."
  value       = hcloud_server.k3s.datacenter
}
