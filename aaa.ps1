$modsFolder = Read-Host 'Enter your mods folder path'
$modsFolder = $modsFolder.Trim('"')

if (-not (Test-Path $modsFolder)) {
    Write-Host 'Folder not found. Check the path and try again.'
    return
}

$staging = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\faggotassfakemoddeletegrigger'

if (-not (Test-Path $staging)) {
    New-Item -ItemType Directory -Path $staging | Out-Null
}

$mods = Get-ChildItem -Path $modsFolder -Filter '*.jar' | Sort-Object Name
if ($mods.Count -eq 0) {
    Write-Host 'No mods found in folder.'
    return
}

Write-Host ''
Write-Host '--- Mods in folder ---'
for ($i = 0; $i -lt $mods.Count; $i++) {
    Write-Host (($i + 1).ToString().PadLeft(3) + '  ' + $mods[$i].Name)
}
Write-Host ''

$selection = Read-Host 'Enter number of mod to remove'
$idx       = 0
if (-not [int]::TryParse($selection, [ref]$idx) -or $idx -lt 1 -or $idx -gt $mods.Count) {
    Write-Host 'Invalid selection.'
    return
}

$selected = $mods[$idx - 1].FullName
$dest     = Join-Path $staging $mods[$idx - 1].Name

Write-Host ''
Write-Host ('Selected: ' + $mods[$idx - 1].Name)
Write-Host ('Moving to: ' + $dest)
Write-Host ''

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class HandleHunter2 {
    [DllImport("ntdll.dll")]
    public static extern int NtQuerySystemInformation(int SystemInformationClass,
        IntPtr SystemInformation, uint SystemInformationLength, out uint ReturnLength);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint dwAccess, bool bInherit, uint dwPID);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool DuplicateHandle(IntPtr hSrcProc, IntPtr hSrcHandle,
        IntPtr hTgtProc, out IntPtr hTgtHandle, uint dwAccess, bool bInherit, uint dwOptions);

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern uint GetFinalPathNameByHandle(IntPtr hFile, StringBuilder lpszFilePath,
        uint cchFilePath, uint dwFlags);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();
}
'@

$PROCESS_DUP_HANDLE      = [uint32]0x0040
$DUPLICATE_CLOSE_SOURCE  = [uint32]0x00000001
$DUPLICATE_SAME_ACCESS   = [uint32]0x00000002
$SystemHandleInformation = 16

$javaPID = (Get-Process -Name 'javaw' -ErrorAction SilentlyContinue | Select-Object -First 1).Id

if (-not $javaPID) {
    Write-Host 'javaw.exe not found — Minecraft not running, moving directly.'
    try {
        Move-Item -Path $selected -Destination $dest -ErrorAction Stop
        Write-Host 'Moved clean.'
    } catch {
        Write-Host ('Move failed: ' + $_.Exception.Message)
    }
    return
}

Write-Host ('Found javaw PID: ' + $javaPID)

$bufSize = [uint32]0x100000
$buf     = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bufSize)
$retLen  = [uint32]0

while ($true) {
    $status = [HandleHunter2]::NtQuerySystemInformation($SystemHandleInformation, $buf, $bufSize, [ref]$retLen)
    if ($status -eq 0) { break }
    if ($status -eq 0xC0000004) {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
        $bufSize = $retLen + 0x10000
        $buf     = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bufSize)
    } else {
        Write-Host ('NtQuerySystemInformation failed: 0x' + $status.ToString('X'))
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
        return
    }
}

$handleCount = [System.Runtime.InteropServices.Marshal]::ReadInt32($buf, 0)
$javaProc    = [HandleHunter2]::OpenProcess($PROCESS_DUP_HANDLE, $false, [uint32]$javaPID)

if ($javaProc -eq [IntPtr]::Zero) {
    Write-Host 'OpenProcess failed — run as Administrator.'
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    return
}

$selfProc    = [HandleHunter2]::GetCurrentProcess()
$entryOffset = 8
$entrySize   = 24
$foundHandle = $false
$sb          = New-Object System.Text.StringBuilder 1024

for ($i = 0; $i -lt $handleCount; $i++) {
    $offset = $entryOffset + ($i * $entrySize)
    $procId = [System.Runtime.InteropServices.Marshal]::ReadInt32($buf, $offset)
    if ($procId -ne $javaPID) { continue }

    $handleVal = [System.Runtime.InteropServices.Marshal]::ReadInt16($buf, $offset + 6)
    $srcHandle = [IntPtr]$handleVal
    $dupHandle = [IntPtr]::Zero

    $duped = [HandleHunter2]::DuplicateHandle($javaProc, $srcHandle, $selfProc,
        [ref]$dupHandle, 0, $false, $DUPLICATE_SAME_ACCESS)
    if (-not $duped) { continue }

    $sb.Clear() | Out-Null
    $len = [HandleHunter2]::GetFinalPathNameByHandle($dupHandle, $sb, 1024, 0)
    [HandleHunter2]::CloseHandle($dupHandle) | Out-Null
    if ($len -eq 0) { continue }

    $resolved = $sb.ToString() -replace '^\\\\\?\\', ''
    if ($resolved -eq $selected) {
        Write-Host ('Found JVM handle: 0x' + $handleVal.ToString('X') + ' — closing remotely.')
        $dummy = [IntPtr]::Zero
        [HandleHunter2]::DuplicateHandle($javaProc, $srcHandle, [IntPtr]::Zero,
            [ref]$dummy, 0, $false, $DUPLICATE_CLOSE_SOURCE) | Out-Null
        $foundHandle = $true
        break
    }
}

[HandleHunter2]::CloseHandle($javaProc) | Out-Null
[System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)

if (-not $foundHandle) {
    Write-Host 'No JVM handle found — file already released or path mismatch.'
}

Start-Sleep -Milliseconds 200

try {
    Move-Item -Path $selected -Destination $dest -ErrorAction Stop
    Write-Host ''
    Write-Host ('Done. ' + $mods[$idx - 1].Name + ' moved to backup folder. Minecraft stable.')
} catch {
    Write-Host ('Move failed: ' + $_.Exception.Message)
}