/// 快传网页（由本机 HTTP 服务器托管，供同一局域网内的浏览器访问）。
///
/// 设计要点：
///  - **网页端可选频道**：浏览器直接打开 `http://<IP>:<端口>/` 时，会拉取
///    App 端已加入的频道列表（`/api/channels`），公共频道点击即进、私有频道
///    弹密码框验证；也可通过二维码 `?ch=<频道>&k=<密码>` 直接进入。频道切换
///    通过顶部「切换频道」按钮重新拉取列表。
///  - **聊天式交互**：消息以气泡流呈现，底部输入框 + 附件按钮，
///    轮询 `/api/messages` 获取新消息，文件可直接点击下载。
///  - 浏览器原生 `<input type=file>` 即可选文件，无需与 App 桥接。
const String kLanWebHtml = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>EverLink 快传</title>
<style>
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  html,body{height:100%;margin:0}
  body{
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif;
    background:#f2f4f6;color:#1f2933;display:flex;flex-direction:column;height:100vh;overflow:hidden;
  }
  header{
    background:#00897b;color:#fff;padding:10px 14px;display:flex;align-items:center;gap:10px;
    box-shadow:0 1px 4px rgba(0,0,0,.15);flex-shrink:0;
  }
  .ch{font-size:16px;font-weight:600;display:flex;align-items:center;gap:5px;min-width:0;cursor:pointer}
  .ch:active{opacity:.7}
  .ch span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .switch-hint{font-size:11px;opacity:.7;margin-left:4px;white-space:nowrap}
  .sub{font-size:11px;opacity:.85;margin-top:2px}
  header .grow{flex:1;min-width:0}
  .namebtn{
    background:rgba(255,255,255,.18);border:none;color:#fff;border-radius:16px;
    padding:6px 12px;font-size:12px;cursor:pointer;white-space:nowrap;
  }
  .namebtn:active{background:rgba(255,255,255,.3)}

  #list{flex:1;overflow-y:auto;padding:14px 12px 6px;-webkit-overflow-scrolling:touch}
  .empty{text-align:center;color:#9aa5b1;font-size:13px;margin-top:40px;line-height:1.8}
  .row{display:flex;margin-bottom:14px;align-items:flex-end;gap:8px}
  .row.me{flex-direction:row-reverse}
  .avatar{
    width:30px;height:30px;border-radius:50%;background:#b0bec5;color:#fff;flex-shrink:0;
    display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:600;
  }
  .row.me .avatar{background:#00897b}
  .bubblewrap{max-width:78%;min-width:0}
  .who{font-size:11px;color:#9aa5b1;margin-bottom:3px;padding:0 4px}
  .row.me .who{text-align:right}
  .bubble{
    background:#fff;border-radius:12px;padding:9px 12px;font-size:14px;line-height:1.55;
    box-shadow:0 1px 2px rgba(0,0,0,.08);word-break:break-word;white-space:pre-wrap;
  }
  .row.me .bubble{background:#c8f0e8;border-radius:12px 12px 4px 12px}
  .row:not(.me) .bubble{background:#fff;border-radius:12px 12px 12px 4px;border:1px solid rgba(0,0,0,.06)}
  .files{margin-top:6px;display:flex;flex-direction:column;gap:6px}
  .bubble.only-files{padding:8px}
  .msg-tag{
    display:inline-block;font-size:9px;font-weight:600;padding:1px 5px;border-radius:4px;
    margin-right:4px;vertical-align:middle;
  }
  .msg-tag.ch{background:#e0f2f1;color:#00695c}
  .msg-tag.p2p{background:#f3e5f5;color:#7b1fa2}
  .fitem{
    display:flex;align-items:center;gap:8px;background:rgba(0,0,0,.04);
    border-radius:8px;padding:7px 9px;text-decoration:none;color:inherit;
  }
  .fitem:active{background:rgba(0,0,0,.09)}
  .ficon{font-size:18px;flex-shrink:0}
  .fmeta{min-width:0;flex:1}
  .fname{font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .fsize{font-size:11px;color:#7b8794}
  .tabs{display:inline-flex;background:rgba(255,255,255,.2);border-radius:10px;padding:2px;margin-top:6px}
  .tab{
    padding:5px 16px;border-radius:8px;font-size:13px;border:none;
    background:transparent;color:rgba(255,255,255,.85);cursor:pointer;transition:.15s;font-weight:500;
  }
  .tab.on{background:rgba(255,255,255,.92);color:#00897b}
  .thumb{max-width:100%;border-radius:8px;display:block;margin-top:4px}
  .time{font-size:10px;color:#b0bec5;margin-top:3px;padding:0 4px}
  .row.me .time{text-align:right}

  footer{background:#fff;border-top:1px solid #e4e7eb;padding:8px 10px;flex-shrink:0}
  .picked{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:6px}
  .chip{
    background:#e0f2f1;border-radius:14px;padding:4px 9px;font-size:12px;
    display:flex;align-items:center;gap:5px;max-width:100%;
  }
  .chip b{font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:150px}
  .chip i{cursor:pointer;font-style:normal;color:#00695c;font-weight:700}
  .inputrow{display:flex;align-items:flex-end;gap:8px}
  .iconbtn{
    width:38px;height:38px;border-radius:50%;border:none;background:#eceff1;color:#455a64;
    font-size:19px;cursor:pointer;flex-shrink:0;display:flex;align-items:center;justify-content:center;
  }
  .iconbtn:active{background:#cfd8dc}
  textarea{
    flex:1;resize:none;border:1px solid #dfe3e8;border-radius:19px;padding:9px 14px;
    font-size:14px;font-family:inherit;max-height:96px;min-height:38px;line-height:1.4;outline:none;
    overflow-y:hidden;
  }
  textarea:focus{border-color:#00897b}
  .send{background:#00897b;color:#fff;border-radius:50%}
  .send:disabled{background:#cfd8dc;color:#90a4ae}
  .send:active:not(:disabled){background:#00695c;transform:scale(0.92)}
  #status{font-size:11px;color:#7b8794;text-align:center;padding:4px 0 0;min-height:16px}
  .bar{height:3px;background:#e0f2f1;border-radius:2px;overflow:hidden;margin-top:5px;display:none}
  .bar.on{display:block}
  .bar i{display:block;height:100%;width:40%;background:#00897b;animation:mv 1s linear infinite}
  @keyframes mv{0%{margin-left:-40%}100%{margin-left:100%}}
  .modal{position:fixed;inset:0;background:rgba(0,0,0,.5);display:none;align-items:center;justify-content:center;z-index:50;animation:fadeIn .2s}
  .modal.on{display:flex}
  .card{
    background:#fff;border-radius:16px;width:84%;max-width:340px;
    box-shadow:0 12px 40px rgba(0,0,0,.18);animation:slideUp .25s ease-out;overflow:hidden;
  }
  @keyframes fadeIn{from{opacity:0}to{opacity:1}}
  @keyframes slideUp{from{transform:translateY(20px);opacity:0}to{transform:translateY(0);opacity:1}}
  .card-head{padding:20px 20px 0;text-align:center}
  .card-body{padding:14px 20px 10px}
  .card-foot{display:flex;gap:0;border-top:1px solid #eee}
  .card-foot button{
    flex:1;border:none;padding:13px 0;font-size:15px;cursor:pointer;background:transparent;
    font-weight:500;transition:background .15s;
  }
  .card-foot button:active{background:rgba(0,0,0,.04)}
  .mok{color:#00897b}
  .mcancel{color:#7b8794}
  .mtitle{font-size:16px;font-weight:600;margin-bottom:4px;color:#1f2933}
  .msub{font-size:13px;color:#7b8794;margin-bottom:2px}
  .lockicon{font-size:36px;display:block;margin-bottom:8px}
  .minput-wrap{position:relative;margin-top:4px}
  .minput-wrap input{
    width:100%;border:1.5px solid #e4e7eb;border-radius:10px;padding:11px 14px;
    font-size:15px;outline:none;box-sizing:border-box;background:#f8f9fa;transition:border-color .2s,background .2s;
  }
  .minput-wrap input:focus{border-color:#00897b;background:#fff}
  .minput-wrap input::placeholder{color:#b0bec5}
  .pinwrap{display:flex;gap:8px;justify-content:center;margin:10px 0 4px}
  .pinbox{
    width:38px;height:46px;text-align:center;font-size:22px;font-weight:700;
    border:1.5px solid #cfd4da;border-radius:10px;outline:none;background:#f8f9fa;
    transition:border-color .15s,background .15s;caret-color:#00897b;
  }
  .pinbox:focus{border-color:#00897b;background:#fff}
  .pinhint{font-size:11px;color:#78909c;text-align:center;margin-top:2px}
  .merr{
    color:#e53935;font-size:12px;min-height:18px;margin-top:8px;text-align:center;transition:opacity .2s;
  }
  .mloading{
    display:inline-flex;align-items:center;gap:6px;color:#00897b;font-size:12px;
  }
  .mloading::before{
    content:'';width:12px;height:12px;border:2px solid #b2dfdb;border-top-color:#00897b;
    border-radius:50%;animation:spin .6s linear infinite;
  }
  @keyframes spin{to{transform:rotate(360deg)}}
  .chlist{max-height:52vh;overflow-y:auto;-webkit-overflow-scrolling:touch;margin-top:4px}
  .chitem{
    display:flex;align-items:center;gap:10px;padding:13px 14px;border-radius:12px;
    background:#f4f7f7;margin-bottom:10px;cursor:pointer;transition:background .15s;
  }
  .chitem:active{background:#e0f2f1}
  .chitem .chname{font-size:15px;font-weight:600;flex:1;min-width:0;display:flex;align-items:center;gap:6px;overflow:hidden}
  .chitem .chname .clock{font-size:14px;flex-shrink:0}
  .chitem .chenter{
    color:#00897b;font-size:13px;font-weight:600;background:rgba(0,137,123,.1);
    padding:5px 12px;border-radius:14px;white-space:nowrap;flex-shrink:0;
  }
  .chitem .chenter:active{background:rgba(0,137,123,.22)}

  /* 网络信息面板 */
  .netbtn{
    display:inline-flex;align-items:center;gap:4px;font-size:11px;
    color:rgba(255,255,255,.75);cursor:pointer;margin-top:4px;user-select:none;
  }
  .netbtn:active{opacity:.7}
  .netbtn .arr{display:inline-block;transition:transform .2s;font-size:9px}
  .netbtn.on .arr{transform:rotate(180deg)}
  .netpanel{
    background:#fff;border-bottom:1px solid #e4e7eb;padding:0;max-height:0;overflow:hidden;
    transition:max-height .3s ease,padding .2s;
  }
  .netpanel.on{max-height:420px;overflow-y:auto;padding:10px 14px;-webkit-overflow-scrolling:touch}
  .netgrid{display:grid;grid-template-columns:auto 1fr;gap:6px 10px;font-size:12px}
  .netgrid .k{color:#7b8794;white-space:nowrap}
  .netgrid .v{color:#1f2933;font-weight:500;word-break:break-all;text-align:right}
  .netips{margin-top:8px}
  .netips-title{font-size:11px;color:#7b8794;margin-bottom:5px;font-weight:600}
  .ipchip{
    display:inline-flex;align-items:center;gap:6px;background:#f0f7f6;border:1px solid #b2dfdb;
    border-radius:8px;padding:5px 9px;margin:0 4px 5px 0;cursor:pointer;transition:.15s;
    max-width:100%;overflow:hidden;
  }
  .ipchip:active{background:#e0f2f1}
  .ipchip .ip{font-size:12px;font-weight:600;color:#00695c;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .ipchip .iptype{font-size:10px;color:#7b8794;background:#e0f2f1;border-radius:4px;padding:1px 5px;white-space:nowrap}
  .ipchip.star{border-color:#00897b;background:#e0f2f1}
  .ipchip .ipcopy{font-size:10px;color:#00897b;flex-shrink:0}
  /* 连接类型徽章 */
  .nettype{
    display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600;
    padding:6px 10px;border-radius:10px;border:1px solid;margin-bottom:10px;
  }
  .nettype .nettype-ic{font-size:14px;line-height:1}

</style>
</head>
<body>
<header>
  <div class="grow">
    <div class="ch" id="chTab">
      <span id="chName">公共频道</span><span id="lock"></span>
      <span class="switch-hint">切换&#9662;</span>
    </div>
    <div class="sub" id="hostName">连接中…</div>
    <div class="tabs">
      <button class="tab on" id="tabChannel">频道</button>
      <button class="tab" id="tabP2P">私聊</button>
    </div>
    <div class="netbtn" id="netBtn">&#x1F4F6; 网络信息 <span class="arr">&#9660;</span></div>
  </div>
  <button class="namebtn" id="btnName">我的昵称</button>
</header>

<div class="netpanel" id="netPanel"></div>

<div id="list"><div class="empty">还没有消息<br>发送文字或文件试试</div></div>

<footer id="chatFooter">
  <div class="picked" id="picked"></div>
  <div class="inputrow">
    <button class="iconbtn" id="btnFile" title="选择文件">+</button>
    <textarea id="text" rows="1" placeholder="输入消息…"></textarea>
    <button class="iconbtn send" id="btnSend" disabled>&#10148;</button>
  </div>
  <div class="bar" id="bar"><i></i></div>
  <div id="status"></div>
  <input type="file" id="file" multiple style="display:none">
</footer>

<div id="nameModal" class="modal">
  <div class="card">
    <div class="card-head">
      <span class="lockicon">&#x1F464;</span>
      <div class="mtitle">设置你的显示名字</div>
      <div class="msub">这个名字会显示在聊天消息中</div>
    </div>
    <div class="card-body">
      <div class="minput-wrap">
        <input id="nameInput" maxlength="20" placeholder="如：我的手机" autocomplete="off">
      </div>
      <div class="merr" id="nameErr"></div>
    </div>
    <div class="card-foot">
      <button id="nameCancel" class="mcancel">取消</button>
      <button id="nameOk" class="mok">保存</button>
    </div>
  </div>
</div>

<div id="pwdModal" class="modal">
  <div class="card">
    <div class="card-head">
      <span class="lockicon">&#x1F512;</span>
      <div class="mtitle">加入频道「<span id="pwdChName"></span>」</div>
      <div class="msub">该频道设置了密码，需要验证后才能进入</div>
    </div>
    <div class="card-body">
      <div class="pinwrap" id="pwdPin"></div>
      <div class="pinhint">请输入 6 位频道 PIN（验证码样式）</div>
      <div class="merr" id="pwdErr"></div>
    </div>
    <div class="card-foot">
      <button id="pwdCancel" class="mcancel">取消</button>
      <button id="pwdOk" class="mok">加入频道</button>
    </div>
  </div>
</div>

<div id="channelPicker" class="modal">
  <div class="card" style="max-width:360px">
    <div class="card-head">
      <span class="lockicon">&#x1F4E2;</span>
      <div class="mtitle">选择一个频道</div>
      <div class="msub">点击频道即可进入，公共频道无需密码</div>
    </div>
    <div class="card-body">
      <div id="channelList" class="chlist"></div>
      <div class="merr" id="chErr"></div>
    </div>
    <div class="card-foot">
      <button id="chCancel" class="mcancel">进入私聊</button>
    </div>
  </div>
</div>

<script>
(function(){
  var qs = new URLSearchParams(location.search);
  var CHANNEL = qs.get('ch') || '';
  var KEY = qs.get('k') || '';
  // 是否已加入某个频道（含公共频道）。用于隔离频道/私聊的存储与轮询，
  // 避免未选择频道时把 P2P 消息误当成频道消息、或存储键与私聊发生碰撞。
  var channelJoined = !!CHANNEL;
  function genName(){
    var pool = ['快乐','安静','勇敢','机智','温柔','酷炫','神秘','阳光','活力','萌萌','小','阿'];
    var w = pool[Math.floor(Math.random()*pool.length)];
    var n = Math.floor(Math.random()*9000+1000);
    return w + n;
  }
  // 扫码连接即自动生成一个友好名字并落盘，避免“其他设备没有名字”的困惑；
  // 用户之后随时可点“我的昵称”改成自定义名字。
  var myName = localStorage.getItem('everlink_web_name');
  if(!myName){ myName = genName(); localStorage.setItem('everlink_web_name', myName); }
  var picked = [];
  var since = 0;
  var sinceP2P = 0;          // 私聊视图独立的 since，避免频道模式漏消息
  var seen = {};
  var sending = false;
  var polling = false;       // 防并发 poll，避免 seen/since 错乱导致 DOM 被破坏
  var p2pMode = false;       // true=私聊视图, false=频道视图
  var view = 'channel';      // 'channel' | 'p2p'
  var serverAddr = '';       // 主机 App 的地址 (host:port)，用于私聊发送
  var pwdFromPicker = false;  // 密码弹窗是否来自频道选择器

  var $ = function(id){ return document.getElementById(id); };

  function esc(s){
    return String(s).replace(/[&<>"']/g, function(c){
      return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
    });
  }
  function setStatus(t){ $('status').textContent = t || ''; }
  function busy(on){ $('bar').className = on ? 'bar on' : 'bar'; }

  // 昵称设置改用页面内弹窗（window.prompt 在手机浏览器/内嵌 WebView 常被禁用）。
  function openNameModal(){
    var inp = $('nameInput');
    inp.value = myName || '';
    $('nameErr').textContent = '';
    $('nameModal').className = 'modal on';
    setTimeout(function(){ try{ inp.focus(); inp.select(); }catch(e){} }, 60);
  }
  function closeNameModal(){ $('nameModal').className = 'modal'; }
  $('btnName').onclick = openNameModal;
  $('chTab').onclick = function(){
    fetchChannels();
  };
  $('nameCancel').onclick = closeNameModal;
  $('nameOk').onclick = function(){
    var v = $('nameInput').value.trim();
    if(!v){ $('nameErr').textContent = '名字不能为空'; return; }
    myName = v;
    localStorage.setItem('everlink_web_name', myName);
    $('btnName').textContent = myName;
    closeNameModal();
    connect(); // 立即重连以通知服务器新昵称
  };
  $('nameInput').addEventListener('keydown', function(e){
    if(e.key === 'Enter'){ e.preventDefault(); $('nameOk').click(); }
  });

  // 频道由 App 端通过二维码指定，网页端只展示、不可更改。
  $('chName').textContent = channelJoined ? (CHANNEL || '公共频道') : '请选择频道';
  $('lock').textContent = KEY ? '\u{1F512}' : '';
  $('btnName').textContent = myName;

  // 频道密码：先查服务端该频道是否需要密码，公共频道无需弹窗。
  var needPwd = false;

  // 验证码式 PIN 输入框（6 个方框）：自动跳格、退格回退、回车提交。
  var PIN_LEN = 6;
  function buildPinBoxes(){
    var wrap = $('pwdPin');
    if(!wrap) return;
    wrap.innerHTML = '';
    for(var i=0;i<PIN_LEN;i++){
      var b = document.createElement('input');
      b.className = 'pinbox';
      b.maxLength = 1;
      b.inputMode = 'numeric';
      b.setAttribute('autocomplete','off');
      b.addEventListener('input', function(){
        this.value = this.value.replace(/\D/g,'').slice(0,1);
        if(this.value && this.nextElementSibling) this.nextElementSibling.focus();
      });
      b.addEventListener('keydown', function(e){
        if(e.key === 'Backspace' && !this.value && this.previousElementSibling){
          this.previousElementSibling.focus();
        } else if(e.key === 'Enter'){
          e.preventDefault(); $('pwdOk').click();
        }
      });
      wrap.appendChild(b);
    }
  }
  function getPin(){
    var boxes = $('pwdPin').querySelectorAll('.pinbox');
    var s = '';
    for(var i=0;i<boxes.length;i++) s += boxes[i].value;
    return s;
  }
  function clearPin(){
    var boxes = $('pwdPin').querySelectorAll('.pinbox');
    for(var i=0;i<boxes.length;i++) boxes[i].value = '';
    if(boxes[0]) boxes[0].focus();
  }

  function openPwdModal(){
    $('pwdChName').textContent = CHANNEL;
    $('pwdErr').textContent = '';
    $('pwdOk').disabled = false;
    $('pwdModal').className = 'modal on';
    setTimeout(function(){ try{ clearPin(); }catch(e){} }, 80);
  }
  function closePwdModal(){ $('pwdModal').className = 'modal'; }
  $('pwdCancel').onclick = function(){
    closePwdModal();
    // 从频道选择器弹出的密码框取消 → 重新打开频道选择器
    if(pwdFromPicker){
      pwdFromPicker = false;
      fetchChannels();
    } else if(!started){
      // 尚未真正进入任何频道（扫码无密码或 picker 流程）时取消密码，
      // 退回频道选择列表，避免卡在空白频道视图。
      fetchChannels();
    }
  };
  $('pwdOk').onclick = function(){
    var k = getPin();
    if(!k){ $('pwdErr').textContent = '请输入频道 PIN'; return; }
    $('pwdErr').innerHTML = '<span class="mloading">验证中…</span>';
    $('pwdOk').disabled = true;
    fetch('/api/auth?ch=' + encodeURIComponent(CHANNEL) + '&k=' + encodeURIComponent(k))
      .then(function(r){ return r.json(); })
      .then(function(d){
        if(d.ok){
          enterChannel(CHANNEL, k);
        } else {
          $('pwdErr').textContent = d.error || '密码不正确';
          $('pwdOk').disabled = false;
          clearPin();
        }
      }).catch(function(){
        $('pwdErr').textContent = '验证请求失败，请检查网络';
        $('pwdOk').disabled = false;
      });
  };
  // 初始化验证码式 PIN 输入框（Enter 提交已绑定到每个方框）。
  buildPinBoxes();

  // 连接状态：带超时 + 可重试，避免"首次请求瞬时失败就永久卡在连接中"。
  // 注意：HTML 已能加载说明主机可达，/api/info 与页面同源同地址；
  // 若首次请求因路由未就绪/瞬时抖动失败，重试通常即可恢复。
  function setHost(text, failed){
    var el = $('hostName');
    el.textContent = text;
    el.style.cursor = failed ? 'pointer' : 'default';
    el.title = failed ? '点击重试' : '';
    el.onclick = failed ? connect : null;
  }
  function connect(){
    setHost('连接中…', false);
    var url = '/api/info?name=' + encodeURIComponent(myName);
    var done = false;
    var fail = function(){
      if (done) return;
      done = true;
      setHost('连接失败 · 点此重试', true);
    };

    // 8 秒超时：优先用 AbortController；旧浏览器/WebView 用 setTimeout 兜底。
    var timer = setTimeout(fail, 8000);
    var opts = {};
    try {
      var ctrl = new AbortController();
      opts.signal = ctrl.signal;
      // AbortController 上的超时与 setTimeout 并行，先完成者生效。
      setTimeout(function(){ try { ctrl.abort(); } catch(e){} }, 8000);
    } catch(e) { /* 不支持 AbortController，setTimeout 已生效 */ }

    fetch(url, opts)
      .then(function(r){ if (!r.ok) throw new Error('http' + r.status); return r.json(); })
      .then(function(d){
        if (done) return;
        done = true;
        clearTimeout(timer);
        serverAddr = d.address || '';
        setHost('已连接 ' + d.name + ' · ' + d.address, false);
        // 拉取网络详情（所有 IP + WiFi 信息）
        fetchNetworkInfo();
      })
      .catch(function(){
      if (done) return;
      done = true;
      clearTimeout(timer);
      setHost('连接失败 · 点此重试', true);
    });
  }

  // ------------------------------------------------------- 网络信息面板
  var netInfo = null;
  var netTimer = null;
  function fetchNetworkInfo(){
    fetch('/api/network?name=' + encodeURIComponent(myName))
      .then(function(r){ return r.json(); })
      .then(function(d){
        netInfo = d;
        renderNetPanel();
      })
      .catch(function(){});
    // 每 30 秒刷新一次（信号强度等会变化）
    if(!netTimer){ netTimer = setInterval(fetchNetworkInfo, 30000); }
  }
  // 连接类型徽章：一眼区分 WiFi / 移动数据 / 以太网，避免把流量当成 WiFi。
  function connTypeHtml(type){
    if(!type) return '';
    var c = connColor(type);
    return '<div class="nettype" style="background:'+c+'1a;border-color:'+c+'55;color:'+c+'">'
      + '<span class="nettype-ic">'+connIcon(type)+'</span>'+esc(type)+'</div>';
  }
  function connColor(t){
    switch(t){
      case 'WiFi': return '#1e88e5';
      case '移动数据': return '#fb8c00';
      case '以太网': return '#8e24aa';
      case 'VPN': return '#fbc02d';
      case 'USB 共享': return '#00acc1';
      case '无网络': return '#9e9e9e';
      default: return '#546e7a';
    }
  }
  function connIcon(t){
    switch(t){
      case 'WiFi': return '\u{1F4F6}';      // 📶
      case '移动数据': return '\u{1F4F1}';  // 📱
      case '以太网': return '\u{1F392}';    // 🔌
      case 'VPN': return '\u{1F512}';       // 🔒
      case 'USB 共享': return '\u{1F517}';  // 🔗
      default: return '\u{1F310}';          // 🌐
    }
  }

  function renderNetPanel(){
    if(!netInfo) return;
    var d = netInfo;
    var rows = '';
    function row(k, v, unit){
      var s = v || '—';
      if(unit && v) s += unit;
      rows += '<div class="k">'+esc(k)+'</div><div class="v">'+esc(s)+'</div>';
    }
    // WiFi 名称
    var ssid = d.wifiName || '';
    // 去掉 iOS/Android 可能返回的前后引号或 <unknown ssid>
    if(ssid && ssid.charAt(0) === '"') ssid = ssid.slice(1, -1);
    if(ssid === '<unknown ssid>') ssid = '';
    row('WiFi 名称', ssid || '—');
    row('WiFi BSSID', d.wifiBssid || '—');
    row('子网掩码', d.subnetMask || '—');
    row('网关', d.gateway || '—');
    // DNS
    var dns = d.dnsServers || [];
    row('DNS 服务器', dns.length ? dns.join('、') : '—');
    // 信号强度
    if(d.signalRssi !== undefined && d.signalRssi !== 0){
      row('信号强度', d.signalRssi + ' dBm（' + (d.signalDescription||'') + '）');
    } else {
      row('信号强度', '—');
    }
    row('服务端口', d.port || '5321');
    // 所有 IP 地址
    var addrs = d.addresses || [];
    var ipHtml = '';
    if(addrs.length){
      ipHtml = '<div class="netips"><div class="netips-title">本机所有可访问 IP（点击复制地址）</div>';
      addrs.forEach(function(a){
        var star = a.primary ? ' star' : '';
        var url = 'http://' + a.ip + ':' + (d.port||5321) + '/';
        ipHtml += '<div class="ipchip'+star+'" data-url="'+esc(url)+'" data-ip="'+esc(a.ip)+'">'
          + '<span class="ip">'+esc(a.ip)+'</span>'
          + (a.type ? '<span class="iptype">'+esc(a.type)+'</span>' : '')
          + (a.primary ? '<span class="iptype" style="background:#00897b;color:#fff">主</span>' : '')
          + '<span class="ipcopy">&#x1F4CB;</span>'
          + '</div>';
      });
      ipHtml += '</div>';
    }
    $('netPanel').innerHTML = connTypeHtml(d.connectionType) + '<div class="netgrid">'+rows+'</div>' + ipHtml;
    // 绑定 IP 点击：复制完整 URL
    Array.prototype.forEach.call($('netPanel').querySelectorAll('.ipchip'), function(el){
      el.onclick = function(){
        var url = el.getAttribute('data-url');
        var ip = el.getAttribute('data-ip');
        // 优先用 Clipboard API，回退到 textarea
        if(navigator.clipboard && navigator.clipboard.writeText){
          navigator.clipboard.writeText(url).then(function(){
            flashCopy(el, '已复制');
          }, function(){
            fallbackCopy(url, el);
          });
        } else {
          fallbackCopy(url, el);
        }
      };
    });
  }
  function flashCopy(el, msg){
    var orig = el.querySelector('.ipcopy').innerHTML;
    el.querySelector('.ipcopy').innerHTML = '&#x2705; ' + msg;
    setTimeout(function(){ el.querySelector('.ipcopy').innerHTML = orig; }, 1500);
  }
  function fallbackCopy(text, el){
    var ta = document.createElement('textarea');
    ta.value = text; ta.style.position='fixed'; ta.style.opacity='0';
    document.body.appendChild(ta); ta.select();
    try{ document.execCommand('copy'); flashCopy(el, '已复制'); }catch(e){}
    document.body.removeChild(ta);
  }
  // 网络面板展开/折叠
  $('netBtn').onclick = function(){
    var p = $('netPanel');
    var btn = $('netBtn');
    var on = p.className.indexOf(' on') >= 0;
    if(on){
      p.className = 'netpanel'; btn.className = 'netbtn';
    } else {
      p.className = 'netpanel on'; btn.className = 'netbtn on';
      if(netInfo){ renderNetPanel(); } // 有缓存先立即渲染，避免“时有时无”
      fetchNetworkInfo();              // 再拉一次最新数据
    }
  };

  // 标签页：频道 / 私聊 / 剪贴板 三视图切换。
  function switchView(name){
    // 关键修正：切走前先把"当前聊天视图"的消息持久化到对应存储键
    // （此时 p2pMode 仍是旧值，key 才正确），避免两模式串台。
    persistMessages();
    view = name;
    p2pMode = (name === 'p2p');

    // 标签高亮
    $('tabChannel').className = name==='channel' ? 'tab on' : 'tab';
    $('tabP2P').className = name==='p2p' ? 'tab on' : 'tab';

    // 频道 / 私聊视图始终显示
    $('list').style.display = '';
    $('chatFooter').style.display = 'block';

    // 频道 / 私聊视图
    $('text').placeholder = p2pMode ? '输入私聊消息…' : '输入消息…';
    document.querySelector('header').style.background = p2pMode ? '#6a1b9a' : '#00897b';
    if(p2pMode){
      $('chName').textContent = '点对点';
      $('lock').textContent = '';
    } else {
      $('chName').textContent = channelJoined ? (CHANNEL || '公共频道') : '请选择频道';
      $('lock').textContent = KEY ? '\u{1F512}' : '';
    }
    var emptyMsg;
    if(p2pMode){
      emptyMsg = '暂无私聊消息<br>在下方输入消息即可与主机设备私聊';
    } else {
      emptyMsg = CHANNEL ? '暂无频道消息<br>发送文字或文件试试' : '请点击上方频道名选择频道';
    }
    $('list').innerHTML = '<div class="empty">' + emptyMsg + '</div>';
    seen = {}; seenMeta = {};
    since = 0; sinceP2P = 0;
    restoreMessages();  // 尝试从 localStorage 恢复新视图的缓存（按新视图严格过滤）
    poll();
  }
  $('tabChannel').onclick = function(){ switchView('channel'); };
  $('tabP2P').onclick = function(){ switchView('p2p'); };

  // ---------------------------------------------------------- 选择文件
  $('btnFile').onclick = function(){ $('file').click(); };
  $('file').onchange = function(e){
    var fs = Array.prototype.slice.call(e.target.files || []);
    fs.forEach(function(f){
      if(f.size > 80*1024*1024){ setStatus('「'+f.name+'」超过 80MB，已跳过'); return; }
      var rd = new FileReader();
      rd.onload = function(){
        picked.push({ name:f.name, size:f.size, mime:f.type||'application/octet-stream', data:rd.result });
        renderPicked();
      };
      rd.readAsDataURL(f);
    });
    e.target.value = '';
  };

  function renderPicked(){
    var box = $('picked');
    box.innerHTML = picked.map(function(f,i){
      return '<div class="chip"><b>'+esc(f.name)+'</b><i data-i="'+i+'">&times;</i></div>';
    }).join('');
    Array.prototype.forEach.call(box.querySelectorAll('i'), function(el){
      el.onclick = function(){ picked.splice(+el.getAttribute('data-i'),1); renderPicked(); };
    });
    refreshSend();
  }

  function refreshSend(){
    $('btnSend').disabled = sending || (!$('text').value.trim() && picked.length===0);
  }
  $('text').oninput = function(){
    // 同步清空 → 读真实 scrollHeight → 回设，浏览器合为一帧不闪。
    // min-height:38px 确保不会真的缩到 0。
    this.style.height = '0px';
    this.style.height = Math.min(this.scrollHeight, 96) + 'px';
    refreshSend();
  };

  // ------------------------------------------------------------ 发送
  $('btnSend').onclick = function(){
    var text = $('text').value.trim();
    if(!text && picked.length===0) return;
    if(!myName){ openNameModal(); return; }
    sending = true; refreshSend(); busy(true); setStatus('发送中…');
    var body = { from:myName, text:text, files:picked };
    if(p2pMode){
      // 私聊：发给已连接的主机 App
      body.target = serverAddr || '127.0.0.1:5321';
    } else {
      body.channel = CHANNEL;
      body.k = KEY;
    }
    fetch('/api/send', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify(body)
    }).then(function(r){ return r.json(); }).then(function(d){
      if(d.ok){
        $('text').value=''; $('text').style.height='auto';
        picked=[]; renderPicked(); setStatus(d.detail||'已发送');
        poll();
      } else {
        setStatus('发送失败：' + (d.error||'未知错误'));
      }
    }).catch(function(err){
      setStatus('发送失败：' + err);
    }).finally(function(){
      sending=false; busy(false); refreshSend();
    });
  };

  // ------------------------------------------------------------ 轮询
  function fileHtml(f){
    var url = '/api/file?id=' + encodeURIComponent(f.id);
    if(f.mime && f.mime.indexOf('image/')===0){
      return '<a class="fitem" href="'+url+'" download><div class="fmeta">'
           + '<img class="thumb" src="'+url+'&inline=1" alt="'+esc(f.name)+'">'
           + '<div class="fname">'+esc(f.name)+'</div>'
           + '<div class="fsize">'+fmtSize(f.size)+' · 点击下载</div></div></a>';
    }
    return '<a class="fitem" href="'+url+'" download><div class="ficon">&#128196;</div>'
         + '<div class="fmeta"><div class="fname">'+esc(f.name)+'</div>'
         + '<div class="fsize">'+fmtSize(f.size)+' · 点击下载</div></div></a>';
  }
  function fmtSize(n){
    if(n<1024) return n+' B';
    if(n<1048576) return (n/1024).toFixed(1)+' KB';
    return (n/1048576).toFixed(1)+' MB';
  }
  function fmtTime(ms){
    var d=new Date(ms), p=function(x){return x<10?'0'+x:x;};
    return p(d.getHours())+':'+p(d.getMinutes());
  }

  function append(m){
    if(seen[m.id]) return;
    // 用服务端下发的 p2p 标志精确判断（兜底：空 channel 且无 p2p 标记也视为 P2P）。
    var isP2PMsg = (m.p2p === true) || (!m.channel && m.channel !== 0);
    if (p2pMode) {
      // 私聊模式：只接受 P2P 消息（点对点消息）
      if (!isP2PMsg) return;
    } else {
      // 频道模式：仅展示已加入频道、且属于当前频道的消息；
      // 公共频道消息 channel='公共频道'（非空），因此不会被误判为 P2P。
      if (!channelJoined) return;
      if (isP2PMsg) return;
      if (m.channel !== CHANNEL) return;
    }
    seen[m.id]=1;
    // 存一份元数据供 persistMessages 用。
    seenMeta[m.id] = { id:m.id, from:m.from, text:m.text||'', time:m.time, channel:m.channel||'', p2p:m.p2p===true, files:(m.files||[]).slice(0,5) };
    renderMsg(m);
  }

  function renderMsg(m){
    var list=$('list');
    if(list.querySelector('.empty')) list.innerHTML='';
    var mine = (m.from === myName);
    var initial = (m.from||'?').trim().charAt(0).toUpperCase();
    var body = '';
    if(m.text) body += esc(m.text);
    var fh = (m.files||[]).map(fileHtml).join('');
    var cls = 'bubble' + (!m.text && fh ? ' only-files' : '');
    // 消息类型标签：频道消息显示频道名，私聊消息显示"私聊"
    var isP2PMsg = (m.p2p === true) || (!m.channel && m.channel !== 0);
    var tagHtml;
    if (isP2PMsg) {
      tagHtml = '<span class="msg-tag p2p">私聊</span>';
    } else {
      tagHtml = '<span class="msg-tag ch">#' + esc(m.channel) + '</span>';
    }
    var html = '<div class="row'+(mine?' me':'')+'" data-id="' + esc(m.id) + '">'
      + '<div class="avatar">'+esc(initial)+'</div>'
      + '<div class="bubblewrap">'
      + (mine?'':'<div class="who">'+tagHtml+esc(m.from)+'</div>')
      + '<div class="'+cls+'">'+body+(fh?'<div class="files">'+fh+'</div>':'')+'</div>'
      + '<div class="time">'+fmtTime(m.time)+'</div>'
      + '</div></div>';
    list.insertAdjacentHTML('beforeend', html);
    list.scrollTop = list.scrollHeight;
  }

  // ---------- 消息持久化 key（按频道/私聊隔离，避免消息混入） ----------
  function msgStoreKey(){
    if (p2pMode) return 'everlink_msgs__p2p';
    // 频道模式：已加入则用真实频道名作 key（公共频道→everlink_msgs_公共频道，
    // 与私聊的 everlink_msgs__p2p 完全隔离）；未加入则用临时 key，不会被读回。
    return channelJoined ? ('everlink_msgs_' + CHANNEL) : 'everlink_msgs__none';
  }

  // 从 localStorage 恢复消息 DOM（页面重载 / WebView 被回收时可救回）。
  // 严格按“当前视图”过滤，杜绝另一模式的消息串台；同时回填 seenMeta，
  // 保证后续 persistMessages 不会把恢复出来的消息漏掉。
  function restoreMessages(){
    try {
      var raw = localStorage.getItem(msgStoreKey());
      if (!raw) return;
      var saved = JSON.parse(raw);
      if (!Array.isArray(saved)) return;
      var list = $('list');
      if (list.querySelector('.empty')) list.innerHTML = '';
      var maxT = 0;
      saved.forEach(function(m){
        var isP2P = (m.p2p === true) || (!m.channel && m.channel !== 0);
        if (p2pMode) {
          if (!isP2P) return;            // 私聊视图只恢复私聊消息
        } else {
          if (isP2P) return;             // 频道视图只恢复频道消息
          if (!channelJoined) return;
          if (m.channel !== CHANNEL) return;
        }
        seen[m.id] = 1;
        seenMeta[m.id] = m;              // 复用缓存元数据，避免下次持久化时丢失
        if (m.time > maxT) maxT = m.time;
        renderMsg(m);
      });
      // 恢复 since 水位：取已缓存消息中的最大 time，避免重复拉取。
      if (maxT > 0) {
        if (p2pMode) { sinceP2P = Math.max(sinceP2P, maxT); }
        else { since = Math.max(since, maxT); }
      }
    } catch(e) { /* localStorage 不可用或数据损坏，忽略 */ }
  }

  // 持久化当前全部消息到 localStorage（最多 100 条，超出裁头）。
  function persistMessages(){
    try {
      var all = [];
      // 从 DOM 反序列化消息元数据：仅保留 id / from / text / time / channel / files（元信息）。
      var rows = $('list').querySelectorAll('.row');
      rows.forEach(function(row){
        var id = row.getAttribute('data-id');
        if (!id) return;
        var m = seenMeta[id];
        if (m) all.push(m);
      });
      if (all.length > 100) all = all.slice(-100);
      localStorage.setItem(msgStoreKey(), JSON.stringify(all));
    } catch(e) {}
  }
  var seenMeta = {};  // id → 消息元数据，供 persistMessages 使用
  function poll(){
    if (polling) return;  // 上一轮尚未返回，跳过本次
    // 剪贴板视图下不轮询聊天消息
    if (view === 'clip') { polling = false; return; }
    // 频道模式下未加入任何频道 → 不拉取，避免返回 P2P 消息；
    // 用 channelJoined 判定（公共频道对 CHANNEL 有真实值，不会误判）。
    if (!p2pMode && !channelJoined) { polling = false; return; }
    polling = true;
    var ch = p2pMode ? '' : CHANNEL;
    var ref = p2pMode ? sinceP2P : since;
    var u = '/api/messages?ch=' + encodeURIComponent(ch)
          + '&since=' + ref + '&k=' + encodeURIComponent(KEY)
          + '&name=' + encodeURIComponent(myName);
    fetch(u).then(function(r){ return r.json(); }).then(function(d){
      var msgs = d.messages || [];
      if (msgs.length > 0) {
        msgs.forEach(function(m){
          if (p2pMode) {
            if(m.time > sinceP2P) sinceP2P = m.time;
          } else {
            if(m.time > since) since = m.time;
          }
          append(m);
        });
        persistMessages();
      }
    }).catch(function(){}).finally(function(){
      polling = false;
    });
  }
  // 启动应用：连接服务器 + 恢复消息 + 开始轮询。
  var started = false;
  function startApp(){
    connect();
    restoreMessages();
    poll();
    if(!started){ started = true; setInterval(poll, 1500); }
  }

  // 页面关闭/跳转前通知服务器断开连接，立即移除设备列表中的入口。
  window.addEventListener('beforeunload', function(){
    navigator.sendBeacon('/api/disconnect');
  });

  // -------------------------------------------- 频道选择（无需扫码直接进入）
  function openPicker(){ $('channelPicker').className = 'modal on'; }
  function closePicker(){ $('channelPicker').className = 'modal'; }

  function renderChannels(list){
    var box = $('channelList');
    if(!list || !list.length){
      box.innerHTML = '<div class="empty">暂无可加入的频道<br>请在 App 中创建或加入频道</div>';
      return;
    }
    box.innerHTML = list.map(function(c){
      var lock = c.private ? '<span class="clock">\u{1F512}</span>' : '';
      return '<div class="chitem" data-name="'+esc(c.name)+'" data-private="'+(c.private?1:0)+'">'
           + '<div class="chname">'+esc(c.name)+' '+lock+'</div>'
           + '<div class="chenter">进入</div></div>';
    }).join('');
    Array.prototype.forEach.call(box.querySelectorAll('.chitem'), function(el){
      el.onclick = function(){
        selectChannel(el.getAttribute('data-name'), el.getAttribute('data-private')==='1');
      };
    });
  }

  function fetchChannels(){
    fetch('/api/channels')
      .then(function(r){ return r.json(); })
      .then(function(d){
        renderChannels((d && d.channels) || []);
        openPicker();
      })
      .catch(function(){
        renderChannels([]);
        openPicker();
      });
  }

  function selectChannel(name, isPrivate){
    $('chErr').textContent = '';
    closePicker();  // 先关闭频道选择器，避免与密码弹窗叠加
    if(isPrivate){
      // 私有频道：复用密码弹窗，验证成功由 pwdOk 调 enterChannel。
      CHANNEL = name;
      KEY = '';
      pwdFromPicker = true;
      openPwdModal();
    } else {
      pwdFromPicker = false;
      enterChannel(name, '');
    }
  }

  // 进入某个频道：设置上下文并切到频道视图，确保只启动一次轮询。
  function enterChannel(name, key){
    CHANNEL = name;
    KEY = key;
    channelJoined = true;
    needPwd = false;
    pwdFromPicker = false;
    closePicker();
    closePwdModal();
    if(!started){ startApp(); }
    switchView('channel');  // switchView 会统一更新 header 显示
  }

  // 进入点对点（私聊）视图。
  function enterP2P(){
    // 不清空 CHANNEL/KEY：用户从私聊切回频道时仍能恢复之前的频道消息
    closePicker();
    closePwdModal();
    if(!started){ startApp(); }
    switchView('p2p');
  }

  $('chCancel').onclick = enterP2P;

  // 复制文本到剪贴板，并在按钮上给出"已复制"反馈（与 IP 复制共用 Clipboard API）。
  function copyClip(text, btn){
    function flash(){
      if(!btn) return;
      var o = btn.textContent;
      btn.classList.add('done');
      btn.textContent = '已复制';
      setTimeout(function(){ btn.classList.remove('done'); btn.textContent = o; }, 1400);
    }
    if(navigator.clipboard && navigator.clipboard.writeText){
      navigator.clipboard.writeText(text).then(flash, function(){ copyClipFallback(text, btn); });
    } else {
      copyClipFallback(text, btn);
    }
  }
  function copyClipFallback(text, btn){
    var ta = document.createElement('textarea');
    ta.value = text; ta.style.position='fixed'; ta.style.opacity='0';
    document.body.appendChild(ta); ta.select();
    try{ document.execCommand('copy'); if(btn){ var o=btn.textContent; btn.classList.add('done'); btn.textContent='已复制'; setTimeout(function(){ btn.classList.remove('done'); btn.textContent=o; }, 1400);} }catch(e){}
    document.body.removeChild(ta);
  }

  // 初始化：
  //  - 扫码带频道且需密码 → 弹密码框；
  //  - 扫码带频道且免密码（公共频道）或无密码参数 → 直接进入；
  //  - 直接输入 IP（无频道参数）→ 拉取频道列表，让用户直接选公共频道等。
  function init(){
    fetchNetworkInfo(); // 立即启动网络信息轮询（不依赖 connect 是否成功）
    connect(); // 先连上主机，拿到 serverAddr 并展示连接状态
    if(CHANNEL && !KEY){
      fetch('/api/auth?ch=' + encodeURIComponent(CHANNEL))
        .then(function(r){ return r.json(); })
        .then(function(d){
          if(d.needPassword){
            needPwd = true;
            $('lock').textContent = '\u{1F512}';
            openPwdModal();
          } else {
            startApp();
          }
        })
        .catch(function(){ startApp(); });
    } else if (CHANNEL && KEY) {
      startApp();
    } else {
      fetchChannels();
    }
  }
  init();
})();
</script>
</body>
</html>
''';
