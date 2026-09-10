# Runbooks

Um arquivo por assunto, ligado por `runbook_url` nas regras de
`clusters/homelab/platform/observabilidade/alertas.yaml`. Alerta que dispara sem
runbook do outro lado do link é o pior dos dois mundos: acorda alguém e não diz o
que fazer.

| Alerta | Runbook |
| --- | --- |
| `DiscoDoNoEnchendo`, `DiscoDoNoQuaseCheio` | [disco-cheio.md](disco-cheio.md) |
| `NoNotReady` | [no-notready.md](no-notready.md) |
| `MemoriaDoNoSaturada`, `NoSofreuOomKill`, `CpuDoNoSaturada` | [saturacao-do-no.md](saturacao-do-no.md) |
| `PodEmCrashLoopBackOff` | [crashloop.md](crashloop.md) |
| `CertificadoExpirando`, `CertificadoNaoRenovado` | [certificado-expirando.md](certificado-expirando.md) |
| `ArgoCdApplicationForaDeSincronia`, `ArgoCdApplicationDegradada`, `ArgoCdSyncFalhando` | [argocd-degradado.md](argocd-degradado.md) |
| `PreviewAmbienteExpirando`, `PreviewAmbienteVencidoNaoColetado`, `PreviewOperatorReconciliacaoFalhando` | [preview-expirando.md](preview-expirando.md) |

Todo runbook segue a mesma ordem: o que o alerta quer dizer, o primeiro comando,
as causas prováveis em ordem com como confirmar cada uma, como corrigir, e como
saber que passou. A última seção é a que costuma faltar — sem ela, o incidente
fecha na esperança.
