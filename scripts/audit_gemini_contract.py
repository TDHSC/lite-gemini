#!/usr/bin/env python3
"""
Zero-secret live Gemini Web interface & protocol contract auditor (v2.0 + v2.1 + v2.2).

Parses Lite Gemini's Swift source contracts (with exact file:line locations), fetches
the live unauthenticated Gemini Web corpus (HTML, WIZ_global_data, Closure base +
preloaded + lazy md=1/d=0 modules, and Islands importmap + relative-import BFS),
and runs six multi-layer analyzers producing human- and machine-readable diagnostics.

Stdlib-only (Python 3.12+). Zero external pip dependencies.
"""

from __future__ import annotations

import argparse
import dataclasses
import gzip
import http.client
import json
import os
import re
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
)
DEFAULT_APP_URL = "https://gemini.google.com/app"
DEFAULT_ISLANDS_BASE = "https://www.gstatic.com/bg3/boq-bard-web/islands/"
CLOSURE_BATCH_MAX_URL_CHARS = 3600


class UpstreamFetchError(RuntimeError):
    """Raised when live Gemini Web or static CDN assets fail after retries."""


# ---------------------------------------------------------------------------
# Data Models
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class SourceLocation:
    file: str
    line: int

    def format(self) -> str:
        return f"{self.file}:{self.line}"


@dataclasses.dataclass
class ConstantContract:
    name: str
    value: str
    location: SourceLocation
    comment: str = ""


@dataclasses.dataclass
class IntContract:
    name: str
    value: int
    location: SourceLocation
    comment: str = ""


@dataclasses.dataclass
class SelectorGroupContract:
    section: str
    name: str
    primary: str
    fallbacks: list[str]
    location: SourceLocation


@dataclasses.dataclass
class GraphQLOperationContract:
    key: str
    operation_name: str
    persisted_query_id: str
    op_location: SourceLocation
    id_location: SourceLocation
    expected_fields: list[str]
    client_location: SourceLocation | None = None


@dataclasses.dataclass
class SourceContract:
    schema_version: str
    verified_build_label: str
    build_label_location: SourceLocation
    endpoints: list[ConstantContract]
    graphql_paths: list[ConstantContract]
    wiz_keys: list[ConstantContract]
    wiz_aux_keys: list[ConstantContract]
    batch_rpcs: list[ConstantContract]
    graphql_operations: list[GraphQLOperationContract]
    process_session_path: tuple[list[int], SourceLocation]
    wire_enums: dict[str, list[IntContract]]
    selector_groups: list[SelectorGroupContract]
    artifact_fields: list[IntContract]
    deep_research_plan_field: IntContract | None
    dynamic_view_field: IntContract | None


@dataclasses.dataclass
class CheckResult:
    check_id: str
    layer: str
    version: str
    name: str
    status: str  # PASS | DEGRADED_FALLBACK_ACTIVE | BREAKING_DRIFT
    location: SourceLocation
    expected: str
    observed: str
    diagnosis: str
    active_fallback_index: int | None = None
    active_fallback_selector: str | None = None
    missing_atoms: list[str] = dataclasses.field(default_factory=list)
    discovered_candidates: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    source_chunks: list[str] = dataclasses.field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "check_id": self.check_id,
            "layer": self.layer,
            "version": self.version,
            "name": self.name,
            "status": self.status,
            "file": self.location.file,
            "line": self.location.line,
            "expected": self.expected,
            "observed": self.observed,
            "diagnosis": self.diagnosis,
        }
        if self.active_fallback_index is not None:
            payload["active_fallback_index"] = self.active_fallback_index
        if self.active_fallback_selector is not None:
            payload["active_fallback_selector"] = self.active_fallback_selector
        if self.missing_atoms:
            payload["missing_atoms"] = self.missing_atoms
        if self.discovered_candidates:
            payload["discovered_candidates"] = self.discovered_candidates
        if self.source_chunks:
            payload["source_chunks"] = self.source_chunks
        return payload


# ---------------------------------------------------------------------------
# Step 1: Swift Source Contract Extractor (exact file + 1-based line numbers)
# ---------------------------------------------------------------------------


def _line_number_at(text: str, char_index: int) -> int:
    return text.count("\n", 0, char_index) + 1


_SWIFT_STR_RE = r'(?:#".*?"#|"(?:[^"\\]|\\.)*")'


def _find_brace_block(text: str, header_pattern: str) -> tuple[str, int] | None:
    """Locate a Swift enum/struct block matching header_pattern and return (body, start_offset)."""
    match = re.search(header_pattern, text)
    if not match:
        return None
    brace_start = text.find("{", match.end() - 1)
    if brace_start == -1:
        return None
    depth = 0
    in_string = False
    in_raw_string = False
    escape = False
    i = brace_start
    n = len(text)
    while i < n:
        ch = text[i]
        if in_raw_string:
            if ch == '"' and i + 1 < n and text[i + 1] == "#":
                in_raw_string = False
                i += 1
        elif in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == "#" and i + 1 < n and text[i + 1] == '"':
                in_raw_string = True
                i += 1
            elif ch == '"':
                in_string = True
            elif ch == "/" and i + 1 < n and text[i + 1] == "/":
                nl = text.find("\n", i)
                if nl == -1:
                    break
                i = nl
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return text[brace_start + 1 : i], brace_start + 1
        i += 1
    return None


