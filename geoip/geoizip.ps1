<#
.SYNOPSIS
    Builds a GeoLite2-Country-CSV compatible zip for the OPNsense GeoIP alias feature.

.DESCRIPTION
    Version: 1.1.1

    Changelog:
        1.1.1  Added -o as a short alias of -OutputDirectory (same syntax as the bash version).
        1.1.0  Added -TestIp to look up the country of an IPv4 or IPv6 address in a generated zip.
        1.0.0  Initial version: builds the zip from RIR statistics.

    Downloads the public "delegated extended" statistics files of the five Regional
    Internet Registries (ARIN, RIPE NCC, APNIC, LACNIC, AFRINIC), extracts every
    allocated or assigned IPv4/IPv6 block with its country code, and writes them
    in the MaxMind GeoLite2-Country-CSV layout expected by OPNsense:

        GeoLite2-Country-CSV_YYYYMMDD/
            GeoLite2-Country-Locations-en.csv
            GeoLite2-Country-Blocks-IPv4.csv
            GeoLite2-Country-Blocks-IPv6.csv

    The RIR data is free and requires no account. Note that it reflects the country
    where a block is registered, not the physical location of each host.

.PARAMETER OutputDirectory
    Build mode: folder where the zip file is written. Defaults to the script folder.
    Short alias: -o

.PARAMETER TestIp
    Lookup mode: IPv4 or IPv6 address to look up in an existing zip. No download is made.

.PARAMETER ZipPath
    Lookup mode: zip file to search. Defaults to GeoLite2-Country-CSV.zip in the script folder.

.EXAMPLE
    .\Build-OpnsenseGeoIpZip.ps1 -OutputDirectory C:\GeoIP

.EXAMPLE
    .\Build-OpnsenseGeoIpZip.ps1 -o C:\GeoIP

.EXAMPLE
    .\Build-OpnsenseGeoIpZip.ps1 -TestIp 8.8.8.8 -ZipPath C:\GeoIP\GeoLite2-Country-CSV.zip
#>

[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')]
    [Alias('o')]
    [string]$OutputDirectory = $PSScriptRoot,

    [Parameter(ParameterSetName = 'Lookup', Mandatory = $true)]
    [string]$TestIp,

    [Parameter(ParameterSetName = 'Lookup')]
    [string]$ZipPath = (Join-Path $PSScriptRoot 'GeoLite2-Country-CSV.zip')
)

$ErrorActionPreference = 'Stop'

# Required by Windows PowerShell 5.1 to reach HTTPS sources.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Public RIR statistics sources.
$RirSources = @(
    'https://ftp.arin.net/pub/stats/arin/delegated-arin-extended-latest'
    'https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest'
    'https://ftp.apnic.net/stats/apnic/delegated-apnic-extended-latest'
    'https://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-extended-latest'
    'https://ftp.afrinic.net/pub/stats/afrinic/delegated-afrinic-extended-latest'
)

#region Helper functions

function ConvertTo-UInt64FromIpv4 {
    param([string]$Address)
    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    return ([uint64]$bytes[0] -shl 24) + ([uint64]$bytes[1] -shl 16) + ([uint64]$bytes[2] -shl 8) + [uint64]$bytes[3]
}

function ConvertTo-Ipv4String {
    param([uint64]$Value)
    return '{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 255), (($Value -shr 16) -band 255), (($Value -shr 8) -band 255), ($Value -band 255)
}

function Get-Ipv4Cidrs {
    <# Splits an IPv4 range (start address + host count) into the minimal list of CIDR blocks. #>
    param([string]$StartAddress, [uint64]$Count)

    $current = ConvertTo-UInt64FromIpv4 $StartAddress
    $end = $current + $Count   # exclusive upper bound

    while ($current -lt $end) {
        # Grow the block while it stays aligned on $current and inside the range.
        $bits = 0
        $size = [uint64]1
        while ($bits -lt 32 -and ($current % ($size * 2)) -eq 0 -and ($current + $size * 2) -le $end) {
            $size *= 2
            $bits++
        }
        '{0}/{1}' -f (ConvertTo-Ipv4String $current), (32 - $bits)
        $current += $size
    }
}

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
        # Codes unknown to .NET (for example EU or AP used by some RIRs).
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

