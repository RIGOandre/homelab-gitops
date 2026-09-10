#!/usr/bin/env python3
"""Confere que cada versão de chart fixada nos Application existe de verdade.

Versão de chart fixada é a coisa mais fácil de errar num repositório GitOps: o
número é digitado à mão, ninguém revisa dígito, e o erro só aparece quando o
Argo CD tenta sincronizar e devolve `chart not found`. Como o sync é
automático, isso acontece sozinho, de madrugada, sem nada tendo mudado no Git.

Precisa do `helm` no PATH — é o CI que roda isto, não a máquina de quem edita.
"""

import glob
import os
import shutil
import subprocess
import sys

import yaml

APPS = "clusters/homelab/apps/*.yaml"


def fontes(doc):
    """Devolve as sources de um Application, seja `source` ou `sources`."""
    spec = doc.get("spec", {})
    if "sources" in spec:
        return spec["sources"]
    if "source" in spec:
        return [spec["source"]]
    return []


def main() -> int:
    if shutil.which("helm") is None:
        print(
            "helm não está no PATH. Este verificador consulta o repositório de\n"
            "cada chart pela rede; sem helm não há o que conferir.",
            file=sys.stderr,
        )
        return 2

    charts = []
    for arquivo in sorted(glob.glob(APPS)):
        for doc in yaml.safe_load_all(open(arquivo)):
            if not doc or doc.get("kind") != "Application":
                continue
            for fonte in fontes(doc):
                # Sem `chart` a source é um diretório do próprio repositório,
                # e aí não há versão de terceiro para conferir.
                if "chart" not in fonte:
                    continue
                charts.append(
                    (
                        os.path.basename(arquivo),
                        fonte["repoURL"],
                        fonte["chart"],
                        str(fonte["targetRevision"]),
                    )
                )

    if not charts:
        print(f"nenhum chart encontrado em {APPS}", file=sys.stderr)
        return 1

    falhas = []
    for i, (arquivo, repo, chart, versao) in enumerate(charts):
        alias = f"repo{i}"
        subprocess.run(
            ["helm", "repo", "add", alias, repo],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        resultado = subprocess.run(
            ["helm", "show", "chart", f"{alias}/{chart}", "--version", versao],
            capture_output=True,
            text=True,
        )
        if resultado.returncode == 0:
            print(f"ok      {chart} {versao}  ({arquivo})")
        else:
            print(f"FALHOU  {chart} {versao}  ({arquivo})")
            falhas.append((arquivo, chart, versao, resultado.stderr.strip()))

    if falhas:
        print(f"\n{len(falhas)} versão(ões) de chart não existem no repositório de origem:\n", file=sys.stderr)
        for arquivo, chart, versao, erro in falhas:
            print(f"  {arquivo}: {chart} {versao}\n    {erro}", file=sys.stderr)
        return 1

    print(f"\n{len(charts)} versões de chart conferidas.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
