@echo off
rem Build the complete Java 11 backend against Stata's real SFI API.
rem Usage: build.bat "C:\Program Files\Stata18\utilities\jar\sfi-api.jar"
setlocal
set "HERE=%~dp0"
set "SFI=%~1"
if "%SFI%"=="" set "SFI=%SFI_JAR%"
if "%SFI%"=="" (
  echo ERROR: supply your Stata sfi-api.jar. In Stata: display c^(sysdir_stata^)
  exit /b 1
)
if not exist "%SFI%" (
  echo ERROR: SFI jar not found at "%SFI%".
  exit /b 1
)
where javac >nul 2>nul
if errorlevel 1 (
  echo ERROR: install JDK 11 or newer and put javac and java on PATH.
  exit /b 1
)
set "OUT=%HERE%build\classes"
set "TOOL=%HERE%build\tools"
set "DIST=%HERE%dist"
if exist "%OUT%" rmdir /s /q "%OUT%"
if exist "%TOOL%" rmdir /s /q "%TOOL%"
mkdir "%OUT%"
mkdir "%TOOL%"
if not exist "%DIST%" mkdir "%DIST%"
javac --release 11 -Xlint:all -cp "%SFI%" -d "%OUT%" "%HERE%src\org\worldbank\suso\*.java"
if errorlevel 1 exit /b 1
javac --release 11 -d "%TOOL%" "%HERE%tools\BuildJar.java"
if errorlevel 1 exit /b 1
java -cp "%TOOL%" BuildJar "%OUT%" "%DIST%\suso.jar"
if errorlevel 1 exit /b 1
echo Built %DIST%\suso.jar ^(SuSo classes only; SFI remains supplied by Stata^).
endlocal