def _parse_swift_string_literal(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith('#"') and raw.endswith('"#'):
        return raw[2:-2]
    if raw.startswith('"') and raw.endswith('"'):
        inner = raw[1:-1]
        return (
            inner.replace('\\"', '"')
            .replace("\\n", "\n")
            .replace("\\t", "\t")
            .replace("\\\\", "\\")
        )
    return raw


def _extract_preceding_doc_comment(text: str, pos: int) -> str:
    line_start = text.rfind("\n", 0, pos) + 1
    lines: list[str] = []
    cursor = line_start - 1
    while cursor > 0:
        prev_start = text.rfind("\n", 0, cursor) + 1
        line = text[prev_start:cursor].strip()
        if line.startswith("///"):
            lines.append(line.lstrip("/").strip())
            cursor = prev_start - 1
        elif line == "":
            break
        else:
            break
    lines.reverse()
    return " ".join(lines)


def _extract_static_strings(
    full_text: str,
    block_text: str,
    block_offset: int,
    file_path: str,
) -> list[ConstantContract]:
    pattern = re.compile(
        rf"static\s+let\s+([A-Za-z_]\w*)\s*(?::\s*String)?\s*=\s*({_SWIFT_STR_RE})"
    )
    results: list[ConstantContract] = []
    for m in pattern.finditer(block_text):
        abs_pos = block_offset + m.start()
        line = _line_number_at(full_text, abs_pos)
        comment = _extract_preceding_doc_comment(full_text, abs_pos)
        results.append(
            ConstantContract(
                name=m.group(1),
                value=_parse_swift_string_literal(m.group(2)),
                location=SourceLocation(file=file_path, line=line),
                comment=comment,
            )
        )
    return results


def _extract_static_string_array(
    full_text: str,
    block_text: str,
    block_offset: int,
    prop_name: str,
    file_path: str,
) -> list[ConstantContract]:
    m = re.search(
        rf"static\s+let\s+{re.escape(prop_name)}\s*:\s*\[String\]\s*=\s*\[(.*?)\]",
        block_text,
        re.S,
    )
    if not m:
        return []
    arr_offset = block_offset + m.start(1)
    results: list[ConstantContract] = []
    for idx, sm in enumerate(re.finditer(rf"({_SWIFT_STR_RE})", m.group(1))):
        abs_pos = arr_offset + sm.start()
        line = _line_number_at(full_text, abs_pos)
        results.append(
            ConstantContract(
                name=f"{prop_name}[{idx}]",
                value=_parse_swift_string_literal(sm.group(1)),
                location=SourceLocation(file=file_path, line=line),
            )
        )
    return results


def _extract_int_enum_cases(
    full_text: str,
    block_text: str,
    block_offset: int,
    file_path: str,
) -> list[IntContract]:
    results: list[IntContract] = []
    for m in re.finditer(r"case\s+([A-Za-z_]\w*)\s*=\s*(-?\d+)", block_text):
        abs_pos = block_offset + m.start()
        line = _line_number_at(full_text, abs_pos)
        comment = _extract_preceding_doc_comment(full_text, abs_pos)
        results.append(
            IntContract(
                name=m.group(1),
                value=int(m.group(2)),
                location=SourceLocation(file=file_path, line=line),
                comment=comment,
            )
        )
    return results


def _extract_selector_groups(
    full_text: str,
    block_text: str,
    block_offset: int,
    section: str,
    file_path: str,
) -> list[SelectorGroupContract]:
    # Locate each `static let <name> = SelectorGroup(` and walk balanced parentheses (string-aware)
    header_re = re.compile(r"static\s+let\s+([A-Za-z_]\w*)\s*=\s*SelectorGroup\s*\(")
    str_re = re.compile(_SWIFT_STR_RE)
    groups: list[SelectorGroupContract] = []
    for m in header_re.finditer(block_text):
        abs_pos = block_offset + m.start()
        line = _line_number_at(full_text, abs_pos)
        # Walk balanced (...) from opening paren
        open_idx = m.end() - 1
        depth = 0
        in_str = False
        in_raw = False
        esc = False
        end_idx = open_idx
        n = len(block_text)
        i = open_idx
        while i < n:
            ch = block_text[i]
            if in_raw:
                if ch == '"' and i + 1 < n and block_text[i + 1] == "#":
                    in_raw = False
                    i += 1
            elif in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
            else:
                if ch == "#" and i + 1 < n and block_text[i + 1] == '"':
                    in_raw = True
                    i += 1
                elif ch == '"':
                    in_str = True
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        end_idx = i
                        break
            i += 1
        args_body = block_text[open_idx + 1 : end_idx]
        p_match = re.search(rf"primary\s*:\s*({_SWIFT_STR_RE})", args_body)
        if not p_match:
            continue
        primary = _parse_swift_string_literal(p_match.group(1))
        fb_start = args_body.find("fallbacks:")
        fallbacks: list[str] = []
        if fb_start != -1:
            fb_slice = args_body[fb_start:]
            fallbacks = [
                _parse_swift_string_literal(sm.group(0))
                for sm in str_re.finditer(fb_slice)
            ]
        groups.append(
            SelectorGroupContract(
                section=section,
                name=m.group(1),
                primary=primary,
                fallbacks=fallbacks,
                location=SourceLocation(file=file_path, line=line),
            )
        )
    return groups


def _extract_graphql_expected_fields(graphql_path: Path, rel_path: str) -> dict[str, tuple[list[str], SourceLocation]]:
    """Inspect GeminiGraphQLClient.swift decoders to verify live Relay AST selection fields."""
    if not graphql_path.exists():
        return {}
    text = graphql_path.read_text(encoding="utf-8")
    specs: dict[str, tuple[str, list[str]]] = {
        "branchConversation": (
            "func decodeBranchConversationId",
            ["branchConversation", "conversationId"],
        ),
        "createPublicShareLink": (
            "func decodeShareLinkResult",
            ["createSharedConversation", "externalUrlId"],
        ),
        "exportMessage": (
            "func decodeExportArtifactURL",
            ["exportMessage", "artifactUrl"],
        ),
        "searchChats": (
            "func decodeSearchHits",
            ["searchHistory", "historySnippets"],
        ),
        "responseTts": (
            "func decodeAudioData",
            ["getTts", "encodedAudio"],
        ),
    }
    output: dict[str, tuple[list[str], SourceLocation]] = {}
    for op_key, (anchor, candidate_fields) in specs.items():
        idx = text.find(anchor)
        if idx == -1:
            continue
        line = _line_number_at(text, idx)
        # Extract the function body window (up to next `nonisolated static func` or `// MARK:`)
        next_idx = text.find("nonisolated static func", idx + len(anchor))
        body = text[idx : next_idx if next_idx != -1 else len(text)]
        observed = [f for f in candidate_fields if f'"{f}"' in body]
        output[op_key] = (observed or candidate_fields, SourceLocation(file=rel_path, line=line))
    return output


def _extract_parser_artifact_contracts(
    parser_path: Path, rel_path: str
) -> tuple[list[IntContract], IntContract | None, IntContract | None]:
    """Extract v2.1 _.Cu Artifact submessage field numbers & Deep Research plan field from GeminiPayloadParser.swift."""
    if not parser_path.exists():
        return [], None, None
    text = parser_path.read_text(encoding="utf-8")
    artifact_fields: list[IntContract] = []

    art_idx = text.find("private static func extractArtifact(proto")
    if art_idx != -1:
        end_idx = text.find("private static func extractArtifact(json", art_idx)
        body = text[art_idx : end_idx if end_idx != -1 else art_idx + 4000]
        field_specs = [
            ("id", r"artifactMsg\.firstString\((\d+)\)"),
            ("title", r"artifactMsg\.firstString\((3)\)"),
            ("text", r"artifactMsg\.firstString\((5)\)"),
            ("documentOneof", r"artifactMsg\.firstSubmessage\((14)\)"),
            ("codeOneof", r"artifactMsg\.firstSubmessage\((15)\)"),
            ("deepResearchOneof", r"artifactMsg\.firstSubmessage\((16)\)"),
            ("editableCanvasOneof", r"artifactMsg\.firstSubmessage\((18)\)"),
        ]
        seen_nums: set[int] = set()
        for label, pat in field_specs:
            m = re.search(pat, body)
            if m:
                val = int(m.group(1))
                if val in seen_nums:
                    continue
                seen_nums.add(val)
                line = _line_number_at(text, art_idx + m.start())
                artifact_fields.append(
                    IntContract(
                        name=label,
                        value=val,
                        location=SourceLocation(file=rel_path, line=line),
                    )
                )
        # Include canonical v2.1 _.Cu fields 4 (subtitle/tag) and 11 (type enum) anchored to extractArtifact
        art_line = _line_number_at(text, art_idx)
        for label, num in [("subtitleTag", 4), ("artifactTypeEnum", 11)]:
            if num not in seen_nums:
                artifact_fields.append(
                    IntContract(
                        name=label,
                        value=num,
                        location=SourceLocation(file=rel_path, line=art_line),
                    )
                )
        artifact_fields.sort(key=lambda item: item.value)

    plan_field: IntContract | None = None
    dr_idx = text.find("private static func extractDeepResearchPlanArtifact(")
    if dr_idx != -1:
        m = re.search(r"attachmentsMsg\.firstSubmessage\((\d+)\)", text[dr_idx : dr_idx + 800])
        if m:
            plan_field = IntContract(
                name="deepResearchPlanAttachment",
                value=int(m.group(1)),
                location=SourceLocation(
                    file=rel_path, line=_line_number_at(text, dr_idx + m.start())
                ),
            )

    dyn_field: IntContract | None = None
    dm = re.search(r"attachmentsMsg\.firstSubmessage\((77)\)", text)
    if dm:
        dyn_field = IntContract(
            name="dynamicViewAttachment",
            value=int(dm.group(1)),
            location=SourceLocation(file=rel_path, line=_line_number_at(text, dm.start())),
        )

    return artifact_fields, plan_field, dyn_field


def extract_source_contract(
    selectors_path: Path,
    parser_path: Path,
    graphql_path: Path,
    repo_root: Path | None = None,
) -> SourceContract:
    def _rel(p: Path) -> str:
        if repo_root:
            try:
                return str(p.resolve().relative_to(repo_root.resolve()))
            except ValueError:
                pass
        return str(p)

    sel_rel = _rel(selectors_path)
    parser_rel = _rel(parser_path)
    gql_rel = _rel(graphql_path)

    text = selectors_path.read_text(encoding="utf-8")

    m_ver = re.search(r'static\s+let\s+schemaVersion\s*=\s*"([^"]+)"', text)
    schema_version = m_ver.group(1) if m_ver else "unknown"

    m_bl = re.search(r'static\s+let\s+verifiedBuildLabel\s*=\s*"([^"]+)"', text)
    verified_build_label = m_bl.group(1) if m_bl else "unknown"
    bl_loc = SourceLocation(
        file=sel_rel,
        line=_line_number_at(text, m_bl.start()) if m_bl else 1,
    )

    # Endpoints
    endpoints: list[ConstantContract] = []
    ep_block = _find_brace_block(text, r"enum\s+Endpoints\b[^{]*\{")
    if ep_block:
        endpoints = _extract_static_strings(text, ep_block[0], ep_block[1], sel_rel)

    # GraphQLGateway
    graphql_paths: list[ConstantContract] = []
    graphql_ops: list[GraphQLOperationContract] = []
    gql_fields_map = _extract_graphql_expected_fields(graphql_path, gql_rel)
    gql_block = _find_brace_block(text, r"enum\s+GraphQLGateway\b[^{]*\{")
    if gql_block:
        gql_body, gql_off = gql_block
        # Top-level constants (before nested enums)
        nested_start = gql_body.find("enum PersistedQuery")
        top_gql = gql_body[:nested_start] if nested_start != -1 else gql_body
        graphql_paths = _extract_static_strings(text, top_gql, gql_off, sel_rel)

        pq_block = _find_brace_block(gql_body, r"enum\s+PersistedQuery\b[^{]*\{")
        op_block = _find_brace_block(gql_body, r"enum\s+OperationName\b[^{]*\{")
        pq_map: dict[str, ConstantContract] = {}
        op_map: dict[str, ConstantContract] = {}
        if pq_block:
            for c in _extract_static_strings(text, pq_block[0], gql_off + pq_block[1], sel_rel):
                pq_map[c.name] = c
        if op_block:
            for c in _extract_static_strings(text, op_block[0], gql_off + op_block[1], sel_rel):
                op_map[c.name] = c

        for key, pq in pq_map.items():
            op = op_map.get(key)
            if not op:
                continue
            expected_fields, client_loc = gql_fields_map.get(key, ([], None))
            graphql_ops.append(
                GraphQLOperationContract(
                    key=key,
                    operation_name=op.value,
                    persisted_query_id=pq.value,
                    op_location=op.location,
                    id_location=pq.location,
                    expected_fields=expected_fields,
                    client_location=client_loc,
                )
            )

    # WizGlobalDataKeys
    wiz_keys: list[ConstantContract] = []
    wiz_aux_keys: list[ConstantContract] = []
    wiz_block = _find_brace_block(text, r"enum\s+WizGlobalDataKeys\b[^{]*\{")
    if wiz_block:
        wiz_keys = _extract_static_strings(text, wiz_block[0], wiz_block[1], sel_rel)
        wiz_aux_keys = _extract_static_string_array(
            text, wiz_block[0], wiz_block[1], "signedOutAuxiliaryKeys", sel_rel
        )

    # BatchExecuteRPC
    batch_rpcs: list[ConstantContract] = []
    rpc_block = _find_brace_block(text, r"enum\s+BatchExecuteRPC\b[^{]*\{")
    if rpc_block:
        batch_rpcs = _extract_static_strings(text, rpc_block[0], rpc_block[1], sel_rel)

    # WireFormat
    process_session_path: tuple[list[int], SourceLocation] = (
        [2, 7, 1, 4, 4],
        SourceLocation(file=sel_rel, line=1),
    )
    wire_enums: dict[str, list[IntContract]] = {}
    wf_block = _find_brace_block(text, r"enum\s+WireFormat\b[^{]*\{")
    if wf_block:
        wf_body, wf_off = wf_block
        m_ps = re.search(
            r"static\s+let\s+processSessionStreamResponsePath\s*:\s*\[Int\]\s*=\s*\[([^\]]+)\]",
            wf_body,
        )
        if m_ps:
            nums = [int(x.strip()) for x in m_ps.group(1).split(",") if x.strip().isdigit()]
            process_session_path = (
                nums,
                SourceLocation(file=sel_rel, line=_line_number_at(text, wf_off + m_ps.start())),
            )
        for enum_name in [
            "StreamResponseField",
            "CandidateField",
            "StructuredNodeField",
            "ListConversationsIndex",
            "ConversationItemIndex",
            "ListTurnsIndex",
            "TurnItemIndex",
            "GetUserStatusIndex",
        ]:
            eb = _find_brace_block(wf_body, rf"enum\s+{enum_name}\b[^{{]*\{{")
            if eb:
                wire_enums[enum_name] = _extract_int_enum_cases(
                    text, eb[0], wf_off + eb[1], sel_rel
                )

    # DOM SelectorGroups
    selector_groups: list[SelectorGroupContract] = []
    for dom_section in ["AuthDOM", "ComposerDOM", "ConversationDOM"]:
        db = _find_brace_block(text, rf"enum\s+{dom_section}\b[^{{]*\{{")
        if db:
            selector_groups.extend(
                _extract_selector_groups(text, db[0], db[1], dom_section, sel_rel)
            )

    artifact_fields, dr_plan_field, dyn_field = _extract_parser_artifact_contracts(
        parser_path, parser_rel
    )

    return SourceContract(
        schema_version=schema_version,
        verified_build_label=verified_build_label,
        build_label_location=bl_loc,
        endpoints=endpoints,
        graphql_paths=graphql_paths,
        wiz_keys=wiz_keys,
        wiz_aux_keys=wiz_aux_keys,
        batch_rpcs=batch_rpcs,
        graphql_operations=graphql_ops,
        process_session_path=process_session_path,
        wire_enums=wire_enums,
        selector_groups=selector_groups,
        artifact_fields=artifact_fields,
        deep_research_plan_field=dr_plan_field,
        dynamic_view_field=dyn_field,
    )


# ---------------------------------------------------------------------------
# Step 2: Zero-Secret Full Live Corpus Fetcher (with keep-alive & retry)
# ---------------------------------------------------------------------------


class _KeepAliveHTTPClient:
    """Thread-safe keep-alive HTTPS client using stdlib http.client with urllib proxy fallback."""

    def __init__(self, timeout: float = 20.0) -> None:
        self.timeout = timeout
        self._local = threading.local()
        self._ssl_context = ssl.create_default_context()
        self._use_urllib = bool(
            os.environ.get("HTTPS_PROXY")
            or os.environ.get("https_proxy")
            or os.environ.get("HTTP_PROXY")
            or os.environ.get("http_proxy")
        )
        self._all_conns: list[http.client.HTTPSConnection] = []
        self._lock = threading.Lock()

    def _get_conn(self, host: str, port: int) -> http.client.HTTPSConnection:
        pool: dict[tuple[str, int], http.client.HTTPSConnection] = getattr(
            self._local, "pool", None
        )
        if pool is None:
            pool = {}
            self._local.pool = pool
        key = (host, port)
        conn = pool.get(key)
        if conn is None:
            conn = http.client.HTTPSConnection(
                host, port, timeout=self.timeout, context=self._ssl_context
            )
            pool[key] = conn
            with self._lock:
                self._all_conns.append(conn)
        return conn

    def _drop_conn(self, host: str, port: int) -> None:
        pool: dict[tuple[str, int], http.client.HTTPSConnection] | None = getattr(
            self._local, "pool", None
        )
        if not pool:
            return
        conn = pool.pop((host, port), None)
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass

    def close(self) -> None:
        with self._lock:
            for conn in self._all_conns:
                try:
                    conn.close()
                except Exception:
                    pass
            self._all_conns.clear()

    def fetch_text(self, url: str, retries: int = 3) -> str:
        headers = {
            "User-Agent": USER_AGENT,
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip",
        }
        last_error: Exception | None = None
        for attempt in range(retries):
            if attempt > 0:
                time.sleep(0.5 * (2 ** (attempt - 1)))
            try:
                if self._use_urllib:
                    return self._fetch_via_urllib(url, headers)
                return self._fetch_via_keepalive(url, headers)
            except UpstreamFetchError as exc:
                # Don't retry hard 404s
                if "HTTP 404" in str(exc):
                    raise
                last_error = exc
            except Exception as exc:
                last_error = exc
        raise UpstreamFetchError(f"Failed to fetch {url} after {retries} attempts: {last_error}")

    def _fetch_via_urllib(self, url: str, headers: dict[str, str]) -> str:
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
                if resp.headers.get("Content-Encoding", "").lower() == "gzip":
                    raw = gzip.decompress(raw)
                return raw.decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            raise UpstreamFetchError(f"HTTP {exc.code} for {url}") from exc

    def _fetch_via_keepalive(self, url: str, headers: dict[str, str], redirects: int = 4) -> str:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname:
            return self._fetch_via_urllib(url, headers)
        host = parsed.hostname
        port = parsed.port or 443
        path = parsed.path or "/"
        if parsed.query:
            path = f"{path}?{parsed.query}"

        conn = self._get_conn(host, port)
        try:
            conn.request("GET", path, headers=headers)
            resp = conn.getresponse()
            raw = resp.read()
            status = resp.status
            encoding = resp.getheader("Content-Encoding", "")
            location = resp.getheader("Location")
        except (http.client.HTTPException, OSError, socket.timeout) as exc:
            self._drop_conn(host, port)
            raise UpstreamFetchError(f"Transport error for {url}: {exc}") from exc

        if status in (301, 302, 303, 307, 308) and location and redirects > 0:
            next_url = urllib.parse.urljoin(url, location)
            return self._fetch_via_keepalive(next_url, headers, redirects=redirects - 1)
        if status >= 400:
            raise UpstreamFetchError(f"HTTP {status} for {url}")
        if encoding.lower() == "gzip":
            raw = gzip.decompress(raw)
        return raw.decode("utf-8", errors="replace")


def _extract_wiz_global_data(html: str) -> dict[str, Any]:
    m = re.search(r"window\.WIZ_global_data\s*=\s*(\{.*?\});", html, re.S)
    if not m:
        return {}
    try:
        parsed = json.loads(m.group(1))
        return parsed if isinstance(parsed, dict) else {}
    except json.JSONDecodeError:
        return {}


def _extract_importmap(html: str) -> dict[str, str]:
    imports: dict[str, str] = {}
    for m in re.finditer(
        r'<script[^>]*type=["\']importmap["\'][^>]*>(.*?)</script>', html, re.S | re.I
    ):
        try:
            data = json.loads(m.group(1))
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict):
            top = data.get("imports")
            if isinstance(top, dict):
                for k, v in top.items():
                    if isinstance(k, str) and isinstance(v, str):
                        imports[k] = v
            scopes = data.get("scopes")
            if isinstance(scopes, dict):
                for scope_map in scopes.values():
                    if isinstance(scope_map, dict):
                        for k, v in scope_map.items():
                            if isinstance(k, str) and isinstance(v, str):
                                imports.setdefault(k, v)
    return imports


def _parse_closure_module_graph(md_text: str) -> tuple[list[str], dict[str, list[str]]]:
    """Parse Closure md=1 JSON `{"moduleGraph": "name:base36deps/..."}`."""
    try:
        payload = json.loads(md_text)
        mg = payload.get("moduleGraph", "") if isinstance(payload, dict) else ""
    except json.JSONDecodeError:
        mg = ""
    if not mg:
        return [], {}
    parts = [p for p in mg.split("/") if p]
    names = [p.split(":")[0] for p in parts]
    deps: dict[str, list[str]] = {}
    for idx, part in enumerate(parts):
        if ":" in part:
            raw_deps = part.split(":", 1)[1].split(",")
            resolved: list[str] = []
            for d in raw_deps:
                if not d:
                    continue
                try:
                    resolved.append(names[int(d, 36)])
                except (ValueError, IndexError):
                    pass
            deps[names[idx]] = resolved
        else:
            deps[names[idx]] = []
    return names, deps


def _compute_transitive_closure(roots: list[str], deps: dict[str, list[str]]) -> set[str]:
    visited: set[str] = set()
    stack = list(roots)
    while stack:
        mod = stack.pop()
        if mod in visited:
            continue
        visited.add(mod)
        stack.extend(deps.get(mod, []))
    return visited


def _build_closure_md_url(base_url: str) -> str:
    url = re.sub(r"/d=\d+", "", base_url)
    url = re.sub(r"/m=[^/?]+.*", "/md=1/m=_b", url)
    return url


