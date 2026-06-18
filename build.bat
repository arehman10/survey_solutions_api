@echo off
rem ---------------------------------------------------------------------------
rem build.bat - compile suso.jar from source against your Stata's SFI library.
rem
rem   A prebuilt dist\suso.jar already ships and should work on any Stata with a
rem   Java 11+ runtime. Rebuild ONLY if the prebuilt jar errors at runtime.
rem
rem Usage:
rem   build.bat "C:\Program Files\Stata18\utilities\jar\sfi-api.jar"
rem   set SFI_JAR=C:\path\to\sfi-api.jar  &  build.bat
rem
rem To find sfi-api.jar, in Stata run:  display c(sysdir_stata)
rem ---------------------------------------------------------------------------
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "SRC=%HERE%src"
set "OUT=%HERE%build\classes"
set "DIST=%HERE%dist"

where javac >nul 2>nul
if errorlevel 1 (
  echo ERROR: javac not found. Install a JDK 11+ ^(Temurin/OpenJDK^) and re-run.
  exit /b 1
)

set "SFI=%~1"
if "%SFI%"=="" set "SFI=%SFI_JAR%"
if "%SFI%"=="" (
  echo Searching for sfi-api.jar under "C:\Program Files\Stata*" ...
  for /d %%D in ("C:\Program Files\Stata*" "C:\Program Files (x86)\Stata*") do (
    for /r "%%D" %%F in (sfi-api.jar) do (
      set "SFI=%%F"
      goto :found
    )
  )
)
:found
if "%SFI%"=="" (
  echo ERROR: could not locate sfi-api.jar.
  echo   In Stata: display c^(sysdir_stata^)  then find sfi-api.jar under that folder.
  echo   Re-run  : build.bat "C:\full\path\to\sfi-api.jar"
  exit /b 1
)
if not exist "%SFI%" (
  echo ERROR: SFI jar not found at "%SFI%".
  exit /b 1
)
echo Using SFI: %SFI%

if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%" 2>nul
if not exist "%DIST%" mkdir "%DIST%"

javac --release 11 -cp "%SFI%" -d "%OUT%" "%SRC%\org\worldbank\suso\*.java"
if errorlevel 1 exit /b 1

pushd "%OUT%"
jar cf "%DIST%\suso.jar" org\worldbank\suso
popd
echo Built: %DIST%\suso.jar
echo Copy suso.jar, suso.ado and suso.sthlp to your Stata PLUS or PERSONAL folder.
endlocal
