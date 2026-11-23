# Desinstalar-Cliente.ps1 - remove impressoras instaladas pela ponte neste PC.
param([switch]$Elevated)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Elevated) { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"; exit }
$lista = @(Get-Printer | Where-Object { $_.PortName -like 'PONTE_*' -or $_.PortName -like 'POS80C_*_9100' })
if (-not $lista) { "Nenhuma impressora da ponte encontrada."; pause; exit }
$i = 0; foreach ($p in $lista) { $i++; "  [$i] $($p.Name)  (porta $($p.PortName))" }
$r = Read-Host "Numero para remover (T = todas, ENTER = cancelar)"
$sel = if ($r -match '^[Tt]$') { $lista } elseif ($r -match '^\d+$' -and [int]$r -le $lista.Count) { @($lista[[int]$r - 1]) } else { @() }
foreach ($p in $sel) { $port = $p.PortName; Remove-Printer -Name $p.Name; Start-Sleep 1; Remove-PrinterPort -Name $port -ErrorAction SilentlyContinue; "Removida: $($p.Name)" }
pause
