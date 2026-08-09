# Firewall and Infrastructure Blocking Analysis

How to analyze tcpdump data to determine if infrastructure is blocking tunnel traffic.

## When to Use This Analysis

- Tunnel status shows "error" despite control plane being established
- IPsec traffic counters show inBytes=0, outBytes=0
- Gateway/RouteAgent logs show NO configuration errors
- Suspect infrastructure (firewall/network) is blocking tunnel traffic

## Data Sources

### tcpdump Analysis Files (TEXT - Always Read These First)

- `tcpdump/cluster1-gateway-<nodename>-analysis.txt`
- `tcpdump/cluster2-gateway-<nodename>-analysis.txt`

These files contain:

- Total packet count
- First 50 packets with details
- Source/destination IP pairs
- Packet direction (In/Out)
- Automatic interpretation

### tcpdump Binary Files (BINARY - Reference Only)

- `tcpdump/cluster1-gateway-<nodename>.pcap`
- `tcpdump/cluster2-gateway-<nodename>.pcap`

## Understanding Packet Capture

**IMPORTANT:** tcpdump captures BOTH incoming and outgoing packets on the gateway node interface.

### Capture Filter

The filter is set based on cable driver and configuration:

- **libreswan with ESP:** `proto 50`
- **libreswan with UDP encapsulation:** `udp port 4500` (or ceIPSecNATTPort)
- **vxlan:** `udp port 4500` (or ceIPSecNATTPort)

The analysis checks for packet direction (In/Out) regardless of underlying protocol.

## Analysis Patterns

### Pattern 1: No Egress Traffic

```text
Cluster1 analysis: "Total packets captured: 0"
Cluster2 analysis: "Total packets captured: 0"
```

**Diagnosis:**

- Gateway pods are NOT sending tunnel traffic
- Appears to be: IPsec tunnel not properly initialized at kernel level (verify with additional kernel-level and IPsec logs)

**Next steps:**

- Check ipsec-status.log for STATE_V2_ESTABLISHED_CHILD_SA
- Review gateway pod logs for cable driver initialization errors

### Pattern 2: Egress but No Ingress (Infrastructure Blocking)

**CRITICAL:** This is the most common infrastructure blocking pattern.

**Example A - Unidirectional blocking:**

```text
Cluster1 analysis: "Total packets captured: 150" (all "Out" direction)
Cluster2 analysis: "Total packets captured: 0"
```

**Diagnosis:**

- Packets leaving cluster1 but NOT arriving at cluster2
- Infrastructure blocking cluster1→cluster2 direction

**Example B - Bidirectional blocking:**

```text
Cluster1 analysis: "Total packets captured: 150" (all "Out", no "In")
Cluster2 analysis: "Total packets captured: 94" (all "Out", no "In")
```

**Diagnosis:**

- Both clusters sending packets, but NEITHER receiving
- Infrastructure blocking tunnel traffic in BOTH directions
- **This is the most common pattern**

**Appears to be:** INFRASTRUCTURE BLOCKING (firewall/network blocking tunnel traffic)

*(This should be verified with additional network/firewall logs and connectivity tests.)*

### Pattern 3: Both Sending but Tunnel Still Error

```text
Cluster1 analysis: "Total packets captured: 150" (bidirectional)
Cluster2 analysis: "Total packets captured: 150" (bidirectional)
```

**Diagnosis:**

- Packets flowing in both directions
- But tunnel status still shows "error"
- Most likely cause: Health check IP issue or packet corruption (verify with additional kernel-level and IPsec logs)

**Next steps:**

- Check: Are packets reaching the right destination IPs?
- Review: Source/destination pairs in analysis file
- Verify: Health check IPs exist on gateway nodes

## Recommended Solutions Based on Pattern

### If Pattern 2 Detected (Infrastructure Blocking)

#### Step 1: Determine Protocol Being Used

Check Gateway CR:

```yaml
status:
  gateways:
  - connections:
    - endpoint:
        backend: libreswan
        backend_config:
          udp-port: "4500"  # If present, UDP encapsulation is enabled
```

Also check Submariner CR:

```yaml
spec:
  ceIPSecForceUDPEncaps: true  # If true, UDP encapsulation forced
```

#### Step 2: Apply Appropriate Workaround

**If using ESP (proto 50):**

**Workaround:** Enable UDP encapsulation to bypass ESP filtering.

*This forces tunnel traffic to use UDP port 4500 instead of ESP (protocol 50), working around infrastructure that blocks ESP.
This does not fix the root cause (firewall policy) and has trade-offs: it changes the exposed protocol/port surface,
still depends on correct firewall configuration for UDP/4500, and may have security or operational implications.*

**For ACM-Managed Submariner:**

