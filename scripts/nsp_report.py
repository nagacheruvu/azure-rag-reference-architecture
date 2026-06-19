#!/usr/bin/env python3
"""In-VNet private-connectivity validator + HTML report server.

Runs INSIDE the private VNet (Azure Container Instance, VNet-injected) where the
Foundry and AI Search resources have public network access DISABLED. It:

  1. Acquires Entra ID tokens via the user-assigned managed identity (IMDS).
  2. Validates private DNS resolution (public FQDNs must resolve to private
     10.x endpoint IPs, not public IPs).
  3. Proves general internet egress is BLOCKED by the subnet NSG.
  4. Makes AUTHENTICATED data-plane calls through the private endpoints to:
       - Microsoft Foundry (primary region)
       - Azure AI Search (secondary region -> cross-region private link)
     and expects HTTP 200.
  5. Renders a styled HTML summary report and serves it on :80 so it can be
     viewed from anywhere inside the VNet (peered network / Bastion / VPN /
     another container).

Configuration comes from environment variables (injected by the container):
  CLIENT_ID        user-assigned managed identity client id
  FOUNDRY_HOST     <foundry>.openai.azure.com
  FOUNDRY_REGION   primary region label (display only)
  SEARCH_HOST      <search>.search.windows.net
  SEARCH_REGION    secondary region label (display only)
  DNS_HOSTS        space-separated FQDNs to resolve
  REFRESH_SECONDS  report refresh / loop interval (default 180)

Only the Python standard library is used (the azure-cli image ships python3).
"""

import os
import ssl
import json
import time
import html
import socket
import datetime
import functools
import threading
import http.server
import urllib.error
import urllib.request

CLIENT_ID = os.environ.get("CLIENT_ID", "")
FOUNDRY_HOST = os.environ.get("FOUNDRY_HOST", "")
FOUNDRY_REGION = os.environ.get("FOUNDRY_REGION", "primary")
SEARCH_HOST = os.environ.get("SEARCH_HOST", "")
SEARCH_REGION = os.environ.get("SEARCH_REGION", "secondary")
DNS_HOSTS = os.environ.get("DNS_HOSTS", "").split()
REFRESH = int(os.environ.get("REFRESH_SECONDS", "180"))
STORAGE_ACCOUNT = os.environ.get("STORAGE_ACCOUNT", "")
STORAGE_CONTAINER = os.environ.get("STORAGE_CONTAINER", "report")
STORAGE_BLOB = os.environ.get("STORAGE_BLOB", "index.html")

try:
    CONFIG = json.loads(os.environ.get("CONFIG_JSON", "") or "{}")
except Exception:
    CONFIG = {}

SITE = "/site"
INDEX = os.path.join(SITE, "index.html")
IMDS = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01"


