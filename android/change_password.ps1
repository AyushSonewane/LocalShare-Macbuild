# ─────────────────────────────────────────────────────────────────────────────
# LocalShare — Keystore Password Changer
#
# Safely changes the PKCS12 keystore password AND keeps key.properties in sync.
# Run from the project root: .\android\change_password.ps1
# ─────────────────────────────────────────────────────────────────────────────

$KeyPropsPath  = "$PSScriptRoot\key.properties"
$KeystorePath  = "$PSScriptRoot\app\localshare-release.jks"

# ── Read current password from key.properties ────────────────────────────────
$props = Get-Content $KeyPropsPath | Where-Object { $_ -match '=' } |
         ForEach-Object {
             $parts = $_ -split '=', 2
             @{ Key = $parts[0].Trim(); Value = $parts[1].Trim() }
         }
$currentPassword = ($props | Where-Object { $_.Key -eq 'storePassword' }).Value

if (-not $currentPassword) {
    Write-Error "Could not read storePassword from key.properties"
    exit 1
}

Write-Host ""
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  LocalShare Keystore Password Changer"    -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Keystore : $KeystorePath"
Write-Host "Current password read from key.properties."
Write-Host ""

# ── Prompt for new password ──────────────────────────────────────────────────
$newPass1 = Read-Host -Prompt "Enter NEW password" -AsSecureString
$newPass2 = Read-Host -Prompt "Confirm NEW password" -AsSecureString

$p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($newPass1))
$p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($newPass2))

if ($p1 -ne $p2) {
    Write-Host ""
    Write-Host "❌ Passwords do not match. No changes made." -ForegroundColor Red
    exit 1
}
if ($p1.Length -lt 6) {
    Write-Host ""
    Write-Host "❌ Password must be at least 6 characters." -ForegroundColor Red
    exit 1
}

# ── Change the keystore password ─────────────────────────────────────────────
Write-Host ""
Write-Host "Updating keystore password..." -ForegroundColor Yellow

$result = keytool -storepasswd `
    -keystore $KeystorePath `
    -storepass $currentPassword `
    -new $p1 2>&1

if ($LASTEXITCODE -ne 0 -and ($result -notmatch 'Warning')) {
    Write-Host ""
    Write-Host "❌ keytool failed:" -ForegroundColor Red
    Write-Host $result
    exit 1
}

Write-Host "✅ Keystore password updated." -ForegroundColor Green

# ── Update key.properties ─────────────────────────────────────────────────────
Write-Host "Updating key.properties..." -ForegroundColor Yellow

$content = Get-Content $KeyPropsPath
$content = $content -replace '^storePassword=.*', "storePassword=$p1"
$content = $content -replace '^keyPassword=.*',   "keyPassword=$p1"
Set-Content $KeyPropsPath $content -Encoding UTF8

Write-Host "✅ key.properties updated."   -ForegroundColor Green
Write-Host ""
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Done! New password is active."           -ForegroundColor Green
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Remember to keep your keystore file backed up!" -ForegroundColor Yellow
Write-Host "  Location: $KeystorePath"
Write-Host ""
