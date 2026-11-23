# Instalar-Servidor.ps1
# Rode no PC onde a impressora esta ligada (USB). Cria a "ponte" de impressao
# pela rede (TCP RAW 9100), sem compartilhamento do Windows e sem senha.
param([switch]$Elevated, [int]$Porta = 9100, [int]$PortaDescoberta = 9101)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Elevated) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated -Porta $Porta -PortaDescoberta $PortaDescoberta"
    exit
}

$Base = 'C:\ProgramData\PonteImpressora'
$LogInstall = Join-Path $PSScriptRoot "instalar-servidor_$env:COMPUTERNAME.log"
Remove-Item $LogInstall -ErrorAction SilentlyContinue
function L($t, $cor = 'Gray') { Write-Host $t -ForegroundColor $cor; $t | Out-File $LogInstall -Append -Encoding utf8 }
function Perguntar($t) { do { $r = (Read-Host "$t [S/N]").Trim().ToUpper() } while ($r -notin 'S','N'); return $r -eq 'S' }

L "==========================================================" Cyan
L "  PONTE DE IMPRESSORA - instalacao no SERVIDOR" Cyan
L "  $(Get-Date)  |  $env:COMPUTERNAME" Cyan
L "==========================================================" Cyan

# --- 1. Deteccao -------------------------------------------------------------
$todas = Get-Printer | Where-Object { $_.Type -eq 'Local' -and $_.PortName -notmatch '^(PORTPROMPT|SHRFAX|nul|FILE|.*pipe|Microsoft|AD_Port|Webex)' }
$usb   = $todas | Where-Object { $_.PortName -match '^(USB|DOT4|COM|LPT)' }
$sugerida = ($usb | Where-Object { $_.Name -match 'POS|80' } | Select-Object -First 1)
if (-not $sugerida) { $sugerida = $usb | Select-Object -First 1 }

$ips = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254*' }).IPAddress -join ', '

L ""
L "Impressoras locais encontradas:" Yellow
$i = 0; $lista = @($todas)
foreach ($p in $lista) { $i++; L ("  [{0}] {1}  (porta {2}, driver {3}){4}" -f $i, $p.Name, $p.PortName, $p.DriverName, $(if ($sugerida -and $p.Name -eq $sugerida.Name) { '  <- detectada' } else { '' })) }
L ""
L "Deteccao:" Yellow
L "  Computador ........ $env:COMPUTERNAME"
L "  IP(s) ............. $ips"
L "  Impressora ........ $(if ($sugerida) { $sugerida.Name } else { '(nenhuma USB encontrada)' })"
L "  Porta de rede ..... TCP $Porta  (descoberta UDP $PortaDescoberta)"
L ""

$impressora = $null
if ($sugerida -and (Perguntar "Usar a impressora '$($sugerida.Name)'?")) {
    $impressora = $sugerida
} else {
    while (-not $impressora) {
        $r = Read-Host "Digite o NUMERO da lista ou o NOME exato da impressora"
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $lista.Count) { $impressora = $lista[[int]$r - 1] }
        else { $impressora = Get-Printer -Name $r -ErrorAction SilentlyContinue }
        if (-not $impressora) { L "  Impressora '$r' nao encontrada." Red }
    }
}
L "Impressora escolhida: $($impressora.Name)" Green
if (-not (Perguntar "Confirma a instalacao da ponte para '$($impressora.Name)' na porta $Porta?")) { L "Cancelado."; pause; exit }

# --- 2. Arquivos e configuracao -------------------------------------------------
New-Item $Base -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'Ponte-Impressora.ps1') "$Base\Ponte-Impressora.ps1" -Force
@{ Impressora = $impressora.Name; Driver = $impressora.DriverName; Porta = $Porta; PortaDescoberta = $PortaDescoberta } |
    ConvertTo-Json | Out-File "$Base\config.json" -Encoding utf8
L "1. Arquivos copiados para $Base"

# --- 3. Tarefa agendada (SYSTEM, no boot, reinicia se cair) ----------------------
$tn = 'Ponte de Impressora (TCP RAW)'
Get-ScheduledTask -TaskName 'Ponte POS-80C (TCP 9100)' -ErrorAction SilentlyContinue | ForEach-Object { Stop-ScheduledTask -TaskName $_.TaskName; Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false }
if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $tn; Unregister-ScheduledTask -TaskName $tn -Confirm:$false }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'ponte9100\.ps1|Ponte-Impressora\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Base\Ponte-Impressora.ps1`""
$t = New-ScheduledTaskTrigger -AtStartup
$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName $tn -Action $a -Trigger $t -Principal $p -Settings $s | Out-Null
Start-ScheduledTask -TaskName $tn
Start-Sleep 5
L "2. Tarefa '$tn': $((Get-ScheduledTask $tn).State)"

# --- 4. Firewall ----------------------------------------------------------------
foreach ($r in @(@{n="Ponte de Impressora TCP $Porta"; p='TCP'; port=$Porta}, @{n="Ponte de Impressora descoberta UDP $PortaDescoberta"; p='UDP'; port=$PortaDescoberta})) {
    Get-NetFirewallRule -DisplayName $r.n -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Protocol $r.p -LocalPort $r.port -Action Allow -Profile Any | Out-Null
}
L "3. Firewall liberado (TCP $Porta, UDP $PortaDescoberta)"

# --- 5. Teste -------------------------------------------------------------------
$ok = Test-NetConnection 127.0.0.1 -Port $Porta -InformationLevel Quiet -WarningAction SilentlyContinue
L "4. Porta $Porta escutando: $ok" $(if ($ok) { 'Green' } else { 'Red' })
if ($ok -and (Perguntar "Imprimir um cupom de teste agora?")) {
    try {
        $c = New-Object Net.Sockets.TcpClient('127.0.0.1', $Porta); $st = $c.GetStream()
        $b = [Text.Encoding]::ASCII.GetBytes("`r`n  TESTE PONTE - $env:COMPUTERNAME`r`n  $(Get-Date)`r`n`r`n`r`n`r`n`r`n") + [byte[]](0x1D, 0x56, 0x42, 0x00)
        $st.Write($b, 0, $b.Length); $c.Close(); Start-Sleep 3
        L "   $((Get-Content "$Base\ponte.log" -Tail 1))"
    } catch { L "   erro: $_" Red }
}

L ""
L "==========================================================" Green
L "  PRONTO. Nos PCs clientes rode cliente\INSTALAR_CLIENTE.cmd" Green
L "  Servidor: $env:COMPUTERNAME  ($ips)   Porta: $Porta" Green
L "  Log da ponte: $Base\ponte.log" Green
L "==========================================================" Green
pause
