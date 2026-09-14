"""Traduz o webhook do Alertmanager para uma publicação no ntfy.

O Alertmanager só sabe mandar o JSON dele por webhook_configs, e o ntfy trata o
corpo do POST como o texto da notificação: apontar um no outro faz chegar no
celular um blob com chaves e colchetes. Esta ponte lê o JSON, escolhe título,
prioridade e etiqueta, e publica cada alerta como uma notificação legível.

Sem dependência externa de propósito — só a biblioteca padrão. A alternativa
era fixar a imagem de um projeto de terceiro cuja tag eu não conseguia
verificar, e tag de imagem que ninguém conferiu vira ImagePullBackOff na
madrugada em que o alerta tentou sair.

O tópico vem do caminho da URL (/homelab-critico, /homelab-aviso), e não da
configuração: é o que permite três receivers de severidades diferentes usarem
uma ponte só.
"""

import base64
import json
import logging
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.environ.get("NTFY_BASE_URL", "https://ntfy.sh").rstrip("/")
PORTA = int(os.environ.get("PORTA", "8080"))
TEMPO_LIMITE = float(os.environ.get("TEMPO_LIMITE", "10"))

# A prioridade sobe com a severidade. Sem isso, aviso e crítico chegam iguais e
# o modo silencioso do celular trata os dois do mesmo jeito — que é como um
# alerta crítico dorme junto com quem devia acordar.
PRIORIDADE = {"critical": "urgent", "warning": "high", "info": "low"}

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ponte")


def cabecalho(texto: str) -> str:
    """Cabeçalho HTTP é latin-1 por especificação; título em português não é.

    RFC 2047 é a saída, e o ntfy decodifica =?UTF-8?B?...?= no Title. Sem isso
    "Nó fora do ar" chega no celular como "NÃ³ fora do ar" — e o alerta que
    ninguém consegue ler é quase tão ruim quanto o alerta que não chegou.
    """
    if texto.isascii():
        return texto
    return "=?UTF-8?B?" + base64.b64encode(texto.encode("utf-8")).decode("ascii") + "?="


def localizar(rotulos: dict) -> str:
    """Onde o problema está, e não de onde a métrica veio.

    `instance` é o alvo que o Prometheus raspou. Para os alertas de nó é o
    próprio nó, e é a resposta certa. Para tudo que sai de um exportador
    compartilhado — preview-operator, cert-manager, Argo CD — é o endereço do
    exportador, igual em todos os alertas dele, e a notificação chega com
    `onde: 10.42.0.17:8080`. Às 3h isso não localiza nada, e ainda ocupa a linha
    que localizaria.

    Por isso o rótulo do objeto vem primeiro. `instance` fica como último
    recurso, que é exatamente onde os alertas de nó o encontram: eles não têm
    `namespace`.
    """
    namespace = rotulos.get("namespace")
    pod = rotulos.get("pod")
    if namespace and pod:
        return f"{namespace}/{pod}"
    return namespace or rotulos.get("instance") or ""


def montar(alerta: dict) -> tuple[str, str, str, str]:
    rotulos = alerta.get("labels") or {}
    anotacoes = alerta.get("annotations") or {}
    resolvido = alerta.get("status") == "resolved"

    nome = rotulos.get("alertname", "alerta sem nome")
    severidade = rotulos.get("severity", "info")

    titulo = f"{'RESOLVIDO' if resolvido else 'DISPARANDO'}: {anotacoes.get('summary') or nome}"

    linhas = [anotacoes.get("description", "").strip()]
    onde = localizar(rotulos)
    if onde:
        linhas.append(f"onde: {onde}")
    # O runbook é o motivo de o alerta ser útil às 3h. Vai no corpo, não em
    # anexo, porque notificação de celular não abre anexo.
    if anotacoes.get("runbook_url"):
        linhas.append(f"runbook: {anotacoes['runbook_url']}")

    corpo = "\n".join(linha for linha in linhas if linha) or nome

    # Alerta resolvido entra sempre como prioridade baixa: a notícia boa não
    # precisa vibrar o telefone.
    prioridade = "low" if resolvido else PRIORIDADE.get(severidade, "default")
    etiquetas = "white_check_mark" if resolvido else ("rotating_light" if severidade == "critical" else "warning")

    return titulo, corpo, prioridade, etiquetas


def publicar(topico: str, alerta: dict) -> None:
    titulo, corpo, prioridade, etiquetas = montar(alerta)
    requisicao = urllib.request.Request(
        f"{BASE}/{topico}",
        data=corpo.encode("utf-8"),
        method="POST",
        headers={
            "Title": cabecalho(titulo),
            "Priority": prioridade,
            "Tags": etiquetas,
        },
    )
    with urllib.request.urlopen(requisicao, timeout=TEMPO_LIMITE) as resposta:
        log.info("publicado em %s (%s): %s", topico, resposta.status, titulo)


class Ponte(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - nome exigido pela BaseHTTPRequestHandler
        # Serve de liveness e readiness probe. Sem isso o kubelet só saberia
        # que o processo existe, não que ele atende.
        self._responder(200 if self.path == "/saude" else 404, b"ok\n")

    def do_POST(self) -> None:  # noqa: N802
        topico = self.path.strip("/").split("?")[0]
        if not topico:
            self._responder(400, b"sem topico no caminho\n")
            return

        try:
            tamanho = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(tamanho) or b"{}")
        except (ValueError, json.JSONDecodeError) as erro:
            log.warning("corpo ilegível: %s", erro)
            self._responder(400, b"corpo nao e json\n")
            return

        alertas = payload.get("alerts") or []
        falhas = 0
        for alerta in alertas:
            try:
                publicar(topico, alerta)
            except (urllib.error.URLError, OSError) as erro:
                falhas += 1
                log.error("falhei ao publicar: %s", erro)

        # 500 quando alguma publicação falhou: é o que faz o Alertmanager
        # tentar de novo. Responder 200 aqui perderia o alerta em silêncio,
        # que é o pior desfecho possível para uma ponte de alerta.
        if falhas:
            self._responder(500, b"falha ao publicar\n")
            return
        self._responder(204, b"")

    def _responder(self, codigo: int, corpo: bytes) -> None:
        self.send_response(codigo)
        self.send_header("Content-Length", str(len(corpo)))
        self.end_headers()
        if corpo:
            self.wfile.write(corpo)

    def log_message(self, formato: str, *args) -> None:
        # O log padrão do http.server vai para stderr sem nível; passa pelo
        # logging para sair junto com o resto e ser filtrável.
        log.info("%s - %s", self.address_string(), formato % args)


if __name__ == "__main__":
    log.info("ponte no ar na porta %s, publicando em %s", PORTA, BASE)
    ThreadingHTTPServer(("", PORTA), Ponte).serve_forever()
