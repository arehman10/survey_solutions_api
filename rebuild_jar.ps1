# Recover the packaged JAR. Decode and verify before replacing a working copy.
$ErrorActionPreference = "Stop"
$payload = Join-Path $PSScriptRoot "suso_jar_base64.txt"
$checksum = Join-Path $PSScriptRoot "suso.jar.sha256"
$target = Join-Path $PSScriptRoot "suso.jar"
$expected = ((Get-Content -Raw $checksum).Trim() -split '\s+')[0].ToLowerInvariant()
if ($expected -notmatch '^[0-9a-f]{64}$') { throw "Invalid suso.jar.sha256 checksum." }
$bytes = [Convert]::FromBase64String((Get-Content -Raw $payload).Trim())
$algorithm = [Security.Cryptography.SHA256]::Create()
try {
    $actual = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
} finally { $algorithm.Dispose() }
if ($actual -ne $expected) { throw "Recovery payload checksum mismatch. The existing suso.jar was not changed." }
$temp = Join-Path $PSScriptRoot (".suso-recovery-" + [Guid]::NewGuid().ToString('N') + ".tmp")
try {
    [IO.File]::WriteAllBytes($temp, $bytes)
    if ([IO.File]::Exists($target)) {
        # Same-directory File.Replace is atomic. Fail safely if unsupported.
        [IO.File]::Replace($temp, $target, $null)
    } else {
        [IO.File]::Move($temp, $target)
    }
    Write-Host "Recovered suso.jar: $($bytes.Length) bytes, SHA256 $actual"
} finally {
    if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
}
