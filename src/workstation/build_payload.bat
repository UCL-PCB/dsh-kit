@echo off
REM Double-clickable wrapper for build_payload.sh, which lives beside this file.
REM %~dp0 is this script's own directory, so the path survives the repo being moved.
REM
REM   double-click             -> rebuild for the targets in dsh-kit.conf
REM   build_payload.bat <args> -> args passed straight through
REM                               e.g. build_payload.bat --target dsh-vm --prune
REM
REM Which repos go in, and which of them are WORKING repos (overwritten inside when
REM carried), is dsh-kit.conf's decision, not this file's - see KIT_WORKING_REPOS.
setlocal

set "BASH=C:\Program Files\Git\bin\bash.exe"

if not exist "%BASH%" (
    echo ERROR: Git Bash not found at "%BASH%"
    pause
    exit /b 1
)

"%BASH%" --login -i "%~dp0build_payload.sh" %*

echo.
echo Exit code: %ERRORLEVEL%
pause
