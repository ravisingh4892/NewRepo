@echo off
rem Launches the Remote Play Stabilizer. Leave this window's app running while you play.
start "" powershell.exe -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\Start-Stabilizer.ps1"
