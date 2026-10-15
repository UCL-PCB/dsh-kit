@echo off
REM INSIDE. Double-clickable wrapper for update_dsh_vm.sh, which lives beside this file:
REM unpack the new payload, refresh the GitLab mirror, reinstall the packages. Every input
REM comes from %USERPROFILE%\dsh-kit.env and the payload's dsh-kit.conf, so there is
REM nothing to type and nothing to remember between trips.
REM
REM This and update_dsh_vm.sh travel BESIDE the zip, like unpack_payload.sh - the copies
REM inside the payload cannot unpack the payload they are in.
REM
REM Arguments are passed straight through, so the .sh options work from a prompt too:
REM   update_dsh_vm.bat --dry-run
REM   update_dsh_vm.bat --skip unpack

setlocal

REM %~dp0 is this file's own directory, with a trailing backslash, so the path survives
REM the payload landing anywhere. pushd makes it the working directory for bash as well,
REM which is how the .sh finds unpack_payload.sh beside it.
pushd "%~dp0"

REM Git for Windows is not always in PATH and is not always in Program Files, so look
REM rather than assume - a hardcoded path is how the previous wrapper went stale.
set "BASH="
for %%B in (
    "%ProgramFiles%\Git\bin\bash.exe"
    "%ProgramFiles(x86)%\Git\bin\bash.exe"
    "%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
    "%ProgramW6432%\Git\bin\bash.exe"
) do if not defined BASH if exist %%B set "BASH=%%~B"

if not defined BASH (
    for /f "delims=" %%B in ('where bash 2^>nul') do if not defined BASH set "BASH=%%B"
)

if not defined BASH (
    echo.
    echo   Could not find bash.exe. Git for Windows provides it.
    echo   Looked in Program Files, Program Files ^(x86^), LOCALAPPDATA\Programs and PATH.
    echo   If it is installed somewhere else, run the script by hand from Git Bash:
    echo.
    echo       bash ./update_dsh_vm.sh
    echo.
    popd
    endlocal
    pause
    exit /b 1
)

echo Using: %BASH%
echo.

REM --login -i so the shell reads ~/.bash_profile and ~/.bashrc. That is where
REM GIT_CEILING_DIRECTORIES is persisted, and without it every git command on this VM
REM dies with "failed to stat" before it starts. The .sh sets it too; this is the belt.
"%BASH%" --login -i ./update_dsh_vm.sh %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo   FAILED - exit code %RC%. See update_dsh_vm.log in this folder,
    echo   and the per-step log named in the output above.
) else (
    echo   OK - see update_dsh_vm.log in this folder.
)

popd
endlocal
REM pause so a double-click leaves the window open long enough to read the result.
pause
