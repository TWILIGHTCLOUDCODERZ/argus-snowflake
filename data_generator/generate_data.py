#!/usr/bin/env python3
"""
ARGUS synthetic data generator  ·  Created by TCC
Snowflake CoCo Hack (GCC Edition) — Week 1

Generates referentially consistent, PRIVACY-SAFE synthetic data for THREE banks
(BANK_A / BANK_B / BANK_C) with realistic clean noise plus deliberately PLANTED
cross-bank fraud rings. A ground-truth file records every planted entity so we
can measure detection recall / false-positive rate in Week 4.

Pure standard library. Deterministic (fixed seed) => reproducible datasets.

Outputs (CSV) into ../data:
  banks.csv, customers.csv, accounts.csv, device_logins.csv, transactions.csv
  ground_truth/planted_rings.json

NOTE: raw national_id / phone stay in customers.csv (a bank's PRIVATE table).
The *_hash columns are what a Snowflake Data Clean Room would share across banks.
Nothing here is real; do not use production data.
"""
from __future__ import annotations
import csv, hashlib, json, os, random
from datetime import datetime, timedelta

# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
SEED = 4471
CLEAN_ROOM_SALT = "argus-tcc-clean-room-salt"   # simulates clean-room hashing
CURRENCY = "AED"
CTR_THRESHOLD = 55_000                            # cash reporting threshold (demo)
BASE_DATE = datetime(2026, 9, 1)                  # analysis window start
WINDOW_DAYS = 30

BANKS = [
    {"bank_id": "BANK_A", "bank_name": "Gulf National Bank",   "country": "AE", "regulator": "CBUAE"},
    {"bank_id": "BANK_B", "bank_name": "Levant Commercial",    "country": "SA", "regulator": "SAMA"},
    {"bank_id": "BANK_C", "bank_name": "Peninsula Finance NBFC","country": "BH", "regulator": "CBB"},
]
CUSTOMERS_PER_BANK = 180
EXTRA_ACCOUNTS_RATE = 0.15         # some customers hold 2 accounts
NORMAL_TXNS_PER_ACCOUNT = (6, 22)  # min,max clean transactions per account

random.seed(SEED)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "data"))
GT = os.path.join(OUT, "ground_truth")
os.makedirs(GT, exist_ok=True)

FIRST = ["Ahmed","Fatima","Omar","Layla","Yusuf","Aisha","Khalid","Mariam","Ali","Noor",
         "Hassan","Sara","Ibrahim","Huda","Tariq","Zainab","Faisal","Amal","Rashid","Salma",
         "Bilal","Reem","Nasser","Dana","Saeed","Lina","Majid","Hana","Waleed","Rania"]
LAST = ["Al-Farsi","Haddad","Nasser","Khoury","Rahman","Saleh","Aziz","Mansour","Qasimi","Habib",
        "Baloch","Siddiqui","Darwish","Fakhoury","Mroue","Zahran","Othman","Hariri","Ghanem","Sayegh"]
NATIONALITIES = ["AE","SA","BH","IN","PK","EG","PH","JO","LB","SD"]

def h(value: str) -> str:
    return hashlib.sha256((CLEAN_ROOM_SALT + "|" + str(value)).encode()).hexdigest()[:24]

def iban(bank_id: str, n: int) -> str:
    cc = {"BANK_A": "AE", "BANK_B": "SA", "BANK_C": "BH"}[bank_id]
    return f"{cc}{(n*7 % 89)+10:02d}{bank_id[-1]}{n:016d}"

def ts_in_window(day_lo=0, day_hi=WINDOW_DAYS):
    d = random.randint(day_lo, day_hi - 1)
    return BASE_DATE + timedelta(days=d, hours=random.randint(6, 22), minutes=random.randint(0, 59))

# --------------------------------------------------------------------------- #
# Accumulators
# --------------------------------------------------------------------------- #
customers, accounts, logins, txns = [], [], [], []
accounts_by_bank: dict[str, list[dict]] = {b["bank_id"]: [] for b in BANKS}
_txn_seq = 0
_login_seq = 0

