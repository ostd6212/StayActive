#!/bin/bash
# Streams StayActive's NSLog output in real time. Start this BEFORE
# running install.sh / opening the app, in its own terminal window.
exec log stream --predicate 'process == "StayActive"' --info
