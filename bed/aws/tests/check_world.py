#!/usr/bin/env python3
# check_world.py WORLD.json AREA... : assertions on the fake's world after spawn_demo.sh ran (prints "ok ..." / "FAIL ..."; exit 1 on a FAIL).
# AREAS: policies (IAM roles, trust, KMS key policy), machines, net ORCH_CIDR, ecr, kms, bucket-untouched
import json, re, sys

ACCOUNT, REGION, CAMPAIGN, PROJECT = "123456789012", "ap-south-1", "demo1", "rhobound-demo"
BUCKET = "rhobound-research-%s-%s" % (ACCOUNT, REGION)
REPO = "rhobound-demo/kshop"
REPO_ARN = "arn:aws:ecr:%s:%s:repository/%s" % (REGION, ACCOUNT, REPO)
SECRETS_ARN = "arn:aws:secretsmanager:%s:%s:secret:rhobound-demo/*" % (REGION, ACCOUNT)
NODE, TOOLS = "rbd-demo1-node", "rbd-demo1-tools"
KMS_ACTIONS = {"kms:Sign", "kms:Verify", "kms:GetPublicKey", "kms:DescribeKey"}
MACHINES = {   # name: (role, type, disk, profile, hop)
    "rbd-d-cp1": ("cp", "m6a.large", 40, NODE, 1), "rbd-d-edge1": ("edge", "m6a.xlarge", 100, NODE, 1),
    "rbd-d-load1": ("load", "m6a.xlarge", 40, NODE, 1), "rbd-d-app1": ("app", "m6a.xlarge", 60, NODE, 1),
    "rbd-d-app2": ("app", "m6a.xlarge", 60, NODE, 1), "rbd-d-app3": ("app", "m6a.xlarge", 60, NODE, 1),
    "rbd-d-ab1": ("ab", "m6a.xlarge", 60, NODE, 1), "rbd-tools1": ("tools", "m6a.2xlarge", 200, TOOLS, 1)}

W = json.load(open(sys.argv[1]))
FAILS = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def lst(x):
    return x if isinstance(x, list) else [x]


def stmts(doc):
    return doc.get("Statement", [])


def actions(doc):
    return {a for s in stmts(doc) for a in lst(s["Action"])}


