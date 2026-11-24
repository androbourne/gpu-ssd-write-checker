@echo off
setlocal DisableDelayedExpansion
set "GPU_CHECK_FILE=%~f0"
powershell.exe -NoLogo -NoProfile -Command "$s=[IO.File]::ReadAllText($env:GPU_CHECK_FILE); Invoke-Expression ($s.Substring($s.IndexOf('# POWERSHELL'+' START')) )"
set "GPU_CHECK_EXIT=%ERRORLEVEL%"
pause
exit /b %GPU_CHECK_EXIT%
# POWERSHELL START
$ErrorActionPreference='Stop'
$report=New-Object 'System.Collections.Generic.List[string]'
function Say($s,$c='Gray') { Write-Host $s -ForegroundColor $c; $report.Add([string]$s) }
try {
Say 'GPU SSD Write Checker v2.1 - Community Edition' Cyan
Say 'Read-only sampling. No telemetry. Reports are saved locally on request.'
$gpus=@(Get-CimInstance Win32_VideoController)
foreach($g in $gpus){ Say ("GPU: {0} | Windows driver: {1}" -f $g.Name,$g.DriverVersion) }
$up=(Get-Date)-(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Say ('System uptime: '+$up.ToString('d\.hh\:mm\:ss'))

$storageNamespace = 'root/Microsoft/Windows/Storage'
$busNames = @('Unknown','SCSI','ATAPI','ATA','IEEE 1394','SSA','Fibre Channel','USB',
              'RAID','iSCSI','SAS','SATA','SD','MMC','Virtual','File-backed Virtual',
              'Storage Spaces','NVMe','SCM','UFS','NVMe-oF')
function Read-Inventory($class, $namespace='root/cimv2') {
    try { Get-CimInstance -Namespace $namespace -ClassName $class }
    catch { Say "Inventory source unavailable: $class" Yellow }
}
function New-DiskRecord($number, $model, $size, $bus, $media, $category, $letters) {
    if (!$bus) { $bus = 'Unknown' }
    if (!$model) { $model = 'Unknown model' }
    $capacity = if ($size -gt 0) { '{0:N2} GiB' -f ($size / 1GB) } else { 'Unknown capacity' }
    $label = if ($null -eq $number) { [string]$model } else { "Disk $number - $model" }
    $driveText = if ($letters) { $letters -join ', ' } else { 'None reported' }
    [pscustomobject]@{
        Number=$number; Label=$label; Category=$category
        Detail="$label | $capacity | Bus $bus | Media $media | Drives $driveText"
    }
}
function Get-Media($type, $bus) {
    switch ([int]$type) {
        3 { return 'HDD' }
        4 { return 'SSD' }
        5 { return 'SCM' }
    }
    if ($bus -eq 'NVMe' -or $bus -eq 'NVMe-oF') { return 'SSD (inferred from bus)' }
    return 'Unknown'
}
function Get-Category($media) {
    if ($media -like 'SSD*') { return 'SSD' }
    if ($media -eq 'HDD') { return 'Excluded' }
    return 'Unknown'
}
$osDisks = @(Read-Inventory MSFT_Disk $storageNamespace)
$physical = @(Read-Inventory MSFT_PhysicalDisk $storageNamespace)
$partitions = @(Read-Inventory MSFT_Partition $storageNamespace)
$legacyDisks = @(Read-Inventory Win32_DiskDrive)
$letterDisks = @{}
$pathDisks = @{}
foreach ($partition in $partitions) {
    if ($partition.DriveLetter -match '^[A-Z]$') {
        $letter = "$($partition.DriveLetter):"
        $letterDisks[$letter] = @($letterDisks[$letter]) + [int]$partition.DiskNumber
    }
    foreach ($path in $partition.AccessPaths) {
        if ($path -match '^[A-Z]:\\') {
            $path = $path.TrimEnd('\') + '\'
            $pathDisks[$path] = @($pathDisks[$path]) + [int]$partition.DiskNumber
        }
    }
}
foreach ($legacy in $legacyDisks) {
    if ($null -eq $legacy.Index -or $legacy.Index -gt [int]::MaxValue) { continue }
    if ($partitions | Where-Object DiskNumber -eq $legacy.Index) { continue }
    try {
        foreach ($partition in (Get-CimAssociatedInstance -InputObject $legacy -Association Win32_DiskDriveToDiskPartition)) {
            foreach ($volume in (Get-CimAssociatedInstance -InputObject $partition -Association Win32_LogicalDiskToPartition)) {
                if ($volume.DeviceID -match '^[A-Z]:$') {
                    $letterDisks[$volume.DeviceID] = @($letterDisks[$volume.DeviceID]) + [int]$legacy.Index
                }
            }
        }
    } catch { }
}
$matchedPhysical = @{}
$numbered = @{}
$inventory = @(
    foreach ($disk in $osDisks) {
        if ($null -eq $disk.Number -or $disk.Number -gt [int]::MaxValue) { continue }
        $number = [int]$disk.Number
        $numbered[$number] = $true
        $bus = if ($disk.BusType -ge 0 -and $disk.BusType -lt $busNames.Count) { $busNames[[int]$disk.BusType] } else { 'Unknown' }
        # PhysicalDisk.DeviceId is a provider identifier, not a Windows disk number.
        $match = @($physical | Where-Object { $disk.UniqueId -and $_.UniqueId -eq $disk.UniqueId })
        if ($match.Count -ne 1 -and $disk.SerialNumber -and $disk.Size -gt 0) {
            $match = @($physical | Where-Object {
                $_.SerialNumber -and $_.SerialNumber.Trim() -eq $disk.SerialNumber.Trim() -and
                $_.Size -eq $disk.Size -and $_.BusType -eq $disk.BusType
            })
        }
        $mediaType = $null
        if ($match.Count -eq 1) {
            $mediaType = $match[0].MediaType
            $matchedPhysical[[string]$match[0].ObjectId] = $true
        }
        $media = Get-Media $mediaType $bus
        $model = if ($disk.Model) { $disk.Model } else { $disk.FriendlyName }
        $letters = @($letterDisks.Keys | Where-Object { $letterDisks[$_] -contains $number } | Sort-Object)
        New-DiskRecord $number $model $disk.Size $bus $media (Get-Category $media) $letters
    }
    foreach ($disk in $legacyDisks) {
        if ($null -eq $disk.Index -or $disk.Index -gt [int]::MaxValue) { continue }
        $number = [int]$disk.Index
        if ($numbered.ContainsKey($number)) { continue }
        $letters = @($letterDisks.Keys | Where-Object { $letterDisks[$_] -contains $number } | Sort-Object)
        New-DiskRecord $number $disk.Model $disk.Size $disk.InterfaceType 'Unknown' 'Unknown' $letters
    }
    foreach ($disk in $physical) {
        if ($matchedPhysical.ContainsKey([string]$disk.ObjectId)) { continue }
        $bus = if ($disk.BusType -ge 0 -and $disk.BusType -lt $busNames.Count) { $busNames[[int]$disk.BusType] } else { 'Unknown' }
        $media = Get-Media $disk.MediaType $bus
        $model = if ($disk.Model) { $disk.Model } else { $disk.FriendlyName }
        New-DiskRecord $null "$model (Windows disk number unavailable)" $disk.Size $bus $media (Get-Category $media) @()
    }
    foreach ($disk in (Read-Inventory Win32_CDROMDrive)) {
        $bus = if ($disk.SCSIPort -and $disk.Name -match 'USB') { 'USB' } else { 'Unknown' }
        New-DiskRecord $null $disk.Name $disk.Size $bus 'Optical' 'Excluded' @($disk.Drive)
    }
)
function Format-Location($path) {
    if ($path -notmatch '^[A-Z]:\\') { return 'Disk mapping unavailable' }
    $pathWithSlash = $path.TrimEnd('\') + '\'
    $mount = $pathDisks.Keys | Where-Object {
        $pathWithSlash.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object Length -Descending | Select-Object -First 1
    $numbers = if ($mount) { $pathDisks[$mount] } else { $letterDisks[$path.Substring(0,2)] }
    $labels = @($numbers | Where-Object { $null -ne $_ } | Sort-Object -Unique | ForEach-Object { "Disk $_" })
    if ($labels.Count) { $labels -join ', ' } else { 'Disk mapping unavailable' }
}
Say ("Windows location: {0} | {1}" -f $env:SystemDrive,(Format-Location $env:windir))
$logCandidates = @(
    @{ Root=$env:PUBLIC; Relative='Documents\NvidiaLogging'; Token='%PUBLIC%' }
    @{ Root=$env:ProgramData; Relative='NVIDIA Corporation\NvContainer'; Token='%ProgramData%' }
    @{ Root=$env:ProgramData; Relative='NVIDIA Corporation\Display.NvContainer'; Token='%ProgramData%' }
)
$foundLog = $false
foreach ($candidate in $logCandidates) {
    if ($candidate.Root -notmatch '^[A-Z]:\\') { continue }
    $folder = Join-Path $candidate.Root $candidate.Relative
    try {
        $log = Get-ChildItem -LiteralPath $folder -Filter '*.log' -File -ErrorAction Stop | Select-Object -First 1
        if (!$log) { continue }
        $foundLog = $true
        # Redirected paths can point at a different volume. Only map registered mounts.
        $mapping = Format-Location $folder
        for ($item = Get-Item -LiteralPath $folder -Force; $item; $item = $item.Parent) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
                !$pathDisks.ContainsKey($item.FullName.TrimEnd('\') + '\')) {
                $mapping = 'Disk mapping unavailable (redirected path)'
                break
            }
        }
        Say ('NVIDIA log folder found: {0}\{1} | {2}' -f $candidate.Token,$candidate.Relative,$mapping)
    } catch { }
}
if (!$foundLog) { Say 'NVIDIA log location: No log found in the checked folders.' }
$eligible = @($inventory | Where-Object Category -eq 'SSD' | Sort-Object Number)
$unknown = @($inventory | Where-Object Category -eq 'Unknown' | Sort-Object Number)
$excluded = @($inventory | Where-Object Category -eq 'Excluded' | Sort-Object Number)
$choices = @($eligible + $unknown)
$option = 0
Say '--- Eligible SSDs ---' Cyan
if (!$eligible.Count) { Say 'None identified.' }
foreach ($disk in $eligible) { $option++; Say ("[{0}] {1}" -f $option,$disk.Detail) }
Say '--- Unknown SSD eligibility ---' Yellow
if (!$unknown.Count) { Say 'None identified.' }
else { Say 'These devices are selectable. Windows could not confirm SSD media.' Yellow }
foreach ($disk in $unknown) { $option++; Say ("[{0}] {1}" -f $option,$disk.Detail) }
Say '--- Not applicable to SSD wear ---' Cyan
if (!$excluded.Count) { Say 'None identified.' }
foreach ($disk in $excluded) { Say $disk.Detail }
$selected = @()
if ($choices.Count) {
    $prompt = 'Choose one listed number, P for GPU processes only, or Q to quit'
    if ($eligible.Count) { $prompt = 'Choose one listed number, A for all eligible SSDs [default], P for GPU only, or Q to quit' }
    while ($true) {
        $selection = (Read-Host $prompt).Trim()
        if ($selection -eq 'Q') { return }
        if ($selection -eq 'P') { break }
        if ($eligible.Count -and (!$selection -or $selection -eq 'A')) { $selected = $eligible; break }
        $index = 0
        if ([int]::TryParse($selection,[ref]$index) -and $index -ge 1 -and $index -le $choices.Count) {
            $selected = @($choices[$index - 1])
            if ($selected[0].Category -eq 'Unknown') { Say 'Selected device has unconfirmed SSD eligibility.' Yellow }
            break
        }
        Write-Host 'Enter one of the listed options.' -ForegroundColor Yellow
    }
}
if ($selected.Count) {
    foreach ($disk in $selected) { Say ("Selected: " + $disk.Label) }
} else { Say 'Test scope: GPU processes only.' }

$duration=30
$v=Read-Host 'Test duration in seconds [30, range 10-300]'
if($v){ $n=0; if([int]::TryParse($v,[ref]$n) -and $n -ge 10 -and $n -le 300){$duration=$n} }
$pattern='^(NVDisplay\.Container|nvcontainer|NVIDIA Share|NVIDIA Web Helper|nvsphelper64|NVIDIA App|AMDRSServ|AMDRSSrcExt|RadeonSoftware|atieclxx|atiesrxx|amdow|AMDSoftware|AMDExternalEvents|igfx.*|IntelGraphicsSoftware.*|IntelArcControl.*|ArcControl.*|GfxUI.*|IntelGraphicsCommandCenter.*|OneApp\.IGCC.*)\.exe$'
function Snapshot { $h=@{}; Get-CimInstance Win32_Process | Where-Object {$_.Name -match $pattern} | ForEach-Object { $key="$( $_.ProcessId ):$( $_.CreationDate )"; $h[$key]=$_ }; return $h }
function DiskSnapshot {
    $samples = @{}
    $ambiguous = @{}
    try {
        foreach ($counter in (Get-CimInstance Win32_PerfRawData_PerfDisk_PhysicalDisk)) {
            if ($counter.Name -notmatch '^([0-9]+)(?:\s|$)') { continue }
            $number = 0
            if (![int]::TryParse($Matches[1], [ref]$number) -or !$diskStats.ContainsKey($number)) { continue }
            if ($samples.ContainsKey($number)) { $ambiguous[$number] = $true }
            $samples[$number] = $counter
        }
    } catch { return @{} }
    foreach ($number in $ambiguous.Keys) { $samples.Remove($number) }
    return $samples
}
$diskStats = @{}
foreach ($disk in $selected) {
    if ($null -ne $disk.Number) {
        $diskStats[$disk.Number] = @{ Bytes=0.0; Seconds=0.0; Peak=0.0; Missing=0; Samples=0 }
    }
}
$prev = Snapshot
$dp = if ($diskStats.Count) { DiskSnapshot } else { @{} }
$stats=@{}; $changed=$false; $peak=0.0; $total=0.0; $elapsed=0.0
Say "Sampling for approximately $duration seconds. Close games and leave PC idle."
$clock=[Diagnostics.Stopwatch]::StartNew(); $last=0.0
while($clock.Elapsed.TotalSeconds -lt $duration){
 Start-Sleep -Seconds 1
 $cur=Snapshot; $now=$clock.Elapsed.TotalSeconds; $dt=$now-$last; $last=$now; $sum=0.0
 foreach($k in $cur.Keys){
  $p=$cur[$k]; if(!$stats.ContainsKey($k)){$stats[$k]=@{Name=$p.Name;PID=$p.ProcessId;Bytes=0.0;Peak=0.0;Lifetime=0.0;Age='Unknown'}}
  $r=$stats[$k]; $r.Lifetime=[double]$p.WriteTransferCount; if($p.CreationDate){$r.Age=((Get-Date)-$p.CreationDate).ToString('d\.hh\:mm\:ss')}
  if($prev.ContainsKey($k)){ $b=[double]$p.WriteTransferCount-[double]$prev[$k].WriteTransferCount; if($b -ge 0){$r.Bytes+=$b; $r.Peak=[math]::Max($r.Peak,$b/$dt); $sum+=$b}else{$changed=$true} }else{$changed=$true}
 }
 foreach($k in $prev.Keys){if(!$cur.ContainsKey($k)){$changed=$true}}
 $total+=$sum; $peak=[math]::Max($peak,$sum/$dt); $elapsed+=$dt; $prev=$cur
 if ($diskStats.Count) {
    $dc = DiskSnapshot
    foreach ($number in $diskStats.Keys) {
        $result = $diskStats[$number]
        $before = $dp[$number]
        $after = $dc[$number]
        if (!$before -or !$after -or $before.Name -ne $after.Name -or
            $null -eq $before.DiskWriteBytesPersec -or $null -eq $after.DiskWriteBytesPersec -or
            $after.Frequency_PerfTime -le 0 -or $after.Frequency_PerfTime -ne $before.Frequency_PerfTime -or
            $after.Timestamp_PerfTime -le $before.Timestamp_PerfTime -or
            $after.DiskWriteBytesPersec -lt $before.DiskWriteBytesPersec) {
            $result.Missing++
            continue
        }
        $seconds = [double]([decimal]$after.Timestamp_PerfTime - [decimal]$before.Timestamp_PerfTime) / $after.Frequency_PerfTime
        $bytes = [double]([decimal]$after.DiskWriteBytesPersec - [decimal]$before.DiskWriteBytesPersec)
        $result.Bytes += $bytes
        $result.Seconds += $seconds
        $result.Peak = [math]::Max($result.Peak, $bytes / $seconds)
        $result.Samples++
    }
    $dp = $dc
 }
 Write-Progress -Activity 'Sampling GPU process I/O and selected disks' -PercentComplete ([math]::Min(100,100*$elapsed/$duration))
}
Write-Progress -Activity 'Sampling GPU process I/O and selected disks' -Completed
Say '--- Global GPU process write I/O (all destinations) ---' Cyan
foreach($r in ($stats.Values | Sort-Object Bytes -Descending)){Say ('{0} PID {1} | Age {2} | Lifetime {3:N2} MiB | Avg {4:N2} KiB/s | Peak {5:N2} KiB/s | Test {6:N2} MiB' -f $r.Name,$r.PID,$r.Age,($r.Lifetime/1MB),($r.Bytes/$elapsed/1KB),($r.Peak/1KB),($r.Bytes/1MB))}
$avg=$total/$elapsed/1KB
Say ('Combined average: {0:N2} KiB/s | Peak: {1:N2} KiB/s | Projected: {2:N3} GiB/day | Test: {3:N2} MiB' -f $avg,($peak/1KB),($total/$elapsed*86400/1GB),($total/1MB))
if ($selected.Count) {
    Say '--- Selected physical disks (writes from all applications) ---' Cyan
    foreach ($disk in $selected) {
        $result = if ($null -ne $disk.Number) { $diskStats[$disk.Number] } else { $null }
        if (!$result -or !$result.Samples) {
            Say ("{0} | Write counters unavailable" -f $disk.Label) Yellow
            continue
        }
        Say ('{0} | {1:N2} MiB written | Avg {2:N2} KiB/s | Peak {3:N2} KiB/s | Covered {4:N1} s' -f
            $disk.Label,($result.Bytes/1MB),($result.Bytes/$result.Seconds/1KB),($result.Peak/1KB),$result.Seconds)
        if ($result.Missing) { Say ("Partial coverage: {0} sampling intervals unavailable." -f $result.Missing) Yellow }
    }
}
if (!$stats.Count) { Say 'No matching GPU background processes were observed.' Yellow }
if($avg -ge 500){Say 'RED - ATTENTION: High GPU process I/O. Investigate with Resource Monitor.' Red}
elseif($avg -ge 100 -or $changed -or !$stats.Count){Say 'YELLOW - WARNING: Elevated I/O or incomplete process coverage. Retest.' Yellow}
else{Say 'GREEN - PASS: No excessive I/O observed in monitored processes.' Green}
Say 'Status applies to observed GPU process I/O using heuristic thresholds. Disk totals include all applications and cannot attribute GPU writes or measure NAND wear.'
if($changed){Say 'Process changes detected; some writes may be missed.' Yellow}
if((Read-Host 'Save diagnostic report beside this script? [y/N]') -match '^y(es)?$'){ $out=Join-Path (Split-Path -Parent $env:GPU_CHECK_FILE) ('GPU-SSD-Report-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.txt'); $report | Set-Content -LiteralPath $out -Encoding UTF8; Write-Host 'Report saved beside script.' }
}catch{Write-Host ('YELLOW - INCONCLUSIVE: '+$_.Exception.Message) -ForegroundColor Yellow; exit 1}