```bash
# On the ACM hub cluster
kubectl patch submarinerconfig -n <managed-cluster-namespace> <config-name> \
  --type merge \
  -p '{"spec": {"ceIPSecForceUDPEncaps": true, "ceIPSecNATTPort": 4500}}'
```

**For Standalone Submariner:**

```bash
# On each managed cluster
kubectl patch submariner -n submariner-operator submariner \
  --type merge \
  -p '{"spec": {"ceIPSecForceUDPEncaps": true, "ceIPSecNATTPort": 4500}}'

# Restart gateway pods to apply changes
kubectl rollout restart daemonset -n submariner-operator submariner-gateway
```

**If already using UDP:**

→ Verify firewall allows the UDP port (default 4500)
→ Check ceIPSecNATTPort setting if custom port is used

## Important Notes

- tcpdump analysis files are pre-generated TEXT files - always read these first
- Binary pcap files are kept for reference but analysis is already done
- Compare analysis from BOTH clusters to identify the pattern
- "Out" packets with NO "In" packets = infrastructure blocking
- If no configuration errors exist in logs, issue is infrastructure-level

## Example Diagnosis Flow

```text
If tunnels are ESTABLISHED (ipsec-status shows STATE_V2_ESTABLISHED_CHILD_SA):
  AND traffic counters show inBytes=0, outBytes=0:
    → IPsec control plane is working, but datapath is broken

    If gateway/routeagent logs show NO configuration errors:
      → Appears to be INFRASTRUCTURE LEVEL (firewall/network blocking)

      Read tcpdump analysis files:
        If cluster1 analysis shows packets (Out) BUT cluster2 shows 0:
          → Packets leaving cluster1 but not reaching cluster2
          → Tunnel traffic being blocked between nodes
          → Check cable driver and protocol:
            - libreswan with ESP: Try UDP encapsulation
            - libreswan with UDP or vxlan: Verify firewall allows UDP port

        If both analysis files show 0 packets:
          → Gateway not sending packets
          → Check gateway pod logs for cable driver initialization errors
```

## VXLAN-Specific: ICMP Health Check Correlation Analysis

**When to use:** Cable driver is VXLAN and enhanced tcpdump captured ICMP packets.

### Overview

VXLAN health checks send ICMP echo requests through the encrypted tunnel. These can be correlated across:
1. Gateway health checks (every 1 second)
2. RouteAgent health checks (every 60 seconds from worker nodes)
3. nftables SNAT/DNAT counters
4. ICMP packet capture on both sides

### ICMP Correlation Key

**Primary correlation key:** ICMP ID (not source IP!)

- Each health check stream has a unique ICMP ID
- Same ICMP ID appears at all packet flow stages
- Source IP changes (GlobalNet SNAT), but ICMP ID stays constant

### Four-Stage Packet Flow

```
Stage 1: Cluster1 Egress (SNAT)
  └─> nftables SNAT counter: Packets leaving gateway

Stage 2: Tunnel Interface
  └─> tcpdump on vxlan-tunnel: Encapsulated packets
      Verify VXLAN encapsulation with inner ICMP:
      tcpdump -nnr <pcap> -T vxlan port 4500

Stage 3: Cluster2 Ingress (DNAT)
  └─> nftables DNAT counter: Packets arriving at remote gateway

Stage 4: Cluster2 Egress (Reply Path)
  └─> Reverse flow for ICMP echo reply
```

### Evidence Collection

**From nftables.log:**
```bash
# SNAT egress (cluster1 sending to 242.1.0.0/16)
counter packets 13049 bytes ...

# DNAT ingress (cluster2 receiving to 242.1.255.240)
counter packets 9373 bytes ...
```

**From tcpdump analysis:**
```
ICMP ID 15832: 50 requests, 0 replies (0% success)
ICMP ID 26003: 58 requests, 58 replies (100% success)
```

### Diagnosis Patterns

#### Pattern A: Table 150 Routing Issue

**Evidence:**
- Gateway health checks: ICMP ID shows 0% success
- RouteAgent health checks: ICMP ID shows 100% success
- Gateway CR status=error
- RouteAgent CR status=connected

**Analysis:**
```
Worker → LocalGW → RemoteGW: ✓ WORKING (RouteAgent proves it)
Gateway → RemoteGW: ✗ FAILING

Appears to be: Table 150 routing configuration issue on gateway node
Possible cause: Using network address (.0) instead of gateway IP
```

**Verification:** Check `*_ip-routes-table150.log` for "default via X.X.X.0" pattern.
**Important:** Verify this pattern before concluding - check multiple data points.

**Remediation:**

1. **Detect deployment type:**
   ```bash
   # Check acm-addons.txt and submarinerconfig.yaml
   # If either contains resources → ACM-Managed
   # If both say "No resources found" → Standalone
   ```