def policies():
    roles = W["roles"]
    check(set(roles) == {NODE, TOOLS}, "exactly the two roles exist: %s" % sorted(roles))
    for r in (NODE, TOOLS):
        if r not in roles:
            continue
        t = roles[r]["trust"]
        check(stmts(t) == [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}], "%s trusts ec2.amazonaws.com only" % r)
        check(roles[r]["tags"] == {"project": PROJECT, "cluster": CAMPAIGN}, "%s tagged project/cluster" % r)
        check(len(roles[r]["policies"]) == 1, "%s has one inline policy (%s)" % (r, sorted(roles[r]["policies"])))
        check(W["profiles"].get(r, {}).get("roles") == [r], "instance profile %s holds role %s" % (r, r))
        for doc in roles[r]["policies"].values():
            acts = actions(doc)
            check(not any("Delete" in a or a.endswith(":*") or a == "*" for a in acts), "%s: no Delete action, no wildcard action (%s)" % (r, sorted(acts)))
            for s in stmts(doc):
                check(s["Effect"] == "Allow", "%s %s: Allow only" % (r, s.get("Sid")))
                for res in lst(s["Resource"]):
                    if res == "*":
                        check(lst(s["Action"]) == ["ecr:GetAuthorizationToken"], "%s %s: Resource * only for ecr:GetAuthorizationToken" % (r, s.get("Sid")))
    if NODE in roles and roles[NODE]["policies"]:
        doc = list(roles[NODE]["policies"].values())[0]
        check(actions(doc) == {"s3:ListBucket", "s3:PutObject"}, "node: actions exactly s3:ListBucket + s3:PutObject")
        check(not any(a.split(":")[0] in ("ecr", "kms", "secretsmanager", "iam") for a in actions(doc)), "node: nothing of ECR, KMS, Secrets Manager, IAM")
        for s in stmts(doc):
            if "s3:PutObject" in lst(s["Action"]):
                check(lst(s["Resource"]) == ["arn:aws:s3:::%s/demo1/d/*" % BUCKET], "node: PutObject only under demo1/d/* (not demo1/ledger/)")
            if "s3:ListBucket" in lst(s["Action"]):
                check(lst(s["Resource"]) == ["arn:aws:s3:::%s" % BUCKET], "node: ListBucket on the research bucket")
                pre = s.get("Condition", {}).get("StringLike", {}).get("s3:prefix", [])
                check(bool(pre) and all(p.startswith("demo1/d/") for p in lst(pre)), "node: ListBucket limited to prefix demo1/d/ (%s)" % pre)
    if TOOLS in roles and roles[TOOLS]["policies"]:
        doc = list(roles[TOOLS]["policies"].values())[0]
        key_arns = {"arn:aws:kms:%s:%s:key/%s" % (REGION, ACCOUNT, k) for k, v in W["keys"].items() if v["state"] != "PendingDeletion"}
        for s in stmts(doc):
            a = set(lst(s["Action"])); res = lst(s["Resource"])
            svc = {x.split(":")[0] for x in a}
            check(len(svc) == 1, "tools %s: one service per statement" % s.get("Sid"))
            if svc == {"s3"}:
                if "s3:ListBucket" in a:
                    check(a == {"s3:ListBucket"} and res == ["arn:aws:s3:::%s" % BUCKET], "tools: ListBucket on the bucket alone")
                    pre = s.get("Condition", {}).get("StringLike", {}).get("s3:prefix", [])
                    check(bool(pre) and all(p.startswith("demo1/") for p in lst(pre)), "tools: ListBucket limited to prefix demo1/")
                else:
                    check(a == {"s3:GetObject", "s3:PutObject"} and res == ["arn:aws:s3:::%s/demo1/*" % BUCKET], "tools: Get/PutObject only under demo1/*")
            elif svc == {"ecr"}:
                if "ecr:GetAuthorizationToken" in a:
                    check(a == {"ecr:GetAuthorizationToken"} and res == ["*"], "tools: GetAuthorizationToken on * (ECR requires it)")
                else:
                    check(res == [REPO_ARN], "tools: ECR push/pull only on %s" % REPO)
                    need = {"ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:InitiateLayerUpload",
                            "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:DescribeImages"}
                    check(need <= a, "tools: ECR push, pull and describe actions present")
                    check(not any(x in a for x in ("ecr:BatchDeleteImage", "ecr:DeleteRepository", "ecr:SetRepositoryPolicy", "ecr:PutLifecyclePolicy")), "tools: no ECR delete/policy action")
            elif svc == {"kms"}:
                check(a == KMS_ACTIONS, "tools: KMS exactly Sign, Verify, GetPublicKey, DescribeKey")
                check(len(res) == 1 and res[0] in key_arns, "tools: KMS on the one live key (%s)" % res)
            elif svc == {"secretsmanager"}:
                check(a == {"secretsmanager:GetSecretValue"} and res == [SECRETS_ARN], "tools: GetSecretValue on rhobound-demo/* only")
            else:
                check(False, "tools: unexpected service %s" % svc)
        check({"s3", "ecr", "kms", "secretsmanager"} == {x.split(":")[0] for x in actions(doc)}, "tools: S3, ECR, KMS and Secrets Manager all granted")


def kms():
    alias = W["aliases"].get("alias/rhobound-demo-verdict")
    check(alias is not None, "alias/rhobound-demo-verdict exists")
    live = {k: v for k, v in W["keys"].items() if v["state"] != "PendingDeletion"}
    check(len(live) == 1 and alias in live, "exactly one live key, the alias's (%d live)" % len(live))
    if alias not in W["keys"]:
        return
    k = W["keys"][alias]
    check(k["spec"] == "ECC_NIST_P256" and k["usage"] == "SIGN_VERIFY", "key ECC_NIST_P256 / SIGN_VERIFY")
    check(k["tags"] == {"project": PROJECT, "cluster": CAMPAIGN}, "key tagged (TagKey/TagValue)")
    st = k["policy"]["Statement"]
    root = [s for s in st if s["Principal"] == {"AWS": "arn:aws:iam::%s:root" % ACCOUNT}]
    tools = [s for s in st if s["Principal"] == {"AWS": "arn:aws:iam::%s:role/%s" % (ACCOUNT, TOOLS)}]
    check(len(st) == 2 and len(root) == 1 and len(tools) == 1, "key policy: the account root and the tools role, nothing else")
    if root:
        check(root[0]["Action"] == "kms:*" and root[0]["Resource"] == "*" and root[0]["Effect"] == "Allow", "key policy: root admin statement (kms:*)")
    if tools:
        check(set(lst(tools[0]["Action"])) == KMS_ACTIONS and tools[0]["Effect"] == "Allow", "key policy: tools role Sign, Verify, GetPublicKey, DescribeKey")
    check(not any(NODE in json.dumps(s) for s in st), "key policy: the node role is not named")


