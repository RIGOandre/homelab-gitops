#!/usr/bin/env python3
"""Renderiza cada Application de chart e confere as chaves de values usadas.

O buraco que este verificador fecha: o Helm ignora em silêncio chave de values
que o chart não conhece. `alertmanager.configSecret` no lugar de
`alertmanager.alertmanagerSpec.configSecret` não dá erro, não deixa o Argo CD
OutOfSync e não aparece em `kubectl get`. O Alertmanager sobe verde, com a rota
padrão, e nenhum alerta chega no celular. É a falha mais cara que este
repositório pode ter, porque ela se disfarça de sucesso.

São duas conferências, e as duas precisam existir:

1. `helm template` com a versão de chart fixada. Pega erro de tipo e de forma
   (o values.schema.json do chart, quando existe) e qualquer template que
   estoure com a nossa configuração.
2. Cada caminho do nosso values tem que existir no values.yaml do chart ou no
   de um subchart dele. É o que pega a chave escrita errado, que o passo 1
   atravessa sem reclamar.

Precisa de `helm` no PATH e de rede: o chart é baixado na versão fixada.
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

import yaml

APPS = "clusters/homelab/apps/*.yaml"

# `$valores/...` é como o Argo CD referencia um arquivo da outra source do
# Application. Para nós a raiz de $valores é a raiz do repositório.
PREFIXO_VALORES = "$valores/"

# Caminhos cujo conteúdo é do componente, não do chart: o chart declara a chave
# e repassa o bloco inteiro adiante sem conhecer o que tem dentro. Descer neles
# reprovaria configuração legítima do Loki, do Grafana e do Alloy.
#
# Cada linha aqui é uma chave que deixa de ser conferida. Por isso são poucas, e
# por isso cada uma diz de quem é o esquema que passa a valer no lugar.
OPACOS = {
    # Config do Loki. O chart serializa este bloco direto no loki.yaml.
    ("loki",),
    # grafana.ini, servido tal e qual ao Grafana.
    ("grafana", "grafana.ini"),
    # Pipeline do Alloy, que é linguagem própria dentro de uma string.
    ("alloy", "configMap", "content"),
}


def fontes(doc):
    """Devolve as sources de um Application, seja `source` ou `sources`."""
    spec = doc.get("spec", {})
    if "sources" in spec:
        return spec["sources"]
    if "source" in spec:
        return [spec["source"]]
    return []


def values_da_source(fonte, raiz):
    """Junta o values inline e os valueFiles de uma source, na ordem do Helm."""
    helm = fonte.get("helm") or {}
    blocos = []

    for referencia in helm.get("valueFiles", []):
        if not referencia.startswith(PREFIXO_VALORES):
            raise ValueError(f"valueFiles fora de {PREFIXO_VALORES}: {referencia}")
        caminho = os.path.join(raiz, referencia[len(PREFIXO_VALORES):])
        with open(caminho, encoding="utf-8") as fh:
            blocos.append((caminho, yaml.safe_load(fh) or {}))

    # Inline por último: é o que o Helm faz com -f arquivo --set-string, e é o
    # que o Argo CD faz com valueFiles + values.
    if helm.get("values"):
        blocos.append(("values inline", yaml.safe_load(helm["values"]) or {}))

    return blocos


def fundir(destino, origem):
    """Merge recursivo, do jeito que o Helm funde values."""
    for chave, valor in origem.items():
        if isinstance(valor, dict) and isinstance(destino.get(chave), dict):
            fundir(destino[chave], valor)
        else:
            destino[chave] = valor
    return destino


def defaults_do_chart(diretorio):
    """values.yaml do chart com o de cada subchart embaixo do nome dele.

    Subchart empacotado vem em charts/. Sem juntar os defaults deles, toda
    chave de `grafana:` ou de `prometheus-node-exporter:` seria reprovada como
    desconhecida, porque o values.yaml do chart de cima só traz o que ele
    sobrescreve.
    """
    caminho = os.path.join(diretorio, "values.yaml")
    if os.path.exists(caminho):
        with open(caminho, encoding="utf-8") as fh:
            defaults = yaml.safe_load(fh) or {}
    else:
        defaults = {}

    for sub in sorted(glob.glob(os.path.join(diretorio, "charts", "*"))):
        if not os.path.isdir(sub):
            continue
        nome = os.path.basename(sub)
        # O alias do subchart pode diferir do nome do diretório; o Chart.yaml de
        # cima é quem sabe. Registrar os dois é mais barato que errar o alias.
        aliases = {nome}
        chart_yaml = os.path.join(diretorio, "Chart.yaml")
        if os.path.exists(chart_yaml):
            with open(chart_yaml, encoding="utf-8") as fh:
                meta = yaml.safe_load(fh) or {}
            for dep in meta.get("dependencies") or []:
                if dep.get("name") == nome and dep.get("alias"):
                    aliases.add(dep["alias"])

        sub_defaults = defaults_do_chart(sub)
        for alias in aliases:
            existente = defaults.get(alias)
            defaults[alias] = fundir(
                dict(sub_defaults), existente if isinstance(existente, dict) else {}
            )

    return defaults


def subcharts(diretorio):
    """Mapa alias -> diretório dos subcharts empacotados em charts/."""
    mapa = {}
    chart_yaml = os.path.join(diretorio, "Chart.yaml")
    meta = {}
    if os.path.exists(chart_yaml):
        with open(chart_yaml, encoding="utf-8") as fh:
            meta = yaml.safe_load(fh) or {}

    for sub in sorted(glob.glob(os.path.join(diretorio, "charts", "*"))):
        if not os.path.isdir(sub):
            continue
        nome = os.path.basename(sub)
        mapa[nome] = sub
        for dep in meta.get("dependencies") or []:
            if dep.get("name") == nome and dep.get("alias"):
                mapa[dep["alias"]] = sub
    return mapa


def texto_dos_templates(diretorio, cache):
    """Tudo que o chart tem de template, num texto só. Sem os subcharts."""
    if diretorio in cache:
        return cache[diretorio]

    pedacos = []
    for base, dirs, arquivos in os.walk(diretorio):
        dirs[:] = [d for d in dirs if d != "charts"]
        for nome in arquivos:
            if not nome.endswith((".yaml", ".yml", ".tpl", ".txt")):
                continue
            try:
                with open(os.path.join(base, nome), encoding="utf-8") as fh:
                    pedacos.append(fh.read())
            except (OSError, UnicodeDecodeError):
                continue

    cache[diretorio] = "\n".join(pedacos)
    return cache[diretorio]


def referenciada(caminho, diretorio, cache):
    """A chave aparece em algum template do chart, mesmo fora do values.yaml?

    O values.yaml de chart grande documenta boa parte das chaves comentadas —
    `configSecret` do alertmanagerSpec e `ingressClassName` do Grafana são
    assim. Elas existem: o template as lê. Conferir só contra o values.yaml
    reprovaria configuração correta, e verificador que acusa o que está certo
    é verificador que se desliga.
    """
    if not caminho:
        return False

    sub = subcharts(diretorio).get(caminho[0])
    if sub and referenciada(caminho[1:], sub, cache):
        return True

    return ".Values." + ".".join(caminho) in texto_dos_templates(diretorio, cache)


def desconhecidas(usados, defaults, prefixo=()):
    """Caminhos de `usados` que não existem em `defaults`.

    Não desce em lista: índice de lista não é chave de configuração, e o chart
    nunca declara os elementos no values.yaml dele.
    """
    faltando = []
    for chave, valor in usados.items():
        caminho = prefixo + (str(chave),)

        if caminho in OPACOS:
            continue

        if not isinstance(defaults, dict) or chave not in defaults:
            faltando.append(caminho)
            continue

        padrao = defaults[chave]

        # Chave declarada com `{}` ou vazia é mapa livre: o chart aceita o que
        # vier e repassa. Descer aqui reprovaria configuração válida.
        if padrao is None or padrao == {}:
            continue

        if isinstance(valor, dict):
            faltando += desconhecidas(valor, padrao, caminho)

    return faltando


def baixar(repo, chart, versao, destino):
    subprocess.run(
        ["helm", "pull", chart, "--repo", repo, "--version", versao,
         "--untar", "--untardir", destino],
        check=True,
        capture_output=True,
        text=True,
    )
    return os.path.join(destino, chart)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kube-version", default="1.31.5",
                        help="versão de Kubernetes usada no render")
    args = parser.parse_args()

    raiz = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    os.chdir(raiz)

    if shutil.which("helm") is None:
        print("helm não está no PATH; não há como renderizar chart nenhum.",
              file=sys.stderr)
        return 2

    falhas = []
    conferidos = 0

    for arquivo in sorted(glob.glob(APPS)):
        with open(arquivo, encoding="utf-8") as fh:
            docs = list(yaml.safe_load_all(fh))

        for doc in docs:
            if not doc or doc.get("kind") != "Application":
                continue
            nome = doc["metadata"]["name"]

            for fonte in fontes(doc):
                # Sem `chart` a source é diretório de manifesto deste
                # repositório: não há values para conferir.
                if "chart" not in fonte:
                    continue

                chart = fonte["chart"]
                versao = str(fonte["targetRevision"])
                blocos = values_da_source(fonte, raiz)
                conferidos += 1

                with tempfile.TemporaryDirectory() as tmp:
                    diretorio = baixar(fonte["repoURL"], chart, versao, tmp)

                    arquivos = []
                    for i, (_, conteudo) in enumerate(blocos):
                        destino = os.path.join(tmp, f"values{i}.yaml")
                        with open(destino, "w", encoding="utf-8", newline="\n") as fh:
                            yaml.safe_dump(conteudo, fh, allow_unicode=True)
                        arquivos += ["-f", destino]

                    render = subprocess.run(
                        ["helm", "template", nome, diretorio,
                         "--namespace", doc["spec"]["destination"]["namespace"],
                         "--kube-version", args.kube_version] + arquivos,
                        capture_output=True,
                        text=True,
                    )
                    if render.returncode != 0:
                        print(f"FALHOU  {nome}: helm template")
                        falhas.append((nome, render.stderr.strip()))
                        continue

                    defaults = defaults_do_chart(diretorio)

                    usados = {}
                    for _, conteudo in blocos:
                        fundir(usados, conteudo)

                    cache = {}
                    orfas = [
                        c for c in desconhecidas(usados, defaults)
                        if not referenciada(c, diretorio, cache)
                    ]

                objetos = render.stdout.count("\nkind: ")
                if orfas:
                    print(f"FALHOU  {nome}: {len(orfas)} chave(s) que o chart "
                          f"{chart} {versao} não conhece")
                    falhas.append((
                        nome,
                        "\n".join("    " + ".".join(c) for c in sorted(orfas)),
                    ))
                else:
                    print(f"ok      {nome} ({chart} {versao}): "
                          f"{objetos} objetos, chaves conferidas")

    if not conferidos:
        print(f"nenhum Application com chart em {APPS}", file=sys.stderr)
        return 1

    if falhas:
        print(f"\n{len(falhas)} Application reprovado(s):\n", file=sys.stderr)
        for nome, detalhe in falhas:
            print(f"  {nome}:\n{detalhe}\n", file=sys.stderr)
        print("Chave que o chart não conhece é ignorada em silêncio: o "
              "componente sobe\nsaudável com a configuração padrão. Confira o "
              "values.yaml do chart na\nversão fixada antes de acrescentar a "
              "chave em OPACOS.", file=sys.stderr)
        return 1

    print(f"\n{conferidos} Application renderizado(s) com a versão fixada.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
