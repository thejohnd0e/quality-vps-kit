# shellcheck shell=bash
# shellcheck disable=SC2034  # the body constants are consumed by the sourcing tests
# Shared canned responses for tests that run the whole `qvk run` against
# stubbed curl. Needs WORK/CF/repo helpers already set up.

IP=203.0.113.10
RIPE_URL="https://stat.ripe.net/data/prefix-overview/data.json?resource=$IP"
INFO_URL="https://ipinfo.io/$IP/json"
ABUSE_URL="https://api.abuseipdb.com/api/v2/check?ipAddress=$IP&maxAgeInDays=90"

RIPE_OK='{"messages":[],"version":"1.3","data_call_status":"supported","status":"ok","status_code":200,"data":{"is_less_specific":false,"announced":true,"asns":[{"asn":64500,"holder":"EXAMPLE-AS - Example Hosting GmbH"}],"related_prefixes":[],"resource":"203.0.113.0/24","type":"prefix","block":{"resource":"203.0.0.0/8","desc":"Administered by ARIN","name":"IANA"}}}'
RIPE_UNANNOUNCED='{"status":"ok","data":{"announced":false,"asns":[],"resource":"203.0.113.0/24","type":"prefix"}}'
INFO_OK=$'{\n  "ip": "203.0.113.10",\n  "hostname": "203-0-113-10.static.example.net",\n  "city": "Frankfurt",\n  "region": "Hesse",\n  "country": "DE",\n  "loc": "50.1,8.6",\n  "org": "AS64500 Example Hosting GmbH",\n  "timezone": "Europe/Berlin"\n}'
INFO_HOSTING=$'{\n  "ip": "203.0.113.10",\n  "country": "DE",\n  "org": "AS64500 Example Hosting GmbH",\n  "hosting": true\n}'
ABUSE_OK='{"data":{"ipAddress":"203.0.113.10","isPublic":true,"abuseConfidenceScore":12,"countryCode":"DE","usageType":"Data Center/Web Hosting/Transit","isp":"Example Hosting","totalReports":3}}'
NC_URL="https://ip.net.coffee/api/iprisk/$IP"
NC_OK='{"ip":"203.0.113.10","cidr":"203.0.113.0/24","is_bogon":false,"is_datacenter":true,"isResidential":false,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_crawler":false,"is_abuser":false,"asn":64500,"asOrganization":"Example Hosting GmbH","country":"Germany","countryCode":"de","trust_score":41,"rdns":"203-0-113-10.example.net"}'
NC_CLEAN='{"ip":"203.0.113.10","isResidential":true,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_crawler":false,"is_abuser":false,"asn":64500,"asOrganization":"Example Home ISP","country":"Germany","countryCode":"de","trust_score":92}'
NC_RESTRICTED='{"ip":"203.0.113.10","isResidential":true,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_crawler":false,"is_abuser":false,"country":"Russia","countryCode":"ru","trust_score":88}'
NC_TOR='{"ip":"203.0.113.10","isResidential":true,"is_tor":true,"is_vpn":false,"is_proxy":false,"is_crawler":false,"is_abuser":false,"countryCode":"de","trust_score":95}'
NC_ABUSER='{"ip":"203.0.113.10","isResidential":true,"is_abuser":true,"is_vpn":false,"is_proxy":false,"is_tor":false,"is_crawler":false,"countryCode":"de","trust_score":88}'
INFO_RU=$'{\n  "ip": "203.0.113.10",\n  "country": "RU",\n  "org": "AS64500 Example Hosting GmbH"\n}'

# intel_fixtures [ripe_rc ripe_code ripe_body info_rc info_code info_body nc_rc nc_code nc_body]
intel_fixtures() {
  fix "" "$RIPE_URL" "${1:-0}" "${2:-200}" "${3:-$RIPE_OK}"
  fix "" "$INFO_URL" "${4:-0}" "${5:-200}" "${6:-$INFO_OK}"
  fix "" "$ABUSE_URL" 0 200 "$ABUSE_OK"
  fix "" "$NC_URL" "${7:-0}" "${8:-200}" "${9:-$NC_OK}"
}

# The all-default case, without making a bare call to a function that takes arguments.
intel_fixtures_default() { intel_fixtures 0 200 "$RIPE_OK" 0 200 "$INFO_OK" 0 200 "$NC_OK"; }

# services_fixtures: gentle HTTP checks of the default endpoint list
services_fixtures() {
  fix "" https://api.openai.com/v1/models 0 401 '{"error":"auth"}'
  fix "" https://chatgpt.com/cdn-cgi/trace 0 200 $'ip=203.0.113.10\nloc=DE\n'
  fix "" https://api.anthropic.com/v1/models 0 401 '{}'
  fix "" https://gemini.google.com/ 0 200 '<html>'
  fix "" https://www.youtube.com/robots.txt 0 200 'User-agent: *'
  fix "" https://www.netflix.com/robots.txt 0 200 'User-agent: *'
  fix "" https://open.spotify.com/robots.txt 0 200 'User-agent: *'
  fix "" https://ya.ru/robots.txt 0 200 'User-agent: *'
  fix "" https://vk.com/robots.txt 0 200 'User-agent: *'
  fix "" https://www.gosuslugi.ru/robots.txt 0 200 'User-agent: *'
}
