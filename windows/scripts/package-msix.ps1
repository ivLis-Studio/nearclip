#requires -Version 5.1
<#
  Builds the Microsoft Store (MSIX) edition of Nearclip: one package per architecture and the bundle Partner Center takes.
    scripts\package-msix.ps1 -Version 1.1.0                          # x64 and Arm64 into artifacts\store
    scripts\package-msix.ps1 -Version 1.1.0 -TestCertificate         # ...plus test-signed copies to sideload in a VM

  Each package is the GitHub build of the app (self-contained, nctailnet.dll included) published with -p:NearclipStore=true,
  which packs it with packaging\Package.appxmanifest and packaging\Images (single-project MSIX: the build merges the app's
  resources and the logos into one resources.pri). Nearclip.exe tells the Store edition apart at run time by its package
  identity (src\Nearclip.App\Platform\PackageInfo.cs).

  Output, in -OutDir (default artifacts\store):
    Nearclip-<version>.msixbundle      unsigned: the Partner Center upload (the Store signs it)
    Nearclip-<version>-<arch>.msix     unsigned, one per architecture
    test-signed\                       -TestCertificate: the same, signed with a throwaway self-signed certificate whose
                                       subject is the Store publisher, and Nearclip-<version>-test.cer to trust first
                                       (Local Machine > Trusted People) - for a test PC, never for the Store

  Needs Windows with the .NET 10 SDK, and native\win-<arch>\nctailnet.dll (tailnet/build.sh windows on a Mac). makeappx and
  signtool come from the Microsoft.Windows.SDK.BuildTools NuGet package the app already restores (or an installed Windows SDK).
#>
param(
    [Parameter(Mandatory)] [string] $Version,
    [ValidateSet("x64", "arm64")] [string[]] $Arch = @("x64", "arm64"),
    [switch] $TestCertificate,
    [string] $OutDir = "artifacts\store"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Root = Split-Path -Parent $PSScriptRoot
$Manifest = Join-Path $Root "packaging\Package.appxmanifest"
$Project = Join-Path $Root "src\Nearclip.App\Nearclip.App.csproj"

if ($Version.Trim().TrimStart("v") -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "-Version must look like 1.2.3, not '$Version'" }
$Version = $Version.Trim().TrimStart("v")
$PackageVersion = "$Version.0"

# The manifest carries the package identity; its version must match (the Store wants the fourth number to be 0).
[xml]$xml = Get-Content -LiteralPath $Manifest -Raw
$identity = $xml.Package.Identity
if ($identity.Version -ne $PackageVersion) { throw "packaging\Package.appxmanifest has Version $($identity.Version); set it to $PackageVersion first" }
$Publisher = $identity.Publisher
Write-Host ("> {0} {1} ({2})" -f $identity.Name, $PackageVersion, $Publisher)

function Find-Tool([string] $name) {
    $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { @("arm64", "x64", "x86") } else { @("x64", "x86") }
    $roots = @()
    $nuget = Join-Path $env:USERPROFILE ".nuget\packages\microsoft.windows.sdk.buildtools"
    if (Test-Path -LiteralPath $nuget) { $roots += Get-ChildItem -LiteralPath $nuget -Directory | Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } -Descending | ForEach-Object { Join-Path $_.FullName "bin" } }
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) { if ($pf) { $roots += Join-Path $pf "Windows Kits\10\bin" } }
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($sdk in (Get-ChildItem -LiteralPath $r -Directory | Where-Object { $_.Name -match '^10\.0\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)) {
            foreach ($a in $hostArch) {
                $p = Join-Path $sdk.FullName "$a\$name"
                if (Test-Path -LiteralPath $p) { return $p }
            }
        }
    }
    throw "$name not found (restore the app once so the Microsoft.Windows.SDK.BuildTools package is in the NuGet cache, or install the Windows SDK)"
}
function Invoke-Tool([string] $Tool, [string[]] $Arguments, [string] $Secret = "") {
    $shown = ($Arguments -join " ")
    if ($Secret) { $shown = $shown.Replace($Secret, "***") }
    Write-Host ("  {0} {1}" -f (Split-Path $Tool -Leaf), $shown)
    & $Tool @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$(Split-Path $Tool -Leaf) failed with exit code $LASTEXITCODE" }
}

$OutDir = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $OutDir))
$Work = Join-Path $OutDir "work-$Version"
$Packages = Join-Path $Work "packages"
$Bundle = Join-Path $OutDir "Nearclip-$Version.msixbundle"
$TestDir = Join-Path $OutDir "test-signed"
foreach ($path in @($Work, $Bundle, $TestDir)) { if (Test-Path -LiteralPath $path) { throw "$path already exists - move it away first" } }
New-Item -ItemType Directory -Path $Packages -Force | Out-Null

