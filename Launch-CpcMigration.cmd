@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 is required. Install it using your organization's approved process.
    pause
    exit /b 1
)
rem Usage: Launch-CpcMigration.cmd [-SmokeTest]
rem TenantId locks scope only; Detect/Connect remain explicit UI actions.
pwsh.exe -NoProfile -STA -File "%~dp0Start-CpcMigration.ps1" -TenantId "TENANTID" %*
if errorlevel 1 (
    echo The application could not start. Review the error above and README.md.
    pause
    exit /b 1
)
endlocal