def new_txn(acc, direction, amount, channel, cp_iban, cp_bank, purpose, ts):
    global _txn_seq
    _txn_seq += 1
    row = {
        "txn_id": f"TX{_txn_seq:08d}", "bank_id": acc["bank_id"], "account_id": acc["account_id"],
        "direction": direction, "amount": round(amount, 2), "currency": CURRENCY, "channel": channel,
        "counterparty_iban": cp_iban, "counterparty_bank": cp_bank, "purpose_code": purpose,
        "ts": ts.isoformat(sep=" "),
    }
    txns.append(row)
    return row

def new_login(acc, device_hash, ts):
    global _login_seq
    _login_seq += 1
    logins.append({
        "login_id": f"LG{_login_seq:08d}", "bank_id": acc["bank_id"], "account_id": acc["account_id"],
        "device_hash": device_hash, "ip_hash": h(f"ip-{random.randint(1,9999)}"), "ts": ts.isoformat(sep=" "),
    })

# --------------------------------------------------------------------------- #
# 1. Populate normal customers / accounts / clean transactions
# --------------------------------------------------------------------------- #
cust_seq = 0
for b in BANKS:
    bid = b["bank_id"]
    for _ in range(CUSTOMERS_PER_BANK):
        cust_seq += 1
        nat_id = f"{random.choice(NATIONALITIES)}-{random.randint(10**8, 10**9-1)}"
        phone = f"+9715{random.randint(10**7, 10**8-1)}"
        name = f"{random.choice(FIRST)} {random.choice(LAST)}"
        cust = {
            "customer_id": f"C{cust_seq:06d}", "bank_id": bid, "full_name": name,
            "national_id": nat_id, "national_id_hash": h(nat_id),
            "phone": phone, "phone_hash": h(phone),
            "email": f"user{cust_seq}@example.com", "nationality": random.choice(NATIONALITIES),
            "dob": f"19{random.randint(60,99)}-{random.randint(1,12):02d}-{random.randint(1,28):02d}",
            "kyc_risk_rating": random.choices(["low","medium","high"], weights=[70,25,5])[0],
            "onboarded_at": (BASE_DATE - timedelta(days=random.randint(30, 1500))).date().isoformat(),
        }
        customers.append(cust)
        n_acc = 1 + (1 if random.random() < EXTRA_ACCOUNTS_RATE else 0)
        for _a in range(n_acc):
            acc_n = len(accounts) + 1
            acc = {
                "account_id": f"A{acc_n:07d}", "bank_id": bid, "customer_id": cust["customer_id"],
                "iban": iban(bid, acc_n), "account_type": random.choice(["current","savings","wallet"]),
                "currency": CURRENCY, "status": random.choices(["active","dormant"], weights=[92,8])[0],
                "opened_at": cust["onboarded_at"],
            }
            accounts.append(acc); accounts_by_bank[bid].append(acc)

# Each customer owns 1-2 personal devices. Logins come only from those, so a
# device seen at more than one bank is a meaningful signal, not random noise.
cust_devices = {c["customer_id"]: [h(f"dev-{c['customer_id']}-{k}") for k in range(random.randint(1, 2))]
                for c in customers}

# clean transactions + logins for every account
for acc in accounts:
    for _ in range(random.randint(*NORMAL_TXNS_PER_ACCOUNT)):
        purpose = random.choices(["salary","retail","remittance","p2p","other"], weights=[20,40,15,20,5])[0]
        direction = "credit" if purpose == "salary" else random.choice(["credit","debit"])
        amount = {"salary": random.uniform(4000,26000), "retail": random.uniform(30,3500),
                  "remittance": random.uniform(500,9000), "p2p": random.uniform(100,6000),
                  "other": random.uniform(50,4000)}[purpose]
        channel = {"salary":"transfer","retail":"card","remittance":"transfer","p2p":"wallet","other":"cash"}[purpose]
        new_txn(acc, direction, amount, channel, iban("BANK_A", random.randint(1,9999)), "EXTERNAL", purpose, ts_in_window())
    for _ in range(random.randint(1,4)):
        new_login(acc, random.choice(cust_devices[acc["customer_id"]]), ts_in_window())

