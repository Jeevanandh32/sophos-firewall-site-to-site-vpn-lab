# Runbook: Sophos Firewall site-to-site lab on AWS

The steps below are in order. Values in `<angle brackets>` come from `terraform output firewalls`.

## 0. Prerequisites (one time)

1. Subscribe to **Sophos Firewall Standalone PAYG** in AWS Marketplace and accept the terms.
   Without this, CloudFormation fails with `OptInRequired`.
2. If your public IP changes (for example, on a new Wi-Fi network), update `terraform/terraform.tfvars` and re-run apply.
   WebAdmin and SSH accept only that IP.

## 1. Deploy (about 15 min, mostly the Sophos boot)

```bash
cd terraform
terraform apply            # review the plan, then type yes
terraform output firewalls
terraform output -json admin_passwords
```

Wait about 10 minutes after apply finishes before opening WebAdmin. Sophos keeps booting after EC2 reports "running".

## 2. Log in and check the interfaces (both firewalls)

1. Open `https://<public_ip>:4444` and accept the self-signed certificate warning.
2. Log in as `admin` with the password for that site.
3. Go to **Network > Interfaces** and check that both ports and their zones are correct:
   - **PortA** = LAN zone, `<lan_private_ip>`
   - **PortB** = WAN zone, `<wan_private_ip>`
4. Go to **Rules and policies > NAT rules** and confirm the default SNAT (MASQ) rule exists.
   It translates LAN traffic to the PortB address, and AWS then maps that to the Elastic IP.

## 3. Firewall policy (Site A; repeat on B if you like)

Create these rules under **Rules and policies > Firewall rules > Add firewall rule**. Rule order matters, so the deny rule must sit above the allow rule.

| # | Name | Action | Source zone/network | Destination zone | Service | Extras |
|---|------|--------|---------------------|------------------|---------|--------|
| 1 | `Deny-LAN-ICMP-Internet` | Drop | LAN / `10.10.0.0/24` | WAN | ICMP Echo (create the service if it's missing) | Log firewall traffic ✔ |
| 2 | `Allow-LAN-to-WAN` | Accept | LAN / `10.10.0.0/24` | WAN | Any | Log ✔; Web policy = `Lab-Block-Social`; NAT = default SNAT |

**Web filter:**
1. Go to **Web > Policies > Add policy** and name it `Lab-Block-Social`.
2. Add a rule that blocks the **Social networking** category and allows everything else.
3. Attach the policy to rule 2.
4. Leave HTTPS decryption off. Sophos still blocks by SNI, and the client sees a failed TLS handshake or a certificate error.

**Logs:** go to **Monitor & analyze > Log viewer** and select **Firewall**, then filter by rule name.
- A dropped ping shows rule `Deny-LAN-ICMP-Internet` with a drop action.
- A blocked site shows under **Web filter**.

## 4. Site-to-site IPsec VPN (IKEv2, PSK)

On **both** firewalls, start with **Administration > Device access**: tick **IPsec** in the **WAN** row, then click Apply and OK. Without it, IKE is dropped and the tunnel never starts.

Pick a long random pre-shared key (PSK), for example with `openssl rand -base64 32`, and use the same one on both sides.

Create the connection under **Site-to-site VPN > IPsec > Add**:

| Field | Site A | Site B |
|-------|--------|--------|
| Name | `S2S_A_to_B` | `S2S_B_to_A` (no hyphens, which SFOS rejects) |
| Connection type | Site-to-site | Site-to-site |
| Gateway type | **Initiate the connection** | **Respond only** |
| Activate on save / Create firewall rule | ✔ / ✔ | ✔ / ✔ |
| Encryption profile | IKEv2 (same profile both sides) | IKEv2 |
| Authentication | Preshared key | same key |
| Listening interface | PortB `<wan_private_ip>` | PortB `<wan_private_ip>` |
| Local ID (IP address) | **Site A public IP** | **Site B public IP** |
| Local subnet | `10.10.0.0/24` | `10.20.0.0/24` |
| Remote gateway | Site B public IP | Site A public IP |
| Remote ID (IP address) | Site B public IP | Site A public IP |
| Remote subnet | `10.20.0.0/24` | `10.10.0.0/24` |

**Why the Local ID is the public IP:** each firewall only sees its private PortB address. AWS NATs it 1:1 to the Elastic IP. So the IDs must be set explicitly, and IKE switches to NAT-T on UDP 4500. Terraform already opens UDP 500, UDP 4500 and ESP between the two public IPs only.

Configure B first, then A. Under **Site-to-site VPN > IPsec**, make sure **Active** is green on both, then click the **Connection** dot on A. Both indicators should turn green, and `ipsec statusall` (Advanced shell) shows `ESTABLISHED`.

The "Create firewall rule" option adds a rule that allows LAN ↔ VPN traffic. Open it and confirm that it's above the WAN rules and limited to the two subnets.

## 5. Test from the clients

```bash
terraform output clients    # copy the ssh command for site-a
# on client-site-a:
sudo tcpdump -ni ens5 icmp &     # watch packets in parallel
bash client-tests.sh a
```

Copy the test script to the client first, either with `scp` over the same Instance Connect tunnel or by pasting it.

Expected results:
- **Internet:** HTTPS works, and the reported public IP is Site A's Elastic IP, which proves NAT.
- **Deny rule:** ping to 1.1.1.1 fails, and the drop shows up in the log viewer.
- **Web filter:** facebook.com fails, and wikipedia.org works.
- **VPN:** ping and SSH to `10.20.0.50` work.

  On fw-a, use **Diagnostics > Packet capture** with filter `host 10.20.0.50` to show the traffic entering the tunnel. Run `tcpdump` on client-site-b to see the packets arrive with source `10.10.0.50` (no NAT across the tunnel).

Save the result files and screenshots to `docs/screenshots/`.

## 6. Backup and restore (Site A)

1. One-time setup: create the **secure storage master key**. SFOS v22 refuses to create backups without it.
   Then go to **Backup & firmware > Backup & restore** and click **Backup now** (local), then **Download > Download backup**.
   Download the file to `backups/` (git-ignored) and note the backup encryption password.
2. Make a visible change, for example by disabling rule 1 (`Deny-LAN-ICMP-Internet`).
   Show that ping to 1.1.1.1 now works.
3. Choose **Upload and restore** with the backup file and password. Click OK on the warning, enter the SSMK, and confirm the interface mapping. The firewall reboots, which takes about 6 minutes, and the web filter needs about 2 more minutes after that.
4. Confirm the change is gone: rule 1 is enabled again, and ping to 1.1.1.1 fails again.
5. Re-run `client-tests.sh a` to capture the before/after evidence.

## 7. Tear down (do not skip: the lab bills hourly)

```bash
cd terraform && terraform destroy
```

This removes both CloudFormation stacks (firewalls, VPCs, EIPs, secrets), the clients and the endpoints.

Afterwards, cancel the Marketplace subscription if you're done for good (**AWS Marketplace > Manage subscriptions**). The secrets stay in "scheduled deletion" for 30 days at no meaningful cost.
