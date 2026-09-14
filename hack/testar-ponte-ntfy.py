#!/usr/bin/env python3
"""Teste da ponte Alertmanager -> ntfy.

A ponte é o último trecho do caminho de um alerta: se ela traduzir errado, o
alerta sai do Prometheus, passa pelo Alertmanager e morre no celular como um
blob ilegível — ou não chega. Nenhuma validação de YAML pega isso.

O teste sobe a ponte de verdade e um ntfy falso, manda um payload no formato do
Alertmanager e confere o que chegou do outro lado.
"""

import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from email.header import decode_header, make_header
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PONTE = os.path.join(RAIZ, "clusters/homelab/platform/observabilidade/ponte-ntfy.py")
PORTA_NTFY = 8399
PORTA_PONTE = 8398

recebidos = []


class NtfyFalso(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):  # noqa: N802
        tamanho = int(self.headers.get("Content-Length") or 0)
        recebidos.append(
            {
                "topico": self.path.strip("/"),
                "titulo": str(make_header(decode_header(self.headers.get("Title", "")))),
                "prioridade": self.headers.get("Priority"),
                "tags": self.headers.get("Tags"),
                "corpo": self.rfile.read(tamanho).decode("utf-8"),
            }
        )
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


def esperar(url: str, tentativas: int = 50) -> None:
    for _ in range(tentativas):
        try:
            urllib.request.urlopen(url, timeout=1)
            return
        except (urllib.error.URLError, OSError):
            time.sleep(0.1)
    raise RuntimeError(f"{url} não respondeu a tempo")


def conferir(condicao: bool, descricao: str, falhas: list) -> None:
    if condicao:
        print(f"ok      {descricao}")
    else:
        print(f"FALHOU  {descricao}")
        falhas.append(descricao)


def main() -> int:
    servidor = ThreadingHTTPServer(("127.0.0.1", PORTA_NTFY), NtfyFalso)
    threading.Thread(target=servidor.serve_forever, daemon=True).start()

    ambiente = dict(os.environ, NTFY_BASE_URL=f"http://127.0.0.1:{PORTA_NTFY}", PORTA=str(PORTA_PONTE))
    ponte = subprocess.Popen([sys.executable, PONTE], env=ambiente,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    falhas = []
    try:
        esperar(f"http://127.0.0.1:{PORTA_PONTE}/saude")

        payload = {
            "alerts": [
                {
                    "status": "firing",
                    "labels": {"alertname": "NoNotReady", "severity": "critical", "instance": "nodo-1"},
                    "annotations": {
                        "summary": "Nó fora do ar",
                        "description": "O nó nodo-1 está NotReady há 5 minutos.",
                        "runbook_url": "https://exemplo/runbooks/no-notready.md",
                    },
                },
                {
                    "status": "resolved",
                    "labels": {"alertname": "DiscoDoNoEnchendo", "severity": "warning", "instance": "/var"},
                    "annotations": {"summary": "Disco /var deve encher em menos de 24h"},
                },
                # Alerta vindo de exportador compartilhado: o `instance` é o
                # endereço do preview-operator, igual em todos os alertas que ele
                # produz. Quem localiza o problema é o namespace.
                {
                    "status": "firing",
                    "labels": {
                        "alertname": "PreviewAmbienteExpirando",
                        "severity": "warning",
                        "instance": "10.42.0.17:8080",
                        "namespace": "previews",
                        "pull_request": "108",
                    },
                    "annotations": {"summary": "Ambiente de preview do PR #108 expira em breve"},
                },
            ]
        }
        requisicao = urllib.request.Request(
            f"http://127.0.0.1:{PORTA_PONTE}/homelab-critico",
            data=json.dumps(payload).encode(),
            method="POST",
        )
        with urllib.request.urlopen(requisicao, timeout=5) as resposta:
            conferir(resposta.status == 204, "o webhook responde 204 ao Alertmanager", falhas)

        time.sleep(0.4)
        conferir(len(recebidos) == 3, f"as três notificações chegaram (chegaram {len(recebidos)})", falhas)
        if len(recebidos) != 3:
            return 1

        disparando, resolvido, compartilhado = recebidos
        conferir(disparando["topico"] == "homelab-critico", "o tópico vem do caminho da URL", falhas)

        # Cabeçalho HTTP é latin-1; título em português não é. Sem RFC 2047 o
        # celular mostra "NÃ³ fora do ar".
        conferir(disparando["titulo"] == "DISPARANDO: Nó fora do ar",
                 f"o acento sobrevive ao cabeçalho ({disparando['titulo']!r})", falhas)
        conferir(disparando["prioridade"] == "urgent", "severidade critical vira prioridade urgent", falhas)
        conferir("runbook: https://exemplo/runbooks/no-notready.md" in disparando["corpo"],
                 "o runbook vai no corpo da notificação", falhas)
        # Alerta de nó não tem namespace: aqui `instance` é o nó, e é o que deve
        # aparecer.
        conferir("onde: nodo-1" in disparando["corpo"], "a instância aparece no corpo", falhas)

        conferir(resolvido["titulo"].startswith("RESOLVIDO:"), "alerta resolvido é marcado como tal", falhas)
        conferir(resolvido["prioridade"] == "low", "resolvido não vibra o telefone", falhas)

        # E aqui o contrário: com namespace no alerta, o endereço de scrape do
        # exportador não pode ganhar a linha. Ele é o mesmo em todos os alertas
        # que aquele exportador produz, então não distingue um do outro.
        conferir("onde: previews" in compartilhado["corpo"],
                 "o namespace ganha do endereço do exportador", falhas)
        conferir("10.42.0.17" not in compartilhado["corpo"],
                 "o endereço de scrape não aparece quando há namespace", falhas)

        # 500 é o que faz o Alertmanager tentar de novo; 200 perderia o alerta
        # em silêncio, que é o pior desfecho para uma ponte de alerta.
        servidor.shutdown()
        requisicao = urllib.request.Request(
            f"http://127.0.0.1:{PORTA_PONTE}/homelab-critico",
            data=json.dumps({"alerts": [{"status": "firing", "labels": {}, "annotations": {}}]}).encode(),
            method="POST",
        )
        codigo = 0
        try:
            with urllib.request.urlopen(requisicao, timeout=15) as resposta:
                codigo = resposta.status
        except urllib.error.HTTPError as erro:
            codigo = erro.code
        conferir(codigo == 500, f"ntfy fora do ar devolve 500 para o Alertmanager tentar de novo (veio {codigo})", falhas)
    finally:
        ponte.terminate()
        ponte.wait(timeout=5)

    print()
    if falhas:
        print(f"{len(falhas)} verificação(ões) falharam.", file=sys.stderr)
        return 1
    print("a ponte traduz o alerta corretamente.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
