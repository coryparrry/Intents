#!/usr/bin/env python3
"""Compute source-review gates with explicit human or automated reviewer provenance."""
import argparse
import hashlib
import json
from pathlib import Path
from document_semantic_report import semantic_metrics


def load_lines(path):
    """Read nonblank JSONL records from a retained evidence file."""
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def validate_sources(run, attempts):
    """Verify the source manifest and attempt evidence refer to the same frozen imported passages."""
    manifest = json.loads((run / "input.json").read_text())
    documents = {item["id"]: item for item in manifest["documents"]}
    sources = load_lines(run / "sources.jsonl")
    by_name = {source["name"]: source for source in sources}
    assert len(by_name) == len(sources), "Conflicting source records"
    assert len(documents) == len(manifest["documents"]), "Duplicate corpus documents"
    for document in documents.values():
        name = document["id"] + "." + document["format"]
        assert Path(name).name == name, "Source paths must stay within the run"
        source = by_name[name]
        assert hashlib.sha256((run / name).read_bytes()).hexdigest() == source["fileDigest"], "Source digest mismatch"
    for item in attempts:
        document = documents[item["documentID"]]
        source = by_name[document["id"] + "." + document["format"]]
        assert item["passage"] in source["passages"], "Attempt passage differs from imported source"
        if case := item.get("candidate"):
            evidence = case["documentEvidence"]
            assert evidence["sourceName"] == source["name"] and evidence["sourceDigest"] == source["fileDigest"], "Candidate source identity mismatch"
            expected_passages = source["passages"] if evidence.get("generatorVersion") in ("document-draft-v7", "document-draft-v8", "document-draft-v9", "document-draft-v10", "document-draft-v11", "document-draft-v12", "document-draft-v13", "document-draft-v14", "document-draft-v15", "document-draft-v16", "document-draft-v17", "document-draft-v18", "document-draft-v19") else [item["passage"]]
            assert evidence["passages"] == expected_passages, "Candidate retained a different passage"
            for citation in evidence["citations"]:
                if evidence.get("generatorVersion") in ("document-draft-v17", "document-draft-v18", "document-draft-v19"):
                    assert any(citation["passageID"] == p["id"] and citation["quote"] in p["text"] for p in source["passages"]), "Unsupported source quote"
                else:
                    assert citation["passageID"] == item["passage"]["id"] and citation["quote"] in item["passage"]["text"], "Unsupported source quote"
            assert any(c["passageID"] == item["passage"]["id"] for c in evidence["citations"]), "Missing focus citation"
    return manifest


def compatible_controls(run, controls_path, manifest):
    """Require successful controls with identical definitions, source inputs, and runtime before reusing them."""
    if not terminal_success(controls_path):
        return False
    control_manifest = json.loads((controls_path / "input.json").read_text())
    if control_manifest["controls"] != manifest["controls"]:
        return False
    for name in ["judge-source-hashes.json", "runtime.json"]:
        if not (run / name).is_file() or not (controls_path / name).is_file():
            return False
        original = json.loads((run / name).read_text())
        if not original or original != json.loads((controls_path / name).read_text()):
            return False
    return True


def terminal_success(run):
    """Return whether retained process evidence records a successful terminal exit."""
    path = run / "exit-code.txt"
    return path.is_file() and path.read_text().strip() == "0"


