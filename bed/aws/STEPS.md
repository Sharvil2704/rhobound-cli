# demo1: your steps in AWS CloudShell

This page is for you, the owner. You run every command below in AWS CloudShell. The orchestrator (your workstation)
never runs `aws`. It reaches the machines over ssh only, after you paste it the inventory block.

Example values on this page: account `123456789012`, address `203.0.113.10`. The script refuses documentation
addresses on purpose, so always type the real one.

## What it creates and what it costs

| | |
|---|---|
| Machines | 8 on-demand machines, 34 vCPU: `rbd-d-cp1` (2 vCPU), `rbd-d-edge1`, `rbd-d-load1`, `rbd-d-app1..3`, `rbd-d-ab1` (4 each) and `rbd-tools1` (8). Ubuntu 24.04, one zone of ap-south-1, own network `10.82.0.0/16`. ssh is open to the orchestrator's address only. |
| Other things | Two roles (`rbd-demo1-node`, `rbd-demo1-tools`), the ECR repository `rhobound-demo/kshop`, the KMS signing key `alias/rhobound-demo-verdict`. Later, if you add them, secrets `rhobound-demo/NAME`. |
| S3 | Only the existing research bucket, only new files under `demo1/`. The script never changes or deletes the bucket. If the bucket is missing, `up` stops (it creates one only with `CREATE_BUCKET=1`). |
| Time cap | Every machine shuts itself down and is deleted **16 hours** after launch. The orchestrator can extend that, never past **48 hours**. |
| Price | About **1.06 USD per hour** for everything (machines 0.94 + disks 0.08 + public IPs 0.04). About **25.5 USD per day**, about **17 USD** if it runs to the 16-hour cap, about 51 USD at the 48-hour ceiling. Small extras: the KMS key (1 USD per month, prorated), each secret (0.40 USD per month), ECR and S3 storage (cents). |

These prices are the AWS list prices for ap-south-1. `plan` prints the live prices; if they differ, trust `plan`.
`up` refuses to start above 2.5 USD per hour (`BUDGET`).

## Before you start (once)

1. **Open CloudShell in Mumbai.** In the AWS console, set the region (top right) to **Asia Pacific (Mumbai)
   ap-south-1**. Then click the CloudShell icon. Use the default environment, not a VPC environment.
2. **Upload the script.** Actions, Upload file, pick `spawn_demo.sh`. Then check it:

       sha256sum spawn_demo.sh

   It must print `0026909b661e2be9ee1c57320f85f1ddd3fd5d897e5b493bbe5d6c1d14f05ab9`. If not, stop and ask.
3. **Find ORCH_IP.** EC2 console, Instances, select the orchestrator machine, copy its **Public IPv4 address**.
   It changes when that machine is stopped and started, so read it again on the day. The script has no default.

## Start the demo

Run these in the folder where you uploaded the script.

1. **Plan (creates nothing):**

       ORCH_IP=203.0.113.10 bash spawn_demo.sh plan

   Look for: about 1.06 USD per hour, `QUOTA OK`, and `plan done: nothing was created`. Any line with
   `OVER BUDGET`, `QUOTA TOO LOW` or `WARNING` means stop and send the output to the orchestrator.

2. **Up — only when the orchestrator says go.** The 16-hour clock starts at launch, so do not run `up` until the
   orchestrator tells you the kit is ready.

       ORCH_IP=203.0.113.10 bash spawn_demo.sh up

   Answer `y`. It takes about 5 minutes. Keep the tab active (press a key now and then). If the session ends or a
   step fails, run the same command again: it finds what exists and makes only what is missing.

3. **Inventory:**

       bash spawn_demo.sh inventory

   Copy everything from `# ---- paste everything` to `# ---- end` and paste it to the orchestrator. It has the
   account id and the machines' addresses, but no secret. From here the orchestrator takes over.

## During the day

- **More time.** `bash spawn_demo.sh extend 4` prints two lines. Paste them to the orchestrator; it runs them.
  CloudShell cannot reach the machines itself. Nothing can run past 48 hours after launch.
- **Status.** `bash spawn_demo.sh status` shows the machines, hours used and hours left.
- **The orchestrator's address changed** (it was stopped and started): run `up` again with the new address,
  `ORCH_IP=<new address> bash spawn_demo.sh up`. It adds the new address and creates nothing else. It prints a
  `deny-ip` line for the old address: run that line. Then run `inventory` again and paste it.
- **Let a second person ssh in** (rarely needed): `bash spawn_demo.sh allow-ip <their address>`; remove it with
  `bash spawn_demo.sh deny-ip <their address>`.
- **A key for the model or the judge (later, not on day 1):**

       bash spawn_demo.sh secret judge-key

  Paste the key at the hidden prompt and press Enter. You will not see it, and the script never prints it. Only
  `rbd-tools1` can read it. Never paste a key at the normal shell prompt: it would stay in the shell history.
  To remove it: `bash spawn_demo.sh secret-rm judge-key` (recoverable for 7 days). Also revoke the key at its
  provider.

## Stop

- **Down** (machines only): `bash spawn_demo.sh down`, then type `demo1`. Network, roles, ECR, KMS key and
  secrets stay, so a later `up` is quick.
- **Destroy** (everything): `bash spawn_demo.sh destroy`, type `demo1`, answer `y`. It then asks two more
  questions: delete the ECR repository with all images (`y` unless you want to keep them), and delete the secrets
  (`y` unless you will reuse a key soon).

What stays after destroy:

- the research bucket and everything under `demo1/` in it (never touched);
- the KMS key, **pending deletion for 7 days**, then gone (cancel in the KMS console within 7 days to keep it);
- deleted secrets, recoverable for 7 days.

If destroy prints `NOT removed: ...`, wait a minute and run it again.

## If something goes wrong

| You see | Do |
|---|---|
| `ORCH_IP is required` or `not a public IPv4 address` | Put the orchestrator's public address in front of the command, as above. |
| `QUOTA TOO LOW` | Stop other machines in ap-south-1, or raise "Running On-Demand Standard instances" in Service Quotas. |
| `no capacity for ...` | Nothing to do: the script tries another family (m6i, m7a, ...). If a machine is still missing, run `up` again later. |
| `NOT LAUNCHED: ...` (exit 3) | Run the same `up` again in a few minutes. |
| `credentials` or `ExpiredToken` errors | Reload the AWS console page, open CloudShell again, run the same command. |

`DRYRUN=1` in front of any command prints every change it would make and makes none.
