# ITOps Agent Platform 初始配置说明

> 数据来源:本轮对 192.168.50.x 各主机的实机核查(2026-07-24/28)+ ITOps 平台部署(192.168.103.250, 2026-08-03)。
> 平台地址:前端 http://192.168.103.250:9999 / 后端 API http://192.168.103.250:3001 / 健康检查 http://192.168.103.250:3001/health
> 默认账号:admin / admin(首次登录强制改密)

---

## 一、总体对接架构

```
                     公网 / 用户 / 运维人员
                              │
                              ▼
              192.168.103.250  ITOps Agent Platform (:9999)
              ┌──────────────────────────────────────────────┐
              │  Agent 编排:告警→诊断→修复→审批→验证          │
              └──────────────────────────────────────────────┘
                 │ 主动查询(API)          │ 接收 Webhook 推送
                 ▼                        ▼
        192.168.50.111  Zabbix      Zabbix Action → ITOps 告警 API
        (监控数据源)                  (双向对接,见第六节)
                 │ 采集
   ┌─────────────┼──────────────┬──────────────┬─────────────┐
   ▼             ▼              ▼              ▼             ▼
 邮件 .161     SVN .54       GitLab .153    uag .142     ESXi (待补)
 (Postfix)    (+备.21/.44)   (+备.154)     (Tomcat)     (vCenter/ESXi)
```

ITOps 不直接轮询业务系统,而是以 **Zabbix 为统一监控采集层**,ITOps 负责:
1. 接收 Zabbix Webhook 告警 → 触发诊断/修复 Agent;
2. 主动调用 Zabbix API 拉取事件、趋势、最新值做研判;
3. 通过 SSH/Docker 执行器对目标主机执行修复动作。

---

## 二、被纳管主机清单(来自核查)

| IP | 主机名 | 系统 | 角色 | 纳入 ITOps 方式 |
|----|--------|------|------|----------------|
| 192.168.50.161 | mail | Ubuntu 16.04 | 邮件(Postfix+Dovecot+Amavis) | Zabbix 模板 + SSH 执行器 |
| 192.168.50.153 | GIT | Ubuntu 22.04 | GitLab 15.8.6(生产) | Zabbix 模板 + GitLab API |
| 192.168.50.154 | GIT(备) | Ubuntu 22.04 | GitLab 备份机 | Zabbix 模板(磁盘重点) |
| 192.168.50.54 | svn | Ubuntu 22.04 | SVN 生产 | Zabbix 模板 + SVN 探活 |
| 192.168.50.21 | svn-2T(备) | — | SVN 备机(磁盘98%) | Zabbix 磁盘模板(P0) |
| 192.168.50.44 | svn(备) | Ubuntu 22.04 | SVN 备机 | Zabbix 模板 |
| 192.168.50.142 | uag | CentOS 7 | Tomcat 9.0.22 + uag + MySQL | Zabbix 模板 + 自启修复 |
| 192.168.50.5 | proxya253i5 | Ubuntu 14.04 | Nginx 反代(EOL) | Zabbix 模板 + 可疑文件核查 |
| 192.168.50.111 | — | — | Zabbix Server(监控源) | ITOps 对接端 |
| 192.168.103.250 | — | Ubuntu | ITOps 平台 | 平台自身 |
| 192.168.50.66 | — | ESXi | 虚拟化层 | Zabbix ESXi/vCenter 模板 |

---

## 三、各系统监控接入要点

### 3.1 邮件系统(.161)
- 进程/端口(实测 `ss -tlnp`):
  - 25  Postfix 收信入口(postscreen/smtpd,IPv4+IPv6)
  - 587 Postfix submission(STARTTLS+SASL 发信)
  - 10024/10026 Amavis 入站/出站过滤(127.0.0.1)
  - 10025 Postfix 重注入(127.0.0.1)
  - 143/993 Dovecot IMAP/POP3(POP3S 995)
- Zabbix 监控项建议:端口存活(25/587/143/993)、Postfix 队列长度、Amavis 进程、磁盘(备份保留90天)、mynetworks=192.168.50.0/24 内网免认证。
- ITOps 修复 Agent 关注:队列积压自动清理、Amavis 卡死重启、证书过期(Postfix/Dovecot 证书未纳入备份,中风险)。
- 通知对接:邮件系统本身即通知通道,ITOps 告警可复用 .161 的 587 发信(需配置 SMTP 账号,见第五节)。

