#!/usr/bin/env python3
"""Embrulha cada dashboard .json num ConfigMap que o Grafana descobre sozinho.

O sidecar do kube-prometheus-stack varre ConfigMaps com o rótulo
`grafana_dashboard` e carrega o JSON de dentro. O dashboard mora como .json
solto porque é assim que ele sai do Grafana e volta para ele — editar JSON
indentado dentro de um bloco YAML é como se perde um painel sem perceber.

O ConfigMap é gerado, nunca editado à mão, e o CI confere que o gerado está em
dia com o .json. Duas cópias que se editam separadamente divergem: o painel no
cluster fica diferente do painel no repositório e ninguém sabe qual vale.
"""

import glob
import json
import os
import pathlib
import sys

DIRETORIO = "clusters/homelab/platform/observabilidade"
NAMESPACE = "observabilidade"


def gerar(caminho_json: str) -> str:
    nome = pathlib.Path(caminho_json).stem
    # Reserializa com indentação fixa: assim o gerado só muda quando o conteúdo
    # muda, e não quando o Grafana exporta com espaçamento diferente.
    corpo = json.dumps(json.load(open(caminho_json)), indent=2, ensure_ascii=False)
    embutido = "\n".join("    " + linha for linha in corpo.splitlines())

    return f"""# GERADO por hack/gerar-configmap-dashboard.py a partir de {nome}.json
# Não edite este arquivo: edite o .json e rode `make dashboards`.
apiVersion: v1
kind: ConfigMap
metadata:
  name: {nome}
  namespace: {NAMESPACE}
  labels:
    # É este rótulo que faz o sidecar do Grafana enxergar o painel.
    grafana_dashboard: "1"
    app.kubernetes.io/name: {nome}
data:
  {nome}.json: |
{embutido}
"""


def main() -> int:
    jsons = sorted(glob.glob(os.path.join(DIRETORIO, "*.json")))
    if not jsons:
        print(f"nenhum dashboard em {DIRETORIO}", file=sys.stderr)
        return 1

    for caminho in jsons:
        destino = caminho.replace(".json", ".configmap.yaml")
        pathlib.Path(destino).write_text(gerar(caminho))
        print(destino)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
