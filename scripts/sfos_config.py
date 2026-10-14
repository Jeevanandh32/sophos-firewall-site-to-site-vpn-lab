"""Push lab config to one Sophos firewall via XML API.
Usage: SFOS_PW=... SFOS_PSK=... python sfos_config.py <site a|b> <step...>
steps: objects webpolicy rules vpn activate
"""
import os, ssl, sys, urllib.parse, urllib.request
from xml.sax.saxutils import escape

SITES = {
    "a": dict(ip="44.218.174.190", local="LAN-A-Net", remote="LAN-B-Net", peer="23.21.5.108",
              conn="S2S_A_to_B", gw="Initiate"),
    "b": dict(ip="23.21.5.108", local="LAN-B-Net", remote="LAN-A-Net", peer="44.218.174.190",
              conn="S2S_B_to_A", gw="RespondOnly"),
}
site = sys.argv[1]; steps = sys.argv[2:]
S = SITES[site]
pw = os.environ["SFOS_PW"]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE


def call(inner, show=True):
    req = (f"<Request><Login><Username>admin</Username><Password>{escape(pw)}</Password></Login>"
           f"{inner}</Request>")
    data = urllib.parse.urlencode({"reqxml": req}).encode()
    with urllib.request.urlopen(f"https://{S['ip']}:4444/webconsole/APIController", data, context=ctx, timeout=90) as r:
        out = r.read().decode()
    if show:
        import re
        for m in re.finditer(r"<(\w+) transactionid=\"[^\"]*\">\s*<Status code=\"(\d+)\">([^<]*)</Status>", out):
            print(f"  {m.group(1)}: {m.group(2)} {m.group(3)}")
        if "<Status code" not in out or "InvalidParams" in out:
            print(out[:1500])
    return out


def rule(name, action, pos, src_zone, src_net, dst_zone, dst_net=None, service=None, web="None", after=None):
    nets = lambda tag, inner, n: f"<{tag}><{inner}>{n}</{inner}></{tag}>" if n else ""
    position = f"<Position>{pos}</Position>" + (f"<After><Name>{after}</Name></After>" if after else "")
    return f"""<FirewallRule><Name>{name}</Name><IPFamily>IPv4</IPFamily><Status>Enable</Status>{position}
<PolicyType>Network</PolicyType><NetworkPolicy><Action>{action}</Action><LogTraffic>Enable</LogTraffic>
<SkipLocalDestined>Disable</SkipLocalDestined>
<SourceZones><Zone>{src_zone}</Zone></SourceZones><DestinationZones><Zone>{dst_zone}</Zone></DestinationZones>
<Schedule>All The Time</Schedule>
{nets('SourceNetworks','Network',src_net)}{nets('DestinationNetworks','Network',dst_net)}{nets('Services','Service',service)}
<WebFilter>{web}</WebFilter><ScanVirus>Disable</ScanVirus><ZeroDayProtection>Disable</ZeroDayProtection>
<ProxyMode>Disable</ProxyMode><DecryptHTTPS>Disable</DecryptHTTPS>
<ApplicationControl>None</ApplicationControl><IntrusionPrevention>None</IntrusionPrevention>
<TrafficShappingPolicy>None</TrafficShappingPolicy></NetworkPolicy></FirewallRule>"""


