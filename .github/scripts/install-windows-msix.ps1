$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$isAdministrator = [Security.Principal.WindowsPrincipal]::new(
  [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdministrator) {
  $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', ('"{0}"' -f $PSCommandPath)
  )
  exit $process.ExitCode
}

$packages = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'baka-*-windows-x64.msix' -File)
$certificates = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'baka-*-windows-certificate.cer' -File)
if ($packages.Count -ne 1 -or $certificates.Count -ne 1) {
  throw 'Keep exactly one baka Windows MSIX and its certificate in the same folder as this installer.'
}

$package = $packages[0]
$certificateFile = $certificates[0]
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateFile.FullName)
$signature = Get-AuthenticodeSignature -LiteralPath $package.FullName
if ($null -eq $signature.SignerCertificate) {
  throw "The MSIX package is not signed: $($package.Name)"
}
if ($signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
  throw 'The supplied certificate does not match the MSIX package signature.'
}

Import-Certificate `
  -FilePath $certificateFile.FullName `
  -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null

$signature = Get-AuthenticodeSignature -LiteralPath $package.FullName
if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
  throw "The MSIX signature is still not trusted after importing the certificate: $($signature.Status)"
}

Add-AppxPackage -Path $package.FullName
Write-Host "Installed $($package.Name) successfully."
