ModelPull for Ubuntu 24.04
==========================

Downloads big files from Hugging Face and Civitai.
It continues from the same byte after a drop, a VPN switch, sleep or a restart.

INSTALL
  1. Open a terminal in this folder.
  2. Run:  ./install.sh
     To start it hidden at every login, run:  ./install.sh --autostart
  3. Open "ModelPull" from the app menu. A page opens in your browser.

  Had the older "Downloader" app? The installer removes it.
  Your jobs, tokens and settings move to the new folders on the first start.

USE
  - Paste a link and click Add.
  - Closing the browser tab does NOT stop downloads.
  - To stop the app, click the power button on the page.
  - To open the page again, click "ModelPull" in the app menu again.

WHERE THINGS ARE
  Downloads      the "Save to" folder (default ~/Downloads)
  Unfinished     <file>.dlpart in the same folder
  Jobs           ~/.local/share/ModelPull/jobs
  Tokens         ~/.config/modelpull/tokens.json (only you can read it)
  Log            ~/.local/state/modelpull/modelpull.log

IF IT DOES NOT START
  Run in a terminal:  ~/.local/bin/modelpull
  If the error says a library is missing, run:  sudo apt install libcurl4t64
  If it says the port is busy, run:  ~/.local/bin/modelpull --port 8766

REMOVE
  ./install.sh --uninstall
