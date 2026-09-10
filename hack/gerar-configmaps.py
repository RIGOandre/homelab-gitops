#!/usr/bin/env python3
"""Embrulha em ConfigMap o que é código, não manifesto.

Dois casos, a mesma razão. O dashboard mora como .json solto porque é assim
que ele sai do Grafana e volta para ele; a ponte do ntfy mora como .py solto
porque é assim que ela roda em teste. Editar qualquer um dos dois indentado
dentro de um bloco YAML é como se perde uma chave sem perceber, e nenhum
editor ajuda lá dentro.

Os ConfigMap são gerados, nunca editados à mão, e o CI confere que o gerado
está em dia com a fonte. Duas cópias que se editam separadamente divergem: o
que roda no cluster fica diferente do que está no repositório e ninguém sabe
qual vale.
"""

import argparse
import glob
import json
import os
import pathlib
import sys

DIRETORIO = "clusters/homelab/platform/observabilidade"
NAMESPACE = "observabilidade"


def embutir(texto: str) -> str:
    return "\n".join(("    " + linha).rstrip() for linha in texto.splitlines())


def envelope(nome: str, arquivo: str, conteudo: str, rotulos: dict, origem: str) -> str:
    linhas_rotulo = "\n".join(f"    {chave}: {valor}" for chave, valor in rotulos.items())
    return f"""# GERADO por hack/gerar-configmaps.py a partir de {origem}
# Não edite este arquivo: edite a fonte e rode `make configmaps`.
apiVersion: v1
kind: ConfigMap
metadata:
  name: {nome}
  namespace: {NAMESPACE}
  labels:
{linhas_rotulo}
data:
  {arquivo}: |
{embutir(conteudo)}
"""


def gerar_dashboard(caminho: str) -> str:
    nome = pathlib.Path(caminho).stem
    # Reserializa com indentação fixa: assim o gerado só muda quando o conteúdo
    # muda, e não quando o Grafana exporta com espaçamento diferente.
    corpo = json.dumps(json.load(open(caminho)), indent=2, ensure_ascii=False)
    return envelope(
        nome,
        f"{nome}.json",
        corpo,
        # É este rótulo que faz o sidecar do Grafana enxergar o painel.
        {"grafana_dashboard": '"1"', "app.kubernetes.io/name": nome},
        f"{nome}.json",
    )


def gerar_ponte(caminho: str) -> str:
    return envelope(
        "ntfy-alertmanager",
        "ponte.py",
        pathlib.Path(caminho).read_text(),
        {"app.kubernetes.io/name": "ntfy-alertmanager"},
        pathlib.Path(caminho).name,
    )


def alvos() -> list[tuple[str, str]]:
    """Pares (destino, conteúdo) de tudo que este script gera."""
    saida = []
    for caminho in sorted(glob.glob(os.path.join(DIRETORIO, "*.json"))):
        saida.append((caminho.replace(".json", ".configmap.yaml"), gerar_dashboard(caminho)))

    ponte = os.path.join(DIRETORIO, "ponte-ntfy.py")
    if os.path.exists(ponte):
        saida.append((ponte.replace(".py", ".configmap.yaml"), gerar_ponte(ponte)))
    return saida


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    # --conferir compara com o arquivo em disco, e não com o que está no Git.
    # Comparar com o Git faria a verificação falhar em árvore suja mesmo quando
    # o gerado está perfeitamente em dia com a fonte — e verificação que falha
    # quando não devia é verificação que se aprende a ignorar.
    parser.add_argument("--conferir", action="store_true",
                        help="não escreve nada; falha se algum gerado estiver defasado")
    args = parser.parse_args()

    pares = alvos()
    if not pares:
        print(f"nada para gerar em {DIRETORIO}", file=sys.stderr)
        return 1

    defasados = []
    for destino, conteudo in pares:
        arquivo = pathlib.Path(destino)
        if args.conferir:
            atual = arquivo.read_text() if arquivo.exists() else None
            if atual != conteudo:
                defasados.append(destino)
                print(f"defasado  {destino}")
            else:
                print(f"em dia    {destino}")
            continue
        arquivo.write_text(conteudo)
        print(destino)

    if defasados:
        print(f"\n{len(defasados)} ConfigMap defasado(s). Rode `make configmaps` e commite.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
