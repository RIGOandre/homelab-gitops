# Postmortem: <título curto do que quebrou, visto por quem usava>

O título descreve o sintoma, não a causa. "Grafana fora por 40 minutos", não
"PVC do Prometheus encheu" — na hora do incidente ninguém sabia do PVC.

- **Data:** AAAA-MM-DD
- **Duração do impacto:** HH:MM até HH:MM (X min)
- **Autor do relato:**
- **Estado:** rascunho | em revisão | fechado

## Regra desta pasta

Este documento descreve sistema, não pessoa. Onde couber nome de gente, cabe nome
de mecanismo: "o alerta de disco não existia", não "esqueceram de criar o
alerta". Se uma ação humana foi o gatilho, a pergunta é por que o sistema
permitiu que aquela ação tivesse aquele efeito — não quem a fez.

O objetivo é que o mesmo incidente não volte. Achar culpado não impede
reincidência; achar o mecanismo, sim.

## 1. Impacto medido

Números, não adjetivos. Se não foi medido, escreva "não medido" — é um achado por
si só, e vira ação lá embaixo.

| O quê | Medida |
| --- | --- |
| Serviços afetados | |
| Início do impacto (primeiro erro real) | |
| Fim do impacto (último erro real) | |
| Duração | |
| Requisições / jobs perdidos | |
| Dado perdido | sim / não / não sei — e por quê |

"Início do impacto" é quando o usuário começou a sentir, que raramente é quando o
alerta tocou. A diferença entre os dois é o número mais útil deste documento.

## 2. Linha do tempo

Fuso fixo e explícito. Um evento por linha, o que foi observado separado do que
se concluiu.

| Hora | O que aconteceu | Como se soube |
| --- | --- | --- |
| 00:00 | | |
| 00:00 | primeiro sintoma visível | |
| 00:00 | alerta disparou | |
| 00:00 | alguém começou a olhar | |
| 00:00 | causa identificada | |
| 00:00 | correção aplicada | |
| 00:00 | impacto encerrado | |
| 00:00 | confirmação de que estava estável | |

Inclua as hipóteses erradas e o tempo gasto nelas. É delas que saem as ações mais
úteis — cada caminho falso é um lugar onde o sistema mentiu sobre si mesmo.

## 3. O que detectou

- **Detectado por:** alerta | usuário | acaso, olhando outra coisa
- **Qual alerta, se houve:**
- **Tempo entre o início do impacto e a detecção:**
- **Se foi usuário ou acaso:** qual alerta deveria ter pegado, e por que não pegou
  (não existia, limiar errado, silenciado, rota de notificação quebrada)

## 4. O que atrasou o diagnóstico

Seção separada de propósito. Quase sempre o tempo até corrigir é dominado pelo
tempo até entender, e melhorar essa parte é mais barato do que melhorar o resto.

- Sinal que faltava:
- Sinal que existia e apontava para o lado errado:
- Painel ou log que não estava acessível durante a queda:
- Runbook inexistente, desatualizado ou incorreto:
- Passo manual que consumiu tempo:

Se algum runbook em `docs/runbooks/` levou para o caminho errado, corrigi-lo é a
primeira ação da lista.

## 5. Causa raiz

Uma coisa que estava verdadeira antes do incidente e sem a qual ele não teria
acontecido. Se a frase precisar de "e", provavelmente são duas causas — separe.

Continue perguntando "e o que permitiu isso?" até chegar num mecanismo que se
possa mudar. "O disco encheu" não é raiz; "não havia nada limitando o crescimento
do journal nem alerta antes do limite do kubelet" é.

**Causa raiz:**

**Fatores que aumentaram a gravidade:**

## 6. Por que não foi pior

Vale escrever. O que segurou (limite, retry, réplica, backup, sorte) é o que se
deve preservar nas ações — e se foi sorte, é uma ação.

## 7. Ações

Cada linha com dono e prazo. Sem dono, não é ação; é desejo.

| # | Ação | Tipo | Dono | Prazo | Estado |
| --- | --- | --- | --- | --- | --- |
| 1 | | evitar | | AAAA-MM-DD | aberta |
| 2 | | detectar | | AAAA-MM-DD | aberta |
| 3 | | diagnosticar mais rápido | | AAAA-MM-DD | aberta |
| 4 | | reduzir impacto | | AAAA-MM-DD | aberta |

Se a lista não tiver pelo menos uma ação de **detectar**, releia a seção 3: um
incidente que demorou a ser notado sempre tem lacuna de detecção.

Ação de tipo "tomar mais cuidado" não conta. Substitua por algo que o sistema
faça sozinho.

## 8. Prova de que a correção funciona

Como se demonstra, sem esperar o próximo incidente, que a ação principal pegou o
problema. Alerta testado com valor forjado, teste no CI, ensaio controlado.

Ação sem prova permanece hipótese.