def _build_closure_lazy_batch_urls(
    base_url: str,
    lazy_modules: list[str],
    exclude_roots: list[str],
    max_url_chars: int = CLOSURE_BATCH_MAX_URL_CHARS,
) -> list[tuple[str, str]]:
    """Pack lazy Closure module IDs into d=0 batch URLs each <= max_url_chars."""
    clean = re.sub(r"/d=\d+", "/d=0", base_url)
    clean = re.sub(r"/exm=[^/]+", "", clean)
    exm = ",".join(exclude_roots)
    prefix = re.sub(r"/m=[^/?]+.*", f"/exm={exm}/m=", clean)
    batches: list[tuple[str, str]] = []
    current: list[str] = []
    current_len = len(prefix)

    for mod in lazy_modules:
        add_len = len(mod) + (1 if current else 0)
        if current and current_len + add_len > max_url_chars:
            batch_name = f"closure_lazy_batch_{len(batches) + 1}({len(current)}_mods)"
            batches.append((batch_name, prefix + ",".join(current)))
            current = [mod]
            current_len = len(prefix) + len(mod)
        else:
            current.append(mod)
            current_len += add_len

    if current:
        batch_name = f"closure_lazy_batch_{len(batches) + 1}({len(current)}_mods)"
        batches.append((batch_name, prefix + ",".join(current)))
    return batches


def _resolve_islands_asset_urls(html: str, importmap: dict[str, str]) -> list[str]:
    """Map @messages/assets/<Chunk>-<Hash>.js keys and islands-*.js entrypoints to executable JS URLs."""
    urls: list[str] = []
    seen: set[str] = set()

    def add(u: str) -> None:
        if u and u not in seen:
            seen.add(u)
            urls.append(u)

    # 1. Entrypoint scripts (`islands-*.js`, `island-bootstrap-runtime-*.js`) from HTML
    for m in re.finditer(
        r'(?:src|href)=["\'](https://[^"\']+/islands/assets/[^"\']+\.js)["\']', html
    ):
        add(m.group(1))

    # 2. Importmap keys: `@messages/assets/<ChunkName>-<Hash>.js` -> executable chunk
    islands_base = DEFAULT_ISLANDS_BASE
    for val in importmap.values():
        bm = re.match(r"^(https?://[^?#]+?/islands/)", val)
        if bm:
            islands_base = bm.group(1)
            break

    for key in importmap.keys():
        km = re.search(r"@messages/(assets/[^?#\s]+)", key)
        if km:
            asset = km.group(1)
            if not asset.endswith(".js"):
                asset += ".js"
            add(islands_base + asset)

    return urls


_RELATIVE_IMPORT_RE = re.compile(
    r"""(?:from|import)\s*\(?\s*["'`](\./[^"'`]+\.js)["'`]"""
)


def fetch_live_corpus(
    app_url: str = DEFAULT_APP_URL,
    timeout: float = 20.0,
    max_workers: int = 24,
) -> dict[str, Any]:
    """Fetch complete zero-secret live Gemini Web corpus (HTML + Closure + Islands)."""
    t0 = time.monotonic()
    client = _KeepAliveHTTPClient(timeout=timeout)
    try:
        html = client.fetch_text(app_url)
        wiz_data = _extract_wiz_global_data(html)
        live_build_label = str(wiz_data.get("cfb2h") or "unknown")
        importmap = _extract_importmap(html)

        closure_urls = sorted(
            set(
                re.findall(
                    r'(?:src|href)=["\'](https://gemini\.gstatic\.com/_/mss/boq-gemini-web-uiserver/_/js/[^"\']+)["\']',
                    html,
                )
            )
        )
        base_url = next((u for u in closure_urls if "/m=_b" in u), None)
        preloaded_urls = [u for u in closure_urls if "/m=_b" not in u]

        closure_chunks: dict[str, str] = {}
        islands_chunks: dict[str, str] = {}
        failed_optional_urls: list[str] = []

        # Fetch Closure base, preloaded modules (e.g. vLefie), and md=1 graph in parallel
        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            initial_futures: dict[Any, tuple[str, str]] = {}
            if base_url:
                initial_futures[pool.submit(client.fetch_text, base_url)] = ("closure", "closure_base:_b")
                md_url = _build_closure_md_url(base_url)
                initial_futures[pool.submit(client.fetch_text, md_url)] = ("md", md_url)
            for idx, pu in enumerate(preloaded_urls):
                m_mod = re.search(r"/m=([^/?]+)", pu)
                label = f"closure_preloaded:{m_mod.group(1) if m_mod else idx}"
                initial_futures[pool.submit(client.fetch_text, pu)] = ("closure", label)

            # Seed Islands initial URLs concurrently too!
            islands_seed_urls = _resolve_islands_asset_urls(html, importmap)
            islands_seen: set[str] = set(islands_seed_urls)
            for iu in islands_seed_urls:
                chunk_name = iu.rsplit("/", 1)[-1]
                initial_futures[pool.submit(client.fetch_text, iu)] = ("islands", iu)

            md_text = ""
            islands_queue: deque[str] = deque()

            for fut in as_completed(initial_futures):
                kind, key = initial_futures[fut]
                try:
                    content = fut.result()
                except UpstreamFetchError as exc:
                    if kind == "islands":
                        failed_optional_urls.append(f"{key}: {exc}")
                        continue
                    raise

                if kind == "md":
                    md_text = content
                elif kind == "closure":
                    closure_chunks[key] = content
                elif kind == "islands":
                    chunk_name = key.rsplit("/", 1)[-1]
                    islands_chunks[chunk_name] = content
                    for rel_imp in _RELATIVE_IMPORT_RE.findall(content):
                        resolved = urllib.parse.urljoin(key, rel_imp)
                        if resolved not in islands_seen:
                            islands_seen.add(resolved)
                            islands_queue.append(resolved)

            # Compute lazy Closure modules & fetch both lazy Closure batches + Islands BFS in parallel
            lazy_batch_urls: list[tuple[str, str]] = []
            preloaded_mod_names = ["_b"]
            for pu in preloaded_urls:
                m_mod = re.search(r"/m=([^/?]+)", pu)
                if m_mod:
                    preloaded_mod_names.extend(m_mod.group(1).split(","))

            if base_url and md_text:
                all_mods, dep_graph = _parse_closure_module_graph(md_text)
                already_loaded = _compute_transitive_closure(preloaded_mod_names, dep_graph)
                lazy_mods = [m for m in all_mods if m not in already_loaded]
                if lazy_mods:
                    lazy_batch_urls = _build_closure_lazy_batch_urls(
                        base_url, lazy_mods, preloaded_mod_names
                    )

            pending_futs: dict[Any, tuple[str, str]] = {}
            for bname, burl in lazy_batch_urls:
                pending_futs[pool.submit(client.fetch_text, burl)] = ("closure_lazy", bname)

            # BFS loop for remaining Islands relative imports alongside lazy Closure batches
            max_islands_bfs = 600
            while pending_futs or islands_queue:
                while islands_queue and len(islands_seen) <= max_islands_bfs + len(islands_seed_urls):
                    next_u = islands_queue.popleft()
                    pending_futs[pool.submit(client.fetch_text, next_u)] = ("islands", next_u)
                if not pending_futs:
                    break
                done_batch = list(as_completed(list(pending_futs.keys())))
                for fut in done_batch:
                    kind, key = pending_futs.pop(fut)
                    try:
                        content = fut.result()
                    except UpstreamFetchError as exc:
                        if kind == "closure_lazy":
                            raise
                        failed_optional_urls.append(f"{key}: {exc}")
                        continue
                    if kind == "closure_lazy":
                        closure_chunks[key] = content
                    elif kind == "islands":
                        chunk_name = key.rsplit("/", 1)[-1]
                        islands_chunks[chunk_name] = content
                        for rel_imp in _RELATIVE_IMPORT_RE.findall(content):
                            resolved = urllib.parse.urljoin(key, rel_imp)
                            if resolved not in islands_seen:
                                islands_seen.add(resolved)
                                islands_queue.append(resolved)

        elapsed = round(time.monotonic() - t0, 2)
        if not html or not closure_chunks or not wiz_data:
            raise UpstreamFetchError(
                "Incomplete live corpus: missing HTML, WIZ_global_data, or Closure JS bundles."
            )
        if islands_seed_urls and not islands_chunks:
            raise UpstreamFetchError(
                "Incomplete live corpus: failed to fetch any Islands JS bundles."
            )

        return {
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "app_url": app_url,
            "live_build_label": live_build_label,
            "html": html,
            "wiz_global_data": wiz_data,
            "importmap": importmap,
            "closure_chunks": closure_chunks,
            "islands_chunks": islands_chunks,
            "stats": {
                "elapsed_seconds": elapsed,
                "html_bytes": len(html.encode("utf-8")),
                "closure_chunk_count": len(closure_chunks),
                "closure_total_chars": sum(len(v) for v in closure_chunks.values()),
                "islands_chunk_count": len(islands_chunks),
                "islands_total_chars": sum(len(v) for v in islands_chunks.values()),
                "importmap_entries": len(importmap),
                "failed_optional_count": len(failed_optional_urls),
            },
        }
    finally:
        client.close()


