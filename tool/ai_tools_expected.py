"""Write what my org-roam MCP server's tools return on test graphs (#58).

The app's AI tools (lib/ai/ai_tools.dart) must give the same results as
the server (https://github.com/ChristianGeng/org-roam-mcp). This script
runs the server's own tool functions on two databases and writes their
results to test/fixtures/ai_tools_expected.json, which
test/ai/ai_tools_test.dart compares with the app:

- the sample notes in test/fixtures/roam/, in a database that
  tool/build_roam_db.dart builds with the app's parser (org-roam's schema
  and encoding, decision 23);
- the random graph of tool/graph_algorithms.py (#27), written straight
  into the same schema.

Run it in the server's environment, from this repo's root:

    uv run --project ~/work/myfiles/org-roam-mcp \\
        python tool/ai_tools_expected.py

The server finds its database through Emacs; here it is given the test
database instead, so no real notes are read.
"""

import hashlib
import json
from pathlib import Path
import random
import sqlite3
import subprocess
import tempfile

import community as community_louvain
from mcp.server.fastmcp import FastMCP
import networkx as nx
from org_roam_mcp import db
from org_roam_mcp import tools_roam

ROOT = Path(__file__).resolve().parent.parent
MAX_HOPS = 8


def server_tools(db_path):
    """The server's tool functions, on the database at db_path."""
    db.detect_db = lambda: str(db_path)
    server = FastMCP("test")
    tools_roam.register(server)
    return {t.name: t.fn for t in server._tool_manager.list_tools()}