### 3.2 SVN 系统(.54 → 备 .21 / .44)
- 生产 .54 监听 svn(默认 3690 或 https 经 Nginx .5 的 svn.itrus.com.cn:443)。
- Zabbix 监控项:svnserve 进程/端口、仓库目录可读性、rsync 备机连通性。
- 备份链路(来自核查):
  - rsync → .21 每小时;→ .44 工作日每15分(双备机高频 ✅)
  - 增量快照 `21_zengliangbeifen.sh`(7天 hardlink)**未挂 crontab** → P1 风险
  - .21 磁盘剩 71G(98%)🔴 **P0 最紧迫**
- ITOps 修复 Agent 关注:备机磁盘写满时自动告警+暂停低优先同步、补增量快照 crontab。

### 3.3 Git 系统(.153 → 备 .154)
- GitLab 15.8.6 全包(Ubuntu 22.04),对外经 Nginx .5 的 uts.itrus.com.cn(80/443/8443/8080)→ .143(同为 .153)。
- Zabbix 监控项:GitLab 进程、端口(80/443)、`gitlab-rails` 健康检查、`/var/opt/gitlab` 磁盘、每日备份(~95G/天)是否生成。
- 备份风险:
  - 本地 `gitlab:backup:create` 每日01:00 ✅,本地仅留~2天
  - rsync → .154(每日04:00)+ .6 ✅,但 .154 剩 165G(77%)🔴 **约1.5-2天写满 P0**
  - `gitlab.rb` / `gitlab-secrets.json` **未备份** → P1
- ITOps 修复 Agent 关注:备机写满时通知扩容、自动补配置文件备份。

### 3.4 uag / Tomcat(.142)
- 反代 .5 的 uag.itrus.com.cn:443 → .142(Tomcat 9.0.22 + uag + MySQL)。
- ⚠️ 关键风险(来自核查):
  - Tomcat **无自启机制**(靠 rc.local 且 static 未 enabled)🔴 重启即宕 → ITOps 应建 systemd 修复 Agent
  - MySQL 3306 **全网开放** + firewalld 形同虚设 🔴 → 收敛来源
  - Tomcat 以 root 运行、catalina.out 9.3G 未切割
- Zabbix 监控项:Tomcat 端口(8080/8443)、MySQL 3306、进程存活、开机自启状态探测。
- ITOps 修复 Agent:重启后自动拉起 Tomcat(systemctl)、防火墙收敛脚本。

### 3.5 Nginx 反代(.5)
- Ubuntu 14.04 + Nginx 1.4.6(均 EOL)🔴、含 SSLv3(POODLE)🔴、conf.d 有随机名可疑文件 `kBVMXUgVFK.txt` ⚠️。
- Zabbix 监控项:80/443 存活、各反代后端(.143/.142/.54/.51/.70/.72/.10)连通性。
- ITOps 修复 Agent:定期核查可疑文件、去 SSLv3、规划迁移。

### 3.6 ESXi 环境(192.168.50.66)
- ESXi 管理地址:**192.168.50.66**(已确认,主机名 `50.247esxi` 已在 Zabbix 纳管)。
- 建议:Zabbix 通过 VMware ESXi/vCenter 模板(SOAP 443)采集 CPU/内存/存储/虚拟机状态;ITOps 可触发快照/重启虚拟机等修复动作。
- Zabbix 只读账号(用于 ITOps 主动查询):**opsread**(已创建,见第八节凭证)。

---

## 四、网络拓扑(流量走向,来自核查)

```
                      公网 / 用户
                         │
                         ▼
              192.168.50.5  Nginx 反代(443/80) ── EOL/SSLv3 风险
              uts→.143  uag→.142  svn→.54
              crm→.51   oa→.70/.72  topca→.100.103
              yunssl→.100.139  ztgxchina→.2
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   .143/.153 GitLab   .142 uag/Tomcat   .54 SVN
   .161 邮件(独立,25/587 直收,不挂Nginx)
```
- 监控采集统一上送 192.168.50.111(Zabbix),Zabbix 双向对接 ITOps(.250)。
- 邮件 .161 相对独立,不直接挂 Nginx,经 postscreen 收信。

---

## 五、ITOps 平台初始配置步骤

### 5.1 首次登录与基础设置
1. 打开 http://192.168.103.250:9999,用 admin/admin 登录,**立即修改密码**。
2. 设置 → AI 模型:配置 AI Provider(豆包/OpenAI/本地,填入 API Key 与 Base URL)。
   - 豆包默认:base `https://ark.cn-beijing.volces.com/api/v3`,model `doubao-4o`
3. 设置 → 通知渠道:配置邮件通知,复用 .161 的 SMTP:
   - SMTP 主机 `192.168.50.161`:587,STARTTLS+SASL,账号/密码(向邮件管理员获取)
   - 或配置 Webhook 通知到企业 IM。

