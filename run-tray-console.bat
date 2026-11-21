@echo off
rem run-tray-console.bat - run the tray in a visible console window (for first runs / debugging).
rem Ctrl+C stops it. Events are appended to strata-tray.log next to this file, which is how hover
rem behaviour is checked: it logs "card shown (hover) at x,y size WxH" and "card hidden (...)".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0strata-tray.ps1" -Trace "%~dp0strata-tray.log"
