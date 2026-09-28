#!/usr/bin/haserl
<% 
# Simple PTZ control panel for SAZ1051 (MiXic MX2208A, /dev/swmotor).
# Buttons send a direction to /usr/bin/swmotor_ctl. The name->cmd mapping is a
# hypothesis (see /etc/swmotor.map and vendor/saz1051/ptz/README.md); if a
# button moves the wrong way, edit the map (or the defaults in swmotor_ctl.c)
# and reload. No device-side state is kept here.
action=${FORM_action}
result=""
case "$action" in
  left|right|up|down|stop|reset)
    /usr/bin/swmotor_ctl "$action" >/dev/null 2>&1
    result="sent: $action"
    ;;
esac
%>
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SAZ1051 PTZ</title>
<style>
  body { font-family: sans-serif; text-align: center; margin-top: 2em; }
  .pad { display: grid; grid-template-columns: 80px 80px 80px; gap: 8px;
         justify-content: center; margin: 1em auto; }
  button { padding: 14px; font-size: 16px; }
  .msg { color: #066; min-height: 1.4em; }
</style>
</head>
<body>
  <h2>SAZ1051 云台控制 (PTZ)</h2>
  <div class="pad">
    <span></span>
    <a href="?action=up"><button>↑ 上</button></a>
    <span></span>
    <a href="?action=left"><button>← 左</button></a>
    <a href="?action=stop"><button>■ 停</button></a>
    <a href="?action=right"><button>右 →</button></a>
    <span></span>
    <a href="?action=down"><button>↓ 下</button></a>
    <span></span>
  </div>
  <div class="msg"><% echo "$result" %></div>
  <p style="color:#888;font-size:12px">
    方向映射为待机验证假设；若方向反了，编辑 <code>/etc/swmotor.map</code>
    或 <code>swmotor_ctl</code> 默认值后刷新。
  </p>
</body>
</html>
