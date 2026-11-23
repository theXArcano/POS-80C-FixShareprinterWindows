# Instalar-Cliente.ps1
# Rode em cada PC que vai imprimir. Procura na rede o PC com a ponte de impressao,
# mostra o que encontrou, pede confirmacao e instala a impressora (porta TCP RAW).
param([switch]$Elevated, [int]$PortaDescoberta = 9101)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Elevated) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated -PortaDescoberta $PortaDescoberta"
    exit
}

$LogInstall = Join-Path $PSScriptRoot "instalar-cliente_$env:COMPUTERNAME.log"
Remove-Item $LogInstall -ErrorAction SilentlyContinue
function L($t, $cor = 'Gray') { Write-Host $t -ForegroundColor $cor; $t | Out-File $LogInstall -Append -Encoding utf8 }
function Perguntar($t) { do { $r = (Read-Host "$t [S/N]").Trim().ToUpper() } while ($r -notin 'S','N'); return $r -eq 'S' }

function Procurar-Pontes([string]$Destino = '255.255.255.255', [int]$Espera = 2500) {
    $achados = @()
    try {
        $u = New-Object Net.Sockets.UdpClient
        $u.EnableBroadcast = $true; $u.Client.ReceiveTimeout = $Espera
        $msg = [Text.Encoding]::ASCII.GetBytes('PONTE-IMPRESSORA?')
        $alvos = @($Destino)
        if ($Destino -eq '255.255.255.255') {
            # broadcast tambem por sub-rede (algumas redes filtram o 255.255.255.255)
            Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254*' } | ForEach-Object {
                $ip = [Net.IPAddress]::Parse($_.IPAddress).GetAddressBytes()
                $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $_.PrefixLength))
                $mb = [BitConverter]::GetBytes($mask); [Array]::Reverse($mb)
                $bc = [byte[]](0..3 | ForEach-Object { [byte](($ip[$_] -bor ((-bnot [int]$mb[$_]) -band 255)) -band 255) })
                $alvos += ([Net.IPAddress]::new($bc)).ToString()
            }
        }
        foreach ($a in ($alvos | Select-Object -Unique)) { [void]$u.Send($msg, $msg.Length, $a, $PortaDescoberta) }
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $fim = (Get-Date).AddMilliseconds($Espera)
        while ((Get-Date) -lt $fim) {
            try {
                $d = $u.Receive([ref]$ep)
                $o = [Text.Encoding]::UTF8.GetString($d) | ConvertFrom-Json
                $o | Add-Member -NotePropertyName IP -NotePropertyValue $ep.Address.ToString() -Force
                $achados += $o
            } catch { break }
        }
        $u.Close()
    } catch {}
    $achados | Sort-Object Computador, Impressora -Unique
}

L "==========================================================" Cyan
L "  PONTE DE IMPRESSORA - instalacao no CLIENTE" Cyan
L "  $(Get-Date)  |  $env:COMPUTERNAME" Cyan
L "==========================================================" Cyan
L ""
L "Procurando impressoras compartilhadas pela ponte na rede..." Yellow
$pontes = @(Procurar-Pontes)

$escolha = $null
if ($pontes.Count -gt 0) {
    L "Encontrado(s):" Yellow
    $i = 0
    foreach ($p in $pontes) { $i++; L ("  [{0}] PC {1} ({2})  ->  impressora '{3}'  driver '{4}'  porta {5}" -f $i, $p.Computador, $p.IP, $p.Impressora, $p.Driver, $p.Porta) }
    L ""
    if ($pontes.Count -eq 1) {
        if (Perguntar "Instalar a impressora '$($pontes[0].Impressora)' do PC $($pontes[0].Computador)?") { $escolha = $pontes[0] }
    } else {
        $r = Read-Host "Digite o numero da opcao (ou ENTER para digitar o PC manualmente)"
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $pontes.Count) { $escolha = $pontes[[int]$r - 1] }
    }
} else {
    L "Nenhuma ponte respondeu automaticamente (rede pode bloquear broadcast)." DarkYellow
}

if (-not $escolha) {
    $pc = (Read-Host "Digite o NOME ou IP do PC onde a impressora esta ligada").Trim()
    $r = @(Procurar-Pontes -Destino $(try { ([Net.Dns]::GetHostAddresses($pc) | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1).ToString() } catch { $pc }))
    if ($r.Count -gt 0) {
        $escolha = $r[0]; $escolha.Computador = $pc
        L "  Ponte encontrada em $pc -> impressora '$($escolha.Impressora)'" Green
    } else {
        $porta = Read-Host "Ponte nao respondeu a descoberta. Porta TCP (ENTER = 9100)"; if (-not $porta) { $porta = 9100 }
        $imp = Read-Host "Digite o NOME da impressora no PC $pc (ex.: POS-80C)"
        $drv = Read-Host "Driver a usar neste PC (ENTER = mesmo nome da impressora)"; if (-not $drv) { $drv = $imp }
        $escolha = [pscustomobject]@{ Computador = $pc; IP = $pc; Impressora = $imp; Driver = $drv; Porta = [int]$porta }
    }
}

