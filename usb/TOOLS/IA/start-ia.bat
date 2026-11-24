@echo off
title Assistant IA hors ligne
set "BIN=%~dp0bin\koboldcpp.exe"
if not exist "%BIN%" ( echo koboldcpp.exe introuvable dans IA\bin & pause & exit /b 1 )

rem Prend le premier modele .gguf trouve dans IA\models
set "MODEL="
for %%F in ("%~dp0models\*.gguf") do if not defined MODEL set "MODEL=%%~fF"
if not defined MODEL ( echo Aucun modele .gguf dans IA\models & pause & exit /b 1 )

echo Modele : %MODEL%
start "" http://localhost:5001
"%BIN%" --model "%MODEL%" --contextsize 8192 --port 5001
