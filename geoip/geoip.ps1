<#
.SYNOPSIS
    Builds a GeoLite2-Country-CSV compatible zip for the OPNsense GeoIP alias feature.

.DESCRIPTION
    Version: 2.1.0

    Changelog:
        2.1.0  Output zip renamed to geoip.zip (inner CSV names unchanged, required by OPNsense).
        2.0.0  Data source replaced: IPLocate.io ip-to-country CSV instead of the five RIR
               statistics files. COPYRIGHT.txt (CC BY-SA 4.0 attribution) added to the zip.
               CSV files are streamed to disk instead of being held in memory.
        1.1.1  Added -o as a short alias of -OutputDirectory (same syntax as the bash version).
        1.1.0  Added -TestIp to look up the country of an IPv4 or IPv6 address in a generated zip.
        1.0.0  Initial version: builds the zip from RIR statistics.

    Downloads the free IPLocate.io "IP to Country" database
    (https://github.com/iplocate/ip-address-databases/tree/main/ip-to-country)
    and writes every IPv4/IPv6 network with its country code in the MaxMind
    GeoLite2-Country-CSV layout expected by OPNsense:

        GeoLite2-Country-CSV_YYYYMMDD/
            COPYRIGHT.txt
            GeoLite2-Country-Locations-en.csv
            GeoLite2-Country-Blocks-IPv4.csv
            GeoLite2-Country-Blocks-IPv6.csv

    No MaxMind data, account or service is used; the GeoLite2 file names are kept
    only because OPNsense expects them.

    Data license: IP address data powered by IPLocate.io (https://www.iplocate.io),
    licensed under CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/).

.PARAMETER OutputDirectory
    Build mode: folder where the zip file is written. Defaults to the script folder.
    Short alias: -o

.PARAMETER TestIp
    Lookup mode: IPv4 or IPv6 address to look up in an existing zip. No download is made.

.PARAMETER ZipPath
    Lookup mode: zip file to search. Defaults to geoip.zip in the script folder.

.EXAMPLE
    .\Build-OpnsenseGeoIpZip.ps1 -OutputDirectory C:\GeoIP

.EXAMPLE
    .\Build-OpnsenseGeoIpZip.ps1 -o C:\GeoIP

.EXAMPLE
    .\Build-OpnsenseGeoIpZip.ps1 -TestIp 8.8.8.8 -ZipPath C:\GeoIP\geoip.zip
#>

[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')]
    [Alias('o')]
    [string]$OutputDirectory = $PSScriptRoot,

    [Parameter(ParameterSetName = 'Lookup', Mandatory = $true)]
    [string]$TestIp,

    [Parameter(ParameterSetName = 'Lookup')]
    [string]$ZipPath = (Join-Path $PSScriptRoot 'geoip.zip')
)

$ErrorActionPreference = 'Stop'

# Required by Windows PowerShell 5.1 to reach HTTPS sources.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# IPLocate ip-to-country database (zip with one CSV: network,continent_code,country_code,country_name).
# The file is stored with Git LFS; this URL redirects to the real content.
$SourceUrl = 'https://github.com/iplocate/ip-address-databases/raw/main/ip-to-country/ip-to-country.csv.zip'

#region Helper functions

function Get-GeonameId {
    <# Returns a stable synthetic numeric id for a two letter country code. #>
    param([string]$CountryCode)
    return 1000000 + ([int][char]$CountryCode[0] - 65) * 26 + ([int][char]$CountryCode[1] - 65)
}

function Get-CountryName {
    param([string]$CountryCode)
    try {
        return ([System.Globalization.RegionInfo]::new($CountryCode)).EnglishName
    }
    catch {
        # Codes unknown to .NET (for example XK).
        return $CountryCode
    }
}

function Test-AddressInNetwork {
    <# Returns $true when the address bytes match the network bytes on the first PrefixLength bits. #>
    param([byte[]]$Address, [byte[]]$Network, [int]$PrefixLength)

    $fullBytes = [int][math]::Floor($PrefixLength / 8)
    for ($i = 0; $i -lt $fullBytes; $i++) {
        if ($Address[$i] -ne $Network[$i]) { return $false }
    }

    $remainingBits = $PrefixLength % 8
    if ($remainingBits -eq 0) { return $true }

    $mask = (0xFF -shl (8 - $remainingBits)) -band 0xFF
    return (($Address[$fullBytes] -band $mask) -eq ($Network[$fullBytes] -band $mask))
}

function Find-IpCountry {
    <# Looks up an IP address in a GeoLite2-Country-CSV zip and returns its country. #>
    param([string]$IpAddress, [string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Zip file not found: $Path. Run the script without -TestIp first to build it."
    }

    $parsedIp = [System.Net.IPAddress]::Parse($IpAddress)
    $addressBytes = $parsedIp.GetAddressBytes()
    $isIpv4 = $parsedIp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    $blocksSuffix = if ($isIpv4) { 'Blocks-IPv4.csv' } else { 'Blocks-IPv6.csv' }

    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Path))
    try {
        # Map geoname_id to country code and name.
        $locationEntry = $zip.Entries | Where-Object { $_.FullName.EndsWith('Locations-en.csv') } | Select-Object -First 1
        $reader = [System.IO.StreamReader]::new($locationEntry.Open())
        $countries = @{}
        foreach ($row in ($reader.ReadToEnd() | ConvertFrom-Csv)) {
            $countries[$row.geoname_id] = $row
        }
        $reader.Dispose()

        # Scan the blocks file of the matching address family.
        $blocksEntry = $zip.Entries | Where-Object { $_.FullName.EndsWith($blocksSuffix) } | Select-Object -First 1
        $reader = [System.IO.StreamReader]::new($blocksEntry.Open())
        try {
            [void]$reader.ReadLine()   # header
            $firstOctetPrefix = "$($addressBytes[0])."

            while ($null -ne ($line = $reader.ReadLine())) {
                $fields = $line.Split(',')
                $networkParts = $fields[0].Split('/')
                $prefixLength = [int]$networkParts[1]

                # Fast IPv4 pre-filter: a /8 or longer network must share the first octet.
                if ($isIpv4 -and $prefixLength -ge 8 -and -not $networkParts[0].StartsWith($firstOctetPrefix)) { continue }

                $networkBytes = [System.Net.IPAddress]::Parse($networkParts[0]).GetAddressBytes()
                if (Test-AddressInNetwork -Address $addressBytes -Network $networkBytes -PrefixLength $prefixLength) {
                    $country = $countries[$fields[1]]
                    return [PSCustomObject]@{
                        IpAddress   = $IpAddress
                        CountryCode = $country.country_iso_code
                        CountryName = $country.country_name
                        Network     = $fields[0]
                    }
                }
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $zip.Dispose()
    }

    return $null
}

#endregion

#region Lookup mode

if ($PSCmdlet.ParameterSetName -eq 'Lookup') {
    $result = Find-IpCountry -IpAddress $TestIp -Path $ZipPath
    if ($result) {
        $result | Format-List
    }
    else {
        Write-Warning "No country found for $TestIp (private, reserved or unassigned address)."
    }
    return
}

#endregion

#region Download

$dateStamp = Get-Date -Format 'yyyyMMdd'
$folderName = "GeoLite2-Country-CSV_$dateStamp"
$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "opnsense-geoip-$dateStamp"
$csvDirectory = Join-Path $workDirectory $folderName
$sourceZip = Join-Path $workDirectory 'ip-to-country.csv.zip'

if (Test-Path $workDirectory) { Remove-Item $workDirectory -Recurse -Force }
New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null

Write-Host "Downloading $SourceUrl"
# The progress bar slows Invoke-WebRequest down a lot in Windows PowerShell 5.1.
$previousProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
try {
    Invoke-WebRequest -Uri $SourceUrl -OutFile $sourceZip -UseBasicParsing
}
finally {
    $ProgressPreference = $previousProgress
}

#endregion

#region Convert to CSV files

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$blocksHeader = 'network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider,is_anycast'

$countries = [System.Collections.Generic.HashSet[string]]::new()
$ipv4Count = 0
$ipv6Count = 0
$skippedCount = 0

# Blocks are streamed directly to disk: the source holds more than two million networks.
$ipv4Writer = [System.IO.StreamWriter]::new((Join-Path $csvDirectory 'GeoLite2-Country-Blocks-IPv4.csv'), $false, $utf8NoBom)
$ipv6Writer = [System.IO.StreamWriter]::new((Join-Path $csvDirectory 'GeoLite2-Country-Blocks-IPv6.csv'), $false, $utf8NoBom)
$ipv4Writer.WriteLine($blocksHeader)
$ipv6Writer.WriteLine($blocksHeader)

$sourceArchive = [System.IO.Compression.ZipFile]::OpenRead($sourceZip)
try {
    $sourceEntry = $sourceArchive.Entries | Where-Object { $_.FullName.EndsWith('.csv') } | Select-Object -First 1
    if (-not $sourceEntry) { throw "No CSV file found in $SourceUrl" }

    $reader = [System.IO.StreamReader]::new($sourceEntry.Open())
    try {
        [void]$reader.ReadLine()   # source header

        # Line format: network,continent_code,country_code,country_name
        # Only the first three fields are used, so the quoted country names (which may
        # contain commas) do not need CSV parsing.
        while ($null -ne ($line = $reader.ReadLine())) {
            $fields = $line.Split(',', 4)
            if ($fields.Count -lt 3) { $skippedCount++; continue }

            $network = $fields[0]
            $countryCode = $fields[2].ToUpperInvariant()
            if ($countryCode -notmatch '^[A-Z]{2}$' -or -not $network.Contains('/')) { $skippedCount++; continue }

            $geonameId = Get-GeonameId $countryCode
            [void]$countries.Add($countryCode)

            if ($network.Contains(':')) {
                $ipv6Writer.WriteLine("$network,$geonameId,$geonameId,,0,0,0")
                $ipv6Count++
            }
            else {
                $ipv4Writer.WriteLine("$network,$geonameId,$geonameId,,0,0,0")
                $ipv4Count++
            }
        }
    }
    finally {
        $reader.Dispose()
    }
}
finally {
    $sourceArchive.Dispose()
    $ipv4Writer.Dispose()
    $ipv6Writer.Dispose()
}

# Locations file: maps geoname_id to country ISO code (continent and EU fields are not used by OPNsense).
$locationLines = [System.Collections.Generic.List[string]]::new()
$locationLines.Add('geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union')
foreach ($countryCode in ($countries | Sort-Object)) {
    $name = (Get-CountryName $countryCode).Replace('"', '""')
    $locationLines.Add("$(Get-GeonameId $countryCode),en,,,$countryCode,`"$name`",0")
}
[System.IO.File]::WriteAllLines((Join-Path $csvDirectory 'GeoLite2-Country-Locations-en.csv'), $locationLines, $utf8NoBom)

# Attribution required by the CC BY-SA 4.0 license of the IPLocate data.
$copyrightText = @"
IP address data powered by IPLocate.io (https://www.iplocate.io)

Source : $SourceUrl
License: Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)
         https://creativecommons.org/licenses/by-sa/4.0/
Built  : $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))

This file set was converted to the GeoLite2-Country-CSV layout for OPNsense GeoIP aliases.
It contains no MaxMind data; the GeoLite2 file names only describe the layout.
"@
[System.IO.File]::WriteAllText((Join-Path $csvDirectory 'COPYRIGHT.txt'), $copyrightText, $utf8NoBom)

#endregion

#region Build zip

# ZipArchive is used instead of Compress-Archive, because Windows PowerShell 5.1
# writes backslashes in entry names, which non Windows systems such as OPNsense misread.
if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$zipPath = Join-Path (Resolve-Path $OutputDirectory) 'geoip.zip'
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem $csvDirectory -File) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, "$folderName/$($file.Name)")
    }
}
finally {
    $zip.Dispose()
}

Remove-Item $workDirectory -Recurse -Force

#endregion

Write-Host ''
Write-Host "Countries     : $($countries.Count)"
Write-Host "IPv4 networks : $ipv4Count"
Write-Host "IPv6 networks : $ipv6Count"
Write-Host "Skipped lines : $skippedCount"
Write-Host "Zip created   : $zipPath"
