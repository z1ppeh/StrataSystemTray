# settings.local.example.ps1 - copy this to settings.local.ps1 if your Strata is NOT set up the way
# the tracked defaults expect (a port other than 8080, or `strata` not on PATH).
# settings.local.ps1 is gitignored, so it stays on your machine.
#
#   copy settings.local.example.ps1 settings.local.ps1
#
# Only $Url, $Every, $StrataCmd, $Control, $Wizard and $SoftControl are read; anything else in this
# file is ignored. Values here beat the script's defaults; -Url / -Every / -NoControl on the command
# line still beat this file.

$Url   = 'http://127.0.0.1:8080'   # where the Terminal server answers
$Every = 1.5                       # how often the card re-reads it, seconds

$StrataCmd = 'strata'              # the Strata command line, for Start / Stop in the menu.
                                    # Full path works too, e.g. 'C:\Strata\terminal\bin\strata.cmd'
$Control   = $true                 # $false = watch only, no Start / Stop / Unload

$SoftControl = $true                # $false hides the two Load / Unload rows (the ones that keep the
                                    # server up and only put the model in or out of graphics memory).
                                    # Start / Stop are unaffected. Default $true.

$Wizard    = ''                    # optional: Strata's start-here script, offered when no model is
                                    # installed. Left empty, it is found next to the install that
                                    # $StrataCmd belongs to (<root>\START-HERE.bat).