planted = {"typologies": [], "benign_controls": []}

# --------------------------------------------------------------------------- #
# 2. PLANTED typologies (cross-bank) — recorded as ground truth
# --------------------------------------------------------------------------- #
def pick_accounts(bid, k):
    return random.sample(accounts_by_bank[bid], k)

# --- T1: fan-in / fan-out mule ring spanning all 3 banks (6-day burst) -------
def plant_fan_in_fan_out(tid):
    burst_start = random.randint(2, WINDOW_DAYS - 8)
    def bt():
        return BASE_DATE + timedelta(days=burst_start + random.randint(0,5),
                                     hours=random.randint(8,20), minutes=random.randint(0,59))
    sources = [a for bid in accounts_by_bank for a in pick_accounts(bid, 3)]       # 9 source mules
    funnels = {b["bank_id"]: pick_accounts(b["bank_id"], 1)[0] for b in BANKS}     # 1 funnel per bank
    consolidation = funnels["BANK_A"]                                              # final consolidation
    members = []
    # sources push into their bank's funnel
    for s in sources:
        f = funnels[s["bank_id"]]
        amt = random.uniform(18_000, 34_000)
        new_txn(s, "debit", amt, "transfer", f["iban"], f["bank_id"], "p2p", bt())
        new_txn(f, "credit", amt, "transfer", s["iban"], s["bank_id"], "p2p", bt())
        members.append({"entity_type":"account","entity_id":s["account_id"],"role":"source_mule","bank_id":s["bank_id"]})
    # funnels forward to consolidation across banks
    for bid, f in funnels.items():
        if f["account_id"] == consolidation["account_id"]:
            continue
        amt = random.uniform(60_000, 95_000)
        new_txn(f, "debit", amt, "transfer", consolidation["iban"], consolidation["bank_id"], "p2p", bt())
        new_txn(consolidation, "credit", amt, "transfer", f["iban"], f["bank_id"], "p2p", bt())
        members.append({"entity_type":"account","entity_id":f["account_id"],"role":"funnel","bank_id":bid})
    members.append({"entity_type":"account","entity_id":consolidation["account_id"],"role":"consolidation","bank_id":consolidation["bank_id"]})
    planted["typologies"].append({
        "typology_id": tid, "name": "Cross-bank fan-in/fan-out mule ring",
        "structure": "9 source mules -> 3 per-bank funnels -> 1 consolidation account, 6-day burst",
        "banks_involved": ["BANK_A","BANK_B","BANK_C"], "burst_start_day": burst_start, "members": members,
    })

# --- T2: shared-identity (synthetic identity) ring across banks --------------
def plant_shared_identity(tid):
    shared_nid = f"AE-{random.randint(10**8,10**9-1)}"
    shared_dev = h(f"dev-synthetic-{tid}")
    members = []
    for b in BANKS:
        acc = pick_accounts(b["bank_id"], 1)[0]
        cust = next(c for c in customers if c["customer_id"] == acc["customer_id"])
        cust["national_id"] = shared_nid                # SAME identity reused
        cust["national_id_hash"] = h(shared_nid)
        cust["kyc_risk_rating"] = "high"
        new_login(acc, shared_dev, ts_in_window())      # SAME device
        members.append({"entity_type":"customer","entity_id":cust["customer_id"],"role":"shared_identity","bank_id":b["bank_id"]})
        members.append({"entity_type":"account","entity_id":acc["account_id"],"role":"shared_identity_account","bank_id":b["bank_id"]})
    planted["typologies"].append({
        "typology_id": tid, "name": "Shared-identity / synthetic-identity ring",
        "structure": "one national_id_hash + one device_hash reused to open accounts at 3 banks",
        "banks_involved": ["BANK_A","BANK_B","BANK_C"], "shared_national_id_hash": h(shared_nid),
        "shared_device_hash": shared_dev, "members": members,
    })