$alvo = $escolha.Computador
if (-not (Test-NetConnection $alvo -Port $escolha.Porta -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    L "  Nome '$alvo' nao respondeu na porta $($escolha.Porta); usando IP $($escolha.IP)" DarkYellow
    $alvo = $escolha.IP
}
$nome  = "$($escolha.Impressora) ($($escolha.Computador))"
$porta = "PONTE_$($escolha.Computador)_$($escolha.Porta)"

L ""
L "Resumo:" Yellow
L "  PC servidor ....... $($escolha.Computador)  ($alvo)"
L "  Impressora ........ $($escolha.Impressora)"
L "  Porta ............. TCP $($escolha.Porta)"
L "  Driver ............ $($escolha.Driver)"
L "  Nome neste PC ..... $nome"
L ""
if (-not (Perguntar "Esta tudo certo? Instalar?")) {
    $nome = (Read-Host "Nome para a impressora neste PC (ENTER = '$nome')").Trim() | ForEach-Object { if ($_) { $_ } else { $nome } }
    $d = (Read-Host "Driver (ENTER = '$($escolha.Driver)')").Trim(); if ($d) { $escolha.Driver = $d }
    if (-not (Perguntar "Instalar '$nome' com o driver '$($escolha.Driver)'?")) { L "Cancelado."; pause; exit }
}

if (-not (Test-NetConnection $alvo -Port $escolha.Porta -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    L "ERRO: $alvo nao responde na porta $($escolha.Porta). Verifique se a ponte esta instalada no servidor." Red; pause; exit 1
}

# --- Driver ---------------------------------------------------------------------
$drv = $escolha.Driver
if (-not (Get-PrinterDriver -Name $drv -ErrorAction SilentlyContinue)) {
    L "Driver '$drv' nao esta instalado. Procurando na pasta driver\ ..." Yellow
    $pastaDrv = Join-Path (Split-Path $PSScriptRoot) 'driver'
    $infs = Get-ChildItem $pastaDrv -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'x64|amd64' }
    foreach ($inf in $infs) {
        L "  pnputil $($inf.Name)"; pnputil /add-driver "$($inf.FullName)" /install | Out-Null
        try { Add-PrinterDriver -Name $drv -ErrorAction Stop; break } catch {}
    }
    if (-not (Get-PrinterDriver -Name $drv -ErrorAction SilentlyContinue)) {
        $exe = Get-ChildItem $pastaDrv -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^unins' } | Select-Object -First 1
        if ($exe) { L "  Abrindo instalador do fabricante: $($exe.Name) (conclua e feche a janela)" Yellow; Start-Process $exe.FullName -Wait }
    }
}
if (-not (Get-PrinterDriver -Name $drv -ErrorAction SilentlyContinue)) {
    L "  Driver '$drv' indisponivel. Usando 'Generic / Text Only' (so texto simples)." DarkYellow
    $drv = 'Generic / Text Only'; Add-PrinterDriver -Name $drv -ErrorAction SilentlyContinue
}
L "Driver: $drv" Green

# --- Limpeza de instalacoes anteriores para o mesmo servidor ---------------------
Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $nome -or $_.PortName -eq $porta -or $_.PortName -like "LPR_$($escolha.Computador)*" -or $_.PortName -like "*_$($escolha.Computador)_9100" } | Remove-Printer -ErrorAction SilentlyContinue
Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'Connection' -and $_.Name -like "\\$($escolha.Computador)\*" } | Remove-Printer -ErrorAction SilentlyContinue
Start-Sleep 1
Get-PrinterPort -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $porta } | Remove-PrinterPort -ErrorAction SilentlyContinue

# --- Porta e impressora -------------------------------------------------------------
Add-PrinterPort -Name $porta -PrinterHostAddress $alvo -PortNumber $escolha.Porta
Get-CimInstance Win32_TCPIPPrinterPort -Filter "Name='$porta'" | Set-CimInstance -Property @{ SNMPEnabled = $false } -ErrorAction SilentlyContinue
Add-Printer -Name $nome -DriverName $drv -PortName $porta
$pr = Get-Printer -Name $nome -ErrorAction SilentlyContinue
if ($pr) { L "Impressora '$nome' instalada (porta $porta -> ${alvo}:$($escolha.Porta))" Green } else { L "ERRO ao criar a impressora." Red; pause; exit 1 }

if (Perguntar "Imprimir pagina de teste?") {
    $w = Get-CimInstance Win32_Printer -Filter "Name='$($nome -replace "'", "\'")'"
    $x = Invoke-CimMethod -InputObject $w -MethodName PrintTestPage
    L "  Pagina de teste enviada (retorno $($x.ReturnValue))"
}
if (Perguntar "Definir '$nome' como impressora padrao deste PC?") {
    (Get-CimInstance Win32_Printer -Filter "Name='$($nome -replace "'", "\'")'") | Invoke-CimMethod -MethodName SetDefaultPrinter | Out-Null
    L "  Definida como padrao."
}
L ""
L "PRONTO." Green
pause
