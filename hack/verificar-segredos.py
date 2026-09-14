#!/usr/bin/env python3
"""Reprova o PR se algum segredo entrou em claro no repositório.

Roda no CI e localmente (`make validar`). Não substitui revisão: pega o erro
mecânico, que é o que acontece de verdade - alguém faz
`kubectl create secret ... --dry-run=client -o yaml > arquivo.yaml`, commita, e
só descobre quando o segredo já está no histórico do Git.

Uso: verificar-segredos.py [raiz-do-repositorio]
"""

import os
import re
import sys

import yaml

# Diretórios que não são código do repositório. .terraform guarda cópia dos
# módulos baixados e daria falso positivo em provider que traz exemplo de Secret.
IGNORAR_DIRS = {".git", ".terraform", "node_modules", ".venv", "vendor"}

SUFIXOS_YAML = (".yaml", ".yml")
SUFIXO_CIFRADO = ".enc.yaml"

# Chave privada age tem corpo bech32 depois do prefixo. Casar só o prefixo faria
# este arquivo se reprovar sozinho, já que ele precisa citar o prefixo.
RE_CHAVE_AGE = re.compile(r"AGE-SECRET-KEY-1[0-9A-Z]{20,}")

# Só interessa o que o sops de fato cifrou.
RE_VALOR_CIFRADO = re.compile(r"^ENC\[AES256_GCM,")

CAMPOS_SEGREDO = ("data", "stringData")

# Lista de exceções: Secret que existe por exigência de outro componente e não
# por carregar credencial. Ver o cabeçalho do arquivo.
ARQUIVO_PERMITIDOS = os.path.join("hack", "segredos-permitidos.txt")

# Aplicado ao conteúdo dos arquivos da lista de exceções. A exceção suspende a
# regra "Secret com data em claro"; não suspende a procura por credencial, senão
# a lista viraria a porta dos fundos que ela deveria evitar.
RE_PALAVRA_CREDENCIAL = re.compile(
    r"(?i)\b(senha|password|passwd|token|api[_-]?key|secret[_-]?key"
    r"|client[_-]?secret|access[_-]?key|bearer|auth[_-]?token)\b\s*[:=]\s*\S"
)
RE_URL_COM_CREDENCIAL = re.compile(r"://[^\s/:@]+:[^\s/@]+@")
RE_CHAVE_PEM = re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----")

# Arquivo maior que isso é artefato, não manifesto. Ler tudo em texto custaria
# caro e não acha nada.
LIMITE_BYTES = 2 * 1024 * 1024


class Resultado:
    def __init__(self):
        self.falhas = []
        self.avisos = []
        self.cifrados = 0
        self.arquivos = 0

    def falhar(self, caminho, motivo):
        self.falhas.append((caminho, motivo))

    def avisar(self, caminho, motivo):
        self.avisos.append((caminho, motivo))


def normalizar(caminho):
    """Caminho relativo com barra normal, independente do sistema de arquivos.

    A lista de exceções é escrita com barra normal, e no Windows o os.path.relpath
    devolve barra invertida: sem esta normalização a exceção nunca casa e o
    verificador reprova em claro um Secret que ele mesmo já tinha liberado.
    """
    return caminho.replace(os.sep, "/")


def ler_permitidos(raiz, res):
    """Lê a lista de exceções. Entrada apontando para arquivo que sumiu reprova."""
    caminho = os.path.join(raiz, ARQUIVO_PERMITIDOS)
    permitidos = set()
    if not os.path.exists(caminho):
        return permitidos
    with open(caminho, "r", encoding="utf-8") as fh:
        for linha in fh:
            linha = linha.split("#", 1)[0].strip()
            if not linha:
                continue
            permitidos.add(normalizar(linha))
            if not os.path.exists(os.path.join(raiz, linha)):
                res.falhar(
                    ARQUIVO_PERMITIDOS,
                    f"exceção para '{linha}', que não existe mais; remova a linha",
                )
    return permitidos


def caminhar(raiz):
    for base, dirs, arquivos in os.walk(raiz):
        dirs[:] = sorted(d for d in dirs if d not in IGNORAR_DIRS)
        for nome in sorted(arquivos):
            yield os.path.join(base, nome)


def ler_texto(caminho):
    try:
        if os.path.getsize(caminho) > LIMITE_BYTES:
            return None
        with open(caminho, "r", encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError):
        return None


def valores_de(bloco):
    """Achata data/stringData para uma lista de (chave, valor-texto)."""
    if not isinstance(bloco, dict):
        return []
    saida = []
    for chave, valor in bloco.items():
        if valor is None:
            continue
        saida.append((chave, valor if isinstance(valor, str) else str(valor)))
    return saida