#region Download and parse

$dateStamp = Get-Date -Format 'yyyyMMdd'
$folderName = "GeoLite2-Country-CSV_$dateStamp"
$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "opnsense-geoip-$dateStamp"
$csvDirectory = Join-Path $workDirectory $folderName

if (Test-Path $workDirectory) { Remove-Item $workDirectory -Recurse -Force }
New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null

$ipv4Blocks = [System.Collections.Generic.List[string]]::new()
$ipv6Blocks = [System.Collections.Generic.List[string]]::new()
$countries = [System.Collections.Generic.HashSet[string]]::new()

foreach ($url in $RirSources) {
    $rawFile = Join-Path $workDirectory ([System.IO.Path]::GetFileName($url))
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $rawFile -UseBasicParsing

    # Line format: registry|cc|type|start|value|date|status[|extensions]
    foreach ($line in [System.IO.File]::ReadLines($rawFile)) {
        if ($line.StartsWith('#')) { continue }

        $fields = $line.Split('|')
        if ($fields.Count -lt 7) { continue }   # version and summary lines

        $countryCode = $fields[1].ToUpperInvariant()
        $type = $fields[2]
        $status = $fields[6]

        if ($countryCode -notmatch '^[A-Z]{2}$') { continue }
        if ($status -ne 'allocated' -and $status -ne 'assigned') { continue }

        $geonameId = Get-GeonameId $countryCode

        switch ($type) {
            'ipv4' {
                foreach ($cidr in Get-Ipv4Cidrs -StartAddress $fields[3] -Count ([uint64]$fields[4])) {
                    $ipv4Blocks.Add("$cidr,$geonameId,$geonameId,,0,0,0")
                }
                [void]$countries.Add($countryCode)
            }
            'ipv6' {
                # For IPv6 the value field is already the prefix length.
                $ipv6Blocks.Add("$($fields[3])/$($fields[4]),$geonameId,$geonameId,,0,0,0")
                [void]$countries.Add($countryCode)
            }
        }
    }
}

#endregion

#region Write CSV files

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$blocksHeader = 'network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider,is_anycast'

# Locations file: maps geoname_id to country ISO code (continent and EU fields are not used by OPNsense).
$locationLines = [System.Collections.Generic.List[string]]::new()
$locationLines.Add('geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union')
foreach ($countryCode in ($countries | Sort-Object)) {
    $name = (Get-CountryName $countryCode).Replace('"', '""')
    $locationLines.Add("$(Get-GeonameId $countryCode),en,,,$countryCode,`"$name`",0")
}

[System.IO.File]::WriteAllLines((Join-Path $csvDirectory 'GeoLite2-Country-Locations-en.csv'), $locationLines, $utf8NoBom)
[System.IO.File]::WriteAllLines((Join-Path $csvDirectory 'GeoLite2-Country-Blocks-IPv4.csv'), [string[]](@($blocksHeader) + $ipv4Blocks), $utf8NoBom)
[System.IO.File]::WriteAllLines((Join-Path $csvDirectory 'GeoLite2-Country-Blocks-IPv6.csv'), [string[]](@($blocksHeader) + $ipv6Blocks), $utf8NoBom)

#endregion

#region Build zip

# ZipArchive is used instead of Compress-Archive, because Windows PowerShell 5.1
# writes backslashes in entry names, which non Windows systems such as OPNsense misread.
if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$zipPath = Join-Path (Resolve-Path $OutputDirectory) 'GeoLite2-Country-CSV.zip'
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
Write-Host "Countries   : $($countries.Count)"
Write-Host "IPv4 blocks : $($ipv4Blocks.Count)"
Write-Host "IPv6 blocks : $($ipv6Blocks.Count)"
Write-Host "Zip created : $zipPath"
