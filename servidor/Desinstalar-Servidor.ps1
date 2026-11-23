# Desinstalar-Servidor.ps1 - remove a ponte de impressao deste PC.
param([switch]$Elevated)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Elevated) { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"; exit }
$r = (Read-Host "Remover a ponte de impressao deste PC ($env:COMPUTERNAME)? [S/N]").Trim().ToUpper()
if ($r -ne 'S') { exit }
foreach ($tn in 'Ponte de Impressora (TCP RAW)', 'Ponte POS-80C (TCP 9100)') {
    if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $tn; Unregister-ScheduledTask -TaskName $tn -Confirm:$false; "Tarefa removida: $tn" }
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'Ponte-Impressora\.ps1|ponte9100\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Ponte de Impressora*' -or $_.DisplayName -like 'Ponte POS-80C*' } | Remove-NetFirewallRule
"Regras de firewall removidas."
Remove-Item 'C:\ProgramData\PonteImpressora' -Recurse -Force -ErrorAction SilentlyContinue
"Pasta C:\ProgramData\PonteImpressora removida. Concluido."
pause
