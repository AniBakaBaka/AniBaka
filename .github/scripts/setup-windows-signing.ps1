if ([string]::IsNullOrWhiteSpace($env:WINDOWS_CERTIFICATE_BASE64)) {
  throw "WINDOWS_CERTIFICATE_BASE64 secret is required."
}

$certificatePath = Join-Path $env:RUNNER_TEMP 'anibaka-windows-signing.pfx'
[IO.File]::WriteAllBytes(
  $certificatePath,
  [Convert]::FromBase64String($env:WINDOWS_CERTIFICATE_BASE64)
)
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
  $certificatePath,
  $env:WINDOWS_CERTIFICATE_PASSWORD,
  [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
)
if (-not $certificate.HasPrivateKey) {
  throw 'The configured Windows PFX does not contain a private key.'
}

$codeSigningEku = '1.3.6.1.5.5.7.3.3'
$ekuExtension = $certificate.Extensions |
  Where-Object { $_.Oid.Value -eq '2.5.29.37' } |
  Select-Object -First 1
if ($null -ne $ekuExtension -and
    $ekuExtension.EnhancedKeyUsages.Value -notcontains $codeSigningEku) {
  throw 'The configured Windows certificate is not valid for code signing.'
}

$configPath = 'windows/packaging/msix/make_config.yaml'
$config = Get-Content -Raw -Encoding utf8 -LiteralPath $configPath
$config = $config -replace '(?m)^certificate_path:.*\r?\n?', ''
$config = $config -replace '(?m)^certificate_password:.*\r?\n?', ''
$publisher = $certificate.Subject.Replace("'", "''")
$certificateYamlPath = $certificatePath.Replace('\', '/').Replace("'", "''")
$certificatePassword = $env:WINDOWS_CERTIFICATE_PASSWORD.Replace("'", "''")
$config = $config -replace '(?m)^publisher:\s*.*$', "publisher: '$publisher'"
$config += @"

certificate_path: '$certificateYamlPath'
certificate_password: '$certificatePassword'
"@
Set-Content -Encoding utf8 -NoNewline -LiteralPath $configPath -Value $config

$fingerprint = $certificate.GetCertHashString('SHA256')
$publicCertificatePath = Join-Path $env:RUNNER_TEMP 'anibaka-windows-signing.cer'
[IO.File]::WriteAllBytes(
  $publicCertificatePath,
  $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert)
)

"certificate_path=$certificatePath" >> $env:GITHUB_OUTPUT
"public_certificate_path=$publicCertificatePath" >> $env:GITHUB_OUTPUT
"fingerprint=$fingerprint" >> $env:GITHUB_OUTPUT
"Windows fixed signing: enabled (`$fingerprint`, `$($certificate.Subject)`)." >> $env:GITHUB_STEP_SUMMARY