2. **Restart RouteAgent to regenerate table 150 route:**

   **ACM-Managed:**
   ```bash
   kubectl delete pod -n <managed-cluster-namespace> \
     -l component=submariner-route-agent
   ```

   **Standalone:**
   ```bash
   kubectl delete pod -n submariner-operator \
     -l app=submariner-route-agent
   ```

3. **Verify after restart:**
   ```bash
   ip route show table 150
   # Should show: default via <valid-host-ip> dev ovn-k8s-mp0
   ```

**⚠️ WORKAROUND:** RouteAgent restart regenerates table 150 route, but does NOT fix root cause.
OVN-K or node reboot can revert it. See [ovn-offline-verification.md](ovn-offline-verification.md)
for full OVN-K configuration verification.

#### Pattern B: Post-Decapsulation Routing Issue

**Evidence:**
- SNAT counter > 0 (packets leaving cluster1)
- Tunnel tcpdump shows packets
- DNAT counter = 0 (packets NOT arriving at cluster2 DNAT rule)

**Analysis:**
```
Observation: Packets appear to reach gateway but not DNAT rule
Possible cause: Post-decapsulation routing issue
```

**This pattern suggests:** After VXLAN decapsulation, packets may not be routed to ovn-k8s-mp0 interface where DNAT rules are applied.

**Use cautious language:** "appears to be", "most likely", "evidence suggests" - this is complex infrastructure behavior.

#### Pattern C: Infrastructure Blocking

**Evidence:**
- SNAT counter > 0
- Tunnel tcpdump = 0 packets
- DNAT counter = 0

**IMPORTANT:** Before concluding infrastructure blocking, check Gateway CR tunnel status on both clusters:

- **If asymmetric** (one cluster connected, other shows different status):
  - NOT infrastructure blocking
  - Pattern indicates local routing or SNAT issue
  - See [asymmetric-tunnel-analysis.md](asymmetric-tunnel-analysis.md)

- **If symmetric** (both clusters show same error status):
  - Proceed with infrastructure blocking analysis

**Analysis (when symmetric error):**
```
Evidence suggests packets not leaving source gateway
Possible cause: Infrastructure/firewall blocking
```

#### Pattern D: Source Not Sending

**Evidence:**
- SNAT counter = 0
- Tunnel tcpdump = 0
- DNAT counter = 0

**Analysis:**
```
Source gateway not sending health checks
Check: IP rules, routing table 150, gateway pod health
```

### Correlation Methodology

1. **Extract ICMP IDs from tcpdump:**
   - Look for patterns like "ICMP ID 12345: X requests, Y replies"
   - Group by success rate (0-30% = failing, 90-100% = working)

2. **Identify health check types:**
   - High-frequency (1-second interval) = Gateway checks
   - Low-frequency (60-second interval) = RouteAgent checks

3. **Cross-reference with nftables:**
   - Nonzero SNAT egress counter indicates gateway is sending
   - Nonzero DNAT ingress counter indicates remote gateway is receiving
   - Counters are cumulative and track ALL traffic, not specific ICMP streams
   - Use as coarse flow health check, not for isolating individual packet drops

4. **Correlate with CR status:**
   - Gateway CR status reflects gateway-to-gateway health
   - RouteAgent CR status reflects full datapath (worker→gateway→remote)

### Important Notes

- **Don't conclude from single data point** - correlate all three stages
- **Always use cautious language** - "appears that", "evidence suggests", "most likely"
- **Present as evidence requiring correlation** - not definitive root cause
- **If Submariner config correct but broken** - possible infrastructure issue
- **Recommend community contact** - provide diagnostic tarball for investigation

### Example Analysis

```
ICMP Analysis Results:
  Gateway health checks (ICMP ID 15832): 0% success
  RouteAgent health checks (ICMP ID 26003): 100% success

nftables Counters:
  Cluster1 SNAT egress: 13,049 packets
  Cluster2 DNAT ingress: 63,552 packets

  ⚠️  IMPORTANT: nftables counters are cumulative since ruleset loaded.
  They track ALL traffic (not just health checks), so non-zero counters
  indicate overall flow health but cannot isolate specific ICMP streams.
  Use ICMP ID correlation to distinguish health check vs other traffic.

Cross-Reference with CRs:
  Gateway CR: status=error
  RouteAgent CR: status=connected

Pattern: Table 150 Routing Issue
  ✓ Worker→GW→Remote path works (RouteAgent proves it)
  ✗ Gateway→Remote path fails (gateway checks fail)

Appears to be: Gateway node table 150 configuration issue
Verify: Check *_ip-routes-table150.log for network address pattern
Recommend: Further investigation with additional data points
```

### When to Use This Analysis

- **Required:** Cable driver = VXLAN
- **Helpful:** Enhanced tcpdump with ICMP capture
- **Critical:** Gateway error + RouteAgent connected pattern
- **Skip:** Both Gateway and RouteAgent show same status (focus on tunnel analysis first)
