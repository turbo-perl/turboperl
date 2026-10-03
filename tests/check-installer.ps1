# Install TurboPerl with its installer, for the current user and with the
# PATH task, check what that did, then uninstall and check that it is all
# gone again - the PATH included, every other entry of it left as it was.
#
#   powershell -File tests\check-installer.ps1 packages\turboperl-<version>-setup.exe <version>
#
# It changes the user's PATH while it runs, so it is meant for CI.

param(
    [Parameter(Mandatory)] [string] $Setup,
    [Parameter(Mandatory)] [string] $Version
)

$ErrorActionPreference = 'Stop'
$dir = Join-Path ([IO.Path]::GetTempPath()) 'turboperl-installer-check'
$fail = 0

function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Output "ok   $name" }
    else     { Write-Output "FAIL $name"; $script:fail++ }
}

function UserPath { [Environment]::GetEnvironmentVariable('Path', 'User') }
function Entries([string]$path) { @($path -split ';' | Where-Object { $_ -ne '' }) }

$before = UserPath
if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }

$p = Start-Process -Wait -PassThru $Setup -ArgumentList `
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', "/DIR=$dir", '/TASKS=addtopath'
Check 'the installer succeeds' ($p.ExitCode -eq 0)

$exe = Join-Path $dir 'turboperl.exe'
Check 'the IDE is installed' (Test-Path $exe)
Check 'it reports the version' ((& $exe --version) -eq "TurboPerl $Version")
Check 'with the debugger bridge beside it' `
    (Test-Path (Join-Path $dir 'lib\TurboPerl\Debug\Bridge.pm'))
Check 'and on the Start menu' `
    (Test-Path (Join-Path ([Environment]::GetFolderPath('Programs')) 'TurboPerl.lnk'))
Check 'its directory is on the PATH' ((Entries (UserPath)) -contains $dir)

$p = Start-Process -Wait -PassThru (Join-Path $dir 'unins000.exe') -ArgumentList `
    '/VERYSILENT', '/SUPPRESSMSGBOXES'
Check 'the uninstaller succeeds' ($p.ExitCode -eq 0)
# The uninstaller hands over to a copy of itself and returns at once.
$until = (Get-Date).AddSeconds(30)
while ((Test-Path $exe) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200 }
Start-Sleep -Seconds 1
Check 'the IDE is gone' (-not (Test-Path $exe))
Check 'and off the Start menu' `
    (-not (Test-Path (Join-Path ([Environment]::GetFolderPath('Programs')) 'TurboPerl.lnk')))
Check 'its directory is off the PATH' (-not ((Entries (UserPath)) -contains $dir))
Check 'and the rest of the PATH is as it was' `
    (((Entries (UserPath)) -join ';') -eq ((Entries $before) -join ';'))

Write-Output ''
Write-Output "installer checks: $fail failed"
if ($fail) { exit 1 }
exit 0
