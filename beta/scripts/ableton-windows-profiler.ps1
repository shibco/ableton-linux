# Collects a short, redacted system summary and copies it to the clipboard
# for pasting into a GitHub issue. 

$ErrorActionPreference = "SilentlyContinue"
$lines = [System.Collections.Generic.List[string]]::new()

function Header([string]$Name) {
    $lines.Add("")
    $lines.Add("[$Name]")
}

function Redact([AllowEmptyString()][string]$Text) {
    if ($Text -match '(?i)^\s*[^:=]*(serial|uuid|udid|wwn|guid|unique[ _-]?id|asset[ _-]?tag|processorid|identifyingnumber|instanceid|pnpdeviceid|address|location[ _-]?id|mount[ _-]?point|device[ _-]?identifier)[^:=]*[:=]') {
        return ""
    }
    foreach ($value in @($env:USERPROFILE, $env:HOME)) {
        if ($value -and [System.IO.Path]::IsPathRooted($value)) {
            $Text = $Text -replace [regex]::Escape($value), "<HOME>"
        }
    }
    $Text = $Text -replace '(?i)C:\\Users\\[^\\\s]+', 'C:\Users\<USER>'
    $Text = $Text -replace '(?i)\b[0-9a-f]{2}(?:[:-][0-9a-f]{2}){5}\b', '<MAC>'
    $Text = $Text -replace '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '<EMAIL>'
    $Text = $Text -replace '(?i)\b(password|passwd|token|secret|api[ _-]?key|machineguid|unlock\.json|ableton[ _-]?(?:serial|licen[cs]e)|licen[cs]e[ _-]?key)\b[^\r\n]*', '$1=<REDACTED>'
    return $Text
}

function Write-Text {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $Value
    )
    process {
        ($Value | Out-String -Width 200) -split "`r?`n" |
            ForEach-Object { (Redact $_).TrimEnd() } |
            Where-Object { $_ -ne "" } |
            ForEach-Object { $lines.Add($_) }
    }
}

$lines.Add("ableton-linux system summary (Windows)")

Header "SYSTEM"
Get-CimInstance Win32_OperatingSystem |
    Select-Object Caption,Version,BuildNumber,OSArchitecture |
    Write-Text
Get-CimInstance Win32_Processor |
    Select-Object Name,NumberOfCores,NumberOfLogicalProcessors |
    Write-Text
Get-CimInstance Win32_ComputerSystem |
    Select-Object Manufacturer,Model,@{n="RAM_GB";e={[math]::Round($_.TotalPhysicalMemory / 1GB, 1)}} |
    Write-Text

Header "DISPLAY"
Get-CimInstance Win32_VideoController |
    Select-Object Name,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution |
    Write-Text

Header "AUDIO"
Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.PNPClass -in @("MEDIA", "AudioEndpoint") } |
    Select-Object Status,PNPClass,Manufacturer,Description |
    Sort-Object PNPClass,Manufacturer,Description -Unique |
    Write-Text

Header "MIDI"
Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.Name -match "(?i)midi|controller|push|keyboard" } |
    Select-Object Status,PNPClass,Manufacturer,Description |
    Sort-Object Manufacturer,Description -Unique |
    Write-Text

Header "ABLETON"
$abletonInstalls = Join-Path $env:ProgramData "Ableton"
if (Test-Path $abletonInstalls) {
    Get-ChildItem $abletonInstalls -Recurse -File -Include "*.exe" |
        Select-Object Name,@{n="Version";e={$_.VersionInfo.FileVersion}} |
        Sort-Object Name,Version -Unique |
        Write-Text
}

$report = $lines -join "`r`n"
$fence = '```'
Write-Output $report
Write-Output ""
if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
    Set-Clipboard -Value "$fence`r`n$report`r`n$fence"
    Write-Output "Copied to your clipboard. Review the summary above, then paste it into your GitHub issue."
} else {
    Write-Output "Set-Clipboard is unavailable. Copy the summary above into your GitHub issue."
}
