#!/usr/bin/env python3
"""
debz_db — Salt external pillar module.
Reads service and cluster definitions from state.db and provides
them as pillar data to minions so they know what to run.

Configure in /etc/salt/master.d/debz.conf:
  ext_pillar:
    - debz_db: {}
"""
import json
import sqlite3

DB_PATH = "/var/lib/debz/state.db"

def ext_pillar(minion_id, pillar, **kwargs):
    """Return debz pillar data for this minion."""
    data = {
        "debz": {
            "node":     {},
            "services": [],
            "cluster":  {},
        }
    }
    try:
        con = sqlite3.connect(DB_PATH)
        con.row_factory = sqlite3.Row

        # This node's own record
        row = con.execute(
            "SELECT * FROM nodes WHERE hostname=?", (minion_id,)
        ).fetchone()
        if row:
            nd = dict(row)
            try: nd["facts"] = json.loads(nd.get("facts", "{}"))
            except Exception: pass
            data["debz"]["node"] = nd

        # This node's cluster
        if row and row["cluster_id"]:
            crow = con.execute(
                "SELECT * FROM clusters WHERE id=?", (row["cluster_id"],)
            ).fetchone()
            if crow:
                cd = dict(crow)
                try: cd["data"] = json.loads(cd.get("data", "{}"))
                except Exception: pass
                data["debz"]["cluster"] = cd

        # Services targeted to this node (or all nodes)
        svc_rows = con.execute("SELECT * FROM services WHERE status != 'defined'").fetchall()
        for s in svc_rows:
            sd = dict(s)
            try: targets = json.loads(sd.get("node_targets", "[]"))
            except Exception: targets = []
            if not targets or minion_id in targets or "all" in targets:
                for f in ("node_targets", "repl_targets", "config"):
                    try: sd[f] = json.loads(sd.get(f, "{}"))
                    except Exception: sd[f] = {}
                data["debz"]["services"].append(sd)

        con.close()
    except Exception as e:
        # Don't break Salt if DB is unavailable (e.g. live ISO)
        data["debz"]["error"] = str(e)

    return data
