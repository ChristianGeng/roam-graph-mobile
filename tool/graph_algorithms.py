"""Write the results of my org-roam MCP server's graph algorithms (#7).

The app's graph views must give the same results as the MCP server
(https://github.com/ChristianGeng/org-roam-mcp), which uses networkx and
python-louvain.
This script builds the graph the way the server does and writes what the
algorithms return to test/fixtures/graph_algorithms_expected.json, which
test/graph/graph_algorithms_test.dart compares with the app. Run it with the
server's library versions (its uv.lock):

    uv run --with networkx==3.6.1 --with python-louvain==0.16 \\
        --with scipy python tool/graph_algorithms.py

Two graphs: the org-roam database of the sample files
(test/fixtures/org_roam_expected.json, from real org-roam), and a random
graph with a fixed seed, for size.
"""

import json
import random
from pathlib import Path

import community as community_louvain
import networkx as nx

ROOT = Path(__file__).resolve().parent.parent
MAX_HOPS = 8  # org_roam_shortest_path follows at most 8 links


def server_graph(nodes, links):
    """A DiGraph as the server's _load_graph_from_db builds it: every node
    (ordered by title, as its query), then an edge per id: link; a link to a
    missing ID adds a bare node."""
    graph = nx.DiGraph()
    for node_id, title in sorted(nodes, key=lambda n: n[1]):
        graph.add_node(node_id, title=title)
    for source, dest in links:
        graph.add_edge(source, dest)
    return graph


def link_counts(graph):
    """org_roam_central: distinct targets plus distinct sources."""
    return {
        n: len(set(graph.successors(n))) + len(set(graph.predecessors(n)))
        for n in graph.nodes
    }


def path_lengths(graph, pairs):
    """org_roam_shortest_path: links followed in their direction, at most
    MAX_HOPS; null when there is none."""
    result = []
    for source, target in pairs:
        try:
            length = nx.shortest_path_length(graph, source, target)
        except nx.NetworkXNoPath:
            length = None
        if length is not None and (length > MAX_HOPS or length == 0):
            length = None
        result.append([source, target, length])
    return result


def louvain(graph):
    """org_roam_communities: best_partition on the undirected graph, without
    a seed. Louvain is random, so: the modularity over 20 seeds, and one
    partition with its modularity to check the app's modularity formula."""
    undirected = graph.to_undirected()
    runs = []
    for seed in range(20):
        partition = community_louvain.best_partition(
            undirected, resolution=1.0, random_state=seed
        )
        runs.append(
            (
                community_louvain.modularity(partition, undirected),
                len(set(partition.values())),
                partition,
            )
        )
    modularities = [m for m, _, _ in runs]
    counts = [c for _, c, _ in runs]
    _, _, first = runs[0]
    return {
        "modularity_min": min(modularities),
        "modularity_max": max(modularities),
        "communities_min": min(counts),
        "communities_max": max(counts),
        "partition": first,
        "partition_modularity": community_louvain.modularity(first, undirected),
    }


def results(nodes, links, pairs):
    graph = server_graph(nodes, links)
    return {
        "nodes": [[n, t] for n, t in nodes],
        "links": links,
        "pagerank": nx.pagerank(graph),
        "link_counts": link_counts(graph),
        "paths": path_lengths(graph, pairs),
        "louvain": louvain(graph),
    }


def sample_files():
    data = json.loads((ROOT / "test/fixtures/org_roam_expected.json").read_text())
    nodes = [(n[0], n[3]) for n in data["nodes"]]
    links = [list(link) for link in data["links"]]
    ids = sorted({n for n, _ in nodes} | {d for _, d in links})
    # Every pair with a path, and a sample of the pairs without one.
    graph = server_graph(nodes, links)
    pairs = [(a, b) for a in ids for b in ids if a != b]
    linked = [(a, b) for a, b in pairs if nx.has_path(graph, a, b)]
    unlinked = [p for p in pairs if p not in set(linked)]
    return results(nodes, links,
                   linked + random.Random(3).sample(unlinked, 200))


def random_graph():
    rng = random.Random(7)
    count = 300
    nodes = [(f"n{i:03d}", f"Node {i:03d}") for i in range(count)]
    links = []
    for _ in range(1200):
        # Some nodes are hubs, as in real notes.
        source = int(rng.random() ** 2 * count)
        links.append([f"n{source:03d}", f"n{rng.randrange(count):03d}"])
    links.append(["n000", "gone"])  # a link to a missing ID
    ids = [n for n, _ in nodes]
    pairs = [(rng.choice(ids), rng.choice(ids)) for _ in range(300)]
    return results(nodes, links, pairs)


def main():
    out = ROOT / "test/fixtures/graph_algorithms_expected.json"
    expected = {"sample_files": sample_files(), "random": random_graph()}
    out.write_text(json.dumps(expected, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