def report(run, labels_path=None, controls_path=None, reviewer_kind="human", semantic_controls_path=None):
    """Validate retained generation, scoring, review, and control evidence before computing qualification metrics."""
    if reviewer_kind not in ("human", "automated"):
        raise ValueError("Reviewer kind must be human or automated")
    attempts = load_lines(run / "attempts.jsonl")
    summary = json.loads((run / "summary.json").read_text())
    candidate_versions = {item['candidate']['documentEvidence'].get('generatorVersion')
                          for item in attempts if item.get('candidate') is not None}
    generation_version = summary.get('generationVersion')
    assert generation_version in {f'document-draft-v{i}' for i in range(1, 20)}, 'Missing or unknown generation version'
    assert not candidate_versions or candidate_versions == {generation_version}, 'Summary/candidate generation version mismatch'
    manifest = validate_sources(run, attempts)
    labels = json.loads(labels_path.read_text()) if labels_path else {}
    candidates = [item for item in attempts if item.get("candidate") is not None]
    identities = [(item["documentID"], item["slot"]) for item in attempts]
    assert len(set(identities)) == len(identities), "Duplicate attempts cannot count toward quality gates"
    rows, reviews, template = [], [], {}
    source_rows = ["# Complete extracted source corpus", "", "Consult these complete sources when checking cross-passage conditions and exceptions.", ""]
    for source in load_lines(run / "sources.jsonl"):
        source_rows += [f"## {source['name']}", ""]
        source_rows += [f"Warning: {warning}" for warning in source.get("warnings", [])]
        for passage in source["passages"]:
            source_rows += [f"### {passage['location']} ({passage['id']})", "", passage["text"], ""]
    (run / "sources.md").write_text("\n".join(source_rows))
    per_document = {}
    for item in attempts:
        totals = per_document.setdefault(item["documentID"], {"attempts": 0, "surfaced": 0, "omitted_or_failed": 0})
        totals["attempts"] += 1
        totals["surfaced" if item.get("candidate") else "omitted_or_failed"] += 1
        outcome = item.get("outcome", "legacy_unknown")
        totals.setdefault("outcomes", {})[outcome] = totals.setdefault("outcomes", {}).get(outcome, 0) + 1
    assert summary["surfaced"] == len(candidates), "Summary does not match the attempt ledger"
    assert summary["attempts"] == len(attempts), "Summary does not match the attempt ledger"
    assert summary["documents"] == len(per_document), "Summary document count does not match the ledger"
    for number, item in enumerate(candidates, 1):
        case = item["candidate"]
        key = f'{item["documentID"]}:{item["slot"]}'
        digest = hashlib.sha256(json.dumps(case, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        fields = {name: None for name in ["supported", "useful_distinct", "rubric_correct", "acceptable_without_edits"]}
        template[key] = {"candidate_sha256": digest, "reviewer_kind": reviewer_kind, **fields, "notes": ""}
        label = labels.get(key)
        valid = isinstance(label, dict) and label.get("candidate_sha256") == digest and label.get("reviewer_kind") == reviewer_kind
        valid = valid and all(type(label.get(name)) is bool for name in fields)
        if valid and label["acceptable_without_edits"]:
            valid = all(label[name] for name in ["supported", "useful_distinct", "rubric_correct"])
        if valid:
            reviews.append(label)
            totals = per_document[item["documentID"]]
            totals["reviewed"] = totals.get("reviewed", 0) + 1
            if reviewer_kind == "human":
                totals["human_reviewed"] = totals.get("human_reviewed", 0) + 1
            for field in ["supported", "useful_distinct", "rubric_correct", "acceptable_without_edits"]:
                totals[field] = totals.get(field, 0) + int(label[field])
        prompt = case["prompt"] if isinstance(case["prompt"], str) else case["prompt"]["text"]
        evidence = case["documentEvidence"]
        rows += [f'## {number}. {key}', '', f'**Document:** {item["documentID"]} — [complete extracted sources](sources.md)', '', f'**Question:** {prompt}', '', f'**Reference:** {case["expected"]}', '', '**Rubric:**', '']
        rows += [f'- {criterion}' for criterion in case["criteriaOverride"]]
        rows += ['', '**Retained source:**', '']
        for passage in evidence["passages"]:
            rows += [f'### {passage["location"]} ({passage["id"]})', '', passage["text"], '']
        rows += ['**Supporting quotes:**', '']
        rows += [f'- {quote["passageID"]}: {quote["quote"]}' for quote in evidence["citations"]]
        rows += ['', f'**{reviewer_kind.capitalize()} labels:** {json.dumps(label) if valid else "Not reviewed"}', '']
    complete = len(reviews) == len(candidates) and len(candidates) >= 100 and summary["documents"] >= 10 and summary["requested"] >= 100
    supported = sum(label["supported"] for label in reviews)
    acceptable = sum(label["acceptable_without_edits"] for label in reviews)
    for document_id, totals in per_document.items():
        requested = next(item["requested"] for item in manifest["documents"] if item["id"] == document_id)
        totals["requested"] = requested
        totals["request_yield"] = totals["surfaced"] / requested
        totals["attempt_yield"] = totals["surfaced"] / totals["attempts"]
    summary.pop("humanReviewComplete", None)
    metrics = {**summary, "per_document": per_document, "reviewer_kind": reviewer_kind,
               "execution_gate_passed": terminal_success(run),
               "reviewed": len(reviews), "review_complete": complete,
               "human_reviewed": len(reviews) if reviewer_kind == "human" else 0,
               "human_review_complete": complete and reviewer_kind == "human",
               "supported_count": supported, "acceptable_count": acceptable,
               "generation_gate_passed": terminal_success(run) and complete and supported / len(candidates) >= .9 and acceptable / len(candidates) >= .8}
    metrics["scoring_gate_passed"] = False
    if controls_path:
        expected = json.loads((controls_path / "input.json").read_text())["controls"]
        results = load_lines(controls_path / "controls.jsonl")
        by_id = {item["control"]["id"]: item for item in results}
        valid = compatible_controls(run, controls_path, manifest) and len(expected) >= 28 and len(by_id) == len(results) == len(expected)
        passed_controls = 0
        failed_controls = []
        for control in expected:
            result = by_id.get(control["id"])
            if result is None or result["control"] != control:
                valid = False
                continue
            checks = sorted((result.get("trace") or {}).get("checks") or [], key=lambda check: check["criterionIndex"])
            correct = [check["criterionIndex"] for check in checks] == list(range(1, len(control["criteria"]) + 1))
            correct = correct and [check["score"] >= 3 for check in checks] == control["expectedRequirementPasses"]
            correct = correct and result["status"] == ("passed" if control["shouldPass"] else "failed")
            correct = correct and bool(checks) and result.get("score") == min(check["score"] for check in checks)
            passed_controls += int(correct)
            if not correct: failed_controls.append(control["id"])
            valid = valid and correct
        metrics["scoring_gate_passed"] = valid
        metrics["scoring_controls"] = len(results)
        metrics["scoring_controls_passed"] = passed_controls
        metrics["failed_controls"] = failed_controls
    if generation_version in ("document-draft-v16", "document-draft-v17", "document-draft-v18", "document-draft-v19"):
        metrics.update(semantic_metrics(run, attempts, semantic_controls_path))
        metrics["generation_gate_passed"] = (metrics["generation_gate_passed"]
            and metrics["semantic_review_gate_passed"] and metrics["semantic_controls_gate_passed"])
    metrics["overall_gate_passed"] = metrics["generation_gate_passed"] and metrics["scoring_gate_passed"]
    metrics["human_overall_gate_passed"] = metrics["overall_gate_passed"] and reviewer_kind == "human"
    (run / "review-template.json").write_text(json.dumps(template, indent=2, ensure_ascii=False) + "\n")
    (run / "review.md").write_text('# Document generation source review\n\n'
        f'These are synthetic test documents. Selected reviewer kind: **{reviewer_kind}**. '
        'Automated assessments are not human approval. Every surfaced draft needs complete, hash-bound labels.\n\n'
        + '\n'.join(rows))
    (run / "quality-gates.json").write_text(json.dumps(metrics, indent=2) + "\n")
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--labels", type=Path)
    parser.add_argument("--controls", type=Path, help="Full frozen 28-control run directory; a pilot is insufficient")
    parser.add_argument("--semantic-controls", type=Path, help="Frozen semantic admission controls for v16 generation")
    parser.add_argument("--reviewer-kind", choices=["human", "automated"], default="human",
                        help="Defaults to human; choose automated only for an explicitly authorized agent-review gate")
    arguments = parser.parse_args()
    report(arguments.run, arguments.labels, arguments.controls, arguments.reviewer_kind, arguments.semantic_controls)
