#!/usr/bin/env python3
"""
Unit tests for scripts/audit_gemini_contract.py and scripts/sync_contract_issue.py.

Covers synthetic corpora for PASS, DEGRADED_FALLBACK_ACTIVE, BREAKING_DRIFT
(including rotated persistedQueryId / batchexecute RPC auto-discovery),
CLI exit codes, --save-corpus / --load-corpus round-trip, and GitHub Issue
fingerprint deduplication, update diffs, and auto-close on recovery.
"""

from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import audit_gemini_contract as agc  # noqa: E402
import sync_contract_issue as sci  # noqa: E402


SELECTORS_SWIFT = REPO_ROOT / "LiteGemini/Bridge/GeminiBridgeSelectors.swift"
PARSER_SWIFT = REPO_ROOT / "LiteGemini/Bridge/GeminiPayloadParser.swift"
GRAPHQL_SWIFT = REPO_ROOT / "LiteGemini/Bridge/GeminiGraphQLClient.swift"


def build_synthetic_passing_corpus(contract: agc.SourceContract) -> dict[str, Any]:
    """Construct a minimal, deterministic synthetic Gemini Web corpus that passes all 6 layers."""
    # 1. Anonymous WIZ_global_data (SNlM0e absent, S06Grb == "")
    wiz_data: dict[str, Any] = {
        "S06Grb": "",
        "QrtxK": "",
        "cfb2h": contract.verified_build_label,
        "FdrFJe": "-123456789",
        "Im6cmf": "/_/BardChatUi",
        "GK6dn": "https://geminiweb-pa.clients6.google.com",
        "d2zJAe": "AIzaSySyntheticTestKey",
        "h1eoVe": "https://push.clients6.google.com/upload/",
        "qKIAYe": "feeds/synthetic",
        "Ylro7b": "CgcSBWjK7pYx",
        "TuX5cc": "en-US",
        "Lz8rbb": False,
        "PI9WOb": "synthetic-server-token",
        "M9l3o": "",
        "dSupif": "",
    }

    # 2. Synthetic Closure JS covering WIZ refs, endpoints, all RPCs, proto decoders, and DOM atoms
    closure_parts: list[str] = [
        '_.ve("SNlM0e");_.ve("oPEP7c");_.ve("S06Grb");_.ve("Lz8rbb");_.ve("PI9WOb");',
        'const EP=["gemini.google.com","geminiweb-pa.clients6.google.com","push.clients6.google.com",'
        '"accounts.google.com","https://gemini.google.com","https://geminiweb-pa.clients6.google.com",'
        '"/v1/processSession","/$rpc/assistant.lamda.bard.GeminiWebService/ProcessSession",'
        '"/v1/conversations:streamGenerate","/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate",'
        '"/_/BardChatUi/data/batchexecute","/upload/",'
        '"/$rpc/gdm.geminiapp.hydrofoil.omakase.OmakaseGateway/ExecuteGraphqlHttp","/_/BardChatUi/graphql"];',
    ]

    # Add gRPC descriptors for every BatchExecuteRPC + GetArtifactVersion
    rpc_class_map = {
        "/BardFrontendService.StreamGenerate": ("_.uv", "_.Du"),
        "/BardFrontendService.ListConversations": ("_.wUb", "_.uUb"),
        "/BardFrontendService.ListConversationTurns": ("_.rUb", "_.oUb"),
        "/BardFrontendService.GetUserStatus": ("_.SSb", "_.QSb"),
    }
    for rpc in contract.batch_rpcs:
        svc = agc._expected_service_method_from_comment(rpc.comment, rpc.name) or f"/BardFrontendService.{rpc.name}"
        resp_c, req_c = rpc_class_map.get(svc, ("_.xResp", "_.xReq"))
        closure_parts.append(
            f'var d_{rpc.name}={{kc:"{rpc.value}",rc:_.Fu?"{svc}":void 0,wc:!0,qc:{resp_c},zc:{req_c}}};'
        )
    closure_parts.append(
        'var d_art={kc:"ArtRpc",rc:_.Fu?"/BardFrontendService.GetArtifactVersion":void 0,wc:!0,qc:_.Cu,zc:_.JNb};'
    )

    # Proto classes & decoders matching v2.0 + v2.1 wire format
    closure_parts.append(
        "_.bN=class extends _.k{constructor(a){super(a)}oa(){return _.Gf(this,_.TOe,4,_.aN)}};"
        "function ps(e){var f,g;return (f=_.Gf(e,_.bN,1,_.UOe))==null?void 0:(g=f.oa())==null?void 0:_.l(g,_.uv,4)}"
        "_.NEb=class extends _.k{constructor(a){super(a)}hasAttachments(){return _.sf(this,13)}};"
        "_.KD=function(a){return _.Jf(a,_.NEb,5,void 0)};"
        "_.Cu=class extends _.k{constructor(a){super(a)}getTitle(){return _.m(this,3)}getText(){return _.m(this,5)}getType(){return _.bg(this,11)}};"
        "_.Cu.prototype.qp=_.ca(147);"
        "WYd=function(a){return _.Jf(a,_.Cu,31,void 0)};"
        "DZd=function(a,d){var x=_.Jf(a,_.Cu,42,void 0);var y=_.Jf(d,_.CMd,77,void 0);return _.l(a,_.TZd,38)};"
        "_.dA=[14,15,16,18,19];"
        "y0d=function(a){return Object.assign({},{artifactId:a.qp()},_.Ng(a,4)&&{Ew:_.m(a,4)},{title:a.getTitle()})};"
        "B0d=function(a){switch(_.Bf(a,_.dA)){case 14:return {artifactType:1};case 15:return {artifactType:2};"
        "case 16:return {artifactType:4};case 18:return {artifactType:5};}};"
        "function drCheck(a){return _.sf(a,19)?'deep-research-confirmation-widget':''}"
        "_.jv=class extends _.k{constructor(a){super(a)}Uf(){return _.m(this,1)}getTitle(){return _.m(this,2)}getIcon(){return _.m(this,5)}};"
        "function listConv(f){return _.Jf(f,_.jv,3,void 0)}"
        "_.rUb=class extends _.k{constructor(a){super(a)}getStatus(){return _.l(this,_.qUb,5)}};"
        "function listModels(b){return _.Jf(b,_.Jqd,16,void 0)}"
    )

    # Synthesize all DOM atoms across primary + fallbacks into a Closure template chunk
    dom_tokens: list[str] = []
    for grp in contract.selector_groups:
        for sel in [grp.primary, *grp.fallbacks]:
            for atom in agc.decompose_css_selector(sel):
                if atom.kind == "tag":
                    dom_tokens.append(f"<{atom.value}></{atom.value}>")
                elif atom.kind == "class":
                    dom_tokens.append(f'class="{atom.value}"')
                elif atom.kind == "data-test-id":
                    dom_tokens.append(f'data-test-id="{atom.value}"')
                elif atom.kind == "jslog":
                    dom_tokens.append(f'jslog="{atom.value};track:generic_click"')
                elif atom.kind == "fonticon":
                    dom_tokens.append(f'fonticon="{atom.value}"')
                elif atom.kind == "href":
                    dom_tokens.append(f'href="https://{atom.value}"')
                elif atom.kind == "role":
                    dom_tokens.append(f'role="{atom.value}"')
                elif atom.kind == "attr":
                    dom_tokens.append(atom.value)
    dom_tokens.append('data-test-id="send-action-v2-button"')

    # 3. Synthetic Islands chunks with Relay ConcreteRequest / PreloadableConcreteRequest
    # Exercise all 3 JS quote styles: backticks (`), double quotes ("), and single quotes (')
    islands_chunks: dict[str, str] = {}
    quote_styles = ["`", '"', "'", "`", '"']
    for idx, op in enumerate(contract.graphql_operations):
        q = quote_styles[idx % len(quote_styles)]
        selections = ",".join(
            f"{{alias:null,args:null,kind:{q}ScalarField{q},name:{q}{f}{q},storageKey:null}}"
            for f in op.expected_fields
        )
        op_kind = "query" if "Query" in op.operation_name else "mutation"
        chunk_body = (
            f"var ast={{fragment:{{argumentDefinitions:[{{kind:{q}LocalArgument{q},name:{q}input{q}}}],"
            f"kind:{q}Fragment{q},name:{q}{op.operation_name}{q},selections:[{selections}]}},"
            f"kind:{q}Request{q},"
            f"params:{{id:{q}{op.persisted_query_id}{q},metadata:{{}},name:{q}{op.operation_name}{q},"
            f"operationKind:{q}{op_kind}{q},text:null}}}};"
        )
        islands_chunks[f"{op.operation_name}-SYNTH{idx}.js"] = chunk_body

    return {
        "fetched_at": "2026-11-26T00:00:00+00:00",
        "app_url": agc.DEFAULT_APP_URL,
        "live_build_label": contract.verified_build_label,
        "html": "<html><body><script>window.WIZ_global_data="
        + json.dumps(wiz_data)
        + ";</script></body></html>",
        "wiz_global_data": wiz_data,
        "importmap": {},
        "closure_chunks": {
            "closure_preloaded:vLefie": "\n".join(closure_parts),
            "closure_lazy_batch_1(templates)": "\n".join(dom_tokens),
        },
        "islands_chunks": islands_chunks,
        "stats": {
            "elapsed_seconds": 0.01,
            "closure_chunk_count": 2,
            "islands_chunk_count": len(islands_chunks),
        },
    }


class ContractAuditUnitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = agc.extract_source_contract(
            selectors_path=SELECTORS_SWIFT,
            parser_path=PARSER_SWIFT,
            graphql_path=GRAPHQL_SWIFT,
            repo_root=REPO_ROOT,
        )
        cls.base_corpus = build_synthetic_passing_corpus(cls.contract)

    def test_source_contract_extraction_completeness_and_line_numbers(self) -> None:
        self.assertTrue(self.contract.verified_build_label.startswith("boq_gemini-web-uiserver_"))
        self.assertGreaterEqual(len(self.contract.wiz_keys), 15)
        self.assertEqual(len(self.contract.batch_rpcs), 13)
        self.assertEqual(len(self.contract.graphql_operations), 5)
        self.assertEqual(len(self.contract.selector_groups), 47)

        # Verify Swift raw strings with embedded quotes were extracted intact
        send_btn = next(g for g in self.contract.selector_groups if g.name == "sendButton")
        self.assertEqual(send_btn.primary, 'input-area-v2 button[jslog^="173899;"]')
        self.assertGreater(send_btn.location.line, 400)
        self.assertEqual(send_btn.location.file, "LiteGemini/Bridge/GeminiBridgeSelectors.swift")

        # Verify v2.1 Artifact field numbers extracted from GeminiPayloadParser.swift
        art_nums = {f.value for f in self.contract.artifact_fields}
        for required in (1, 3, 4, 5, 11, 14, 15, 16, 18):
            self.assertIn(required, art_nums)
        self.assertIsNotNone(self.contract.deep_research_plan_field)
        self.assertEqual(self.contract.deep_research_plan_field.value, 19)

    def test_synthetic_passing_corpus_passes_all_six_layers(self) -> None:
        report = agc.run_audit(self.contract, copy.deepcopy(self.base_corpus))
        self.assertEqual(report["overall_status"], "PASS")
        self.assertEqual(report["summary"]["breaking"], 0)
        self.assertEqual(report["summary"]["degraded"], 0)
        self.assertEqual(report["summary"]["pass"], report["summary"]["total"])
        self.assertGreaterEqual(report["summary"]["total"], 100)

        # CLI --load-corpus round-trip should exit 0
        with tempfile.TemporaryDirectory() as tmpdir:
            corpus_path = Path(tmpdir) / "corpus.json.gz"
            json_out = Path(tmpdir) / "report.json"
            md_out = Path(tmpdir) / "report.md"
            agc.save_corpus(self.base_corpus, corpus_path)

            proc = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS_DIR / "audit_gemini_contract.py"),
                    "--load-corpus",
                    str(corpus_path),
                    "--json-out",
                    str(json_out),
                    "--markdown-out",
                    str(md_out),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
            saved = json.loads(json_out.read_text(encoding="utf-8"))
            self.assertEqual(saved["overall_status"], "PASS")
            self.assertIn("PASS", md_out.read_text(encoding="utf-8"))

    def test_primary_selector_removed_fallback_survives_reports_degraded(self) -> None:
        corpus = copy.deepcopy(self.base_corpus)
        # Remove primary VE ID 173899 for ComposerDOM.sendButton, while fallbacks[0] (`arrow_upward`) remains
        for k in list(corpus["closure_chunks"].keys()):
            corpus["closure_chunks"][k] = corpus["closure_chunks"][k].replace("173899", "999999")

        report = agc.run_audit(self.contract, corpus)
        self.assertEqual(report["overall_status"], "DEGRADED_FALLBACK_ACTIVE")
        self.assertEqual(report["summary"]["breaking"], 0)
        self.assertEqual(report["summary"]["degraded"], 1)

        send_check = next(
            c for c in report["checks"] if c["check_id"] == "dom.ComposerDOM.sendButton"
        )
        self.assertEqual(send_check["status"], "DEGRADED_FALLBACK_ACTIVE")
        self.assertEqual(send_check["active_fallback_index"], 0)
        self.assertIn("arrow_upward", send_check["active_fallback_selector"])
        self.assertEqual(send_check["missing_atoms"], ['[jslog^="173899;"]'])

        # CLI exits 0 without --fail-on-degraded, and exits 2 with --fail-on-degraded
        with tempfile.TemporaryDirectory() as tmpdir:
            cpath = Path(tmpdir) / "degraded.json"
            agc.save_corpus(corpus, cpath)
            p_default = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS_DIR / "audit_gemini_contract.py"),
                    "--load-corpus",
                    str(cpath),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(p_default.returncode, 0)

            p_strict = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS_DIR / "audit_gemini_contract.py"),
                    "--load-corpus",
                    str(cpath),
                    "--fail-on-degraded",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(p_strict.returncode, 2)

    def test_rotated_persisted_query_id_and_rpc_id_report_breaking_with_auto_discovery(self) -> None:
        corpus = copy.deepcopy(self.base_corpus)

        # 1. Rotate GraphQL persistedQueryId for ChatResponseActionBarBranchMutation
        old_hash = "2/JElMc8MRhiCK7G6DRucRllH8DyUUtlgZACqza4oLISU="
        new_hash = "2/ROTATED_LIVE_HASH_ABCDEF0123456789ABCDEF0="
        for chunk_name, body in list(corpus["islands_chunks"].items()):
            if old_hash in body:
                corpus["islands_chunks"][chunk_name] = body.replace(old_hash, new_hash)

        # 2. Rotate batchexecute RPC ID MaZiqc -> N3wRpc keeping /BardFrontendService.ListConversations anchor
        corpus["closure_chunks"]["closure_preloaded:vLefie"] = corpus["closure_chunks"][
            "closure_preloaded:vLefie"
        ].replace('"MaZiqc"', '"N3wRpc"')

        # 3. Break all selectors for deepResearchConfirmButton (primary + fallback)
        corpus["closure_chunks"]["closure_lazy_batch_1(templates)"] = corpus["closure_chunks"][
            "closure_lazy_batch_1(templates)"
        ].replace("confirm-button", "launch-research-btn")

        report = agc.run_audit(self.contract, corpus)
        self.assertEqual(report["overall_status"], "BREAKING_DRIFT")

        # Verify GraphQL rotation auto-discovered exact new hash
        gql_check = next(
            c for c in report["checks"] if c["check_id"] == "graphql.branchConversation"
        )
        self.assertEqual(gql_check["status"], "BREAKING_DRIFT")
        self.assertEqual(gql_check["expected"], old_hash)
        self.assertEqual(gql_check["observed"], new_hash)
        self.assertTrue(gql_check["discovered_candidates"])
        self.assertEqual(gql_check["discovered_candidates"][0]["persisted_query_id"], new_hash)

        # Verify batchexecute RPC rotation auto-discovered N3wRpc via /BardFrontendService.ListConversations
        rpc_check = next(c for c in report["checks"] if c["check_id"] == "rpc.listConversations")
        self.assertEqual(rpc_check["status"], "BREAKING_DRIFT")
        self.assertTrue(rpc_check["discovered_candidates"])
        self.assertEqual(rpc_check["discovered_candidates"][0]["rpc_id"], "N3wRpc")
        self.assertEqual(
            rpc_check["discovered_candidates"][0]["service_method"],
            "/BardFrontendService.ListConversations",
        )

        # Verify total DOM selector break
        dom_check = next(
            c
            for c in report["checks"]
            if c["check_id"] == "dom.ConversationDOM.deepResearchConfirmButton"
        )
        self.assertEqual(dom_check["status"], "BREAKING_DRIFT")

        # Verify Markdown report includes human-readable mismatch explanation
        md = agc.render_markdown_report(report)
        self.assertIn(new_hash, md)
        self.assertIn("N3wRpc", md)
        self.assertIn("LiteGemini/Bridge/GeminiBridgeSelectors.swift:", md)

    def test_wiz_anonymous_invariant_and_artifact_oneof_drift_detection(self) -> None:
        corpus = copy.deepcopy(self.base_corpus)
        # Violate anonymous invariant: SNlM0e unexpectedly populated
        corpus["wiz_global_data"]["SNlM0e"] = "unexpected-token"
        # Remove Artifact Deep Research oneof branch 16
        corpus["closure_chunks"]["closure_preloaded:vLefie"] = (
            corpus["closure_chunks"]["closure_preloaded:vLefie"]
            .replace("case 16:return {artifactType:4};", "")
            .replace(",16,", ",")
        )

        report = agc.run_audit(self.contract, corpus)
        self.assertEqual(report["overall_status"], "BREAKING_DRIFT")

        wiz_xsrf = next(c for c in report["checks"] if c["check_id"] == "wiz.xsrfToken")
        self.assertEqual(wiz_xsrf["status"], "BREAKING_DRIFT")

        art_16 = next(c for c in report["checks"] if c["check_id"] == "proto.artifact.field_16")
        self.assertEqual(art_16["status"], "BREAKING_DRIFT")


