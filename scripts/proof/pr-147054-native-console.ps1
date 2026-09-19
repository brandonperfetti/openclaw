param(
  [Parameter(Mandatory)][string]$Baseline,
  [Parameter(Mandatory)][string]$Candidate,
  [Parameter(Mandatory)][string]$Evidence
)
$ErrorActionPreference = "Stop"
if (-not $IsWindows) { throw "Native Windows is required." }
New-Item -ItemType Directory -Force -Path $Evidence | Out-Null
$root = Join-Path $env:RUNNER_TEMP ("pr147054-console-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null
$node = (Get-Command node.exe).Source
$interop = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class NativeConsole {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct Startup {
    public int cb; public string reserved; public string desktop; public string title;
    public int x,y,xsize,ysize,xchars,ychars,fill,flags;
    public short show,reserved2; public IntPtr reservedPtr,input,output,error;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct Info { public IntPtr process,thread; public uint pid,tid; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool CreateProcessW(string app,StringBuilder command,IntPtr pa,IntPtr ta,
    bool inherit,uint flags,IntPtr env,string cwd,ref Startup startup,out Info info);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool AttachConsole(uint pid);
  public delegate bool Handler(uint signal);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool SetConsoleCtrlHandler(Handler handler,bool add);
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GenerateConsoleCtrlEvent(uint signal,uint group);
  public static Handler KeepAlive = signal => true;
  public static uint Start(string command,string cwd) {
    var startup = new Startup(); startup.cb=Marshal.SizeOf(startup);
    Info info;
    if (!CreateProcessW(null,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,
        0x10,IntPtr.Zero,cwd,ref startup,out info))
      throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    CloseHandle(info.process); CloseHandle(info.thread); return info.pid;
  }
}
'@
Add-Type -TypeDefinition $interop
$interopPath = Join-Path $root "interop.cs"
[IO.File]::WriteAllText($interopPath,$interop)
$signalScript = Join-Path $root "signal.ps1"
@'
param([uint32]$Target,[uint32]$Event,[string]$Interop,[string]$Result)
$ErrorActionPreference="Stop"
Add-Type -TypeDefinition ([IO.File]::ReadAllText($Interop))
[NativeConsole]::FreeConsole() | Out-Null
if (-not [NativeConsole]::AttachConsole($Target)) { throw "AttachConsole failed." }
try {
  if (-not [NativeConsole]::SetConsoleCtrlHandler([NativeConsole]::KeepAlive,$true)) {
    throw "Cannot protect the signal sender."
  }
  $ok=[NativeConsole]::GenerateConsoleCtrlEvent($Event,0)
  [IO.File]::WriteAllText($Result,(@{nativeApi="GenerateConsoleCtrlEvent";event=$Event;target=$Target;success=$ok}|ConvertTo-Json))
  if (-not $ok) { throw "GenerateConsoleCtrlEvent failed." }
  Start-Sleep -Milliseconds 200
} finally {
  [NativeConsole]::FreeConsole() | Out-Null
}
'@ | Set-Content -LiteralPath $signalScript
$workerText = @'
import { writeFileSync, openSync, fsyncSync, closeSync } from "node:fs";
import path from "node:path";
await import(process.env.PR147054_MODULE);
const root=process.env.PR147054_CELL;
const save=(name,value)=>writeFileSync(path.join(root,name),JSON.stringify(value));
let stopping=false;
let completed=false;
const keepAlive=setInterval(()=>{},1000);
const admittedAt=Date.now();
save("admitted.json",{pid:process.pid,at:admittedAt});
// Work is admitted before any stop event, not created by the stop callback.
setTimeout(()=>{
  const fd=openSync(path.join(root,"effect.json"),"w");
  writeFileSync(fd,JSON.stringify({pid:process.pid,at:Date.now(),effect:"completed"}));
  fsyncSync(fd);closeSync(fd);completed=true;
  if(stopping){clearInterval(keepAlive);process.exit(0);}
},3200);
const stop=(signal)=>{
  if(stopping)return;
  stopping=true;
  save("draining.json",{pid:process.pid,signal,at:Date.now()});
  if(completed){clearInterval(keepAlive);process.exit(0);}
};
process.on("SIGINT",()=>stop("SIGINT"));
process.on("SIGTERM",()=>stop("SIGTERM"));
save("ready.json",{pid:process.pid,ppid:process.ppid,at:Date.now()});
'@
$supervisorText = @'
const {runRespawnedChild}=await import(process.env.PR147054_MODULE);
runRespawnedChild(process.execPath,[process.env.PR147054_WORKER,"gateway","run"],process.env);
'@
$rows = @()
$tracked = @()
function Test-Alive([int]$ProcessId) {
  return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}
function Wait-Json([string]$File,[int]$TimeoutMs) {
  $until=[DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  do {
    if (Test-Path -LiteralPath $File) {
      try { return Get-Content -LiteralPath $File -Raw | ConvertFrom-Json } catch {}
    }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $until)
  throw "Missing proof observation: $File"
}
try {
  foreach ($arm in @("baseline","candidate")) {
    $source = if ($arm -eq "baseline") { $Baseline } else { $Candidate }
    $module = (Resolve-Path (Join-Path $source "node-runtime-recovery.mjs")).Path
    foreach ($event in @(0,1)) {
      $cell=Join-Path $root "$arm-$event"
      New-Item -ItemType Directory -Path $cell | Out-Null
      $worker=Join-Path $cell "worker.mjs";$supervisor=Join-Path $cell "supervisor.mjs"
      [IO.File]::WriteAllText($worker,$workerText)
      [IO.File]::WriteAllText($supervisor,$supervisorText)
      $env:PR147054_MODULE=([Uri]$module).AbsoluteUri
      $env:PR147054_WORKER=$worker
      $env:PR147054_CELL=$cell
      $parentPid=[NativeConsole]::Start(('"{0}" "{1}" gateway run' -f $node,$supervisor),$cell)
      $tracked += [int]$parentPid
      $ready=Wait-Json (Join-Path $cell "ready.json") 15000
      $tracked += [int]$ready.pid
      if ($ready.ppid -ne $parentPid) { throw "Recovery child is not owned by the tracked wrapper." }
      $admitted=Wait-Json (Join-Path $cell "admitted.json") 2000
      if($admitted.pid -ne $ready.pid){throw "Work was not admitted by the tracked recovery child."}
      $signalResult=Join-Path $cell "signal.json"
      $start=[Diagnostics.Stopwatch]::StartNew()
      & pwsh -NoProfile -NonInteractive -File $signalScript -Target $parentPid -Event $event -Interop $interopPath -Result $signalResult
      if ($LASTEXITCODE -ne 0) { throw "Native console event sender failed." }
      $native=Wait-Json $signalResult 2000
      if (-not $native.success) { throw "Native console event was not sent." }
      $until=[DateTime]::UtcNow.AddSeconds(12)
      while (((Test-Alive $parentPid) -or (Test-Alive $ready.pid)) -and [DateTime]::UtcNow -lt $until) {
        Start-Sleep -Milliseconds 50
      }
      $effectPath=Join-Path $cell "effect.json"
      $effect=if(Test-Path -LiteralPath $effectPath){Get-Content -LiteralPath $effectPath -Raw | ConvertFrom-Json}else{$null}
      $drainPath=Join-Path $cell "draining.json"
      $drain=if(Test-Path -LiteralPath $drainPath){Get-Content -LiteralPath $drainPath -Raw | ConvertFrom-Json}else{$null}
      $gone=(-not (Test-Alive $parentPid)) -and (-not (Test-Alive $ready.pid))
      $row=[ordered]@{arm=$arm;event=$event;eventName=if($event -eq 0){"Ctrl+C"}else{"Ctrl+Break"};
        native=$native;sourceSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $module).Hash.ToLower();
        ready=$ready;admitted=$admitted;drain=$drain;effect=$effect;elapsedMs=$start.ElapsedMilliseconds;trackedPidsGone=$gone}
      $rows += $row
      if (-not $gone) { throw "Tracked wrapper or recovery child survived native console stop." }
      if ($arm -eq "baseline" -and $null -ne $effect) { throw "Baseline did not reproduce lost drain." }
      if ($arm -eq "candidate") {
        if ($null -eq $effect -or $null -eq $drain -or $effect.pid -ne $ready.pid -or ($effect.at-$admitted.at) -lt 3000 -or $drain.at -gt $effect.at) {
          throw "Candidate did not durably finish its admitted drain."
        }
      }
    }
  }
} finally {
  $cleanupErrors=@()
  $tracked += @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) } | ForEach-Object { [int]$_.ProcessId })
  $tracked = @($tracked | Sort-Object -Unique)
  foreach($processId in $tracked) {
    if(Test-Alive $processId) {
      $p=Get-CimInstance Win32_Process -Filter "ProcessId=$processId"
      if ($p.CommandLine -and $p.CommandLine.Contains($root)) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
      else { $cleanupErrors += "Tracked PID identity changed: $processId" }
    }
  }
  Start-Sleep -Milliseconds 100
  foreach($processId in $tracked) {
    if(Test-Alive $processId) { $cleanupErrors += "Tracked PID still present: $processId" }
  }
  [ordered]@{os=[Environment]::OSVersion.VersionString;node=(& $node --version);
    scope="Real native Windows console events, candidate recovery module with synthetic drain worker; not full packaged Gateway/platform acceptance.";
    cases=$rows;cleanupErrors=$cleanupErrors} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Evidence "console-proof.json")
  if($cleanupErrors.Count -eq 0) { Remove-Item -LiteralPath $root -Recurse -Force }
  if($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join "; ") }
}
if($rows.Count -ne 4) { throw "Incomplete native console proof." }
Write-Host "Native Ctrl+C and Ctrl+Break reproduced before and passed after; tracked PIDs gone."