# --- T3: structuring (smurfing) just under CTR threshold ---------------------
def plant_structuring(tid):
    acc = pick_accounts(random.choice([b["bank_id"] for b in BANKS]), 1)[0]
    day0 = random.randint(2, WINDOW_DAYS - 7)
    n = random.randint(8, 11); members = []
    for i in range(n):
        amt = random.uniform(CTR_THRESHOLD - 3000, CTR_THRESHOLD - 200)  # just under threshold
        ts = BASE_DATE + timedelta(days=day0 + i // 2, hours=random.randint(9,18))
        new_txn(acc, "credit", amt, "cash", "", "EXTERNAL", "other", ts)
    members.append({"entity_type":"account","entity_id":acc["account_id"],"role":"structuring","bank_id":acc["bank_id"]})
    planted["typologies"].append({
        "typology_id": tid, "name": "Cash structuring below reporting threshold",
        "structure": f"{n} cash deposits of ~{CTR_THRESHOLD-1500} {CURRENCY} over a few days (CTR threshold {CTR_THRESHOLD})",
        "banks_involved": [acc["bank_id"]], "members": members,
    })

# --- T4: circular layering loop A -> B -> C -> A -----------------------------
def plant_circular(tid):
    a = pick_accounts("BANK_A",1)[0]; b = pick_accounts("BANK_B",1)[0]; c = pick_accounts("BANK_C",1)[0]
    amt = random.uniform(120_000, 180_000); day0 = random.randint(3, WINDOW_DAYS-5)
    def bt(off): return BASE_DATE + timedelta(days=day0+off, hours=random.randint(9,17))
    hops = [(a,b,0),(b,c,1),(c,a,2)]
    for src,dst,off in hops:
        val = amt * random.uniform(0.9,0.98)
        new_txn(src,"debit",val,"transfer",dst["iban"],dst["bank_id"],"p2p",bt(off))
        new_txn(dst,"credit",val,"transfer",src["iban"],src["bank_id"],"p2p",bt(off))
    members = [{"entity_type":"account","entity_id":x["account_id"],"role":"layering_hop","bank_id":x["bank_id"]} for x in (a,b,c)]
    planted["typologies"].append({
        "typology_id": tid, "name": "Circular cross-bank layering loop",
        "structure": "A -> B -> C -> A, ~equal value returning to origin within days",
        "banks_involved": ["BANK_A","BANK_B","BANK_C"], "members": members,
    })

# --- BENIGN hard negative: household shares one tablet across 2 banks ---------
# Weak signal only (shared device, different identities, no suspicious flows).
# ARGUS must NOT escalate this — used to measure false positives in Week 4.
# Known quirk (kept for reproducibility): the random picks are not excluded from ring
# members, so with seed 4471 A0000275 is also a RING-005 source mule. The benign test
# uses A0000004 (see `benign_only_account` in planted_rings.json).
def plant_benign_shared_device(bid_):
    a = pick_accounts("BANK_A", 1)[0]; b = pick_accounts("BANK_B", 1)[0]
    household_dev = h(f"dev-household-{bid_}")
    new_login(a, household_dev, ts_in_window()); new_login(b, household_dev, ts_in_window())
    planted["benign_controls"].append({
        "control_id": bid_, "name": "Household shared device (benign)",
        "structure": "2 different identities at 2 banks share one device; normal flows only",
        "expected": "do_not_escalate", "shared_device_hash": household_dev,
        "members": [{"entity_type":"account","entity_id":x["account_id"],"bank_id":x["bank_id"]} for x in (a, b)],
    })

plant_fan_in_fan_out("RING-001")
plant_shared_identity("RING-002")
plant_structuring("RING-003")
plant_circular("RING-004")
plant_fan_in_fan_out("RING-005")   # a second mule ring for variety
plant_benign_shared_device("BENIGN-001")

# --------------------------------------------------------------------------- #
# 2b. LIVE FEED — future micro-batches with a forming fraud ring (RING-006)
# --------------------------------------------------------------------------- #
# All historical lists (txns, logins, customers, accounts) are frozen above.
# New random draws happen only from here onward; _txn_seq is NOT touched.

_used_accts = set()
for _t in planted["typologies"]:
    for _m in _t["members"]:
        if _m["entity_type"] == "account":
            _used_accts.add(_m["entity_id"])
for _bc in planted["benign_controls"]:
    for _m in _bc["members"]:
        if _m.get("entity_type") == "account":
            _used_accts.add(_m["entity_id"])

_avail = {bid: [a for a in accs if a["account_id"] not in _used_accts]
          for bid, accs in accounts_by_bank.items()}

live_rows: list[dict] = []
_lv_seq = 0

def _lv_txn(fseq, bno, acc, direction, amount, channel, cp_iban, cp_bank, purpose):
    global _lv_seq
    _lv_seq += 1
    return {
        "feed_seq": fseq, "batch_no": bno, "txn_id": f"LV{_lv_seq:08d}",
        "bank_id": acc["bank_id"], "account_id": acc["account_id"],
        "direction": direction, "amount": round(amount, 2), "currency": CURRENCY,
        "channel": channel, "counterparty_iban": cp_iban,
        "counterparty_bank": cp_bank, "purpose_code": purpose,
    }

# RING-006: cross-bank fan-in/fan-out forming gradually over batches 3-10
# consolidation = BANK_B funnel (different bank from RING-001/005 which use BANK_A)
_r6_sources = {bid: random.sample(_avail[bid], 3) for bid in ["BANK_A", "BANK_B", "BANK_C"]}
_r6_src_ids = {a["account_id"] for bid in _r6_sources for a in _r6_sources[bid]}
_r6_funnels = {bid: random.choice([a for a in _avail[bid] if a["account_id"] not in _r6_src_ids])
               for bid in ["BANK_A", "BANK_B", "BANK_C"]}
_r6_consolidation = _r6_funnels["BANK_B"]

# Schedule source->funnel transfers across batches 3-7
_r6_xfers: list[tuple] = []  # (batch, sender, receiver, amount)
_all_src = [(bid, s) for bid in ["BANK_A", "BANK_B", "BANK_C"] for s in _r6_sources[bid]]
for _i, (_bid, _src) in enumerate(_all_src):
    _batch = 3 + (_i * 5) // len(_all_src)  # spread 9 sources across batches 3-7
    _r6_xfers.append((_batch, _src, _r6_funnels[_bid], random.uniform(18_000, 34_000)))

# Schedule funnel->consolidation cross-bank transfers in batches 8-10
for _bid in ["BANK_A", "BANK_C"]:  # BANK_B funnel IS the consolidation
    _r6_xfers.append((random.choice([8, 9, 10]), _r6_funnels[_bid], _r6_consolidation,
                       random.uniform(60_000, 95_000)))

# All accounts available for noise (excluding ring-006 members for cleanliness)
_r6_all_ids = _r6_src_ids | {_r6_funnels[b]["account_id"] for b in _r6_funnels}
_noise_pool = [a for a in accounts if a["account_id"] not in _r6_all_ids]

_feed_seq = 0
for _bno in range(1, 13):
    # ~15 clean noise transactions per batch
    for _nacc in random.sample(_noise_pool, 15):
        _purpose = random.choices(["salary","retail","remittance","p2p","other"], weights=[20,40,15,20,5])[0]
        _dir = "credit" if _purpose == "salary" else random.choice(["credit","debit"])
        _amt = {"salary": random.uniform(4000,26000), "retail": random.uniform(30,3500),
                "remittance": random.uniform(500,9000), "p2p": random.uniform(100,6000),
                "other": random.uniform(50,4000)}[_purpose]
        _ch = {"salary":"transfer","retail":"card","remittance":"transfer","p2p":"wallet","other":"cash"}[_purpose]
        _feed_seq += 1
        live_rows.append(_lv_txn(_feed_seq, _bno, _nacc, _dir, _amt, _ch,
                                 iban("BANK_A", random.randint(1,9999)), "EXTERNAL", _purpose))

    # RING-006 transfers scheduled for this batch (both legs)
    for (_b, _snd, _rcv, _a) in _r6_xfers:
        if _b != _bno:
            continue
        _feed_seq += 1
        live_rows.append(_lv_txn(_feed_seq, _bno, _snd, "debit", _a, "transfer",
                                 _rcv["iban"], _rcv["bank_id"], "p2p"))
        _feed_seq += 1
        live_rows.append(_lv_txn(_feed_seq, _bno, _rcv, "credit", _a, "transfer",
                                 _snd["iban"], _snd["bank_id"], "p2p"))

# Record RING-006 ground truth
_r6_members: list[dict] = []
for _bid in ["BANK_A", "BANK_B", "BANK_C"]:
    for _s in _r6_sources[_bid]:
        _r6_members.append({"entity_type":"account","entity_id":_s["account_id"],"role":"source_mule","bank_id":_bid})
    if _r6_funnels[_bid]["account_id"] != _r6_consolidation["account_id"]:
        _r6_members.append({"entity_type":"account","entity_id":_r6_funnels[_bid]["account_id"],"role":"funnel","bank_id":_bid})
_r6_members.append({"entity_type":"account","entity_id":_r6_consolidation["account_id"],"role":"consolidation","bank_id":_r6_consolidation["bank_id"]})

planted["live_typologies"] = [{
    "typology_id": "RING-006",
    "name": "Cross-bank fan-in/fan-out mule ring (live forming)",
    "structure": "9 source mules -> 3 per-bank funnels -> 1 consolidation (BANK_B), forming over batches 3-10",
    "banks_involved": ["BANK_A", "BANK_B", "BANK_C"],
    "forms_over_batches": [3, 10],
    "members": _r6_members,
}]

# --------------------------------------------------------------------------- #
# 3. Write CSVs + ground truth
# --------------------------------------------------------------------------- #
def write_csv(name, rows, fields):
    with open(os.path.join(OUT, name), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields); w.writeheader(); w.writerows(rows)

write_csv("banks.csv", BANKS, ["bank_id","bank_name","country","regulator"])
write_csv("customers.csv", customers,
          ["customer_id","bank_id","full_name","national_id","national_id_hash","phone","phone_hash",
           "email","nationality","dob","kyc_risk_rating","onboarded_at"])
write_csv("accounts.csv", accounts,
          ["account_id","bank_id","customer_id","iban","account_type","currency","status","opened_at"])
write_csv("device_logins.csv", logins, ["login_id","bank_id","account_id","device_hash","ip_hash","ts"])
write_csv("transactions.csv", txns,
          ["txn_id","bank_id","account_id","direction","amount","currency","channel",
           "counterparty_iban","counterparty_bank","purpose_code","ts"])
write_csv("live_feed.csv", live_rows,
          ["feed_seq","batch_no","txn_id","bank_id","account_id","direction","amount","currency",
           "channel","counterparty_iban","counterparty_bank","purpose_code"])

planted["meta"] = {"seed": SEED, "currency": CURRENCY, "ctr_threshold": CTR_THRESHOLD,
                   "base_date": BASE_DATE.date().isoformat(), "window_days": WINDOW_DAYS}
with open(os.path.join(GT, "planted_rings.json"), "w", encoding="utf-8") as f:
    json.dump(planted, f, indent=2)

print("ARGUS synthetic data generated:")
print(f"  banks            : {len(BANKS)}")
print(f"  customers        : {len(customers)}")
print(f"  accounts         : {len(accounts)}")
print(f"  device_logins    : {len(logins)}")
print(f"  transactions     : {len(txns)}")
print(f"  planted rings    : {len(planted['typologies'])}  -> data/ground_truth/planted_rings.json")
print(f"  benign negatives : {len(planted['benign_controls'])}")
print(f"  live_feed rows   : {len(live_rows)}  (batches: 12)")
print(f"  output dir       : {OUT}")