def ecr():
    r = W["repos"].get(REPO)
    check(r is not None and len(W["repos"]) == 1, "ECR repository %s exists (and only it)" % REPO)
    if r:
        check(r["mut"] == "MUTABLE" and r["scan"] is True and r["enc"] == "AES256", "ECR: MUTABLE, scan on push, AES256")
        check(r["tags"] == {"project": PROJECT, "cluster": CAMPAIGN}, "ECR tagged project/cluster")


def machines():
    live = [i for i in W["instances"] if i["State"]["Name"] in ("pending", "running")]
    names = sorted({t["Value"] for i in live for t in i["Tags"] if t["Key"] == "Name"})
    check(names == sorted(MACHINES) and len(live) == len(MACHINES), "the 8 machines, once each: %s" % names)
    vcpu = {"large": 2, "xlarge": 4, "2xlarge": 8}
    check(sum(vcpu[i["InstanceType"].split(".")[1]] for i in live) == 34, "34 vCPU in all")
    for i in live:
        tm = {t["Key"]: t["Value"] for t in i["Tags"]}
        n = tm["Name"]
        if n not in MACHINES:
            continue
        role, typ, disk, prof, hop = MACHINES[n]
        check(tm.get("role") == role and tm.get("project") == PROJECT and tm.get("cluster") == CAMPAIGN and tm.get("max_hours") == "16",
              "%s: tags role=%s project cluster max_hours=16" % (n, role))
        check(i["InstanceType"] == typ, "%s: type %s (got %s)" % (n, typ, i["InstanceType"]))
        check("VolumeSize=%d,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true" % disk in i["_bdm"], "%s: %d GB gp3 encrypted" % (n, disk))
        check(i["_profile"] == prof, "%s: instance profile %s (got %s)" % (n, prof, i["_profile"]))
        check(i["_meta"] == "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=%d" % hop, "%s: IMDSv2 required, hop limit %d" % (n, hop))
        check(i["_shutdown"] == "terminate" and i["_public"] and i["_key"] == "rbd-demo1-orchestrator", "%s: shutdown=terminate, public IP, orchestrator key" % n)


def net(orch):
    vpcs = W["have"].get("vpcs", []); subs = W["have"].get("subnets", [])
    check(len(vpcs) == 1 and vpcs[0]["cidr"] == "10.82.0.0/16", "one VPC 10.82.0.0/16")
    check(len(subs) == 1 and subs[0]["cidr"] == "10.82.1.0/24", "one subnet 10.82.1.0/24")
    igws = W["have"].get("internet-gateways", [])
    check(len(igws) == 1 and vpcs and igws[0]["attached"] == vpcs[0]["id"], "one internet gateway, attached")
    check(W["have"].get("route") is True, "default route")
    check(len(W["sgs"]) == 1, "one security group")
    for sid, g in W["sgs"].items():
        ssh = sorted(r["CidrIp"] for p in g["perms"] if p["IpProtocol"] == "tcp" for r in p.get("IpRanges", []))
        other = [p for p in g["perms"] if p["IpProtocol"] != "tcp" and not p.get("UserIdGroupPairs")]
        self_ = [p for p in g["perms"] if p["IpProtocol"] == "-1" and p.get("UserIdGroupPairs") == [{"GroupId": sid}]]
        check(ssh == sorted(orch.split(",")), "ssh only from %s (got %s)" % (orch, ssh))
        check(all(p.get("FromPort") == 22 for p in g["perms"] if p["IpProtocol"] == "tcp"), "tcp rules are port 22 only")
        check(len(self_) == 1 and not other, "all traffic between members, nothing open to the world")


def bucket_untouched():
    check(W["buckets"] == {}, "no bucket created and no bucket setting written")


AREAS = {"policies": policies, "kms": kms, "ecr": ecr, "machines": machines, "bucket-untouched": bucket_untouched}
args = sys.argv[2:]
i = 0
while i < len(args):
    if args[i] == "net":
        net(args[i + 1]); i += 2
    else:
        AREAS[args[i]](); i += 1
sys.exit(1 if FAILS else 0)
