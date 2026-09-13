param(
  [string]$EasyLocatePath = ""
)

$ErrorActionPreference = "Stop"
$ProjectRef = "tijiamrfnxrbitafiflj"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

if (-not $EasyLocatePath) {
  $WorkspaceRoot = Split-Path -Parent $ProjectRoot
  $EasyLocatePath = Join-Path $WorkspaceRoot "Easy Locate"
}

$Candidates = @(
  (Join-Path $EasyLocatePath ".env.local"),
  (Join-Path $EasyLocatePath ".env.production.local"),
  (Join-Path $EasyLocatePath ".env")
)

$EnvFile = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $EnvFile) {
  throw "Could not find an Easy Locate .env file under '$EasyLocatePath'. Pass -EasyLocatePath if the project lives somewhere else."
}

$Values = @{}
Get-Content $EnvFile | ForEach-Object {
  $line = $_.Trim()
  if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) { return }
  $parts = $line.Split("=", 2)
  $name = $parts[0].Trim()
  $value = $parts[1].Trim().Trim('"').Trim("'")
  $Values[$name] = $value
}

$EasyUrl = $Values["VITE_SUPABASE_URL"]
if (-not $EasyUrl) { $EasyUrl = "https://ngvlalawiiziisznjdwm.supabase.co" }

$EasyKey = $Values["VITE_SUPABASE_PUBLISHABLE_KEY"]
if (-not $EasyKey) { $EasyKey = $Values["VITE_SUPABASE_ANON_KEY"] }
if (-not $EasyKey) { $EasyKey = $Values["SUPABASE_PUBLISHABLE_KEY"] }
if (-not $EasyKey) { $EasyKey = $Values["SUPABASE_ANON_KEY"] }

if (-not $EasyKey) {
  throw "Easy Locate publishable/anon key was not found in $EnvFile. Add the public frontend key there first; never use the service-role key for this connector."
}

Write-Host "Configuring XOS Staging Easy Locate connector from the local Easy Locate frontend environment..."
Write-Host "Source: $EnvFile"
Write-Host "The publishable key value will not be printed."

& supabase secrets set `
  "EASY_LOCATE_SUPABASE_URL=$EasyUrl" `
  "EASY_LOCATE_PUBLISHABLE_KEY=$EasyKey" `
  "EASY_LOCATE_SITE_URL=https://easy-locate.vercel.app" `
  --project-ref $ProjectRef

if ($LASTEXITCODE -ne 0) {
  throw "supabase secrets set failed. Confirm the Supabase CLI is logged into the account that can manage XOS Staging."
}

Write-Host "Done. Reload Quick Solution Admin > Quick Points and the Easy Locate search should report Ready."
