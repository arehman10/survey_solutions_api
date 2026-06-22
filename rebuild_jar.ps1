# rebuild_jar.ps1 - reconstruct suso.jar from suso_jar_base64.txt on Windows.
#   Expected:  size = 33325 bytes   sha256 = 9763F8E2689A0B38D4023429698A787AD9457C3820D1E61F687C28EDCAF0AEED
$ErrorActionPreference = "Stop"
$b64 = Get-Content -Raw ".\suso_jar_base64.txt"
[IO.File]::WriteAllBytes(".\suso.jar", [Convert]::FromBase64String($b64.Trim()))
$sz = (Get-Item ".\suso.jar").Length
$sha = (Get-FileHash ".\suso.jar" -Algorithm SHA256).Hash
Write-Host "Wrote suso.jar: $sz bytes, sha256 $sha"
if ($sz -ne 33325) { Write-Warning "size mismatch (expected 33325)" }
elseif ($sha -ne "9763F8E2689A0B38D4023429698A787AD9457C3820D1E61F687C28EDCAF0AEED") { Write-Warning "sha256 mismatch (expected 9763F8E2689A0B38D4023429698A787AD9457C3820D1E61F687C28EDCAF0AEED)" }
else { Write-Host "Integrity OK." }