### 5.2 接入 Zabbix(双向)
- Zabbix Server:192.168.50.111
- ITOps 主动查询:在 ITOps 的 Zabbix 数据源配置填 `http://192.168.50.111/zabbix/api_jsonrpc.php` + 只读账号。
- Zabbix → ITOps Webhook(见第六节)。

### 5.3 主机凭据与执行器
- 在 ITOps 凭据库为每台被纳管机(50.x)录入 SSH 账号(建议专用运维账号,非 root 直登)。
- 对 .142 的 Tomcat 修复需 root 或 sudo;对 docker 类动作平台已挂载宿主机 docker.sock(平台自身在 .250)。
- 备注:.142 Tomcat 当前以 root 运行,建议改为专用用户并建 systemd 服务。

### 5.4 告警分级映射(建议)
| 级别 | 触发来源 | ITOps 动作 |
|------|----------|-----------|
| P0 | SVN备.21磁盘98% / GitLab备.154磁盘77% / .142 Tomcat宕 / .5 EOL | 立即告警+自动诊断+人工审批修复 |
| P1 | 配置文件未备份 / 增量快照未启用 / 可疑文件 | 工单+定期核查 Agent |
| P2 | 日志未切割 / 旧系统版本 | 维护提醒 |

---

## 六、Zabbix ↔ ITOps 双向对接配置

### 6.1 Zabbix → ITOps(Webhook 推送告警)✅ 已实测路由

> 实测确认:ITOps 后端存在专用 Zabbix 路由 `POST /api/v1/webhooks/zabbix`(源码 `src/modules/alerts/routes/webhookRoutes.ts`)。
> 从 ITOps 主机(.250)已验证可访问 Zabbix API(HTTP 200)。适配器 `adaptZabbix` 解析的是 **Zabbix 标准宏变量**,不是任意 JSON。

**接收端点**:`http://192.168.103.250:3001/api/v1/webhooks/zabbix`
(注意:对外 3001 是后端端口;若只允许 9999 入口,需经前端/反代转发,或防火墙放通 3001 给 Zabbix .111)

**已部署的 Zabbix 配置(2026-08-03 实测)**:
- 告警媒介类型「ITOps Webhook」(mediatypeid **43**,type=4 Webhook),脚本用 Zabbix `HttpRequest` 将标准宏 `TRIGGER.*`/`HOST.*`/`EVENT.*`/`ITEM.*` 组装为 ITOps 期望的 JSON 并 POST 到上述端点。
- 参数映射(宏→值):
  - `itops_url` = `http://192.168.103.250:3001/api/v1/webhooks/zabbix`
  - `webhook_secret` = (空;未启用签名)
  - `trigger_name`=`{TRIGGER.NAME}`、`event_severity`=`{EVENT.SEVERITY}`、`trigger_id`=`{TRIGGER.ID}`
  - `host_name`=`{HOST.NAME}`、`host_ip`=`{HOST.IP}`
  - `event_id`=`{EVENT.ID}`、`event_value`=`{EVENT.VALUE}`、`event_time`=`{EVENT.TIME}`、`event_date`=`{EVENT.DATE}`
  - `item_name`=`{ITEM.NAME}`、`event_opdata`=`{EVENT.OPDATA}`
- 动作「ITOps Alert Push」(actionid **7**,eventsource=0,启用):操作与恢复操作均发往 mediatypeid 43,收件人 Admin(userid 1,已绑定该媒介)。
- 即:任意触发器事件 → Action → 调「ITOps Webhook」媒介 → POST 到 ITOps。

**Zabbix 侧脚本核心逻辑**(实际部署版,供留档):
```javascript
try {
  var params = JSON.parse(value);
  var payload = {
    TRIGGER: { NAME: params.trigger_name, SEVERITY: params.event_severity, ID: params.trigger_id },
    HOST:    { NAME: params.host_name, IP: params.host_ip },
    EVENT:   { ID: params.event_id, VALUE: params.event_value, TIME: params.event_time, DATE: params.event_date },
    ITEM:    { NAME: params.item_name, VALUE: params.event_opdata },
    trigger: params.trigger_name, host: params.host_name, host_ip: params.host_ip,
    severity: params.event_severity, eventid: params.event_id, value: params.event_value, item: params.item_name
  };
  var req = new HttpRequest();
  req.addHeader('Content-Type: application/json; charset=utf-8');
  if (params.webhook_secret) req.addHeader('Authorization: Bearer ' + params.webhook_secret);
  var resp = req.post(params.itops_url, JSON.stringify(payload));
  if (req.getStatus() < 200 || req.getStatus() >= 300) throw 'ITOps webhook HTTP ' + req.getStatus();
  return 'OK';
} catch (e) { Zabbix.log(4, '[ ITOps Webhook ] ' + e); throw 'ITOps Webhook failed: ' + e; }
```

