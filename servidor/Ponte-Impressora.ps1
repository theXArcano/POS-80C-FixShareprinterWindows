# Ponte-Impressora.ps1
# Recebe trabalhos de impressao pela rede (TCP RAW, padrao 9100) e repassa para
# uma impressora local. Responde a descoberta por UDP (padrao 9101) para que os
# clientes encontrem este PC sozinhos.
# Executado pela tarefa agendada criada por Instalar-Servidor.ps1 (conta SYSTEM).

$ErrorActionPreference = 'Continue'
$Base   = 'C:\ProgramData\PonteImpressora'
$Config = Get-Content (Join-Path $Base 'config.json') -Raw | ConvertFrom-Json
$Log    = Join-Path $Base 'ponte.log'

function Write-Log($t) {
    try {
        if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 1MB) { Move-Item $Log "$Log.old" -Force }
        "$(Get-Date -Format s) $t" | Out-File $Log -Append -Encoding utf8
    } catch {}
}

Add-Type @"
using System; using System.Runtime.InteropServices;
public class RawPrn {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public class DI { public string n; public string o; public string t; }
 [DllImport("winspool.drv", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool OpenPrinter(string p, out IntPtr h, IntPtr d);
 [DllImport("winspool.drv", SetLastError=true)] static extern bool ClosePrinter(IntPtr h);
 [DllImport("winspool.drv", CharSet=CharSet.Unicode, SetLastError=true)] static extern int StartDocPrinter(IntPtr h, int l, DI di);
 [DllImport("winspool.drv", SetLastError=true)] static extern bool EndDocPrinter(IntPtr h);
 [DllImport("winspool.drv", SetLastError=true)] static extern bool StartPagePrinter(IntPtr h);
 [DllImport("winspool.drv", SetLastError=true)] static extern bool EndPagePrinter(IntPtr h);
 [DllImport("winspool.drv", SetLastError=true)] static extern bool WritePrinter(IntPtr h, byte[] b, int c, out int w);
 public static string Send(string printer, byte[] data, string doc) {
  IntPtr h; if (!OpenPrinter(printer, out h, IntPtr.Zero)) return "OpenPrinter erro " + Marshal.GetLastWin32Error();
  DI di = new DI(); di.n = doc; di.t = "RAW";
  if (StartDocPrinter(h, 1, di) == 0) { int e = Marshal.GetLastWin32Error(); ClosePrinter(h); return "StartDoc erro " + e; }
  StartPagePrinter(h); int w; bool ok = WritePrinter(h, data, data.Length, out w); EndPagePrinter(h); EndDocPrinter(h); ClosePrinter(h);
  return ok ? ("ok " + w + " bytes") : ("WritePrinter erro " + Marshal.GetLastWin32Error());
 }
}
"@

# --- Descoberta UDP (roda em paralelo) ---------------------------------------
$udp = [powershell]::Create()
[void]$udp.AddScript({
    param($Porta, $Info, $Log)
    while ($true) {
        try {
            $u = New-Object Net.Sockets.UdpClient($Porta)
            $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            while ($true) {
                $req = [Text.Encoding]::ASCII.GetString($u.Receive([ref]$ep))
                if ($req -eq 'PONTE-IMPRESSORA?') {
                    $resp = [Text.Encoding]::UTF8.GetBytes($Info)
                    [void]$u.Send($resp, $resp.Length, $ep)
                }
            }
        } catch {
            try { "$(Get-Date -Format s) udp erro: $($_.Exception.Message)" | Out-File $Log -Append -Encoding utf8 } catch {}
            try { $u.Close() } catch {}
            Start-Sleep 5
        }
    }
}).AddArgument([int]$Config.PortaDescoberta).AddArgument((@{
    Computador = $env:COMPUTERNAME
    Impressora = $Config.Impressora
    Driver     = $Config.Driver
    Porta      = [int]$Config.Porta
} | ConvertTo-Json -Compress)).AddArgument($Log)
[void]$udp.BeginInvoke()

# --- Ponte TCP RAW ------------------------------------------------------------
Write-Log "Iniciando: TCP $($Config.Porta) -> '$($Config.Impressora)' | descoberta UDP $($Config.PortaDescoberta)"
while ($true) {
    try {
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::IPv6Any, [int]$Config.Porta)
        $l.Server.DualMode = $true
        $l.Start()
        while ($true) {
            $c  = $l.AcceptTcpClient()
            $de = $c.Client.RemoteEndPoint.ToString()
            $s  = $c.GetStream(); $s.ReadTimeout = 20000
            $ms = New-Object IO.MemoryStream; $buf = New-Object byte[] 65536
            try { while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) } } catch {}
            $c.Close()
            if ($ms.Length -gt 0) {
                $r = [RawPrn]::Send($Config.Impressora, $ms.ToArray(), "Rede $de")
                Write-Log "$de -> $r"
            }
        }
    } catch {
        Write-Log "erro: $($_.Exception.Message)"
        try { $l.Stop() } catch {}
        Start-Sleep 5
    }
}