for step in steps:
    print(f"[site-{site}] {step}")
    if step == "objects":
        call("""<Set operation="add">
<IPHost><Name>LAN-A-Net</Name><IPFamily>IPv4</IPFamily><HostType>Network</HostType><IPAddress>10.10.0.0</IPAddress><Subnet>255.255.255.0</Subnet></IPHost>
<IPHost><Name>LAN-B-Net</Name><IPFamily>IPv4</IPFamily><HostType>Network</HostType><IPAddress>10.20.0.0</IPAddress><Subnet>255.255.255.0</Subnet></IPHost>
<Services><Name>ICMP-Echo</Name><Type>ICMP</Type><ServiceDetails><ServiceDetail><ICMPType>Echo</ICMPType><ICMPCode>Any Code</ICMPCode></ServiceDetail></ServiceDetails></Services>
</Set>""")
    elif step == "webpolicy":
        call("""<Set operation="add"><WebFilterPolicy><Name>Lab-Block-Social</Name><DefaultAction>Allow</DefaultAction>
<EnableReporting>Enable</EnableReporting><DownloadFileSizeRestriction>0</DownloadFileSizeRestriction>
<DownloadFileSizeRestrictionEnabled>0</DownloadFileSizeRestrictionEnabled><GoogAppDomainListEnabled>0</GoogAppDomainListEnabled>
<YoutubeFilterIsStrict>0</YoutubeFilterIsStrict><YoutubeFilterEnabled>0</YoutubeFilterEnabled><EnforceSafeSearch>0</EnforceSafeSearch>
<EnforceImageLicensing>0</EnforceImageLicensing><XFFEnabled>0</XFFEnabled><Office365Enabled>0</Office365Enabled><QuotaLimit>60</QuotaLimit>
<Description>Lab: block Social Networking category</Description>
<RuleList><Rule><CategoryList><Category><ID>Social Networking</ID><type>WebCategory</type></Category></CategoryList>
<HTTPAction>Deny</HTTPAction><HTTPSAction>Deny</HTTPSAction><FollowHTTPAction>1</FollowHTTPAction>
<ExceptionList><FileTypeCategory/></ExceptionList><Schedule>All The Time</Schedule>
<PolicyRuleEnabled>1</PolicyRuleEnabled><CCLRuleEnabled>0</CCLRuleEnabled></Rule></RuleList>
</WebFilterPolicy></Set>""")
    elif step == "rules":
        L, R = S["local"], S["remote"]
        call('<Set operation="add">'
             + rule("Allow-LAN-to-WAN", "Accept", "Bottom", "LAN", L, "WAN", web="Lab-Block-Social")
             + "</Set>")
        call('<Set operation="add">'
             + rule("Deny-LAN-ICMP-Internet", "Drop", "Top", "LAN", L, "WAN", service="ICMP-Echo")
             + rule("Allow-LAN-to-VPN", "Accept", "Top", "LAN", L, "VPN", dst_net=R)
             + rule("Allow-VPN-to-LAN", "Accept", "Top", "VPN", R, "LAN", dst_net=L)
             + "</Set>")
    elif step == "vpn":
        psk = os.environ["SFOS_PSK"]
        call(f"""<Set operation="add"><VPNIPSecConnection><Configuration>
<Name>{S['conn']}</Name>{os.environ.get('DESC','')}
<ConnectionType>SiteToSite</ConnectionType><Policy>IKEv2</Policy>
<ActionOnVPNRestart>{S['gw']}</ActionOnVPNRestart>
<AuthenticationType>PresharedKey</AuthenticationType><PresharedKey>{escape(psk)}</PresharedKey>
<SubnetFamily>IPv4</SubnetFamily><EndpointFamily>IPv4</EndpointFamily>
<LocalWANPort>PortB</LocalWANPort><AliasLocalWANPort>PortB</AliasLocalWANPort>
<RemoteHost>{S['peer']}</RemoteHost>
<LocalSubnet>{S['local']}</LocalSubnet>
<NATedLAN/>
<LocalIDType>IP Address</LocalIDType><LocalID>{S['ip']}</LocalID>
{os.environ.get('NATT','')}
<RemoteNetwork><Network>{S['remote']}</Network></RemoteNetwork>
<RemoteIDType>IP Address</RemoteIDType><RemoteID>{S['peer']}</RemoteID>
<UserAuthenticationMode>Disable</UserAuthenticationMode>
<Protocol>ALL</Protocol>
</Configuration></VPNIPSecConnection></Set>""")
    elif step == "dumpvpn":
        print(call("<Get><VPNIPSecConnection></VPNIPSecConnection></Get>", show=False)[:4000])
    elif step == "dumprules":
        import re
        out = call("<Get><FirewallRule></FirewallRule></Get>", show=False)
        for m in re.finditer(r"<Name>([^<]*)</Name>\s*(?:<Description>[^<]*</Description>\s*|<Description\s*/>\s*)?<IPFamily>IPv4</IPFamily>\s*<Status>(\w+)</Status>\s*<Position>(\w+)</Position>", out):
            print("  ", m.groups())
