#!/bin/sh
# CFW: the panel page. Generated, so a model only shows what it supports.
. /snom/cfw/model.conf
has() { case " $CFW_FEATURES " in *" $1 "*) return 0;; esac; return 1; }
echo "Content-type: text/html"
echo ""
cat <<H
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CFW Settings</title><style>
body{font:15px system-ui,sans-serif;max-width:640px;margin:0 auto;padding:16px;background:#f4f4f4;color:#222}
.card{background:#fff;border-radius:8px;padding:12px 16px;margin:12px 0}h2{margin:.2em 0;font-size:17px}
input{width:100%;box-sizing:border-box;padding:7px;margin:6px 0}button{padding:7px 14px;border:0;border-radius:5px;background:#555;color:#fff}
</style></head><body>
<h1>CFW Settings</h1><div>snom $CFW_MODEL custom firmware</div>
<div class="card"><h2>Remote control</h2><p>See the screen and press the keys from this browser.</p>
<form method="get" action="/cgi-bin/remote"><button style="background:#36c">Open remote</button></form></div>
<div class="card"><h2>System</h2><p>Status, logs, settings backup and reboot.</p>
<form method="get" action="/cgi-bin/sysinfo" style="display:inline"><button>Status</button></form>
<form method="get" action="/cgi-bin/logs" style="display:inline"><button>Logs</button></form>
<form method="get" action="/cgi-bin/backup" style="display:inline"><button>Back up settings</button></form>
<form method="post" action="/cgi-bin/reboot" style="display:inline"><button style="background:#c33">Reboot</button></form></div>
<div class="card"><h2>Reset root password</h2><p>Set the root password back to the firmware default. This password also logs in here.</p>
<form method="post" action="/cgi-bin/reset-pw"><button>Reset</button></form></div>
<div class="card"><h2>Reset SSH config</h2><p>Restore the default <code>/etc/ssh/sshd_config</code> and reload sshd.</p>
<form method="post" action="/cgi-bin/reset-ssh"><button>Reset</button></form></div>
H
if has doom; then cat <<H
<div class="card"><h2>Boot Doom</h2><p>URL of a WAD. It runs from RAM and is discarded on quit.</p>
<form method="post" action="/cgi-bin/boot-doom"><input type="url" name="url" placeholder="http://host/freedoom2.wad" required>
<button style="background:#c33">Boot Doom</button></form></div>
H
fi
if has nes; then cat <<H
<div class="card"><h2>Boot NES</h2><p>URL of a .nes ROM (mapper 0-4). It runs from RAM and is discarded on quit.</p>
<form method="post" action="/cgi-bin/boot-nes"><input type="url" name="url" placeholder="http://host/game.nes" required>
<button style="background:#36c">Boot NES</button></form></div>
H
fi
cat <<H
<div class="card"><h2>Screenshot</h2><p>What the phone's screen shows right now.</p>
<form method="get" action="/cgi-bin/screenshot" target="_blank"><button>Take screenshot</button></form></div>
<p>Logins travel unencrypted. Use this panel on a trusted network only.</p>
</body></html>
H
