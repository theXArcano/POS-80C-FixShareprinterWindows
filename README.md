# POS-80C — compartilhar impressora entre PCs Windows 11 sem autenticação

Scripts para compartilhar uma impressora USB (pensados para a térmica **POS-80C**, mas servem para qualquer impressora) de um PC para outros PCs da rede **sem usar o compartilhamento do Windows e sem pedir senha**.

Uso interno da SUINFO/DPE-MA.

---

## Por que isso existe

Ao compartilhar a POS-80C entre dois PCs com Windows 11 24H2/25H2, o cliente pedia usuário e senha e **recusava qualquer credencial**: administrador local, um usuário criado só para isso, conta Convidado e até conta de domínio fora da rede da Defensoria.

No PC que compartilha a impressora, o Visualizador de Eventos mostrava:

| Evento | Detalhe |
|---|---|
| Segurança **4625** | `Status 0xC000006D`, `SubStatus 0x0`, NTLM, logon tipo 3 |
| Sistema **LsaSrv 6167** | *"Há uma incompatibilidade parcial na ID do computador… Isso também pode ocorrer se a máquina foi clonada sem o uso do sysprep."* |

**Causa:** os PCs foram clonados da mesma imagem **sem `sysprep /generalize`**, então têm o mesmo SID de máquina. Desde as atualizações de **agosto/setembro de 2025 (KB5064081 / KB5065426)**, o Windows 11 24H2/25H2 e o Windows Server 2025 **bloqueiam a autenticação Kerberos e NTLM entre máquinas com SID duplicado** ([KB5070568 – Microsoft](https://support.microsoft.com/topic/kerberos-and-ntlm-authentication-failures-due-to-duplicate-sids-76f7394d-c460-4882-9ed1-d27e0960f949)).

Esse bloqueio afeta compartilhamento de pastas, de impressoras e RDP entre os clones. Nenhum ajuste de senha, NTLM, Convidado ou GPO local resolve. A solução definitiva é refazer a imagem com sysprep. Enquanto isso, este kit contorna o problema para impressoras.

## Como funciona

```
 PC CLIENTE                                 PC SERVIDOR (impressora na USB)
 ┌───────────────────────────┐   TCP 9100   ┌────────────────────────────────┐
 │ Impressora "POS-80C (PC)" │ ───────────► │ Ponte-Impressora.ps1 (SYSTEM)  │
 │ driver POS-80C            │   (RAW)      │   └─► WritePrinter RAW ─► USB  │
 │ porta TCP/IP RAW          │              │                                │
 └───────────────────────────┘   UDP 9101   │ responde à descoberta          │
        descoberta ◄──────────────────────── │ {PC, impressora, driver}       │
                                             └────────────────────────────────┘
```

- No **servidor**, uma tarefa agendada roda como `SYSTEM` desde o boot e escuta na porta **TCP 9100** (o mesmo protocolo das impressoras de rede, "RAW/JetDirect"). Cada trabalho recebido é enviado sem alteração para a impressora local.
- O cliente **renderiza o trabalho com o driver dele** e manda os bytes prontos. Por isso o cliente precisa do driver da impressora instalado.
- Não há compartilhamento SMB, RPC de spooler nem autenticação. O bloqueio de SID duplicado não se aplica.
- A ponte também responde na porta **UDP 9101** a uma mensagem de descoberta. É assim que o instalador do cliente encontra o servidor sozinho.

## Estrutura

```
servidor/
  INSTALAR_SERVIDOR.cmd      → instala a ponte (pede confirmação)
  DESINSTALAR_SERVIDOR.cmd   → remove tudo
  Instalar-Servidor.ps1
  Desinstalar-Servidor.ps1
  Ponte-Impressora.ps1       → serviço da ponte (copiado para C:\ProgramData\PonteImpressora)
cliente/
  INSTALAR_CLIENTE.cmd       → encontra a ponte e instala a impressora (pede confirmação)
  DESINSTALAR_CLIENTE.cmd    → remove as impressoras da ponte
  Instalar-Cliente.ps1
  Desinstalar-Cliente.ps1
driver/                      → coloque aqui o driver do fabricante (não versionado)
```

## Passo a passo

### 0. Preparar o pendrive
1. Baixe este repositório (**Code → Download ZIP**) e extraia no pendrive.
2. Copie o driver do fabricante para `driver\`. Para a POS-80C, copie a pasta `C:\POS Printer Driver V7.17` de um PC que já tenha o driver.

### 1. No PC onde a impressora está ligada (servidor)
Dê dois cliques em **`servidor\INSTALAR_SERVIDOR.cmd`** e aceite o UAC.

O script:
1. **lista as impressoras locais** e destaca a USB detectada (dá preferência a nomes com "POS"/"80");
2. mostra o **nome do PC, os IPs e a porta** e **pergunta se está certo**;
3. se não estiver, você **digita o número da lista ou o nome exato** da impressora;
4. instala a ponte, cria a tarefa agendada e libera o firewall (TCP 9100 e UDP 9101);
5. oferece imprimir um **cupom de teste**.

### 2. Em cada PC que vai imprimir (cliente)
Dê dois cliques em **`cliente\INSTALAR_CLIENTE.cmd`** e aceite o UAC.

O script:
1. **procura a ponte na rede** e lista PC, IP, impressora e driver;
2. **pede confirmação**. Se nada for encontrado, ou se você recusar, **digite o nome ou IP do PC**. Se a ponte também não responder assim, informe manualmente o nome da impressora, o driver e a porta;
3. mostra um **resumo** e pergunta se está tudo certo. Ainda dá para trocar o nome da impressora no PC e o driver;
4. instala o driver, se faltar: tenta o `.inf` (pnputil), depois o instalador `.exe` do fabricante e, por último, *Generic / Text Only*;
5. cria a porta TCP/IP RAW (SNMP desligado) e a impressora **"<impressora> (<PC servidor>)"**;
6. oferece **página de teste** e **definir como padrão**.

Os dois instaladores gravam um log ao lado do script: `instalar-servidor_<PC>.log` e `instalar-cliente_<PC>.log`.

## Solução de problemas

| Sintoma | O que verificar |
|---|---|
| Cliente não encontra a ponte | A rede pode bloquear broadcast. Digite o nome ou IP do servidor quando o script pedir. |
| "não responde na porta 9100" | No servidor: `Get-ScheduledTask 'Ponte de Impressora (TCP RAW)'` deve estar *Running*. Confira o firewall e o log `C:\ProgramData\PonteImpressora\ponte.log`. |
| Imprime caracteres estranhos | O cliente está com driver diferente do da impressora (ex.: *Generic / Text Only*). Instale o driver correto. |
| Nada sai, mas o log mostra `ok N bytes` | Problema na impressora ou na fila local do servidor. Teste imprimir direto nele. |
| Log mostra `OpenPrinter erro 1801` | O nome da impressora mudou no servidor. Rode o `INSTALAR_SERVIDOR.cmd` de novo. |
| PC servidor troca de IP | O cliente usa o **nome** do PC. Se o nome não resolver, ele usa o IP salvo na porta; reinstale o cliente ou reserve o IP no DHCP. |

Diagnóstico rápido do SID duplicado, no PC que recebe a conexão:

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; Id=6167} -MaxEvents 5
```

## Segurança

- A porta 9100 **aceita trabalhos de qualquer PC da rede**, sem autenticação, como qualquer impressora de rede. Ela só imprime; não dá acesso a arquivos.
- A tarefa roda como `SYSTEM` e só usa `OpenPrinter`/`WritePrinter` na impressora configurada.
- Se quiser restringir, edite a regra de firewall *"Ponte de Impressora TCP 9100"* e limite os IPs remotos.

## Solução definitiva

Refazer a imagem dos PCs com **`sysprep /generalize`** antes da captura no FOG, para que cada máquina tenha um SID único. Depois disso, o compartilhamento normal do Windows volta a funcionar entre elas.

## Histórico

- **23/11/2026** — Primeira versão, criada no caso LBJD1141 → LBJD1135 (POS-80C, Win11 25H2/24H2). Antes de chegar nesta solução foram testados e descartados: LPD (o Windows 11 25H2 recusa abrir a fila por IP), ajustes de NTLM/LmCompatibilityLevel, RPC por pipes nomeados, usuário local dedicado e conta Convidado.