foreach ($a in $Arch) {
    $platform = if ($a -eq "arm64") { "ARM64" } else { "x64" }
    if (-not (Test-Path -LiteralPath (Join-Path $Root "native\win-$a\nctailnet.dll"))) { throw "native\win-$a\nctailnet.dll is missing (tailnet/build.sh windows)" }
    Write-Host "> win-$a"
    $appx = Join-Path $Work "appx-$a\"
    # An unpackaged publish uses the same intermediate directory but omits the Store logos from its PRI.
    # Reusing that index produces an otherwise valid MSIX whose manifest images fail Store validation.
    & dotnet clean $Project -c Release "-p:Platform=$platform" -r "win-$a" -p:NearclipStore=true -v:minimal | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "clean win-$a failed with exit code $LASTEXITCODE" }
    & dotnet publish $Project -c Release "-p:Platform=$platform" -r "win-$a" -p:NearclipStore=true "-p:Version=$Version" "-p:AppxPackageDir=$appx" -v:minimal | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish win-$a failed with exit code $LASTEXITCODE" }
    $msix = @(Get-ChildItem -LiteralPath $appx -Recurse -Filter *.msix | Sort-Object LastWriteTime -Descending)
    if ($msix.Count -eq 0) { throw "the Store build for win-$a made no .msix in $appx" }
    & (Join-Path $PSScriptRoot "validate-msix-resources.ps1") -PackagePath $msix[0].FullName -MakePri (Find-Tool "makepri.exe") -ExpectedIdentity $identity.Name
    $target = Join-Path $Packages "Nearclip-$Version-$a.msix"
    Copy-Item -LiteralPath $msix[0].FullName -Destination $target
    Copy-Item -LiteralPath $target -Destination $OutDir
}

$MakeAppx = Find-Tool "makeappx.exe"
Write-Host "> bundle"
Invoke-Tool $MakeAppx @("bundle", "/d", $Packages, "/p", $Bundle, "/bv", $PackageVersion, "/o")

if ($TestCertificate) {
    # Copies signed with a throwaway certificate whose subject is the Store publisher (Windows only installs signed
    # packages). Made in memory; the private key only exists in work\ while signing.
    $SignTool = Find-Tool "signtool.exe"
    Write-Host "> test-signed copies"
    $signed = Join-Path $Work "packages-test"
    New-Item -ItemType Directory -Path $signed, $TestDir -Force | Out-Null
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $request = New-Object Security.Cryptography.X509Certificates.CertificateRequest($Publisher, $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add((New-Object Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($false, $false, 0, $true)))
    $request.CertificateExtensions.Add((New-Object Security.Cryptography.X509Certificates.X509KeyUsageExtension([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true)))
    $usages = New-Object Security.Cryptography.OidCollection
    [void]$usages.Add((New-Object Security.Cryptography.Oid("1.3.6.1.5.5.7.3.3", "Code Signing")))
    $request.CertificateExtensions.Add((New-Object Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($usages, $false)))
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(90))
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $password = [Convert]::ToBase64String($bytes)
    $pfx = Join-Path $Work "test-signing.pfx"
    [IO.File]::WriteAllBytes($pfx, $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password))
    try {
        foreach ($a in $Arch) {
            $copy = Join-Path $signed "Nearclip-$Version-$a.msix"
            Copy-Item -LiteralPath (Join-Path $Packages "Nearclip-$Version-$a.msix") -Destination $copy
            Invoke-Tool $SignTool @("sign", "/fd", "SHA256", "/f", $pfx, "/p", $password, $copy) -Secret $password
            Copy-Item -LiteralPath $copy -Destination $TestDir
        }
        $testBundle = Join-Path $TestDir "Nearclip-$Version.msixbundle"
        Invoke-Tool $MakeAppx @("bundle", "/d", $signed, "/p", $testBundle, "/bv", $PackageVersion, "/o")
        Invoke-Tool $SignTool @("sign", "/fd", "SHA256", "/f", $pfx, "/p", $password, $testBundle) -Secret $password
        [IO.File]::WriteAllBytes((Join-Path $TestDir "Nearclip-$Version-test.cer"), $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    }
    finally {
        Remove-Item -LiteralPath $pfx -Force -ErrorAction SilentlyContinue
        $certificate.Dispose()
        $rsa.Dispose()
    }
}

Write-Host "done: $OutDir"
Get-ChildItem -LiteralPath $OutDir -File -Recurse | Where-Object { $_.FullName -notlike "$Work*" } | ForEach-Object {
    Write-Host ("  {0,-56} {1,8:N1} MB" -f $_.FullName.Substring($OutDir.Length + 1), ($_.Length / 1MB))
}
Write-Host "  Partner Center > Packages: upload Nearclip-$Version.msixbundle (unsigned; the Store signs it)."