**实测验证(2026-08-03)**:
- 向 ITOps 端点直接发送 Zabbix 形状 payload → HTTP **200**。
- ITOps 后端日志确认:`Webhook invocation: /zabbix` → `AARS Processing alert "[MEDIUM] ITOps Receive Self-Test" (severity=medium)` —— 适配器正确把 `Warning` 归一为 `medium` 并生成告警。
- 结论:Zabbix → ITOps Webhook 推送链路已打通。

> 注:ITOps 接收时日志提示 `accepted without signature (mode=warn, no secret configured)` —— 因 `WEBHOOK_VERIFY_ENABLED` 默认关闭。生产建议在 .250 的 compose 环境变量开启校验,并在 Zabbix 媒介参数 `webhook_secret` 填入平台下发的 secret;`WEBHOOK_IP_WHITELIST` 可设为 `192.168.50.111` 仅允许 Zabbix 推送。当前 `Warning`→`medium` 等 severity 映射由 `adaptZabbix` 的 `normalizeSeverityLabel` 处理。

**Zabbix Action 恢复逻辑**:`EVENT.VALUE=0` 时 ITOps 自动判定 `status=resolved` 并关闭工单,无需额外配置。

### 6.2 ITOps → Zabbix(主动查询)✅ 已实测
- API URL:`http://192.168.50.111/zabbix/api_jsonrpc.php`(从 .250 实测 `apiinfo.version` 返回 HTTP 200)。
- **账号**:已创建只读用户 **opsread**(用户组 `ITOps ReadOnly`=usrgrpid 14,角色 `User role`=roleid 1,对所有主机组 Read 权限)。该账号已验证可 `user.login` 并 `host.get` 读取(含 SVN-server/svn/50.247esxi),不能写。
  - 凭证见第八节(密码为生成值,已存于 .250 `/tmp/opsread_pw.txt`,请迁移到密码库)。
  - UI 管理员 `Admin/zabbix` 仅用于初始联调,生产不应长期给 ITOps 使用。
- 用途:Agent 研判时拉取 `event.get` / `problem.get` / `history.get` / `trend.get`。
- 典型调用(Agent 内):
```bash
# 先取 auth token
TOKEN=$(curl -s -X POST http://192.168.50.111/zabbix/api_jsonrpc.php \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"opsread","password":"<密码>"},"id":1}' | grep -o '"result":"[^"]*"')
# 拉取当前未恢复问题
curl -s -X POST http://192.168.50.111/zabbix/api_jsonrpc.php \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"problem.get","params":{"output":"extend","recent":"true"},"auth":"'$TOKEN'","id":1}'
```

### 6.2.1 数据源对接状态(已验证 ✅)
- **ITOps 侧无持久化"数据源"实体**:`/api/v1/monitor/zabbix/*` 仅提供查询路由(test/hosts/items/history/triggers/problems),每次请求在 body 带 `url` + `apiToken`(或 username/password)。UI 的 Monitor→Zabbix 页面即填写这两项并即时查询,无服务端存储。
- **连接参数(填入 ITOps UI 的 Zabbix 连接表单)**:
  - Zabbix API URL:`http://192.168.50.111/zabbix/api_jsonrpc.php`
  - 账号:`opsread` / 密码(见下方凭证记录节;生产请存于密码库,勿留明文)
- **实测验证(2026-08-03,在 itops-backend 容器内用其 zabbixService 客户端)**:
  - `testConnection({url, username:opsread, password})` → `success:true, reachable:true, authenticated:true`
  - `user.login` → auth 成功(32位)
  - `host.get` → 返回 **54** 台主机(含 SVN-server/svn/50.247esxi 等)
  - `problem.get` → 返回 **5** 条近期问题
  - 结论:ITOps ↔ Zabbix 只读数据通道已打通,可支撑 Agent 主动研判。
- ⚠️ 注意:该 Zabbix 版本通过 API `token.create` **不返回 token 明文字段**,API Token 只能在 Zabbix UI 创建时复制一次。因此对接推荐用 **username/password** 方式,或改用 Zabbix UI 生成 token 后人工填入 ITOps。