def get_token(resource):
    """Acquire an Entra ID access token for `resource` from IMDS."""
    url = "{0}&resource={1}&client_id={2}".format(IMDS, resource, CLIENT_ID)
    req = urllib.request.Request(url, headers={"Metadata": "true"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.load(resp).get("access_token", "")
    except Exception:
        return ""


def is_private_ip(ip):
    try:
        parts = [int(p) for p in ip.split(".")]
    except ValueError:
        return False
    if len(parts) != 4:
        return False
    if parts[0] == 10:
        return True
    if parts[0] == 192 and parts[1] == 168:
        return True
    if parts[0] == 172 and 16 <= parts[1] <= 31:
        return True
    return False


def resolve(host):
    """Return the sorted set of IPs `host` resolves to (empty on failure)."""
    try:
        infos = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)
        return sorted({info[4][0] for info in infos})
    except Exception:
        return []


def internet_blocked(target=("1.1.1.1", 443), timeout=6):
    """True if outbound internet is blocked (connection cannot be established)."""
    try:
        with socket.create_connection(target, timeout=timeout):
            return False  # connected -> internet reachable
    except Exception:
        return True  # blocked / timed out -> expected behaviour


def https_get(url, token, timeout=20):
    """Authenticated GET. Returns (status_code, latency_ms, snippet)."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    headers = {}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, headers=headers)
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            body = resp.read(240).decode("utf-8", "ignore")
            return resp.status, int((time.time() - start) * 1000), body
    except urllib.error.HTTPError as err:
        body = err.read(240).decode("utf-8", "ignore")
        return err.code, int((time.time() - start) * 1000), body
    except Exception as err:
        return 0, int((time.time() - start) * 1000), str(err)


def auth_call(url, token, retries=6, delay=15):
    """Call an endpoint, retrying transient RBAC-propagation 403/000 results."""
    status, latency, body = https_get(url, token)
    attempts = 1
    while status in (0, 403) and attempts < retries:
        time.sleep(delay)
        status, latency, body = https_get(url, token)
        attempts += 1
    return status, latency, body, attempts


def badge(ok):
    return ('<span class="badge pass">PASS</span>' if ok
            else '<span class="badge fail">FAIL</span>')


def _g(obj, *keys, default=""):
    """Safe nested getter for the CONFIG dict."""
    cur = obj
    for k in keys:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return default
    return cur


def run_checks():
    """Run every validation and return a structured result dict."""
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    cog_token = get_token("https://cognitiveservices.azure.com")
    search_token = get_token("https://search.azure.com")

    # 1. Private DNS resolution.
    dns_rows = []
    dns_ok = bool(DNS_HOSTS)
    for host in DNS_HOSTS:
        ips = resolve(host)
        private = bool(ips) and all(is_private_ip(ip) for ip in ips)
        dns_ok = dns_ok and private
        dns_rows.append({
            "host": host,
            "ips": ", ".join(ips) if ips else "(no answer)",
            "ok": private,
        })

    # 2. Internet egress blocked.
    inet_blocked = internet_blocked()

    # 3. Token acquisition.
    tokens_ok = bool(cog_token) and bool(search_token)

    # 4. Foundry private data-plane (primary region).
    foundry_url = "https://{0}/openai/models?api-version=2024-10-21".format(FOUNDRY_HOST)
    f_status, f_ms, f_body, f_try = auth_call(foundry_url, cog_token)
    foundry_ok = f_status == 200

    # 5. AI Search private data-plane (secondary region, cross-region).
    search_url = "https://{0}/indexes?api-version=2023-11-01".format(SEARCH_HOST)
    s_status, s_ms, s_body, s_try = auth_call(search_url, search_token)
    search_ok = s_status == 200

    overall = dns_ok and inet_blocked and tokens_ok and foundry_ok and search_ok

    return {
        "now": now,
        "overall": overall,
        "dns_ok": dns_ok,
        "dns_rows": dns_rows,
        "inet_blocked": inet_blocked,
        "tokens_ok": tokens_ok,
        "cog_token": bool(cog_token),
        "search_token": bool(search_token),
        "foundry": {"ok": foundry_ok, "status": f_status, "ms": f_ms,
                    "url": foundry_url, "tries": f_try},
        "search": {"ok": search_ok, "status": s_status, "ms": s_ms,
                   "url": search_url, "tries": s_try},
    }


def _tab_network():
    e = html.escape
    vnet = _g(CONFIG, "vnet", default={})
    rows = []
    for sn in _g(vnet, "subnets", default=[]):
        rows.append(
            "<tr><td class='mono'>{0}</td><td class='mono'>{1}</td>"
            "<td class='mono'>{2}</td><td class='mono'>{3}</td><td>{4}</td></tr>".format(
                e(sn.get("name", "")), e(sn.get("prefix", "")),
                e(sn.get("delegation", "")), e(sn.get("nsg", "")),
                e(sn.get("purpose", ""))))
    subnet_rows = "".join(rows) or "<tr><td colspan='5'>no config</td></tr>"
    return """
  <div class="card">
    <h2>Virtual network</h2>
    <table>
      <tr><td>Name</td><td class="mono">{name}</td></tr>
      <tr><td>Address space</td><td class="mono">{space}</td></tr>
      <tr><td>Region</td><td class="mono">{region}</td></tr>
    </table>
  </div>
  <div class="card">
    <h2>Subnets, ranges &amp; delegation</h2>
    <table>
      <tr><th>Subnet</th><th>Range</th><th>Delegation</th><th>NSG</th><th>Purpose</th></tr>
      {rows}
    </table>
  </div>""".format(
        name=e(_g(vnet, "name")), space=e(_g(vnet, "addressSpace")),
        region=e(_g(CONFIG, "location")), rows=subnet_rows)


def _dns_diagram_svg():
    """Inline SVG illustrating the private DNS resolution + cross-region private link."""
    e = html.escape
    f_region = e(_g(CONFIG, "foundry", "region") or FOUNDRY_REGION)
    s_region = e(_g(CONFIG, "search", "region") or SEARCH_REGION)
    return """
  <div class="card">
    <h2>How private DNS + cross-region private link works</h2>
    <svg viewBox="0 0 920 360" width="100%" role="img" aria-label="Private DNS resolution flow" style="max-width:920px">
      <defs>
        <marker id="arr" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
          <path d="M0,0 L8,3 L0,6 Z" fill="#5b8cff"/>
        </marker>
        <style>
          .b{{fill:#161d2e;stroke:#2c3a59;stroke-width:1.5;rx:10}}
          .bz{{fill:#101a32;stroke:#2f6df0;stroke-width:1.5}}
          .bp{{fill:#0e2a1c;stroke:#1c9b5a;stroke-width:1.5}}
          .t{{fill:#e6e9ef;font:13px 'Segoe UI',sans-serif}}
          .ts{{fill:#9fb3d1;font:11px 'Segoe UI',sans-serif}}
          .tm{{fill:#bcd0f5;font:11px Consolas,monospace}}
          .ln{{stroke:#5b8cff;stroke-width:2;fill:none;marker-end:url(#arr)}}
          .lbl{{fill:#7f93b5;font:10.5px 'Segoe UI',sans-serif}}
        </style>
      </defs>

      <rect class="b" x="20"  y="140" width="170" height="74" rx="10"/>
      <text class="t"  x="105" y="168" text-anchor="middle">Report container</text>
      <text class="ts" x="105" y="186" text-anchor="middle">snet-web</text>
      <text class="tm" x="105" y="202" text-anchor="middle">VNet-injected ACI</text>

      <rect class="bz" x="250" y="30"  width="200" height="74" rx="10"/>
      <text class="t"  x="350" y="58"  text-anchor="middle">Azure-provided DNS</text>
      <text class="tm" x="350" y="76"  text-anchor="middle">168.63.129.16</text>
      <text class="ts" x="350" y="92"  text-anchor="middle">VNet default resolver</text>

      <rect class="bz" x="250" y="140" width="200" height="84" rx="10"/>
      <text class="t"  x="350" y="166" text-anchor="middle">Private DNS zones</text>
      <text class="tm" x="350" y="184" text-anchor="middle">privatelink.openai&hellip;</text>
      <text class="tm" x="350" y="200" text-anchor="middle">privatelink.search&hellip;</text>
      <text class="ts" x="350" y="216" text-anchor="middle">linked to the VNet</text>

      <rect class="bp" x="510" y="120" width="180" height="120" rx="10"/>
      <text class="t"  x="600" y="146" text-anchor="middle">Private endpoints</text>
      <text class="ts" x="600" y="164" text-anchor="middle">snet-pe</text>
      <text class="tm" x="600" y="184" text-anchor="middle">10.40.1.5 openai</text>
      <text class="tm" x="600" y="200" text-anchor="middle">10.40.1.7 search</text>
      <text class="ts" x="600" y="222" text-anchor="middle">private IPs only</text>

      <rect class="b" x="740" y="60"  width="160" height="74" rx="10"/>
      <text class="t"  x="820" y="88"  text-anchor="middle">Microsoft Foundry</text>
      <text class="tm" x="820" y="106" text-anchor="middle">{f_region}</text>
      <text class="ts" x="820" y="122" text-anchor="middle">public access OFF</text>

      <rect class="b" x="740" y="220" width="160" height="74" rx="10"/>
      <text class="t"  x="820" y="248" text-anchor="middle">Azure AI Search</text>
      <text class="tm" x="820" y="266" text-anchor="middle">{s_region}</text>
      <text class="ts" x="820" y="282" text-anchor="middle">public access OFF</text>

      <path class="ln" d="M190,162 L246,80"/>
      <text class="lbl" x="196" y="116">1. resolve FQDN</text>
      <path class="ln" d="M350,104 L350,138"/>
      <text class="lbl" x="356" y="124">2. CNAME to privatelink zone</text>
      <path class="ln" d="M450,182 L506,182"/>
      <text class="lbl" x="452" y="174">3. returns private IP</text>
      <path class="ln" d="M190,176 L506,196"/>
      <text class="lbl" x="250" y="250">4. traffic to PE (private IP) — never leaves the VNet</text>
      <path class="ln" d="M690,150 L736,104"/>
      <text class="lbl" x="640" y="120">private link</text>
      <path class="ln" d="M690,210 L736,250"/>
      <text class="lbl" x="624" y="246">cross-region private link</text>
    </svg>
    <p class="note">The report container in <code>snet-web</code> resolves each public FQDN through the VNet's
    Azure DNS, which is overridden by the linked <code>privatelink.*</code> zones to return a
    <b>private 10.40.1.x</b> address. Traffic then flows over the private endpoint to Foundry
    (<b>{f_region}</b>) and Search (<b>{s_region}</b>) — two different regions — without ever
    using a public IP or leaving the Microsoft backbone.</p>
  </div>""".format(f_region=f_region, s_region=s_region)


def _tab_dns(r):
    e = html.escape
    rows = []
    for row in r["dns_rows"]:
        rows.append(
            "<tr><td class='mono'>{0}</td><td class='mono'>{1}</td>"
            "<td class='c'>{2}</td></tr>".format(
                e(row["host"]), e(row["ips"]), badge(row["ok"])))
    dns_table = "".join(rows) or "<tr><td colspan='3'>no hosts configured</td></tr>"

    zrows = []
    for z in _g(CONFIG, "dnsZones", default=[]):
        zrows.append(
            "<tr><td class='mono'>{0}</td><td>{1}</td><td class='c'>{2}</td></tr>".format(
                e(z.get("zone", "")), e(z.get("service", "")),
                badge(bool(z.get("linkedToVnet")))))
    zone_table = "".join(zrows) or "<tr><td colspan='3'>no zones</td></tr>"

    return _dns_diagram_svg() + """
  <div class="card">
    <h2>Private DNS zones (linked to VNet)</h2>
    <table>
      <tr><th>Zone</th><th>Backs</th><th class="c">VNet link</th></tr>
      {zones}
    </table>
  </div>
  <div class="card">
    <h2>Live DNS resolution (must be private 10.40.1.x)</h2>
    <table>
      <tr><th>Hostname</th><th>Resolved IP(s)</th><th class="c">Private?</th></tr>
      {dns}
    </table>
  </div>""".format(zones=zone_table, dns=dns_table)


def _tab_services(r):
    e = html.escape
    f = r["foundry"]
    s = r["search"]
    fc = _g(CONFIG, "foundry", default={})
    sc = _g(CONFIG, "search", default={})

    def svc_card(title, cfg, region, status, ok):
        eps = "".join("<li class='mono'>{0}</li>".format(e(x))
                      for x in cfg.get("endpoints", [])) or "<li>n/a</li>"
        return """
  <div class="card">
    <h2>{title} <span class="pill">{region}</span></h2>
    <table>
      <tr><td>Resource</td><td class="mono">{name}</td></tr>
      <tr><td>Kind / SKU</td><td>{kind} &middot; {sku}</td></tr>
      <tr><td>Public network access</td><td><b>{pna}</b></td></tr>
      <tr><td>Auth</td><td>{auth}</td></tr>
      <tr><td>Private endpoint</td><td class="mono">{pe} &rarr; {pesub}</td></tr>
      <tr><td>Hello-world call</td><td>HTTP <b>{status}</b> {bdg}</td></tr>
    </table>
    <h2>Endpoints</h2>
    <ul class="eps">{eps}</ul>
  </div>""".format(
            title=e(title), region=e(region), name=e(cfg.get("name", "")),
            kind=e(cfg.get("kind", "")), sku=e(cfg.get("sku", "")),
            pna=e(cfg.get("publicNetworkAccess", "")), auth=e(cfg.get("authMode", "")),
            pe=e(cfg.get("privateEndpoint", "")), pesub=e(cfg.get("peSubnet", "")),
            status=status, bdg=badge(ok), eps=eps)

    return (svc_card("Microsoft Foundry", fc, _g(fc, "region") or FOUNDRY_REGION,
                     f["status"], f["ok"])
            + svc_card("Azure AI Search (cross-region)", sc,
                       _g(sc, "region") or SEARCH_REGION, s["status"], s["ok"]))


def _tab_nsg():
    e = html.escape
    rows = []
    for n in _g(CONFIG, "nsgs", default=[]):
        rows.append(
            "<tr><td class='mono'>{0}</td><td class='mono'>{1}</td><td>{2}</td></tr>".format(
                e(n.get("name", "")), e(n.get("appliesTo", "")), e(n.get("summary", ""))))
    table = "".join(rows) or "<tr><td colspan='3'>no NSGs</td></tr>"
    return """
  <div class="card">
    <h2>Network security groups</h2>
    <table>
      <tr><th>NSG</th><th>Subnet</th><th>Rule summary</th></tr>
      {rows}
    </table>
    <p class="note">Egress is locked down: only Entra ID (AzureActiveDirectory), Azure
    infrastructure (AzureCloud) and intra-VNet traffic are permitted; general Internet is
    denied. This is what proves the services are reachable <i>only</i> over private link.</p>
  </div>""".format(rows=table)


def _tab_deploy():
    e = html.escape
    dep = _g(CONFIG, "portalDeploymentsUrl")
    rgu = _g(CONFIG, "portalResourceGroupUrl")
    dep_link = ("<a href='{0}' target='_blank'>View deployments in Azure portal</a>".format(e(dep))
                if dep else "n/a")
    rg_link = ("<a href='{0}' target='_blank'>Open resource group</a>".format(e(rgu))
               if rgu else "n/a")
    return """
  <div class="card">
    <h2>Deployment</h2>
    <table>
      <tr><td>Subscription</td><td class="mono">{sub}</td></tr>
      <tr><td>Resource group</td><td class="mono">{rg}</td></tr>
      <tr><td>Environment</td><td class="mono">{env}</td></tr>
      <tr><td>Resource token</td><td class="mono">{tok}</td></tr>
      <tr><td>IaC template</td><td class="mono">{tpl}</td></tr>
      <tr><td>Portal &mdash; deployments</td><td>{deplink}</td></tr>
      <tr><td>Portal &mdash; resource group</td><td>{rglink}</td></tr>
    </table>
    <p class="note">This environment is defined entirely in the Bicep template
    <code>{tpl}</code> and deployed with <code>az deployment group create</code>.</p>
  </div>""".format(
        sub=e(_g(CONFIG, "subscriptionId")), rg=e(_g(CONFIG, "resourceGroup")),
        env=e(_g(CONFIG, "environmentName")), tok=e(_g(CONFIG, "resourceToken")),
        tpl=e(_g(CONFIG, "templatePath")), deplink=dep_link, rglink=rg_link)


def render_html(r):
    """Build the tabbed HTML report from a results dict."""
    e = html.escape
    banner_cls = "ok" if r["overall"] else "bad"
    banner_txt = ("ALL PRIVATE CONNECTIVITY CHECKS PASSED"
                  if r["overall"] else "ONE OR MORE CHECKS FAILED")

    f = r["foundry"]
    s = r["search"]
    f_region = _g(CONFIG, "foundry", "region") or FOUNDRY_REGION
    s_region = _g(CONFIG, "search", "region") or SEARCH_REGION

    status_tab = """
  <div class="card">
    <h2>Summary</h2>
    <table>
      <tr><th>Check</th><th>Detail</th><th class="c">Result</th></tr>
      <tr><td>Private DNS resolution</td><td>public FQDNs resolve to private 10.x endpoint IPs</td><td class="c">{dns_badge}</td></tr>
      <tr><td>Internet egress blocked</td><td>subnet NSG denies general internet (tested 1.1.1.1:443)</td><td class="c">{inet_badge}</td></tr>
      <tr><td>Managed-identity tokens</td><td>Cognitive: {cog}, Search: {srch}</td><td class="c">{tok_badge}</td></tr>
      <tr><td>Foundry private endpoint <span class="pill">{f_region}</span></td><td>authenticated GET /openai/models &rarr; HTTP {f_status} ({f_ms} ms)</td><td class="c">{f_badge}</td></tr>
      <tr><td>AI Search private endpoint <span class="pill">{s_region} &middot; cross-region</span></td><td>authenticated GET /indexes &rarr; HTTP {s_status} ({s_ms} ms)</td><td class="c">{s_badge}</td></tr>
    </table>
  </div>
  <div class="card">
    <h2>Cross-region &ldquo;hello world&rdquo; (live)</h2>
    <p class="note">Both services have <b>public network access disabled</b>. These authenticated
    calls succeed only because the report container reaches them over private endpoints &mdash;
    and the two services sit in <b>different regions</b>.</p>
    <div class="hw">
      <div class="hwbox {f_state}">
        <div class="hwt">Microsoft Foundry</div>
        <div class="hwr">{f_region}</div>
        <div class="hwc mono">GET /openai/models</div>
        <div class="hws">HTTP {f_status} &middot; {f_ms} ms {f_badge}</div>
      </div>
      <div class="hwarrow">&harr;<div class="lbl">cross-region<br>private link</div></div>
      <div class="hwbox {s_state}">
        <div class="hwt">Azure AI Search</div>
        <div class="hwr">{s_region}</div>
        <div class="hwc mono">GET /indexes</div>
        <div class="hws">HTTP {s_status} &middot; {s_ms} ms {s_badge}</div>
      </div>
    </div>
  </div>""".format(
        dns_badge=badge(r["dns_ok"]), inet_badge=badge(r["inet_blocked"]),
        tok_badge=badge(r["tokens_ok"]),
        cog="present" if r["cog_token"] else "EMPTY",
        srch="present" if r["search_token"] else "EMPTY",
        f_region=e(f_region), s_region=e(s_region),
        f_status=f["status"], f_ms=f["ms"], f_badge=badge(f["ok"]),
        s_status=s["status"], s_ms=s["ms"], s_badge=badge(s["ok"]),
        f_state="ok" if f["ok"] else "bad", s_state="ok" if s["ok"] else "bad")

    tabs = [
        ("status", "Status", status_tab),
        ("network", "Network", _tab_network()),
        ("dns", "Private DNS", _tab_dns(r)),
        ("services", "Services", _tab_services(r)),
        ("nsg", "NSG", _tab_nsg()),
        ("deploy", "Deployment", _tab_deploy()),
    ]
    nav = "".join(
        "<button class='tab' data-tab='{0}' onclick=\"showTab('{0}')\">{1}</button>".format(tid, tlabel)
        for tid, tlabel, _ in tabs)
    panes = "".join(
        "<section id='pane-{0}' class='pane'>{1}</section>".format(tid, body)
        for tid, _, body in tabs)

    return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="{refresh}">
<title>Private Connectivity Report</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font-family: 'Segoe UI', system-ui, sans-serif; margin: 0; background: #0f1420; color: #e6e9ef; }}
  .wrap {{ max-width: 980px; margin: 0 auto; padding: 28px 20px 60px; }}
  h1 {{ font-size: 22px; margin: 0 0 4px; }}
  .sub {{ color: #94a3b8; font-size: 13px; margin-bottom: 18px; }}
  .banner {{ padding: 14px 20px; border-radius: 10px; font-weight: 600; font-size: 16px;
            margin-bottom: 18px; letter-spacing: .3px; }}
  .banner.ok {{ background: #06371f; color: #54e08a; border: 1px solid #138a4e; }}
  .banner.bad {{ background: #3a0f12; color: #ff7b85; border: 1px solid #b3303b; }}
  .tabs {{ display:flex; flex-wrap:wrap; gap:6px; margin-bottom:18px; border-bottom:1px solid #243049; }}
  .tab {{ background:transparent; border:none; color:#9fb3d1; font:600 13px 'Segoe UI',sans-serif;
         padding:9px 14px; cursor:pointer; border-radius:8px 8px 0 0; }}
  .tab:hover {{ color:#e6e9ef; background:#161d2e; }}
  .tab.active {{ color:#fff; background:#1d2740; border-bottom:2px solid #5b8cff; }}
  .pane {{ display:none; }}
  .pane.active {{ display:block; }}
  .card {{ background: #161d2e; border: 1px solid #243049; border-radius: 10px;
          padding: 4px 18px 16px; margin-bottom: 18px; }}
  .card h2 {{ font-size: 13px; text-transform: uppercase; letter-spacing: .6px;
             color: #9fb3d1; margin: 16px 0 10px; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
  th, td {{ text-align: left; padding: 8px 10px; border-bottom: 1px solid #233048; vertical-align: top; }}
  th {{ color: #8aa0c2; font-weight: 600; font-size: 12px; text-transform: uppercase; }}
  td.c, th.c {{ text-align: center; }}
  .mono {{ font-family: 'Cascadia Code', Consolas, monospace; font-size: 12.5px; }}
  .badge {{ display: inline-block; padding: 2px 10px; border-radius: 999px;
           font-size: 11px; font-weight: 700; letter-spacing: .5px; }}
  .badge.pass {{ background: #16432a; color: #5ee08c; }}
  .badge.fail {{ background: #4a1418; color: #ff7b85; }}
  .pill {{ display:inline-block; padding:2px 9px; border-radius:6px; background:#1d2740;
          color:#9fb3d1; font-size:12px; margin-left:6px; }}
  .note {{ color:#94a3b8; font-size:12.5px; line-height:1.5; }}
  ul.eps {{ margin:4px 0 10px; padding-left:20px; }} ul.eps li {{ margin:3px 0; }}
  .hw {{ display:flex; align-items:center; gap:14px; flex-wrap:wrap; margin:6px 0 4px; }}
  .hwbox {{ flex:1; min-width:220px; border-radius:10px; padding:12px 14px; border:1px solid #243049; background:#101a32; }}
  .hwbox.ok {{ border-color:#1c9b5a; background:#0e2a1c; }}
  .hwbox.bad {{ border-color:#b3303b; background:#3a0f12; }}
  .hwt {{ font-weight:700; font-size:15px; }}
  .hwr {{ color:#bcd0f5; font:12px Consolas,monospace; margin:2px 0 8px; }}
  .hwc {{ color:#9fb3d1; }} .hws {{ margin-top:8px; font-size:13px; }}
  .hwarrow {{ text-align:center; color:#5b8cff; font-size:22px; }}
  .hwarrow .lbl {{ color:#7f93b5; font-size:10.5px; }}
  footer {{ color: #64748b; font-size: 12px; margin-top: 8px; }}
  code {{ background:#0d1322; padding:1px 5px; border-radius:4px; }}
  a {{ color:#7aa7ff; }}
</style>
</head>
<body>
<div class="wrap">
  <h1>Private Connectivity Validation</h1>
  <div class="sub">Served from inside the VNet &middot; public network access is <b>disabled</b> on both services &middot; generated {now}</div>

  <div class="banner {banner_cls}">{banner_txt}</div>

  <div class="tabs">{nav}</div>
  {panes}

  <footer>
    Page auto-refreshes every {refresh}s. RBAC propagation can take several minutes after first
    deploy, so Foundry/Search may briefly show <code>403</code> before turning green.
  </footer>
</div>
<script>
  function showTab(id) {{
    document.querySelectorAll('.pane').forEach(function(p){{ p.classList.remove('active'); }});
    document.querySelectorAll('.tab').forEach(function(t){{ t.classList.remove('active'); }});
    var pane = document.getElementById('pane-' + id);
    var tab = document.querySelector(".tab[data-tab='" + id + "']");
    if (pane) pane.classList.add('active');
    if (tab) tab.classList.add('active');
    if (history.replaceState) history.replaceState(null, '', '#' + id);
  }}
  showTab((location.hash || '#status').slice(1));
</script>
</body>
</html>""".format(
        refresh=REFRESH, now=e(r["now"]),
        banner_cls=banner_cls, banner_txt=banner_txt,
        nav=nav, panes=panes)



def write_report(html_text):
    tmp = INDEX + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(html_text)
    os.replace(tmp, INDEX)


def upload_blob(html_text):
    """Upload the rendered report to a blob using the managed identity.

    Writes through the storage blob private endpoint (Entra ID auth, no keys), so
    the report can be downloaded from outside the VNet via AAD credentials.
    """
    if not STORAGE_ACCOUNT:
        return "skipped"
    token = get_token("https://storage.azure.com/")
    if not token:
        return "no-token"
    url = "https://{0}.blob.core.windows.net/{1}/{2}".format(
        STORAGE_ACCOUNT, STORAGE_CONTAINER, STORAGE_BLOB)
    data = html_text.encode("utf-8")
    req = urllib.request.Request(url, data=data, method="PUT", headers={
        "Authorization": "Bearer " + token,
        "x-ms-blob-type": "BlockBlob",
        "x-ms-version": "2021-08-06",
        "Content-Type": "text/html; charset=utf-8",
        "Content-Length": str(len(data)),
    })
    try:
        ctx = ssl.create_default_context()
        with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
            return "ok({0})".format(resp.status)
    except urllib.error.HTTPError as err:
        return "http{0}".format(err.code)
    except Exception as err:
        return "err({0})".format(err)


def report_loop():
    while True:
        try:
            results = run_checks()
            html_text = render_html(results)
            write_report(html_text)
            blob = upload_blob(html_text)
            print("report updated: overall={0} foundry={1} search={2} blob={3}".format(
                results["overall"], results["foundry"]["status"],
                results["search"]["status"], blob), flush=True)
        except Exception as err:  # never let the loop die
            print("report error: {0}".format(err), flush=True)
        time.sleep(REFRESH)


def main():
    os.makedirs(SITE, exist_ok=True)
    write_report("<!DOCTYPE html><html><body style='font-family:sans-serif;background:#0f1420;"
                 "color:#e6e9ef;padding:40px'><h2>Running private-connectivity checks&hellip;</h2>"
                 "<p>This page will refresh automatically.</p>"
                 "<meta http-equiv='refresh' content='10'></body></html>")

    threading.Thread(target=report_loop, daemon=True).start()

    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=SITE)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 80), handler)
    print("serving report on :80", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
