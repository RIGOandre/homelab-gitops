# Segredos

Duas camadas, com responsabilidades diferentes.

**SOPS + age, no Git.** Guarda uma credencial só: o `secret-id` do AppRole que o
External Secrets usa para entrar no Vault (`vault-approle.enc.yaml`). É a raiz da
confiança. Está no Git porque precisa existir antes de qualquer coisa que leia
segredo de algum lugar — inclusive antes do próprio External Secrets.

**External Secrets + Vault, em tempo de execução.** Guarda todo o resto. O Git
fica com o endereço do segredo, nunca com o valor. Trocar a senha do Grafana é um
`vault kv put`; o ESO percebe no próximo `refreshInterval` e reescreve o Secret.
Sem commit, sem PR, sem sync.

A regra prática: se rotacionar aquilo exigir um commit, está na camada errada.

## Arquivos

| Arquivo | O que é |
| --- | --- |
| `vault-approle.enc.yaml` | Cifrado de verdade com sops/age. Único segredo versionado. |
| `clustersecretstore-vault.yaml` | Como o ESO autentica no Vault. |
| `externalsecret-grafana-admin.yaml` | Exemplo do caminho normal de um segredo. |
| `argocd-cmp/` | Insumo da instalação do Argo CD. **Não é aplicado pelo Argo CD.** |

O `argocd-cmp/` fica em subdiretório de propósito: o plugin sops só gera o que
está na raiz deste diretório (`-maxdepth 1`). Se estivesse solto aqui, o patch do
repo-server seria aplicado no cluster como um Deployment pela metade.

## Pré-requisitos que não estão neste diretório

- Namespace `external-secrets` e o operator instalado (Helm, no bootstrap).
- Vault no ar, com o AppRole `external-secrets` e o KV v2 montado em `kv/`.
- Namespace `observabilidade`, criado pela frente de observabilidade. Antes disso
  o `ExternalSecret` do Grafana fica em `SecretSyncedError` — é esperado.
- Secret `sops-age` no namespace `argocd` e o sidecar sops no `argocd-repo-server`.
  Os dois entram por `make bootstrap`. Ver `docs/segredos.md`.

## Vault seala quando o nó reinicia

Queda de luz derruba o nó, o Vault volta selado e todo `ExternalSecret` para de
sincronizar. Não há auto-unseal aqui: isso exigiria uma KMS externa, que é
exatamente a dependência de nuvem que este cluster não quer ter. O preço é um
unseal manual depois de cada reinício não planejado. Os Secrets já materializados
continuam no cluster, então nada cai na hora — o que quebra é a próxima rotação.

## Mexendo num segredo cifrado

Nunca edite o `.enc.yaml` na mão. Use `make cifrar` / `make decifrar`, ou:

    sops clusters/homelab/platform/secrets/vault-approle.enc.yaml

O sops abre o `$EDITOR` com o conteúdo em claro e recifra ao salvar. Editar o
arquivo direto quebra o MAC e a decifragem falha com `MAC mismatch` — que é o
sops avisando que o arquivo foi adulterado, funcionando como deveria.