def checar_cifrado(caminho, docs, res):
    """Arquivo *.enc.yaml: tem que estar cifrado de verdade."""
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        if "sops" not in doc:
            res.falhar(caminho, "termina em .enc.yaml mas não tem bloco 'sops'; "
                                "provavelmente foi commitado antes de cifrar")
            continue
        vazio = True
        for campo in CAMPOS_SEGREDO:
            for chave, valor in valores_de(doc.get(campo)):
                vazio = False
                if not RE_VALOR_CIFRADO.match(valor):
                    res.falhar(
                        caminho,
                        f"{campo}.{chave} não está cifrado (esperado ENC[AES256_GCM,...])",
                    )
        if not vazio:
            res.cifrados += 1


def checar_credencial_aparente(caminho, campo, chave, valor, res):
    """Heurística aplicada ao que está na lista de exceções."""
    if RE_CHAVE_PEM.search(valor):
        achado = "uma chave privada em PEM"
    elif RE_URL_COM_CREDENCIAL.search(valor):
        achado = "uma URL com usuário e senha embutidos"
    elif RE_PALAVRA_CREDENCIAL.search(valor):
        achado = "um campo com cara de credencial"
    else:
        return
    res.falhar(
        caminho,
        f"está em {ARQUIVO_PERMITIDOS}, mas {campo}.{chave} contém {achado}; "
        "a exceção não cobre isso - o valor vai para o Vault",
    )


def checar_claro(caminho, docs, res, permitido=False):
    """Arquivo comum: não pode ter Secret com conteúdo, nem bloco sops."""
    for doc in docs:
        if not isinstance(doc, dict):
            continue

        # Cifrado com o nome errado. O sidecar do Argo CD escolhe o que decifrar
        # pelo glob *.enc.yaml; com outro nome ele aplica o blob cru e o erro no
        # sync não diz nada sobre o nome do arquivo.
        if "sops" in doc:
            res.falhar(caminho, "tem bloco 'sops' mas não termina em .enc.yaml; "
                                "o Argo CD não vai decifrar este arquivo")

        if doc.get("kind") != "Secret":
            continue

        for campo in CAMPOS_SEGREDO:
            for chave, valor in valores_de(doc.get(campo)):
                if valor == "":
                    continue
                if permitido:
                    checar_credencial_aparente(caminho, campo, chave, valor, res)
                    continue
                res.falhar(
                    caminho,
                    f"kind: Secret com {campo}.{chave} em claro; "
                    "renomeie para *.enc.yaml e rode `make cifrar`",
                )


def checar_texto_cru(caminho, texto, res):
    """Fallback para YAML que não parseia (template de Helm, por exemplo)."""
    if re.search(r"^kind:\s*Secret\s*$", texto, re.MULTILINE) and re.search(
        r"^\s*(data|stringData):\s*$", texto, re.MULTILINE
    ):
        res.falhar(caminho, "não parseia como YAML e aparenta ser um Secret com "
                            "data; confira à mão")


def main(argv):
    raiz = os.path.abspath(argv[1]) if len(argv) > 1 else os.getcwd()
    if not os.path.isdir(raiz):
        print(f"raiz inexistente: {raiz}", file=sys.stderr)
        return 2

    res = Resultado()
    permitidos = ler_permitidos(raiz, res)

    for caminho in caminhar(raiz):
        rel = normalizar(os.path.relpath(caminho, raiz))
        texto = ler_texto(caminho)
        if texto is None:
            continue

        # Vale para qualquer arquivo, não só YAML: a chave privada já apareceu
        # em .env, em anotação de script e em README.
        if RE_CHAVE_AGE.search(texto):
            res.falhar(rel, "contém uma chave privada age (AGE-SECRET-KEY-1...); "
                            "ela nunca entra no Git - ver docs/segredos.md")

        if not caminho.endswith(SUFIXOS_YAML):
            continue

        res.arquivos += 1
        try:
            docs = list(yaml.safe_load_all(texto))
        except yaml.YAMLError as erro:
            res.avisar(rel, f"não parseia como YAML ({type(erro).__name__})")
            checar_texto_cru(rel, texto, res)
            continue

        if caminho.endswith(SUFIXO_CIFRADO):
            checar_cifrado(rel, docs, res)
        else:
            checar_claro(rel, docs, res, permitido=rel in permitidos)

    for caminho, motivo in res.avisos:
        print(f"aviso     {caminho}: {motivo}")

    for caminho, motivo in res.falhas:
        print(f"REPROVADO {caminho}: {motivo}")

    print(
        f"\n{res.arquivos} YAML conferidos, "
        f"{res.cifrados} arquivo(s) cifrado(s) validado(s), "
        f"{len(permitidos)} exceção(ões) na lista, "
        f"{len(res.falhas)} reprovação(ões)."
    )
    return 1 if res.falhas else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
