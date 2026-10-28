#requires -Version 5.1
# Check the packaged PRI, not just the PNG files copied to the package.
param(
    [Parameter(Mandatory)] [string] $PackagePath,
    [Parameter(Mandatory)] [string] $MakePri,
    [Parameter(Mandatory)] [string] $ExpectedIdentity
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path ([IO.Path]::GetTempPath()) ("nearclip-pri-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory $work | Out-Null
$zip = [IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
    $pri = $zip.GetEntry("resources.pri")
    if (-not $pri) { throw "resources.pri missing from $PackagePath" }
    $inputPath = Join-Path $work "resources.pri"
    $dumpPath = Join-Path $work "resources.xml"
    [IO.Compression.ZipFileExtensions]::ExtractToFile($pri, $inputPath)
    & $MakePri dump /if $inputPath /of $dumpPath /o | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "makepri dump failed for $PackagePath" }
    $index = New-Object System.Xml.XmlDocument
    $index.Load($dumpPath)
    $map = $index.SelectSingleNode("/PriInfo/ResourceMap[@primary='true']")
    if (-not $map -or $map.GetAttribute("name") -ne $ExpectedIdentity) { throw "PRI identity does not match $ExpectedIdentity" }
    foreach ($name in @("StoreLogo", "Square44x44Logo", "Square150x150Logo", "SmallTile", "LargeTile", "Wide310x150Logo")) {
        $resource = $map.SelectSingleNode("ResourceMapSubtree[@name='Files']/ResourceMapSubtree[@name='Images']/NamedResource[@name='$name.png']")
        if (-not $resource) { throw "Images\$name.png is absent from the packaged PRI" }
        $candidates = @($resource.SelectNodes("Candidate[@type='Path']/Value"))
        if ($candidates.Count -eq 0) { throw "Images\$name.png has no packaged image candidates" }
        foreach ($value in $candidates) {
            $entry = $value.InnerText.Replace('\', '/')
            if (-not $zip.GetEntry($entry)) { throw "PRI references missing image: $entry" }
        }
    }
    Write-Host "Validated PRI identity and all manifest logo candidates: $PackagePath"
} finally {
    $zip.Dispose()
    Remove-Item -LiteralPath $work -Recurse -Force
}