def quoted(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def random_graph():
    """tool/graph_algorithms.py's random graph: 300 nodes, 1200 links, one
    to a missing ID."""
    rng = random.Random(7)
    count = 300
    nodes = [(f"n{i:03d}", f"Node {i:03d}") for i in range(count)]
    links = []
    for _ in range(1200):
        source = int(rng.random() ** 2 * count)
        links.append([f"n{source:03d}", f"n{rng.randrange(count):03d}"])
    links.append(["n000", "gone"])
    return nodes, links


def write_db(path, nodes, links):
    """nodes and links in org-roam's tables, as the server reads them."""
    conn = sqlite3.connect(path)
    conn.executescript(
        "CREATE TABLE files (file UNIQUE PRIMARY KEY, title, hash, atime, mtime);"
        "CREATE TABLE nodes (id NOT NULL PRIMARY KEY, file NOT NULL, level"
        " NOT NULL, pos NOT NULL, todo, priority, scheduled, deadline, title,"
        " properties, olp);"
        "CREATE TABLE links (pos NOT NULL, source NOT NULL, dest NOT NULL,"
        " type NOT NULL, properties NOT NULL);"
    )
    for node_id, title in nodes:
        conn.execute(
            "INSERT INTO nodes (id, file, level, pos, title) VALUES (?,?,0,1,?)",
            (quoted(node_id), quoted(f"/random/{node_id}.org"), quoted(title)),
        )
    for pos, (source, dest) in enumerate(links):
        conn.execute(
            "INSERT INTO links VALUES (?,?,?,?,?)",
            (pos + 1, quoted(source), quoted(dest), quoted("id"), "nil"),
        )
    conn.commit()
    conn.close()


def read_graph(path):
    """Node IDs and titles, and id: links, as the server's queries see them."""
    conn = sqlite3.connect(path)
    nodes = [
        (db._strip_elisp_quotes(i), db._strip_elisp_quotes(t)) for i, t in conn.execute("SELECT id, title FROM nodes")
    ]
    links = [
        [db._strip_elisp_quotes(s), db._strip_elisp_quotes(d)]
        for s, d in conn.execute("SELECT source, dest FROM links WHERE type = '\"id\"'")
    ]
    conn.close()
    return nodes, links


def louvain_ranges(nodes, links):
    """Louvain is random and the server sets no seed: the modularity (at
    resolution 1, as the server reports it) and the number of communities
    over 20 seeds, for each resolution the app is tested with."""
    graph = nx.DiGraph()
    for node_id, title in sorted(nodes, key=lambda n: n[1]):
        graph.add_node(node_id, title=title)
    for source, dest in links:
        graph.add_edge(source, dest)
    undirected = graph.to_undirected()
    result = {}
    for resolution in (0.5, 1.0, 2.0):
        runs = []
        for seed in range(20):
            partition = community_louvain.best_partition(undirected, resolution=resolution, random_state=seed)
            runs.append(
                (
                    community_louvain.modularity(partition, undirected),
                    len(set(partition.values())),
                )
            )
        result[str(resolution)] = {
            "modularity_min": min(m for m, _ in runs),
            "modularity_max": max(m for m, _ in runs),
            "communities_min": min(c for _, c in runs),
            "communities_max": max(c for _, c in runs),
        }
    return graph, result


def calls(tools, nodes, links, *, paths, read):
    ids = sorted(n for n, _ in nodes)
    some = ids if len(ids) <= 60 else random.Random(5).sample(ids, 40)
    results = {}

    def record(name, **args):
        results.setdefault(name, []).append([args, tools[name](**args)])

    for search in ["a", "ALPHA", "eta", "%", "_e", "node 01", "zz", ""]:
        record("org_roam_find", search=search)
    for node_id in some + ["gone"]:
        record("org_roam_backlinks", node_id=node_id)
        record("org_roam_suggest_links", node_id=node_id)
        record("org_roam_suggest_links", node_id=node_id, limit=3)
        record("org_roam_clustering_coefficient", node_id=node_id)
        for depth in (1, 2) if len(ids) > 60 else (1, 2, 3):
            record("org_roam_bfs", node_id=node_id, depth=depth)
    for a in some:
        for b in some[:3]:
            record("org_roam_common_neighbors", node_a=a, node_b=b)
    if paths:
        # Every pair with a path, and some without one.
        graph = nx.DiGraph()
        graph.add_nodes_from(ids)
        graph.add_edges_from(links)
        pairs = [(a, b) for a in ids for b in ids]
        linked = [(a, b) for a, b in pairs if nx.has_path(graph, a, b)]
        unlinked = [p for p in pairs if p not in set(linked)]
        for a, b in linked + random.Random(3).sample(unlinked, 60):
            record("org_roam_shortest_path", start_id=a, end_id=b)
    if read:
        for node_id in ids:
            text = tools["org_roam_read_node"](node_id=node_id)
            results.setdefault("org_roam_read_node", []).append(
                [{"node_id": node_id}, hashlib.sha1(text.encode()).hexdigest()]
            )
    for limit in (5, 20, 1000):
        for name in (
            "org_roam_central",
            "org_roam_pagerank",
            "org_roam_betweenness",
            "org_roam_closeness",
        ):
            record(name, limit=limit)
    record("org_roam_clustering_coefficient")
    record("org_roam_orphans")
    record("org_roam_graph_stats")
    record("org_roam_connected_components")
    return results


def path_hops(graph, ids):
    """For the random graph, where the server's query lists every path and
    takes too long: the lengths of the 3 shortest paths without repeated
    nodes, of at most 8 links, from networkx's shortest_simple_paths."""
    rng = random.Random(9)
    result = []
    for _ in range(150):
        a, b = rng.choice(ids), rng.choice(ids)
        hops = []
        try:
            for path in nx.shortest_simple_paths(graph, a, b):
                if len(path) - 1 > MAX_HOPS or len(hops) == 3:
                    break
                hops.append(len(path) - 1)
        except nx.NetworkXNoPath:
            pass
        result.append([a, b, hops])
    return result


def main():
    expected = {}
    with tempfile.TemporaryDirectory() as tmp:
        sample_db = Path(tmp) / "sample.db"
        subprocess.run(
            [
                "dart",
                "run",
                "tool/build_roam_db.dart",
                str(ROOT / "test/fixtures/roam"),
                str(sample_db),
            ],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        nodes, links = read_graph(sample_db)
        _, louvain = louvain_ranges(nodes, links)
        expected["sample_files"] = {
            "calls": calls(server_tools(sample_db), nodes, links, paths=True, read=True),
            "louvain": louvain,
        }

        nodes, links = random_graph()
        random_db = Path(tmp) / "random.db"
        write_db(random_db, nodes, links)
        graph, louvain = louvain_ranges(nodes, links)
        expected["random"] = {
            "nodes": [list(n) for n in nodes],
            "links": links,
            "calls": calls(server_tools(random_db), nodes, links, paths=False, read=False),
            "louvain": louvain,
            "path_hops": path_hops(graph, [n for n, _ in nodes]),
        }
    out = ROOT / "test/fixtures/ai_tools_expected.json"
    out.write_text(json.dumps(expected, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"wrote {out} ({out.stat().st_size // 1000} KB)")


if __name__ == "__main__":
    main()