def save_corpus(corpus: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(corpus, ensure_ascii=False).encode("utf-8")
    if path.suffix == ".gz":
        path.write_bytes(gzip.compress(raw, compresslevel=6))
    else:
        path.write_bytes(raw)


def load_corpus(path: Path) -> dict[str, Any]:
    raw = path.read_bytes()
    if path.suffix == ".gz" or raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    data = json.loads(raw.decode("utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"Invalid corpus format in {path}")
    return data


# ---------------------------------------------------------------------------
# Step 3: Six Multi-Layer Contract Analyzers
# ---------------------------------------------------------------------------


class CorpusIndex:
    """Fast lookup helpers over HTML, Closure JS chunks, and Islands JS chunks."""

    def __init__(self, corpus: dict[str, Any]) -> None:
        self.html: str = str(corpus.get("html") or "")
        self.wiz: dict[str, Any] = dict(corpus.get("wiz_global_data") or {})
        self.live_build_label: str = str(
            corpus.get("live_build_label") or self.wiz.get("cfb2h") or "unknown"
        )
        self.closure_chunks: dict[str, str] = dict(corpus.get("closure_chunks") or {})
        self.islands_chunks: dict[str, str] = dict(corpus.get("islands_chunks") or {})

        self.all_sources: list[tuple[str, str]] = [("html", self.html)]
        for k, v in self.closure_chunks.items():
            self.all_sources.append((k, v))
        for k, v in self.islands_chunks.items():
            self.all_sources.append((k, v))

        self.closure_joined: str = "\n".join(self.closure_chunks.values())
        self.islands_joined: str = "\n".join(self.islands_chunks.values())
        self.all_joined: str = self.html + "\n" + self.closure_joined + "\n" + self.islands_joined

    def find_chunks_containing(self, needle: str, limit: int = 5) -> list[str]:
        if not needle:
            return []
        hits: list[str] = []
        for name, text in self.all_sources:
            if needle in text:
                hits.append(name)
                if len(hits) >= limit:
                    break
        return hits

    def find_chunks_matching(
        self, pattern: re.Pattern[str], prefilter: str | None = None, limit: int = 5
    ) -> list[str]:
        hits: list[str] = []
        for name, text in self.all_sources:
            if prefilter and prefilter not in text:
                continue
            if pattern.search(text):
                hits.append(name)
                if len(hits) >= limit:
                    break
        return hits


# --- Analyzer 1: WIZ_global_data Keys ---


def analyze_wiz_keys(contract: SourceContract, idx: CorpusIndex) -> list[CheckResult]:
    results: list[CheckResult] = []
    all_keys = contract.wiz_keys + contract.wiz_aux_keys

    # Expected anonymous invariants on https://gemini.google.com/app
    signed_in_only_keys = {"xsrfToken", "userEmail"}

    for item in all_keys:
        key = item.value
        in_wiz = key in idx.wiz
        wiz_val = idx.wiz.get(key)
        js_pattern = re.compile(rf"""["'`]{re.escape(key)}["'`]""")
        js_chunks = [
            name
            for name, text in idx.all_sources
            if name != "html" and key in text and js_pattern.search(text)
        ][:5]

        # Special anonymous invariants
        if item.name == "xsrfToken":
            # SNlM0e must be absent/empty in anonymous WIZ_global_data, and referenced in JS
            anon_ok = (not in_wiz) or (wiz_val in (None, ""))
            if anon_ok and js_chunks:
                status = "PASS"
                observed = f"absent in anon WIZ_global_data; referenced in {len(js_chunks)} JS chunk(s)"
                diagnosis = "Anonymous XSRF invariant holds and key is actively referenced in live JS."
            elif not anon_ok:
                status = "BREAKING_DRIFT"
                observed = f"unexpected non-empty value in anon WIZ_global_data ({type(wiz_val).__name__})"
                diagnosis = (
                    f"WIZ_global_data[{key!r}] unexpectedly populated on anonymous /app load; "
                    "signed-out detection invariant may be broken."
                )
            else:
                status = "BREAKING_DRIFT"
                observed = "absent in WIZ_global_data AND unreferenced in live JS"
                diagnosis = (
                    f"XSRF key {key!r} is no longer referenced in live Closure/Islands JS bundles. "
                    "Google may have rotated the XSRF WIZ_global_data key."
                )
            results.append(
                CheckResult(
                    check_id=f"wiz.{item.name}",
                    layer="wiz_global_data",
                    version="v2.0",
                    name=f"WizGlobalDataKeys.{item.name} ({key})",
                    status=status,
                    location=item.location,
                    expected=f"absent in anon WIZ_global_data; referenced in JS as '{key}'",
                    observed=observed,
                    diagnosis=diagnosis,
                    source_chunks=js_chunks,
                )
            )
            continue

        if item.name == "gaiaUserId":
            anon_empty = (not in_wiz) or (wiz_val in (None, ""))
            if anon_empty and (in_wiz or js_chunks):
                status = "PASS"
                observed = (
                    f"WIZ[{key!r}]={wiz_val!r}; referenced in {len(js_chunks)} JS chunk(s)"
                    if in_wiz
                    else f"referenced in {len(js_chunks)} JS chunk(s)"
                )
                diagnosis = "Anonymous Gaia ID invariant holds (empty string when signed out)."
            elif not anon_empty:
                status = "BREAKING_DRIFT"
                observed = f"WIZ[{key!r}]={wiz_val!r} (expected empty string when signed out)"
                diagnosis = f"Gaia user ID key {key!r} is non-empty on an anonymous session."
            else:
                status = "BREAKING_DRIFT"
                observed = "absent in both WIZ_global_data and live JS"
                diagnosis = f"Gaia user ID key {key!r} disappeared from both boot globals and JS."
            results.append(
                CheckResult(
                    check_id=f"wiz.{item.name}",
                    layer="wiz_global_data",
                    version="v2.0",
                    name=f"WizGlobalDataKeys.{item.name} ({key})",
                    status=status,
                    location=item.location,
                    expected=f"WIZ[{key!r}] == '' when anonymous and present in WIZ/JS",
                    observed=observed,
                    diagnosis=diagnosis,
                    source_chunks=(["html"] if in_wiz else []) + js_chunks,
                )
            )
            continue

        # Semantic sanity checks for critical host/prefix WIZ values
        semantic_mismatch: str | None = None
        if in_wiz and isinstance(wiz_val, str):
            if item.name == "rpcPrefix" and "/_/BardChatUi" not in wiz_val:
                semantic_mismatch = f"Expected '/_/BardChatUi' in WIZ[{key!r}], got {wiz_val!r}"
            elif item.name == "apiHost" and "clients6.google.com" not in wiz_val:
                semantic_mismatch = f"Expected clients6 API host in WIZ[{key!r}], got {wiz_val!r}"
            elif item.name == "uploadURL" and "/upload" not in wiz_val:
                semantic_mismatch = f"Expected upload URL in WIZ[{key!r}], got {wiz_val!r}"

        if semantic_mismatch:
            status = "BREAKING_DRIFT"
            observed = f"WIZ[{key!r}]={wiz_val!r}"
            diagnosis = semantic_mismatch
        elif in_wiz or js_chunks:
            status = "PASS"
            val_preview = (
                f"{str(wiz_val)[:48]}..." if isinstance(wiz_val, str) and len(wiz_val) > 48 else repr(wiz_val)
            )
            parts = []
            if in_wiz:
                parts.append(f"in anon WIZ ({val_preview})")
            if js_chunks:
                parts.append(f"in {len(js_chunks)} JS chunk(s)")
            observed = "; ".join(parts)
            diagnosis = f"WIZ key {key!r} verified live."
        else:
            status = "BREAKING_DRIFT"
            observed = "missing from anon WIZ_global_data and all Closure/Islands JS bundles"
            diagnosis = (
                f"WIZ_global_data key {key!r} ({item.name}) was not found in anonymous HTML boot "
                "globals or any fetched Closure/Islands module."
            )

        version = "v2.2" if item.name in {"serverToken", "apiKey", "apiHost"} else "v2.0"
        results.append(
            CheckResult(
                check_id=f"wiz.{item.name}",
                layer="wiz_global_data",
                version=version,
                name=f"WizGlobalDataKeys.{item.name} ({key})",
                status=status,
                location=item.location,
                expected=(
                    f"referenced in JS ('{key}')"
                    if item.name in signed_in_only_keys
                    else f"present in WIZ_global_data or JS ('{key}')"
                ),
                observed=observed,
                diagnosis=diagnosis,
                source_chunks=(["html"] if in_wiz else []) + js_chunks,
            )
        )

    return results


# --- Analyzer 2: Endpoints & Hosts ---


def analyze_endpoints(contract: SourceContract, idx: CorpusIndex) -> list[CheckResult]:
    results: list[CheckResult] = []
    # Select endpoint & GraphQL path constants that represent live hosts/routes
    checked_endpoint_names = {
        "geminiHost",
        "apiHost",
        "uploadHost",
        "accountsHost",
        "processSessionPath",
        "processSessionRPCPath",
        "streamGenerateSSEPath",
        "legacyStreamGeneratePath",
        "batchExecutePath",
        "uploadPath",
    }
    checked_graphql_names = {
        "executePath",
        "sameOriginFallbackPath",
        "defaultOrigin",
        "defaultApiOrigin",
    }

    items: list[tuple[str, str, ConstantContract]] = []
    for c in contract.endpoints:
        if c.name in checked_endpoint_names:
            items.append(("Endpoints", "v2.0", c))
    for c in contract.graphql_paths:
        if c.name in checked_graphql_names:
            items.append(("GraphQLGateway", "v2.2", c))

    # Some paths are concatenated from service prefix + method in Closure/Islands JS.
    # Verify exact literal first; if split by Google's client generator, verify BOTH parts exist.
    split_equivalents: dict[str, list[str]] = {
        "processSessionPath": ["v1/processSession", "processSession"],
        "processSessionRPCPath": [
            "assistant.lamda.bard.GeminiWebService",
            "ProcessSession",
        ],
        "streamGenerateSSEPath": ["conversations:streamGenerate"],
        "legacyStreamGeneratePath": [
            "/_/BardChatUi",
            "/assistant.lamda.BardFrontendService/StreamGenerate",
        ],
        "batchExecutePath": ["/_/BardChatUi", "batchexecute"],
        "executePath": [
            "gdm.geminiapp.hydrofoil.omakase.OmakaseGateway",
            "ExecuteGraphqlHttp",
        ],
        "sameOriginFallbackPath": ["/_/BardChatUi", "/graphql"],
    }

    for section, version, item in items:
        exact_chunks = idx.find_chunks_containing(item.value)
        if exact_chunks:
            status = "PASS"
            observed = f"exact literal found in {len(exact_chunks)} source(s): {', '.join(exact_chunks[:3])}"
            diagnosis = f"Endpoint/host `{item.value}` verified directly in live corpus."
            chunks = exact_chunks
        elif item.name in split_equivalents:
            parts = split_equivalents[item.name]
            matched_parts = {p: idx.find_chunks_containing(p, limit=2) for p in parts}
            if all(matched_parts.values()):
                status = "PASS"
                chunks = sorted({c for cs in matched_parts.values() for c in cs})[:5]
                observed = (
                    "assembled components verified live: "
                    + ", ".join(f"`{p}`" for p in parts)
                )
                diagnosis = (
                    f"Endpoint `{item.value}` verified via live service/route components "
                    f"({', '.join(parts)})."
                )
            else:
                missing_parts = [p for p, cs in matched_parts.items() if not cs]
                status = "BREAKING_DRIFT"
                chunks = []
                observed = f"missing component(s): {', '.join(missing_parts)}"
                diagnosis = (
                    f"Endpoint `{item.value}` not found in live corpus (missing: "
                    f"{', '.join(missing_parts)}). Google may have changed the service path or host."
                )
        else:
            status = "BREAKING_DRIFT"
            chunks = []
            observed = "not found anywhere in HTML, Closure, or Islands bundles"
            diagnosis = (
                f"Host/path `{item.value}` disappeared from live HTML and JS bundles."
            )

        results.append(
            CheckResult(
                check_id=f"endpoint.{section}.{item.name}",
                layer="endpoints",
                version=version,
                name=f"{section}.{item.name}",
                status=status,
                location=item.location,
                expected=item.value,
                observed=observed,
                diagnosis=diagnosis,
                source_chunks=chunks,
            )
        )
    return results


# --- Analyzer 3: batchexecute RPC IDs ---


# Matches Closure gRPC descriptor literals regardless of minified property names:
# e.g. {kc:"MaZiqc",rc:_.Fu?"/BardFrontendService.ListConversations":void 0,wc:!0,qc:_.wUb,zc:_.uUb}
_GRPC_DESCRIPTOR_RE = re.compile(
    r'\{[A-Za-z_$][\w$]*:"([A-Za-z0-9_-]{4,12})",'
    r'[A-Za-z_$][\w$]*:[^?]{1,40}\?"(/[A-Za-z0-9_.]+\.[A-Za-z0-9_]+)":void 0,'
    r"([^}]{1,260})\}"
)
_NEW_D_RPC_RE = re.compile(r'new\s+_\.[A-Za-z_$][\w$]*\("([A-Za-z0-9_-]{5,10})"')


@dataclasses.dataclass
class LiveRPCDescriptor:
    rpc_id: str
    service_method: str
    response_class: str | None
    request_class: str | None
    chunk: str
    raw_tail: str


def extract_live_rpc_descriptors(
    idx: CorpusIndex,
) -> tuple[dict[str, LiveRPCDescriptor], dict[str, LiveRPCDescriptor], dict[str, str]]:
    """Extract live Closure gRPC descriptors keyed by rpc_id and by /Service.Method."""
    by_id: dict[str, LiveRPCDescriptor] = {}
    by_service_method: dict[str, LiveRPCDescriptor] = {}
    bare_ids: dict[str, str] = {}

    for chunk_name, text in idx.closure_chunks.items():
        for m in _GRPC_DESCRIPTOR_RE.finditer(text):
            rpc_id = m.group(1)
            svc_method = m.group(2)
            tail = m.group(3)
            # Extract response/request proto class references (typically 2nd & 3rd class tokens after bool)
            class_refs = re.findall(
                r"[A-Za-z_$][\w$]*:((?:_\.)?[A-Za-z_$][\w$]*)", tail
            )
            # Filter out booleans/void/true/false
            proto_refs = [
                r
                for r in class_refs
                if r not in ("true", "false", "void", "null", "undefined")
            ]
            resp_cls = proto_refs[0] if len(proto_refs) >= 1 else None
            req_cls = proto_refs[1] if len(proto_refs) >= 2 else None

            desc = LiveRPCDescriptor(
                rpc_id=rpc_id,
                service_method=svc_method,
                response_class=resp_cls,
                request_class=req_cls,
                chunk=chunk_name,
                raw_tail=tail,
            )
            by_id[rpc_id] = desc
            by_service_method[svc_method] = desc

        for m in _NEW_D_RPC_RE.finditer(text):
            bare_ids.setdefault(m.group(1), chunk_name)

    return by_id, by_service_method, bare_ids


def _expected_service_method_from_comment(comment: str, prop_name: str) -> str | None:
    m = re.search(r"([A-Za-z0-9_]+\.[A-Za-z0-9_]+)", comment)
    if m:
        return "/" + m.group(1).lstrip("/")
    # Fallback heuristic from Swift camelCase property name
    pascal = prop_name[0].upper() + prop_name[1:] if prop_name else ""
    return f"/BardFrontendService.{pascal}" if pascal else None


def analyze_batch_rpcs(
    contract: SourceContract,
    idx: CorpusIndex,
) -> tuple[list[CheckResult], dict[str, LiveRPCDescriptor]]:
    by_id, by_svc, bare_ids = extract_live_rpc_descriptors(idx)
    results: list[CheckResult] = []

    for item in contract.batch_rpcs:
        rpc_id = item.value
        expected_svc = _expected_service_method_from_comment(item.comment, item.name)
        desc = by_id.get(rpc_id)

        if desc:
            if expected_svc and desc.service_method != expected_svc:
                results.append(
                    CheckResult(
                        check_id=f"rpc.{item.name}",
                        layer="batchexecute_rpc",
                        version="v2.0",
                        name=f"BatchExecuteRPC.{item.name} ({rpc_id})",
                        status="BREAKING_DRIFT",
                        location=item.location,
                        expected=f"{rpc_id} -> {expected_svc}",
                        observed=f"{rpc_id} now maps to {desc.service_method} in {desc.chunk}",
                        diagnosis=(
                            f"RPC ID `{rpc_id}` was reassigned from `{expected_svc}` to "
                            f"`{desc.service_method}`."
                        ),
                        discovered_candidates=(
                            [
                                {
                                    "rpc_id": by_svc[expected_svc].rpc_id,
                                    "service_method": expected_svc,
                                    "chunk": by_svc[expected_svc].chunk,
                                }
                            ]
                            if expected_svc in by_svc
                            else []
                        ),
                        source_chunks=[desc.chunk],
                    )
                )
            else:
                results.append(
                    CheckResult(
                        check_id=f"rpc.{item.name}",
                        layer="batchexecute_rpc",
                        version="v2.0",
                        name=f"BatchExecuteRPC.{item.name} ({rpc_id})",
                        status="PASS",
                        location=item.location,
                        expected=f"{rpc_id} ({expected_svc or 'any'})",
                        observed=f"{desc.rpc_id} -> {desc.service_method} (resp={desc.response_class})",
                        diagnosis="Verified live Closure gRPC descriptor matches expected RPC ID.",
                        source_chunks=[desc.chunk],
                    )
                )
            continue

        # Secondary check: bare RPC ID literal (e.g. `new _.D("<rpcid>")` or quoted token)
        if rpc_id in bare_ids or f'"{rpc_id}"' in idx.closure_joined:
            chunk = bare_ids.get(rpc_id) or (
                idx.find_chunks_containing(f'"{rpc_id}"', limit=1) or ["closure"]
            )[0]
            results.append(
                CheckResult(
                    check_id=f"rpc.{item.name}",
                    layer="batchexecute_rpc",
                    version="v2.0",
                    name=f"BatchExecuteRPC.{item.name} ({rpc_id})",
                    status="PASS",
                    location=item.location,
                    expected=rpc_id,
                    observed=f"found literal '{rpc_id}' in {chunk}",
                    diagnosis="RPC ID present in live Closure bundle.",
                    source_chunks=[chunk],
                )
            )
            continue

        # Missing! Auto-discover replacement via /Service.Method anchor!
        candidates: list[dict[str, Any]] = []
        if expected_svc and expected_svc in by_svc:
            live = by_svc[expected_svc]
            candidates.append(
                {
                    "rpc_id": live.rpc_id,
                    "service_method": live.service_method,
                    "response_class": live.response_class,
                    "chunk": live.chunk,
                }
            )
            diagnosis = (
                f"RPC ID `{rpc_id}` for `{expected_svc}` disappeared from live build "
                f"`{idx.live_build_label}`. Live replacement discovered: `{live.rpc_id}` "
                f"in `{live.chunk}`."
            )
            observed = f"missing `{rpc_id}`; live `{expected_svc}` uses `{live.rpc_id}`"
        else:
            # Fuzzy search by method name tail
            method_tail = (expected_svc or "").rsplit(".", 1)[-1].lower()
            for svc_m, live in sorted(by_svc.items()):
                if method_tail and method_tail in svc_m.lower():
                    candidates.append(
                        {
                            "rpc_id": live.rpc_id,
                            "service_method": live.service_method,
                            "chunk": live.chunk,
                        }
                    )
            candidates = candidates[:5]
            diagnosis = (
                f"RPC ID `{rpc_id}` ({expected_svc or item.name}) was not found in live Closure "
                f"modules (`{idx.live_build_label}`)."
            )
            observed = (
                f"missing `{rpc_id}`; {len(candidates)} fuzzy candidate(s) found"
                if candidates
                else f"missing `{rpc_id}` and anchor `{expected_svc}`"
            )

        results.append(
            CheckResult(
                check_id=f"rpc.{item.name}",
                layer="batchexecute_rpc",
                version="v2.0",
                name=f"BatchExecuteRPC.{item.name} ({rpc_id})",
                status="BREAKING_DRIFT",
                location=item.location,
                expected=f"{rpc_id} ({expected_svc or item.name})",
                observed=observed,
                diagnosis=diagnosis,
                discovered_candidates=candidates,
            )
        )

    return results, by_svc


# --- Analyzer 4: Omakase Relay GraphQL Contracts (v2.2) ---


_QUOTE_VAL = r"""["'`]([^"'`]+)["'`]"""
_RELAY_NAME_RE = re.compile(rf"""\bname\s*:\s*{_QUOTE_VAL}""")
_RELAY_ID_RE = re.compile(rf"""\bid\s*:\s*["'`](2/[A-Za-z0-9+/_=-]{{16,128}})["'`]""")
_RELAY_KIND_RE = re.compile(rf"""\boperationKind\s*:\s*{_QUOTE_VAL}""")
_RELAY_FIELD_RE = re.compile(
    rf"""kind\s*:\s*["'`](?:ScalarField|LinkedField)["'`]\s*,\s*name\s*:\s*{_QUOTE_VAL}"""
)
_RELAY_ARG_RE = re.compile(
    rf"""kind\s*:\s*["'`](?:LocalArgument|Variable)["'`]\s*,\s*name\s*:\s*{_QUOTE_VAL}"""
)


@dataclasses.dataclass
class LiveRelayOperation:
    operation_name: str
    persisted_query_id: str
    operation_kind: str
    chunk_name: str
    argument_names: list[str]
    selection_fields: list[str]
    is_preloadable: bool


def _iter_relay_params_blocks(text: str):
    """Linear-time extractor for `params:{...}` blocks (supports nested `{}` like `metadata:{}`)."""
    for needle in ("params:{", "params: {"):
        pos = text.find(needle)
        n = len(text)
        while pos != -1:
            brace_start = text.find("{", pos)
            if brace_start == -1:
                break
            depth = 0
            end = -1
            limit = min(n, brace_start + 600)
            for i in range(brace_start, limit):
                ch = text[i]
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
            if end != -1:
                yield pos, end + 1, text[brace_start + 1 : end]
            pos = text.find(needle, pos + len(needle))


def extract_live_relay_operations(idx: CorpusIndex) -> dict[str, LiveRelayOperation]:
    """Extract all Relay ConcreteRequest & PreloadableConcreteRequest ops from Islands chunks."""
    ops: dict[str, LiveRelayOperation] = {}

    sources: list[tuple[str, str]] = list(idx.islands_chunks.items()) + list(
        idx.closure_chunks.items()
    )

    for chunk_name, text in sources:
        if "params:{" not in text and "params: {" not in text:
            continue
        for start_pos, end_pos, params_body in _iter_relay_params_blocks(text):
            if "2/" not in params_body:
                continue
            nm = _RELAY_NAME_RE.search(params_body)
            im = _RELAY_ID_RE.search(params_body)
            if not nm or not im:
                continue
            op_name = nm.group(1)
            pq_id = im.group(1)
            km = _RELAY_KIND_RE.search(params_body)
            op_kind = km.group(1) if km else "unknown"

            win_start = max(0, start_pos - 6000)
            win_end = min(len(text), end_pos + 6000)
            window = text[win_start:win_end]

            is_preloadable = "PreloadableConcreteRequest" in text[max(0, start_pos - 80) : start_pos]
            args = sorted(set(_RELAY_ARG_RE.findall(window)))
            fields = sorted(set(_RELAY_FIELD_RE.findall(window)))

            existing = ops.get(op_name)
            if existing is None or (len(fields) > len(existing.selection_fields)):
                ops[op_name] = LiveRelayOperation(
                    operation_name=op_name,
                    persisted_query_id=pq_id,
                    operation_kind=op_kind,
                    chunk_name=chunk_name,
                    argument_names=args,
                    selection_fields=fields,
                    is_preloadable=is_preloadable,
                )

    return ops


def analyze_graphql_contracts(contract: SourceContract, idx: CorpusIndex) -> list[CheckResult]:
    live_ops = extract_live_relay_operations(idx)
    results: list[CheckResult] = []

    for op in contract.graphql_operations:
        live = live_ops.get(op.operation_name)
        if not live:
            # Fuzzy search by key fragments
            needle = op.key.lower().replace("createpublic", "").replace("response", "")
            candidates = [
                {
                    "operation_name": lo.operation_name,
                    "persisted_query_id": lo.persisted_query_id,
                    "operation_kind": lo.operation_kind,
                    "chunk": lo.chunk_name,
                }
                for lo in live_ops.values()
                if needle in lo.operation_name.lower()
                or any(f in lo.selection_fields for f in op.expected_fields[:1])
            ][:5]
            results.append(
                CheckResult(
                    check_id=f"graphql.{op.key}",
                    layer="omakase_graphql",
                    version="v2.2",
                    name=f"GraphQLGateway.{op.key} ({op.operation_name})",
                    status="BREAKING_DRIFT",
                    location=op.id_location,
                    expected=f"{op.operation_name} -> {op.persisted_query_id}",
                    observed="operation not found in any fetched Islands Relay bundle",
                    diagnosis=(
                        f"Relay operation `{op.operation_name}` was not found across "
                        f"{len(idx.islands_chunks)} Islands chunks (`{idx.live_build_label}`). "
                        "Operation may have been renamed or moved."
                    ),
                    discovered_candidates=candidates,
                )
            )
            continue

        # Check persistedQueryId match
        id_matches = live.persisted_query_id == op.persisted_query_id

        # Check expected selection fields in live AST (or anywhere in the chunk for preloadable ops)
        chunk_text = idx.islands_chunks.get(live.chunk_name) or idx.closure_chunks.get(
            live.chunk_name, ""
        )
        missing_fields = [
            f
            for f in op.expected_fields
            if f not in live.selection_fields
            and not re.search(rf"""name\s*:\s*["'`]{re.escape(f)}["'`]""", chunk_text)
        ]

        if id_matches and not missing_fields:
            results.append(
                CheckResult(
                    check_id=f"graphql.{op.key}",
                    layer="omakase_graphql",
                    version="v2.2",
                    name=f"GraphQLGateway.{op.key} ({op.operation_name})",
                    status="PASS",
                    location=op.id_location,
                    expected=f"{op.persisted_query_id} (fields: {', '.join(op.expected_fields)})",
                    observed=(
                        f"exact hash match ({live.operation_kind}); "
                        f"fields verified in {live.chunk_name}"
                    ),
                    diagnosis=(
                        f"Persisted query ID and expected response fields for `{op.operation_name}` "
                        "match live Islands Relay AST."
                    ),
                    source_chunks=[live.chunk_name],
                )
            )
        elif not id_matches:
            results.append(
                CheckResult(
                    check_id=f"graphql.{op.key}",
                    layer="omakase_graphql",
                    version="v2.2",
                    name=f"GraphQLGateway.{op.key} ({op.operation_name})",
                    status="BREAKING_DRIFT",
                    location=op.id_location,
                    expected=op.persisted_query_id,
                    observed=live.persisted_query_id,
                    diagnosis=(
                        f"Persisted query ID rotated for `{op.operation_name}` in `{live.chunk_name}`: "
                        f"expected `{op.persisted_query_id}`, live is `{live.persisted_query_id}`."
                        + (
                            f" Also missing selection field(s): {', '.join(missing_fields)}."
                            if missing_fields
                            else ""
                        )
                    ),
                    discovered_candidates=[
                        {
                            "operation_name": live.operation_name,
                            "persisted_query_id": live.persisted_query_id,
                            "operation_kind": live.operation_kind,
                            "chunk": live.chunk_name,
                            "selection_fields": live.selection_fields[:20],
                        }
                    ],
                    source_chunks=[live.chunk_name],
                )
            )
        else:
            results.append(
                CheckResult(
                    check_id=f"graphql.{op.key}",
                    layer="omakase_graphql",
                    version="v2.2",
                    name=f"GraphQLGateway.{op.key} ({op.operation_name})",
                    status="BREAKING_DRIFT",
                    location=op.client_location or op.op_location,
                    expected=f"selection fields {op.expected_fields}",
                    observed=f"missing {missing_fields}; observed {live.selection_fields[:15]}",
                    diagnosis=(
                        f"Persisted query ID matches for `{op.operation_name}`, but expected response "
                        f"selection field(s) `{', '.join(missing_fields)}` disappeared from "
                        f"`{live.chunk_name}`."
                    ),
                    discovered_candidates=[
                        {
                            "operation_name": live.operation_name,
                            "chunk": live.chunk_name,
                            "live_selection_fields": live.selection_fields[:25],
                        }
                    ],
                    source_chunks=[live.chunk_name],
                )
            )

    return results


# --- Analyzer 5: Protobuf / JSPB Wire Field Indices (v2.0 + v2.1) ---


def _find_class_definition_body(closure_text: str, symbol: str) -> str | None:
    """Locate `symbol=class extends ...{...}` using fast literal str.find() anchoring."""
    if not symbol:
        return None
    needle = f"{symbol}=class"
    pos = closure_text.find(needle)
    while pos != -1:
        # Ensure we didn't match a suffix of another identifier (e.g. foo_.uv=class)
        if pos == 0 or not (closure_text[pos - 1].isalnum() or closure_text[pos - 1] in "_$."):
            brace = closure_text.find("{", pos + len(needle), pos + len(needle) + 80)
            if brace != -1:
                depth = 0
                for i in range(brace, min(len(closure_text), brace + 4000)):
                    ch = closure_text[i]
                    if ch == "{":
                        depth += 1
                    elif ch == "}":
                        depth -= 1
                        if depth == 0:
                            return closure_text[brace : i + 1]
        pos = closure_text.find(needle, pos + len(needle))
    return None


def _iter_literal_windows(text: str, needle: str, before: int = 200, after: int = 200, max_hits: int = 64):
    """Yield (pos, window) around each literal occurrence of needle in O(n) C-speed."""
    pos = text.find(needle)
    count = 0
    n = len(text)
    while pos != -1 and count < max_hits:
        yield pos, text[max(0, pos - before) : min(n, pos + len(needle) + after)]
        count += 1
        pos = text.find(needle, pos + len(needle))


def _find_accessor_field_numbers_for_class(closure_text: str, cls_symbol: str) -> list[int]:
    """Find field numbers passed to `_.xx(<arg>, <cls_symbol>, <fieldNum>` via fast str.find()."""
    needle = f",{cls_symbol},"
    nums: set[int] = set()
    for _, win in _iter_literal_windows(closure_text, needle, before=24, after=24, max_hits=200):
        for m in re.finditer(rf",\s*{re.escape(cls_symbol)},\s*(\d{{1,3}})\b", win):
            nums.add(int(m.group(1)))
    return sorted(nums)


def _extract_enclosing_class_symbol(prefix_window: str) -> str | None:
    """Given text immediately preceding a method inside `SYM=class extends ...{`, extract `SYM`."""
    idx = prefix_window.rfind("=class extends ")
    if idx == -1:
        idx = prefix_window.rfind("=class ")
    if idx == -1:
        return None
    tail = prefix_window[idx:]
    if "};" in tail:
        return None
    m = re.search(r"((?:_\.)?[A-Za-z_$][\w$]*)$", prefix_window[:idx].rstrip())
    return m.group(1) if m else None


def _extract_field_numbers_in_code(snippet: str) -> set[int]:
    """Extract proto field numbers passed to Closure JSPB accessor helpers like _.m(this,3), _.l(a,Cls,5)."""
    nums: set[int] = set()
    for m in re.finditer(
        r"_\.[A-Za-z0-9_$]{1,4}\((?:this|[A-Za-z_$][\w$]*),(?:(?:_\.)?[A-Za-z_$][\w$]*,)?(\d{1,3})\b",
        snippet,
    ):
        nums.add(int(m.group(1)))
    return nums


def analyze_proto_wire_format(
    contract: SourceContract,
    idx: CorpusIndex,
    live_rpcs_by_svc: dict[str, LiveRPCDescriptor],
) -> list[CheckResult]:
    results: list[CheckResult] = []
    closure = idx.closure_joined

    sg_desc = live_rpcs_by_svc.get("/BardFrontendService.StreamGenerate")
    art_desc = live_rpcs_by_svc.get("/BardFrontendService.GetArtifactVersion")
    lt_desc = live_rpcs_by_svc.get("/BardFrontendService.ListConversationTurns")
    us_desc = live_rpcs_by_svc.get("/BardFrontendService.GetUserStatus")

    sg_cls = sg_desc.response_class if sg_desc else None
    art_cls = art_desc.response_class if art_desc else None
    lt_cls = lt_desc.response_class if lt_desc else None

    # 5a. ProcessSession WebChannel path [2, 7, 1, 4, 4] -> StreamGenerateResponse
    ps_path, ps_loc = contract.process_session_path
    ps_ok = False
    ps_obs = "StreamGenerate response class not resolved"
    ps_chunks: list[str] = []
    if sg_cls:
        needle_sg4 = f",{sg_cls},{ps_path[-1]})"
        found_pos = closure.find(needle_sg4)
        if found_pos != -1:
            ctx = closure[max(0, found_pos - 700) : min(len(closure), found_pos + 220)]
            m_tp = re.search(
                rf"_\.[A-Za-z_$][\w$]*\([^,]+,\s*((?:_\.)?[A-Za-z_$][\w$]*),\s*{ps_path[2]}\b",
                ctx,
            )
            tp_cls = m_tp.group(1) if m_tp else None
            tp_body = _find_class_definition_body(closure, tp_cls) if tp_cls else None
            tp_has_4 = bool(tp_body and f",{ps_path[3]}," in tp_body or (tp_body and f",{ps_path[3]})" in tp_body))
            has_ps_svc = "ProcessSession" in closure
            ps_ok = bool(tp_cls and tp_has_4 and has_ps_svc)
            ps_obs = (
                f"StreamGenerate={sg_cls} decoded at field {ps_path[-1]}; "
                f"TurnPayload={tp_cls} (field {ps_path[3]}={'ok' if tp_has_4 else 'missing'})"
            )
            ps_chunks = idx.find_chunks_containing(needle_sg4, limit=2)
        else:
            alt_nums = _find_accessor_field_numbers_for_class(closure, sg_cls)
            ps_obs = (
                f"{sg_cls} not decoded at terminal field {ps_path[-1]}; "
                f"observed submessage field numbers: {alt_nums}"
            )
    results.append(
        CheckResult(
            check_id="proto.processSessionPath",
            layer="proto_wire_format",
            version="v2.0",
            name="WireFormat.processSessionStreamResponsePath",
            status="PASS" if ps_ok else "BREAKING_DRIFT",
            location=ps_loc,
            expected=f"path {ps_path} -> {sg_cls or 'StreamGenerateResponse'}",
            observed=ps_obs,
            diagnosis=(
                "WebChannel ProcessSession -> StreamGenerateResponse protobuf traversal verified."
                if ps_ok
                else f"Expected ProcessSession path {ps_path} terminating in `{sg_cls}` not matched in live Closure bundle."
            ),
            source_chunks=ps_chunks,
        )
    )

    # 5b. Candidate (`_.NEb`) & StreamGenerateResponse field 5 (candidates), 13 (attachments), 31/42 (artifacts), 38 (thoughts)
    cand_fields_map = {c.name: c for c in contract.wire_enums.get("CandidateField", [])}
    sr_fields_map = {c.name: c for c in contract.wire_enums.get("StreamResponseField", [])}

    # Discover Candidate class dynamically via fast linear search on `hasAttachments(){`
    att_num = cand_fields_map["attachments"].value if "attachments" in cand_fields_map else 13
    cand_cls: str | None = None
    att_body_re = re.compile(rf"hasAttachments\(\)\{{return\s+_\.[A-Za-z_$][\w$]*\(this,{att_num}\)\}}")
    for pos, win in _iter_literal_windows(closure, "hasAttachments(){", before=180, after=80, max_hits=64):
        if att_body_re.search(win):
            sym = _extract_enclosing_class_symbol(closure[max(0, pos - 180) : pos])
            if sym:
                cand_cls = sym
                break

    # Check StreamGenerateResponse.candidates (field 5) -> repeated Candidate
    cand_sr_contract = sr_fields_map.get("candidates")
    if cand_sr_contract:
        f5_ok = False
        f5_obs = "Candidate class not located"
        if cand_cls:
            cand_nums = _find_accessor_field_numbers_for_class(closure, cand_cls)
            f5_ok = cand_sr_contract.value in cand_nums
            if f5_ok:
                f5_obs = f"repeated {cand_cls} verified at field {cand_sr_contract.value}"
            else:
                f5_obs = f"{cand_cls} not at field {cand_sr_contract.value}; found at fields {cand_nums}"
        results.append(
            CheckResult(
                check_id="proto.streamResponse.candidates",
                layer="proto_wire_format",
                version="v2.0",
                name=f"StreamResponseField.candidates (field {cand_sr_contract.value})",
                status="PASS" if f5_ok else "BREAKING_DRIFT",
                location=cand_sr_contract.location,
                expected=f"field {cand_sr_contract.value} (repeated Candidate)",
                observed=f5_obs,
                diagnosis=(
                    "StreamGenerateResponse.candidates field index verified."
                    if f5_ok
                    else f"StreamGenerateResponse.candidates field {cand_sr_contract.value} shifted or missing."
                ),
            )
        )

    # Check Candidate.attachments (field 13)
    if "attachments" in cand_fields_map:
        c_att = cand_fields_map["attachments"]
        results.append(
            CheckResult(
                check_id="proto.candidate.attachments",
                layer="proto_wire_format",
                version="v2.0",
                name=f"CandidateField.attachments (field {c_att.value})",
                status="PASS" if cand_cls else "BREAKING_DRIFT",
                location=c_att.location,
                expected=f"hasAttachments() -> field {c_att.value}",
                observed=f"{cand_cls}.hasAttachments() reads field {c_att.value}" if cand_cls else "missing",
                diagnosis=(
                    "Candidate.attachments field index verified."
                    if cand_cls
                    else f"Could not verify Candidate.hasAttachments() at field {c_att.value}."
                ),
            )
        )

    # Check Candidate.artifacts (31) and Candidate.secondaryArtifacts (42) via resolved Artifact class
    art_accessor_fields = _find_accessor_field_numbers_for_class(closure, art_cls) if art_cls else []
    for field_key in ("artifacts", "secondaryArtifacts"):
        cf = cand_fields_map.get(field_key)
        if not cf:
            continue
        ok = bool(art_cls and cf.value in art_accessor_fields)
        if ok:
            obs = f"repeated {art_cls} decoded at field {cf.value}"
            candidates: list[dict[str, Any]] = []
        elif art_cls:
            obs = f"{art_cls} not decoded at field {cf.value}; observed fields: {art_accessor_fields}"
            candidates = [{"artifact_class": art_cls, "observed_fields": art_accessor_fields}]
        else:
            obs = "Artifact class not resolved from /BardFrontendService.GetArtifactVersion"
            candidates = []
        results.append(
            CheckResult(
                check_id=f"proto.candidate.{field_key}",
                layer="proto_wire_format",
                version="v2.1",
                name=f"CandidateField.{field_key} (field {cf.value})",
                status="PASS" if ok else "BREAKING_DRIFT",
                location=cf.location,
                expected=f"repeated {art_cls or 'Artifact'} at field {cf.value}",
                observed=obs,
                diagnosis=(
                    f"Candidate.{field_key} (field {cf.value}) verified against live `{art_cls}`."
                    if ok
                    else f"Candidate.{field_key} expected at field {cf.value} for `{art_cls}`, but disappeared."
                ),
                discovered_candidates=candidates,
            )
        )

    # Check Candidate.thoughts (38) using fast literal search on `,38)`
    if "thoughts" in cand_fields_map:
        c_th = cand_fields_map["thoughts"]
        th_needle = f",{c_th.value})"
        pat_th = re.compile(
            rf"_\.[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,(?:_\.)?[A-Za-z_$][\w$]*,{c_th.value}\)"
        )
        th_ok = False
        th_obs = f"no field-{c_th.value} submessage decoder found"
        fallback_match: str | None = None
        for _, win in _iter_literal_windows(closure, th_needle, before=400, after=400, max_hits=120):
            tm = pat_th.search(win)
            if not tm:
                continue
            if fallback_match is None:
                fallback_match = tm.group(0)
            if "thought" in win.lower() or ",31," in win or ",42," in win or (art_cls and art_cls in win):
                th_ok = True
                th_obs = f"verified decoder `{tm.group(0)}`"
                break
        if not th_ok and fallback_match:
            th_ok = True
            th_obs = f"verified submessage decoder `{fallback_match}`"
        results.append(
            CheckResult(
                check_id="proto.candidate.thoughts",
                layer="proto_wire_format",
                version="v2.0",
                name=f"CandidateField.thoughts (field {c_th.value})",
                status="PASS" if th_ok else "BREAKING_DRIFT",
                location=c_th.location,
                expected=f"submessage at field {c_th.value}",
                observed=th_obs,
                diagnosis=(
                    f"Candidate.thoughts (field {c_th.value}) verified in Closure decoder."
                    if th_ok
                    else f"Candidate.thoughts (field {c_th.value}) submessage decoder not found."
                ),
            )
        )

    # 5c. v2.1 Artifact (`_.Cu`) internal fields (1, 3, 4, 5, 11) and oneof branches (14, 15, 16, 18)
    art_body = _find_class_definition_body(closure, art_cls) if art_cls else None
    art_body_fields = _extract_field_numbers_in_code(art_body) if art_body else set()

    # Locate Artifact oneof switch via fast literal anchor `){case 14:`
    oneof_switch_cases: set[int] = set()
    oneof_array_nums: set[int] = set()
    oneof_context = ""
    sw_re = re.compile(
        r"switch\(_\.[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,((?:_\.)?[A-Za-z_$][\w$]*)\)\)\{case\s+14:"
    )
    for pos, win in _iter_literal_windows(closure, "){case 14:", before=80, after=3200, max_hits=32):
        m_sw = sw_re.search(win)
        if not m_sw:
            continue
        if "artifactType:" not in win and not ("case 15:" in win and "case 16:" in win):
            continue
        oneof_sym = m_sw.group(1)
        oneof_context = closure[max(0, pos - 1200) : min(len(closure), pos + 3200)]
        oneof_switch_cases = {int(n) for n in re.findall(r"\bcase\s+(\d+):", win)}
        arr_needle = f"{oneof_sym}=["
        arr_pos = closure.find(arr_needle)
        if arr_pos != -1:
            end_b = closure.find("]", arr_pos + len(arr_needle), arr_pos + len(arr_needle) + 160)
            if end_b != -1:
                arr_str = closure[arr_pos + len(arr_needle) : end_b]
                oneof_array_nums = {
                    int(x.strip()) for x in arr_str.split(",") if x.strip().isdigit()
                }
        break

    for af in contract.artifact_fields:
        num = af.value
        if num in (14, 15, 16, 18):
            ok = (num in oneof_switch_cases) or (num in oneof_array_nums)
            obs = (
                f"case {num} present in Artifact oneof switch (cases={sorted(oneof_switch_cases)[:10]})"
                if ok
                else f"case {num} missing from Artifact oneof switch (observed cases={sorted(oneof_switch_cases)}, array={sorted(oneof_array_nums)})"
            )
            diag = (
                f"v2.1 Artifact oneof branch {num} ({af.name}) verified."
                if ok
                else f"v2.1 Artifact oneof branch {num} ({af.name}) disappeared from live Artifact switch."
            )
        elif num in (3, 5, 11):
            ok = num in art_body_fields
            obs = (
                f"{art_cls} class accesses field {num}"
                if ok
                else f"field {num} missing from {art_cls} body (observed fields={sorted(art_body_fields)})"
            )
            diag = (
                f"v2.1 Artifact field {num} ({af.name}) verified on `{art_cls}`."
                if ok
                else f"v2.1 Artifact field {num} ({af.name}) not found on `{art_cls}`."
            )
        elif num == 4:
            ok = (4 in art_body_fields) or bool(
                re.search(r"_\.[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,4\)", oneof_context)
            )
            if not ok:
                # Also check the Artifact extractor around `{artifactId:...}` (`y0d`) where `_.Ng(a,4)` / `_.m(a,4)` lives
                for _, awin in _iter_literal_windows(closure, "artifactId:", before=120, after=220, max_hits=32):
                    if "getTitle()" in awin and re.search(r"_\.[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,4\)", awin):
                        ok = True
                        break
            obs = "field 4 verified in Artifact extractor" if ok else "field 4 not found in Artifact extractor"
            diag = (
                "v2.1 Artifact field 4 (subtitle/tag) verified."
                if ok
                else "v2.1 Artifact field 4 not found in Artifact class or extractor."
            )
        else:
            ok = (
                (num in art_body_fields)
                or bool(art_cls and f"{art_cls}.prototype." in closure)
                or ("artifactId:" in oneof_context)
            )
            obs = (
                f"{art_cls} artifactId accessor verified"
                if ok
                else f"field {num} ({af.name}) not verified on {art_cls}"
            )
            diag = (
                f"v2.1 Artifact field {num} ({af.name}) verified."
                if ok
                else f"v2.1 Artifact field {num} ({af.name}) could not be verified."
            )

        results.append(
            CheckResult(
                check_id=f"proto.artifact.field_{num}",
                layer="proto_wire_format",
                version="v2.1",
                name=f"Artifact.{af.name} (field {num})",
                status="PASS" if ok else "BREAKING_DRIFT",
                location=af.location,
                expected=f"Artifact ({art_cls or '_.Cu'}) field {num}",
                observed=obs,
                diagnosis=diag,
                discovered_candidates=(
                    [{"oneof_cases": sorted(oneof_switch_cases), "oneof_array": sorted(oneof_array_nums)}]
                    if not ok and num in (14, 15, 16, 18)
                    else []
                ),
            )
        )

    # 5d. Deep Research Plan attachment field 19 (`attachmentsMsg.firstSubmessage(19)`)
    if contract.deep_research_plan_field:
        drf = contract.deep_research_plan_field
        dr_needle = f",{drf.value})"
        dr_has_accessor = False
        dr_pat = re.compile(rf"_\.[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,(?:(?:_\.)?[A-Za-z_$][\w$]*,)?{drf.value}\)")
        for _, win in _iter_literal_windows(closure, dr_needle, before=40, after=8, max_hits=64):
            if dr_pat.search(win):
                dr_has_accessor = True
                break
        dr_ok = dr_has_accessor and (
            "deep-research-confirmation-widget" in closure
            or "deep_research" in closure.lower()
            or "research-steps" in closure
        )
        results.append(
            CheckResult(
                check_id="proto.attachments.deepResearchPlan",
                layer="proto_wire_format",
                version="v2.1",
                name=f"Attachments.deepResearchPlan (field {drf.value} / JSPB [{drf.value - 1}])",
                status="PASS" if dr_ok else "BREAKING_DRIFT",
                location=drf.location,
                expected=f"field {drf.value} on attachments submessage",
                observed=(
                    f"field {drf.value} accessor & Deep Research confirmation module present"
                    if dr_ok
                    else f"field {drf.value} Deep Research plan accessor not found"
                ),
                diagnosis=(
                    "v2.1 Deep Research plan confirmation field verified."
                    if dr_ok
                    else f"Deep Research plan field {drf.value} not verified in Closure bundle."
                ),
            )
        )

    # 5e. Dynamic View attachment field 77
    if contract.dynamic_view_field:
        dvf = contract.dynamic_view_field
        dv_needle = f",{dvf.value},"
        dv_ok = False
        dv_pat = re.compile(
            rf"_\.[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,(?:_\.)?[A-Za-z_$][\w$]*,{dvf.value}[,)]"
        )
        for needle in (dv_needle, f",{dvf.value})"):
            for _, win in _iter_literal_windows(closure, needle, before=40, after=16, max_hits=64):
                if dv_pat.search(win):
                    dv_ok = True
                    break
            if dv_ok:
                break
        results.append(
            CheckResult(
                check_id="proto.attachments.dynamicView",
                layer="proto_wire_format",
                version="v2.0",
                name=f"Attachments.dynamicView (field {dvf.value} / JSPB [{dvf.value - 1}])",
                status="PASS" if dv_ok else "BREAKING_DRIFT",
                location=dvf.location,
                expected=f"repeated dynamic view at field {dvf.value}",
                observed=(
                    f"field {dvf.value} submessage accessor verified"
                    if dv_ok
                    else f"field {dvf.value} accessor missing"
                ),
                diagnosis=(
                    "Attachments dynamic view field 77 verified."
                    if dv_ok
                    else f"Dynamic view attachment field {dvf.value} disappeared."
                ),
            )
        )

    # 5f. ListConversations (`MaZiqc` -> field 3 / JSPB [2])
    lc_idx_map = {c.name: c for c in contract.wire_enums.get("ListConversationsIndex", [])}
    if "conversations" in lc_idx_map:
        c_conv = lc_idx_map["conversations"]
        proto_num = c_conv.value + 1  # JSPB [2] -> proto field 3
        conv_cls: str | None = None
        icon_re = re.compile(r"getIcon\(\)\{return\s+_\.[A-Za-z_$][\w$]*\(this,5\)\}")
        title_re = re.compile(r"getTitle\(\)\{return\s+_\.[A-Za-z_$][\w$]*\(this,2\)\}")
        for pos, win in _iter_literal_windows(closure, "getIcon(){", before=360, after=80, max_hits=32):
            if icon_re.search(win) and title_re.search(win):
                sym = _extract_enclosing_class_symbol(closure[max(0, pos - 360) : pos])
                if sym:
                    conv_cls = sym
                    break
        conv_fields = _find_accessor_field_numbers_for_class(closure, conv_cls) if conv_cls else []
        ok = bool(conv_cls and proto_num in conv_fields)
        results.append(
            CheckResult(
                check_id="proto.listConversations.conversations",
                layer="proto_wire_format",
                version="v2.0",
                name=f"ListConversationsIndex.conversations (JSPB [{c_conv.value}] / field {proto_num})",
                status="PASS" if ok else "BREAKING_DRIFT",
                location=c_conv.location,
                expected=f"repeated Conversation at field {proto_num} (JSPB [{c_conv.value}])",
                observed=(
                    f"repeated {conv_cls} verified at field {proto_num}"
                    if ok
                    else f"Conversation class ({conv_cls}) not decoded at field {proto_num} (observed={conv_fields})"
                ),
                diagnosis=(
                    "ListConversations conversations array index verified."
                    if ok
                    else f"ListConversations conversations field {proto_num} shifted or missing."
                ),
            )
        )

    # 5g. ListConversationTurns (`hNvQHb` -> field 5 / JSPB [4] status)
    lt_idx_map = {c.name: c for c in contract.wire_enums.get("ListTurnsIndex", [])}
    if "status" in lt_idx_map:
        c_st = lt_idx_map["status"]
        proto_num = c_st.value + 1  # JSPB [4] -> proto field 5
        lt_body = _find_class_definition_body(closure, lt_cls) if lt_cls else None
        lt_fields = _extract_field_numbers_in_code(lt_body) if lt_body else set()
        ok = proto_num in lt_fields
        results.append(
            CheckResult(
                check_id="proto.listTurns.status",
                layer="proto_wire_format",
                version="v2.0",
                name=f"ListTurnsIndex.status (JSPB [{c_st.value}] / field {proto_num})",
                status="PASS" if ok else "BREAKING_DRIFT",
                location=c_st.location,
                expected=f"{lt_cls or 'ListConversationTurnsResponse'} field {proto_num} (JSPB [{c_st.value}])",
                observed=(
                    f"{lt_cls}.getStatus() reads field {proto_num}"
                    if ok
                    else f"field {proto_num} missing from {lt_cls} (observed={sorted(lt_fields)})"
                ),
                diagnosis=(
                    "ListConversationTurns status field verified."
                    if ok
                    else f"ListConversationTurns status field {proto_num} shifted on `{lt_cls}`."
                ),
            )
        )

    # 5h. GetUserStatus (`otAQ7b` -> field 16 / JSPB [15] availableModels)
    us_idx_map = {c.name: c for c in contract.wire_enums.get("GetUserStatusIndex", [])}
    if "availableModels" in us_idx_map:
        c_mod = us_idx_map["availableModels"]
        proto_num = c_mod.value + 1  # JSPB [15] -> proto field 16
        us_has_16 = False
        if us_desc:
            mod_pat = re.compile(
                rf"_\.[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,(?:_\.)?[A-Za-z_$][\w$]*,{proto_num}[,)]"
            )
            for needle in (f",{proto_num},", f",{proto_num})"):
                for _, win in _iter_literal_windows(closure, needle, before=40, after=12, max_hits=64):
                    if mod_pat.search(win):
                        us_has_16 = True
                        break
                if us_has_16:
                    break
        results.append(
            CheckResult(
                check_id="proto.getUserStatus.availableModels",
                layer="proto_wire_format",
                version="v2.0",
                name=f"GetUserStatusIndex.availableModels (JSPB [{c_mod.value}] / field {proto_num})",
                status="PASS" if us_has_16 else "BREAKING_DRIFT",
                location=c_mod.location,
                expected=f"GetUserStatus ({us_desc.response_class if us_desc else '?'}) field {proto_num}",
                observed=(
                    f"repeated model accessor at field {proto_num} verified alongside {us_desc.rpc_id}"
                    if us_has_16 and us_desc
                    else f"field {proto_num} accessor or GetUserStatus descriptor missing"
                ),
                diagnosis=(
                    "GetUserStatus availableModels field index verified."
                    if us_has_16
                    else f"GetUserStatus availableModels field {proto_num} could not be verified."
                ),
            )
        )

    return results


# --- Analyzer 6: DOM SelectorGroups (v2.0 + v2.1 + v2.2) ---


@dataclasses.dataclass(frozen=True)
class SelectorAtom:
    kind: str  # tag | class | data-test-id | jslog | fonticon | attr | href | role
    value: str
    raw: str


_GENERIC_HTML_TAGS = {
    "a",
    "button",
    "div",
    "span",
    "img",
    "input",
    "textarea",
    "p",
    "ul",
    "li",
    "nav",
    "header",
    "footer",
    "main",
    "section",
    "form",
    "label",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
}


def decompose_css_selector(selector: str) -> list[SelectorAtom]:
    """Decompose a CSS selector string into verifiable structural atoms."""
    # Remove :not(...) clauses so negated classes/attributes aren't required to exist
    cleaned = re.sub(r":not\([^)]*\)", " ", selector)
    # Unwrap :has(...) so inner selectors are also verified
    cleaned = re.sub(r":has\(([^)]*)\)", r" \1 ", cleaned)

    atoms: list[SelectorAtom] = []
    seen: set[tuple[str, str]] = set()

    def add(kind: str, val: str, raw: str) -> None:
        key = (kind, val)
        if val and key not in seen:
            seen.add(key)
            atoms.append(SelectorAtom(kind=kind, value=val, raw=raw))

    # 1. Attribute selectors `[attr op "val"]` or `[attr]`
    attr_re = re.compile(
        r"""\[\s*([A-Za-z0-9_-]+)\s*(?:([*^$|~]?=)\s*["']([^"']+)["'](?:\s+[iIsS])?)?\s*\]"""
    )
    for m in attr_re.finditer(cleaned):
        attr_name = m.group(1).lower()
        attr_val = m.group(3)
        raw = m.group(0)
        if attr_name == "data-test-id" and attr_val:
            add("data-test-id", attr_val, raw)
        elif attr_name == "jslog" and attr_val:
            ve_id = attr_val.split(";", 1)[0].strip()
            add("jslog", ve_id, raw)
        elif attr_name in ("fonticon", "data-mat-icon-name") and attr_val:
            add("fonticon", attr_val, raw)
        elif attr_name == "href" and attr_val:
            add("href", attr_val, raw)
        elif attr_name == "role" and attr_val:
            add("role", attr_val, raw)
        elif attr_name in (
            "webkitdirectory",
            "data-mode-id",
            "gem-open-account-menu",
            "cdktextareaautosize",
            "mat-menu-item",
            "contenteditable",
            "aria-haspopup",
        ):
            add("attr", attr_name, raw)
        elif attr_name == "aria-label":
            # aria-label text can be localized/runtime-injected; verify attribute presence
            add("attr", "aria-label", raw)
        elif attr_name == "type" and attr_val:
            add("attr", f'type="{attr_val}"', raw)
        elif attr_name == "multiple":
            add("attr", "multiple", raw)

    # Strip attribute blocks before scanning for tag names & classes
    no_attrs = attr_re.sub(" ", cleaned)

    # 2. Class names `.foo-bar`
    for m in re.finditer(r"\.([A-Za-z_][A-Za-z0-9_-]*)", no_attrs):
        add("class", m.group(1), m.group(0))

    # Strip classes & pseudos before scanning for custom element tags
    no_classes = re.sub(r"\.[A-Za-z_][A-Za-z0-9_-]*", " ", no_attrs)
    no_classes = re.sub(r":[A-Za-z_-]+", " ", no_classes)

    # 3. Custom element tag names (containing `-`)
    for m in re.finditer(r"(?<![A-Za-z0-9_-])([a-z][a-z0-9]*(?:-[a-z0-9]+)+)(?![A-Za-z0-9_-])", no_classes):
        tag = m.group(1)
        if tag not in _GENERIC_HTML_TAGS:
            add("tag", tag, tag)

    return atoms


def _atom_exists_in_corpus(atom: SelectorAtom, idx: CorpusIndex) -> tuple[bool, list[str]]:
    """Verify whether a single CSS selector atom exists in live HTML, Closure, or Islands."""
    val = atom.value
    if atom.kind == "tag":
        pat = re.compile(rf"""(?:<|["'`\s,>]){re.escape(val)}(?:[\s"'`>.,:\[]|$)""")
        chunks = idx.find_chunks_matching(pat, prefilter=val, limit=3)
        return bool(chunks), chunks

    if atom.kind == "class":
        pat = re.compile(rf"""(?<![A-Za-z0-9_-]){re.escape(val)}(?![A-Za-z0-9_-])""")
        chunks = idx.find_chunks_matching(pat, prefilter=val, limit=3)
        return bool(chunks), chunks

    if atom.kind == "data-test-id":
        pat = re.compile(rf"""["'`]{re.escape(val)}""")
        chunks = idx.find_chunks_matching(pat, prefilter=val, limit=3)
        return bool(chunks), chunks

    if atom.kind == "jslog":
        pat = re.compile(rf"""(?<!\d){re.escape(val)}(?:;|\b)""")
        chunks = idx.find_chunks_matching(pat, prefilter=val, limit=3)
        return bool(chunks), chunks

    if atom.kind == "fonticon":
        pat = re.compile(rf"""["'`]{re.escape(val)}["'`]""")
        chunks = idx.find_chunks_matching(pat, prefilter=val, limit=3)
        return bool(chunks), chunks

    if atom.kind == "href":
        chunks = idx.find_chunks_containing(val, limit=3)
        if not chunks and "/" in val:
            tail = val.rsplit("/", 1)[-1]
            chunks = idx.find_chunks_containing(tail, limit=3)
        return bool(chunks), chunks

    if atom.kind == "role":
        pat = re.compile(rf"""["'`]{re.escape(val)}["'`]""")
        chunks = idx.find_chunks_matching(pat, prefilter=val, limit=3)
        return bool(chunks), chunks

    if atom.kind == "attr":
        if val.startswith('type="'):
            inner = val.split('"', 2)[1]
            pat = re.compile(rf"""type["'`\s:=]+["'`]?{re.escape(inner)}["'`]?""")
            chunks = idx.find_chunks_matching(pat, prefilter=inner, limit=3)
            return bool(chunks), chunks
        chunks = idx.find_chunks_containing(val, limit=3)
        return bool(chunks), chunks

    chunks = idx.find_chunks_containing(val, limit=3)
    return bool(chunks), chunks


def _discover_nearby_test_ids(
    idx: CorpusIndex,
    anchor_atoms: list[SelectorAtom],
    missing_atoms: list[SelectorAtom],
) -> list[dict[str, Any]]:
    """Find nearby data-test-id values in chunks containing surviving anchor atoms or related keywords."""
    candidates: list[dict[str, Any]] = []
    seen_vals: set[str] = set()

    # Collect keywords from missing atoms to rank relevant live data-test-ids
    keywords: set[str] = set()
    for a in missing_atoms:
        for tok in re.split(r"[^a-zA-Z0-9]+", a.value.lower()):
            if len(tok) >= 3 and tok not in ("button", "item", "menu", "icon", "true"):
                keywords.add(tok)

    # Search chunks containing surviving anchor atoms first
    anchor_chunks: list[str] = []
    for a in anchor_atoms:
        ok, chunks = _atom_exists_in_corpus(a, idx)
        if ok:
            for c in chunks:
                if c not in anchor_chunks:
                    anchor_chunks.append(c)

    target_sources = (
        [(n, t) for n, t in idx.all_sources if n in anchor_chunks]
        if anchor_chunks
        else idx.all_sources
    )

    test_id_re = re.compile(r"""data-test-id["'`\s,:=]+["'`]([a-zA-Z0-9_-]{3,64})["'`]""")
    for chunk_name, text in target_sources:
        for m in test_id_re.finditer(text):
            val = m.group(1)
            if val in seen_vals:
                continue
            low = val.lower()
            if keywords and not any(kw in low for kw in keywords):
                continue
            seen_vals.add(val)
            candidates.append({"data-test-id": val, "chunk": chunk_name})
            if len(candidates) >= 8:
                return candidates

    return candidates


def _selector_version(group: SelectorGroupContract) -> str:
    v22_names = {
        "branchButton",
        "shareButton",
        "modifyResponseButton",
        "retryWithoutToolButton",
        "ttsControl",
        "searchChatsButton",
        "moreActionsButton",
        "overlayMenuItems",
    }
    v21_names = {
        "codeImportTrigger",
        "codeFolderUploadItem",
        "directoryFileInput",
        "toolboxDrawerTrigger",
        "toolboxDrawerItem",
        "toolboxDeselectButton",
        "deepResearchConfirmationWidget",
        "deepResearchConfirmButton",
        "deepResearchEditButton",
        "deepResearchProcessingStatus",
    }
    if group.name in v22_names:
        return "v2.2"
    if group.name in v21_names:
        return "v2.1"
    return "v2.0"


def analyze_dom_selectors(contract: SourceContract, idx: CorpusIndex) -> list[CheckResult]:
    results: list[CheckResult] = []
    atom_cache: dict[SelectorAtom, tuple[bool, list[str]]] = {}

    def check_atom(atom: SelectorAtom) -> tuple[bool, list[str]]:
        if atom not in atom_cache:
            atom_cache[atom] = _atom_exists_in_corpus(atom, idx)
        return atom_cache[atom]

    def evaluate_selector(sel: str) -> tuple[bool, list[SelectorAtom], list[SelectorAtom], list[str]]:
        atoms = decompose_css_selector(sel)
        if not atoms:
            return True, [], [], []
        found_atoms: list[SelectorAtom] = []
        missing_atoms: list[SelectorAtom] = []
        chunks: list[str] = []
        for a in atoms:
            ok, c = check_atom(a)
            if ok:
                found_atoms.append(a)
                for ch in c:
                    if ch not in chunks:
                        chunks.append(ch)
            else:
                missing_atoms.append(a)
        return len(missing_atoms) == 0, found_atoms, missing_atoms, chunks[:5]

    for group in contract.selector_groups:
        p_ok, p_found, p_missing, p_chunks = evaluate_selector(group.primary)
        version = _selector_version(group)
        check_id = f"dom.{group.section}.{group.name}"

        if p_ok:
            results.append(
                CheckResult(
                    check_id=check_id,
                    layer="dom_selectors",
                    version=version,
                    name=f"{group.section}.{group.name}",
                    status="PASS",
                    location=group.location,
                    expected=group.primary,
                    observed=f"all {len(p_found)} primary atom(s) verified live",
                    diagnosis="Primary CSS selector atoms verified in live corpus.",
                    source_chunks=p_chunks,
                )
            )
            continue

        # Primary missing >= 1 atom; test fallbacks in priority order
        active_fb_idx: int | None = None
        active_fb_sel: str | None = None
        active_fb_chunks: list[str] = []
        fallback_reports: list[str] = []

        for fb_idx, fb_sel in enumerate(group.fallbacks):
            fb_ok, _, fb_missing, fb_chunks = evaluate_selector(fb_sel)
            if fb_ok and active_fb_idx is None:
                active_fb_idx = fb_idx
                active_fb_sel = fb_sel
                active_fb_chunks = fb_chunks
            elif not fb_ok:
                fallback_reports.append(
                    f"fallbacks[{fb_idx}] missing {[a.raw for a in fb_missing]}"
                )

        nearby = _discover_nearby_test_ids(idx, p_found, p_missing)
        missing_raws = [a.raw for a in p_missing]

        if active_fb_idx is not None and active_fb_sel is not None:
            results.append(
                CheckResult(
                    check_id=check_id,
                    layer="dom_selectors",
                    version=version,
                    name=f"{group.section}.{group.name}",
                    status="DEGRADED_FALLBACK_ACTIVE",
                    location=group.location,
                    expected=group.primary,
                    observed=(
                        f"primary missing {missing_raws}; "
                        f"kept alive by fallbacks[{active_fb_idx}] (`{active_fb_sel}`)"
                    ),
                    diagnosis=(
                        f"Primary selector `{group.primary}` lost atom(s) {', '.join(missing_raws)}. "
                        f"Lite Gemini is currently kept alive by `fallbacks[{active_fb_idx}]`: "
                        f"`{active_fb_sel}`. Update `primary` before Google drops this fallback too."
                    ),
                    active_fallback_index=active_fb_idx,
                    active_fallback_selector=active_fb_sel,
                    missing_atoms=missing_raws,
                    discovered_candidates=nearby,
                    source_chunks=active_fb_chunks,
                )
            )
        else:
            results.append(
                CheckResult(
                    check_id=check_id,
                    layer="dom_selectors",
                    version=version,
                    name=f"{group.section}.{group.name}",
                    status="BREAKING_DRIFT",
                    location=group.location,
                    expected=group.primary,
                    observed=(
                        f"primary missing {missing_raws}; ALL {len(group.fallbacks)} fallback(s) failed "
                        f"({'; '.join(fallback_reports[:3])})"
                    ),
                    diagnosis=(
                        f"Primary selector `{group.primary}` AND all {len(group.fallbacks)} fallback "
                        f"selector(s) failed verification against live build `{idx.live_build_label}`. "
                        f"Missing primary atoms: {', '.join(missing_raws)}."
                    ),
                    missing_atoms=missing_raws,
                    discovered_candidates=nearby,
                )
            )

    return results


# ---------------------------------------------------------------------------
# Audit Orchestrator & Report Generators
# ---------------------------------------------------------------------------


def run_audit(contract: SourceContract, corpus: dict[str, Any]) -> dict[str, Any]:
    idx = CorpusIndex(corpus)

    checks: list[CheckResult] = []
    checks.extend(analyze_wiz_keys(contract, idx))
    checks.extend(analyze_endpoints(contract, idx))
    rpc_checks, live_rpcs_by_svc = analyze_batch_rpcs(contract, idx)
    checks.extend(rpc_checks)
    checks.extend(analyze_graphql_contracts(contract, idx))
    checks.extend(analyze_proto_wire_format(contract, idx, live_rpcs_by_svc))
    checks.extend(analyze_dom_selectors(contract, idx))

    pass_count = sum(1 for c in checks if c.status == "PASS")
    degraded_count = sum(1 for c in checks if c.status == "DEGRADED_FALLBACK_ACTIVE")
    breaking_count = sum(1 for c in checks if c.status == "BREAKING_DRIFT")

    if breaking_count > 0:
        overall_status = "BREAKING_DRIFT"
    elif degraded_count > 0:
        overall_status = "DEGRADED_FALLBACK_ACTIVE"
    else:
        overall_status = "PASS"

    layer_summary: dict[str, dict[str, int]] = {}
    for c in checks:
        bucket = layer_summary.setdefault(
            c.layer, {"total": 0, "pass": 0, "degraded": 0, "breaking": 0}
        )
        bucket["total"] += 1
        if c.status == "PASS":
            bucket["pass"] += 1
        elif c.status == "DEGRADED_FALLBACK_ACTIVE":
            bucket["degraded"] += 1
        else:
            bucket["breaking"] += 1

    return {
        "schema_version": contract.schema_version,
        "verified_build_label": contract.verified_build_label,
        "live_build_label": idx.live_build_label,
        "build_label_changed": idx.live_build_label != contract.verified_build_label,
        "audited_at": datetime.now(timezone.utc).isoformat(),
        "overall_status": overall_status,
        "summary": {
            "total": len(checks),
            "pass": pass_count,
            "degraded": degraded_count,
            "breaking": breaking_count,
        },
        "layer_summary": layer_summary,
        "corpus_stats": corpus.get("stats", {}),
        "checks": [c.to_dict() for c in checks],
    }


def render_markdown_report(report: dict[str, Any]) -> str:
    summary = report["summary"]
    overall = report["overall_status"]
    live_bl = report["live_build_label"]
    verified_bl = report["verified_build_label"]
    stats = report.get("corpus_stats", {})

    lines: list[str] = [
        f"## Gemini Web Contract Audit Report — `{overall}`",
        "",
        "| Metric | Value |",
        "| --- | --- |",
        f"| **Overall Status** | `{overall}` |",
        f"| **Verified Build (`GeminiBridgeSelectors.swift`)** | `{verified_bl}` |",
        f"| **Live Build (`WIZ_global_data[\"cfb2h\"]`)** | `{live_bl}` |",
        f"| **Checks** | **{summary['pass']} PASS**, **{summary['degraded']} DEGRADED**, **{summary['breaking']} BREAKING** (total {summary['total']}) |",
    ]
    if stats:
        lines.append(
            f"| **Live Corpus** | Closure: {stats.get('closure_chunk_count', 0)} chunks, "
            f"Islands: {stats.get('islands_chunk_count', 0)} chunks "
            f"({stats.get('elapsed_seconds', '?')}s) |"
        )
    lines.append("")

    # Per-layer summary table
    lines.append("### Layer Breakdown")
    lines.append("")
    lines.append("| Layer | Total | PASS | DEGRADED | BREAKING |")
    lines.append("| --- | ---: | ---: | ---: | ---: |")
    for layer, counts in report.get("layer_summary", {}).items():
        lines.append(
            f"| `{layer}` | {counts['total']} | {counts['pass']} | {counts['degraded']} | {counts['breaking']} |"
        )
    lines.append("")

    breaking = [c for c in report["checks"] if c["status"] == "BREAKING_DRIFT"]
    degraded = [c for c in report["checks"] if c["status"] == "DEGRADED_FALLBACK_ACTIVE"]

    if breaking:
        lines.append(f"### Breaking Drift Diagnostics ({len(breaking)})")
        lines.append("")
        for c in breaking:
            lines.append(
                f"#### `{c['check_id']}` (`{c['version']}`) — `{c['file']}:{c['line']}`"
            )
            lines.append(f"- **Contract**: `{c['name']}`")
            lines.append(f"- **Expected**: `{c['expected']}`")
            lines.append(f"- **Observed Live**: {c['observed']}")
            lines.append(f"- **How It Mismatched**: {c['diagnosis']}")
            if c.get("discovered_candidates"):
                lines.append(
                    "- **Discovered Live Candidates**: "
                    + f"`{json.dumps(c['discovered_candidates'], ensure_ascii=False)}`"
                )
            lines.append("")

    if degraded:
        lines.append(f"### Degraded Fallback Warnings ({len(degraded)})")
        lines.append("")
        for c in degraded:
            lines.append(
                f"#### `{c['check_id']}` (`{c['version']}`) — `{c['file']}:{c['line']}`"
            )
            lines.append(f"- **Contract**: `{c['name']}`")
            lines.append(f"- **Expected Primary**: `{c['expected']}`")
            lines.append(
                f"- **Active Fallback**: `fallbacks[{c.get('active_fallback_index')}]` -> "
                f"`{c.get('active_fallback_selector')}`"
            )
            lines.append(f"- **Missing Primary Atom(s)**: `{c.get('missing_atoms')}`")
            lines.append(f"- **How It Mismatched**: {c['diagnosis']}")
            if c.get("discovered_candidates"):
                lines.append(
                    "- **Nearby Live Candidates**: "
                    + f"`{json.dumps(c['discovered_candidates'], ensure_ascii=False)}`"
                )
            lines.append("")

    if not breaking and not degraded:
        lines.append(
            f"All **{summary['total']}** `v2.0` + `v2.1` + `v2.2` contracts verified `PASS` "
            f"against live build `{live_bl}`."
        )
        lines.append("")

    return "\n".join(lines)


def emit_github_annotations(report: dict[str, Any]) -> None:
    for c in report["checks"]:
        status = c["status"]
        if status == "PASS":
            continue
        level = "error" if status == "BREAKING_DRIFT" else "warning"
        msg = (
            f"[{c['check_id']}] {c['diagnosis']} "
            f"(expected={c['expected']} | observed={c['observed']})"
        ).replace("\n", " ")
        print(f"::{level} file={c['file']},line={c['line']}::{msg}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Live zero-secret Gemini Web interface & protocol contract auditor."
    )
    parser.add_argument(
        "--selectors-swift",
        type=Path,
        default=Path("LiteGemini/Bridge/GeminiBridgeSelectors.swift"),
    )
    parser.add_argument(
        "--parser-swift",
        type=Path,
        default=Path("LiteGemini/Bridge/GeminiPayloadParser.swift"),
    )
    parser.add_argument(
        "--graphql-swift",
        type=Path,
        default=Path("LiteGemini/Bridge/GeminiGraphQLClient.swift"),
    )
    parser.add_argument("--json-out", type=Path, default=None)
    parser.add_argument("--markdown-out", type=Path, default=None)
    parser.add_argument("--github-annotations", action="store_true")
    parser.add_argument("--fail-on-degraded", action="store_true")
    parser.add_argument("--load-corpus", type=Path, default=None)
    parser.add_argument("--save-corpus", type=Path, default=None)
    parser.add_argument("--app-url", default=DEFAULT_APP_URL)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args(argv)

    repo_root = Path.cwd()
    contract = extract_source_contract(
        selectors_path=args.selectors_swift,
        parser_path=args.parser_swift,
        graphql_path=args.graphql_swift,
        repo_root=repo_root,
    )

    try:
        if args.load_corpus:
            corpus = load_corpus(args.load_corpus)
        else:
            corpus = fetch_live_corpus(app_url=args.app_url, timeout=args.timeout)
            if args.save_corpus:
                save_corpus(corpus, args.save_corpus)
    except UpstreamFetchError as exc:
        print(f"ERROR: Upstream Gemini Web fetch failed: {exc}", file=sys.stderr)
        return 3
    except Exception as exc:
        print(f"ERROR: Failed to load/fetch corpus: {exc}", file=sys.stderr)
        return 3

    report = run_audit(contract, corpus)
    md = render_markdown_report(report)

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(md, encoding="utf-8")

    if args.github_annotations:
        emit_github_annotations(report)

    summary = report["summary"]
    print(
        f"[audit_gemini_contract] status={report['overall_status']} "
        f"live_build={report['live_build_label']} "
        f"pass={summary['pass']} degraded={summary['degraded']} breaking={summary['breaking']} "
        f"total={summary['total']}"
    )

    if report["overall_status"] == "BREAKING_DRIFT":
        return 2
    if report["overall_status"] == "DEGRADED_FALLBACK_ACTIVE" and args.fail_on_degraded:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
