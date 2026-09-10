# A zona é buscada por nome em vez de ter o ID no tfvars. O ID muda se a zona
# for removida e recadastrada na conta, e um ID errado no DNS não dá erro: cria
# registro na zona errada.
data "cloudflare_zone" "principal" {
  name = var.dominio
}

locals {
  # Com o proxy ligado a Cloudflare ignora o TTL e exige o valor 1 (automático).
  # Mandar 300 com proxied = true é erro de API, não aviso.
  ttl_efetivo = var.proxy_cloudflare ? 1 : var.ttl_dns
}

resource "cloudflare_record" "apex" {
  zone_id = data.cloudflare_zone.principal.id
  name    = "@"
  type    = "A"
  content = hcloud_primary_ip.k3s.ip_address
  ttl     = local.ttl_efetivo
  proxied = var.proxy_cloudflare
}

# O curinga é o que faz ambiente de preview funcionar sem tocar em DNS.
#
# Cada PR sobe um Ingress com host próprio (pr-137.exemplo.com.br) e o hostname
# já resolve no minuto zero, sem apply de Terraform, sem esperar propagação e
# sem dar à esteira de CI credencial de escrita em DNS. O ingress-nginx decide
# o que responde em cada host; o DNS só aponta todo mundo para o mesmo nó.
#
# O custo: qualquer subdomínio que não exista resolve para este servidor e cai
# no default backend do ingress-nginx. Isso é aceitável aqui porque o nó só
# atende o que tem Ingress declarado, mas é o motivo de o default backend
# devolver 404 seco em vez da página de alguma aplicação.
resource "cloudflare_record" "curinga" {
  zone_id = data.cloudflare_zone.principal.id
  name    = "*"
  type    = "A"
  content = hcloud_primary_ip.k3s.ip_address
  ttl     = local.ttl_efetivo
  proxied = var.proxy_cloudflare
}
