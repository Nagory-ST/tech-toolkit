@echo off
rem Tech Toolkit - lanceur cle USB (a placer a la racine de la partition TOOLS, a cote de toolkit.ps1 et tools.json)
set "TK_ROOT=%~dp0"
if not exist "%~dp0toolkit.ps1" (
  echo toolkit.ps1 introuvable a cote de START.bat
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -Command "iex ([IO.File]::ReadAllText('%~dp0toolkit.ps1',[Text.Encoding]::UTF8))"