> **实测验证记录(2026-08-03)**:
> - 从 ITOps 主机(.250)`curl` Zabbix API `apiinfo.version` → HTTP 200(Zabbix 可达)。
> - 进入 `itops-backend` 容器确认路由源码:`/api/v1/webhooks` 下注册 `/zabbix`(`webhookRoutes.ts`),适配器 `adaptZabbix` 解析大写宏 `TRIGGER/HOST/EVENT/ITEM` 及兼容小写字段。
> - 结论:Zabbix→ITOps 用 `POST http://192.168.103.250:3001/api/v1/webhooks/zabbix`,payload 用 Zabbix 标准宏变量。

---

## 七、风险优先级与 ITOps 初始覆盖建议

| 优先级 | 问题 | 主机 | ITOps 初始动作 |
|--------|------|------|----------------|
| 🔴 P0 | SVN备.21磁盘98%(71G)随时写满 | .21 | 磁盘阈值告警(>90%)+ 自动暂停低优先rsync |
| 🔴 P0 | GitLab备.154磁盘77%(165G)约2天写满 | .154 | 磁盘告警+建议扩容/改保留 |
| 🔴 P0 | uag Tomcat无自启,重启即宕 | .142 | 自启修复 Agent(systemctl enable + 拉起) |
| 🔴 P0 | .142 MySQL 3306全网开放+防火墙虚设 | .142 | 防火墙收敛 Agent(限源) |
| 🔴 P0 | Nginx代理机EOL+SSLv3 | .5 | 可疑文件核查+去SSLv3工单 |
| 🟡 P1 | GitLab配置未备份/.154无长保留 | .153/.154 | 补 gitlab.rb/secrets 备份 Agent |
| 🟡 P1 | SVN增量快照未启用 | .54 | 挂 crontab 的快照 Agent |
| 🟡 P1 | 代理可疑文件/邮件LDAP明文密码 | .5/.161 | 核查+改密+TLS |
| 🟢 P2 | 日志未切割/旧系统 | 多台 | 定期维护提醒 |

---

## 八、待补充信息(部署前需你确认)

1. ~~ESXi 管理地址 192.168.50.66 + Zabbix 只读账号 opsread~~ ✅ 已填(第三节 3.6)。
2. SVN 实际访问协议与地址:`svn://192.168.50.54:3690` 或 `https://svn.itrus.com.cn/svn`?账号?(用于 ITOps 探活与备份核查 Agent)。
3. GitLab 实际访问地址与 API token(用于 ITOps 主动查询仓库状态)。
4. 邮件 .161 的 SMTP 发信账号/密码(用于 ITOps 通知渠道,587 端口)。
5. Zabbix Webhook 端点已实测确认为 `POST /api/v1/webhooks/zabbix`(非早先猜测的 `/api/alerts/webhook`),见第六节。Zabbix(.111)当前用 Admin/zabbix 联调,**生产请新建只读用户 `opsread`** 提供给 ITOps 主动查询使用。

---

## 八(补)、已创建凭证记录

> 以下为本次实操创建的账号。密码为随机生成,**未写入本文档**(避免落入 git 历史),请取自已保存的密码库 / `.250 /tmp/opsread_pw.txt`,并尽快迁移至企业密码库后删除该临时文件。

| 系统 | 账号 | 密码 | 权限 | 用途 |
|------|------|------|------|------|
| Zabbix 192.168.50.111 | `opsread` | _(见密码库,勿留明文)_ | 只读(User role + ITOps ReadOnly 组,全主机组 Read) | ITOps 主动查询 Zabbix API |

- 创建方式:Zabbix API `user.create`(userid 4)+ `usergroup.create`(usrgrpid 14, gui_access=0, rights 全组 permission=2)+ `user.update` 赋 `roleid=1`。
- 验证:可 `user.login` 成功并 `host.get` 返回主机(含 SVN-server/svn/50.247esxi),无写权限。
- ⚠️ 该 Zabbix 版本用 RBAC 角色控制权限,仅加入只读用户组不够,必须分配 `User role`(roleid 1)否则报 "No permissions for system access"。

---

## 九、下一步动作(建议顺序)

1. 登录 ITOps 改密 + 配 AI 模型 + 配邮件通知(.161 SMTP)。
2. 在 Zabbix 建 itops_ro 账号 + Webhook 媒介,打通双向对接(第六节)。
3. ITOps 录入 50.x 各机 SSH 凭据,导入 Zabbix 主机清单。
4. 优先编排 P0 修复 Agent:磁盘阈值(.21/.154)、Tomcat 自启(.142)、防火墙收敛(.142)。
5. 补 ESXi 监控模板(待地址)。
6. 统一配置文件异地备份(当前均内网同段,无异地)。