class ContractIssueSyncTests(unittest.TestCase):
    def _make_report(
        self,
        build: str = "boq_gemini-web-uiserver_20261126.01_p0",
        breaking_ids: list[str] | None = None,
        degraded_ids: list[str] | None = None,
    ) -> dict[str, Any]:
        breaking_ids = breaking_ids or []
        degraded_ids = degraded_ids or []
        checks = [
            {"check_id": cid, "status": "BREAKING_DRIFT"} for cid in breaking_ids
        ] + [
            {"check_id": cid, "status": "DEGRADED_FALLBACK_ACTIVE"} for cid in degraded_ids
        ] + [
            {"check_id": "wiz.buildLabel", "status": "PASS"}
        ]
        overall = (
            "BREAKING_DRIFT"
            if breaking_ids
            else ("DEGRADED_FALLBACK_ACTIVE" if degraded_ids else "PASS")
        )
        return {
            "live_build_label": build,
            "overall_status": overall,
            "summary": {
                "total": len(checks),
                "pass": 1,
                "degraded": len(degraded_ids),
                "breaking": len(breaking_ids),
            },
            "checks": checks,
        }

    def test_issue_lifecycle_create_dedupe_update_close(self) -> None:
        report_v1 = self._make_report(
            build="boq_gemini-web-uiserver_20261126.01_p0",
            breaking_ids=["graphql.branchConversation"],
            degraded_ids=["dom.ComposerDOM.sendButton"],
        )
        md_v1 = "## Report v1\nBreaking: graphql.branchConversation"

        # 1. No existing issue -> CREATE
        gh_calls: list[list[str]] = []

        def mock_gh_create(args: list[str]) -> str:
            gh_calls.append(args)
            if args[:2] == ["issue", "list"]:
                return "[]"
            if args[:2] == ["issue", "create"]:
                return "https://github.com/example/lite-gemini/issues/42"
            return ""

        res_create = sci.sync_contract_issue(
            report=report_v1,
            markdown_report=md_v1,
            gh_runner=mock_gh_create,
        )
        self.assertEqual(res_create["action"], "create")
        self.assertEqual(
            res_create["title"],
            "[Contract Drift] boq_gemini-web-uiserver_20261126.01_p0: 1 breaking, 1 degraded",
        )
        self.assertIn("<!-- contract-drift-fingerprint:", res_create["body"])
        self.assertTrue(any(c[:2] == ["issue", "create"] for c in gh_calls))

        # 2. Same failure on next 6-hour cron -> NOOP (no duplicate comment/edit!)
        existing_issue = {
            "number": 42,
            "title": res_create["title"],
            "body": res_create["body"],
        }
        gh_calls_dedupe: list[list[str]] = []

        def mock_gh_dedupe(args: list[str]) -> str:
            gh_calls_dedupe.append(args)
            if args[:2] == ["issue", "list"]:
                return json.dumps([existing_issue])
            return ""

        res_dedupe = sci.sync_contract_issue(
            report=report_v1,
            markdown_report=md_v1,
            gh_runner=mock_gh_dedupe,
        )
        self.assertEqual(res_dedupe["action"], "noop")
        self.assertFalse(any(c[:2] in (["issue", "edit"], ["issue", "comment"]) for c in gh_calls_dedupe))

        # 3. New build + additional breaking check -> UPDATE (edit body + post concise diff comment)
        report_v2 = self._make_report(
            build="boq_gemini-web-uiserver_20261127.02_p0",
            breaking_ids=["graphql.branchConversation", "rpc.listConversations"],
            degraded_ids=[],
        )
        gh_calls_update: list[list[str]] = []

        def mock_gh_update(args: list[str]) -> str:
            gh_calls_update.append(args)
            if args[:2] == ["issue", "list"]:
                return json.dumps([existing_issue])
            return ""

        res_update = sci.sync_contract_issue(
            report=report_v2,
            markdown_report="## Report v2",
            gh_runner=mock_gh_update,
        )
        self.assertEqual(res_update["action"], "update")
        self.assertEqual(res_update["issue_number"], 42)
        self.assertIn("rpc.listConversations", res_update["comment"])
        self.assertIn("boq_gemini-web-uiserver_20261127.02_p0", res_update["comment"])
        self.assertTrue(any(c[:2] == ["issue", "edit"] for c in gh_calls_update))
        self.assertTrue(any(c[:2] == ["issue", "comment"] for c in gh_calls_update))

        # 4. Recovery (PASS) -> CLOSE with resolution comment
        report_pass = self._make_report(
            build="boq_gemini-web-uiserver_20261128.01_p0",
            breaking_ids=[],
            degraded_ids=[],
        )
        gh_calls_close: list[list[str]] = []

        def mock_gh_close(args: list[str]) -> str:
            gh_calls_close.append(args)
            if args[:2] == ["issue", "list"]:
                return json.dumps([existing_issue])
            return ""

        res_close = sci.sync_contract_issue(
            report=report_pass,
            markdown_report="## All PASS",
            gh_runner=mock_gh_close,
        )
        self.assertEqual(res_close["action"], "close")
        self.assertEqual(res_close["issue_numbers"], [42])
        self.assertIn("All contracts verified `PASS` against `boq_gemini-web-uiserver_20261128.01_p0`", res_close["comment"])
        self.assertTrue(any(c[:2] == ["issue", "close"] for c in gh_calls_close))

    def test_sync_cli_dry_run(self) -> None:
        report = self._make_report(breaking_ids=["graphql.exportMessage"])
        with tempfile.TemporaryDirectory() as tmpdir:
            rpath = Path(tmpdir) / "report.json"
            mpath = Path(tmpdir) / "report.md"
            rpath.write_text(json.dumps(report), encoding="utf-8")
            mpath.write_text("## Drift", encoding="utf-8")

            proc = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS_DIR / "sync_contract_issue.py"),
                    "--report",
                    str(rpath),
                    "--markdown",
                    str(mpath),
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
            out = json.loads(proc.stdout)
            self.assertTrue(out["dry_run"])
            self.assertEqual(out["action"], "create")
            self.assertEqual(out["fingerprint"], sci.compute_fingerprint(report))


if __name__ == "__main__":
    unittest.main(verbosity=2)
