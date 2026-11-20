#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["boto3"]
# ///
"""Download a CDE job run's (or session's) archived Spark logs from S3 and merge
them into time-ordered, readable stdout/stderr files.

Workaround for runs whose logs are too large for the CDE UI/API to serve.

Environment:
    AWS_ENDPOINT_URL_S3     S3 endpoint (AWS_ENDPOINT_URL is also accepted)
    AWS_ACCESS_KEY_ID       access key
    AWS_SECRET_ACCESS_KEY   secret key
    AWS_SESSION_TOKEN       optional
    AWS_REGION              optional, default us-east-1
    AWS_CA_BUNDLE           optional CA bundle for the endpoint
    CDE_LOGS_BUCKET         bucket, if --bucket / --log-location is not given

Usage:
    uv run awc-cde-logs.py <run-id> --bucket <bucket>
    python3 awc-cde-logs.py <session-id> --session --bucket <bucket> --timestamps
    python3 awc-cde-logs.py <run-id> --merge-only          # re-merge what is on disk

Output, under <out>/<id>/:
    raw/...                                   the downloaded objects, S3 layout kept
    manifest.json                             listing used to order the objects
    logs/driver/<container>/{stdout,stderr}.log
    logs/executor_<N>/<container>/{stdout,stderr}.log
"""

import argparse
import concurrent.futures as cf
import contextlib
import datetime
import gzip
import heapq
import json
import os
import re
import shutil
import sys
from typing import NoReturn

RUN_PREFIX = "cde-run-logs/runs/{}/"
SESSION_PREFIX = "cde-session-logs/sessions/{}/"
MANIFEST = "manifest.json"
STREAMS = ("stdout", "stderr")
IOSTREAM_ATTR = "log.iostream"
LOGTAG_ATTR = "logtag"
EXEC_ID_RE = re.compile(r"-exec-(\d+)(?:-|$)")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def die(msg) -> NoReturn:
    log(f"error: {msg}")
    sys.exit(1)


# ---------------------------------------------------------------- selection


def parse_key(rel):
    """Splits a key relative to the workload prefix into (kind, pod, container, hour).

    Returns None for a key outside the driver/executors layout.
    """
    parts = rel.split("/")
    if len(parts) >= 4 and parts[0] == "driver":
        return "driver", "", parts[1], parts[2]
    if len(parts) >= 5 and parts[0] == "executors":
        return "executor", parts[1], parts[2], parts[3]
    return None


def selected(rel, args):
    parsed = parse_key(rel)
    if parsed is None or rel.endswith(".part"):
        return False
    kind, _, _, hour = parsed
    if args.driver_only and kind != "driver":
        return False
    if args.from_hour and hour < args.from_hour:
        return False
    return not (args.to_hour and hour > args.to_hour)


def group_entities(rels):
    """Maps each output directory (relative to logs/) to the keys it merges.

    Executors are named executor_<N> after the pod's -exec-<N> suffix, as the
    CDE UI does; if two pods would share a name, both keep their pod name.
    """
    parsed = [(rel, key) for rel in rels if (key := parse_key(rel)) is not None]
    pod_names = {}
    for _, (kind, pod, _, _) in parsed:
        if kind == "executor" and pod not in pod_names:
            m = EXEC_ID_RE.search(pod)
            pod_names[pod] = f"executor_{m.group(1)}" if m else pod
    claimed = {}
    for pod, name in pod_names.items():
        claimed.setdefault(name, []).append(pod)
    for name, pods in claimed.items():
        if len(pods) > 1:
            for pod in pods:
                pod_names[pod] = pod

    groups = {}
    for rel, (kind, pod, container, _) in parsed:
        entity = f"driver/{container}" if kind == "driver" else f"{pod_names[pod]}/{container}"
        groups.setdefault(entity, []).append(rel)
    return groups


# ---------------------------------------------------------------- download


def s3_client(args):
    try:
        import boto3  # pyright: ignore[reportMissingImports]
        from botocore.config import Config  # pyright: ignore[reportMissingImports]
    except ImportError:
        die("boto3 is not installed: pip install boto3, or run with `uv run awc-cde-logs.py`")

    endpoint = os.environ.get("AWS_ENDPOINT_URL_S3") or os.environ.get("AWS_ENDPOINT_URL")
    if not endpoint:
        die("set AWS_ENDPOINT_URL_S3 to the S3 endpoint")
    for var in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"):
        if not os.environ.get(var):
            die(f"set {var}")

    cfg = {
        "s3": {"addressing_style": args.addressing_style},
        "retries": {"max_attempts": 10, "mode": "adaptive"},
        "max_pool_connections": args.parallel,
    }
    # Newer botocore checksums every request by default, which S3-compatible
    # gateways often reject; older botocore does not know these options.
    try:
        config = Config(
            request_checksum_calculation="when_required",
            response_checksum_validation="when_required",
            **cfg,
        )
    except TypeError:
        config = Config(**cfg)
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name=region,
        config=config,
        verify=False if args.no_verify_ssl else None,
    )


def download(args, bucket, prefix, base):
    client = s3_client(args)
    raw = os.path.join(base, "raw")

    objects, ignored = [], 0
    for page in client.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        for o in page.get("Contents", []):
            rel = o["Key"][len(prefix) :]
            if not selected(rel, args):
                ignored += parse_key(rel) is None
                continue
            objects.append(
                {
                    "key": rel,
                    "size": o["Size"],
                    "etag": o.get("ETag", "").strip('"'),
                    "last_modified": o["LastModified"].isoformat(),
                }
            )
    if ignored:
        log(f"ignoring {ignored} object(s) outside the driver/executors layout")
    if not objects:
        die(f"no log objects found under s3://{bucket}/{prefix}")

    total = sum(o["size"] for o in objects)
    log(f"found {len(objects)} object(s), {human(total)}, under s3://{bucket}/{prefix}")

    # Written before downloading so an interrupted run can resume and still merge.
    manifest = load_manifest(base)
    manifest.update({o["key"]: o for o in objects})
    os.makedirs(base, exist_ok=True)
    with open(os.path.join(base, MANIFEST), "w", encoding="utf-8") as f:
        json.dump(
            {
                "bucket": bucket,
                "prefix": prefix,
                "objects": sorted(manifest.values(), key=lambda o: o["key"]),
            },
            f,
            indent=1,
        )

    def fetch(o):
        dest = os.path.join(raw, o["key"])
        if os.path.exists(dest) and os.path.getsize(dest) == o["size"]:
            return False
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        part = dest + ".part"
        client.download_file(bucket, prefix + o["key"], part)
        os.replace(part, dest)
        return True

    done = fetched = 0
    failed = []
    with cf.ThreadPoolExecutor(args.parallel) as pool:
        futures = {pool.submit(fetch, o): o for o in objects}
        for fut in cf.as_completed(futures):
            done += 1
            try:
                fetched += fut.result()
            except Exception as e:  # noqa: BLE001 - report every failed key, then stop
                failed.append(futures[fut]["key"])
                log(f"download failed: {futures[fut]['key']}: {e}")
            if done % 500 == 0 or done == len(objects):
                log(f"  downloaded {done}/{len(objects)}")
    log(f"downloaded {fetched}, already present {len(objects) - fetched - len(failed)}")
    if failed:
        die(f"{len(failed)} object(s) failed to download; re-run to retry them")


def load_manifest(base):
    try:
        with open(os.path.join(base, MANIFEST), encoding="utf-8") as f:
            return {o["key"]: o for o in json.load(f)["objects"]}
    except FileNotFoundError:
        return {}


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024:
            return f"{n:.0f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


# ---------------------------------------------------------------- normalize
#
# Each object is converted once into one small, sorted "run" file per stream,
# one record per line: ts \t src \t seq \t logtag \t json-escaped body.
# The merge then only ever reads these line by line.


def first_attr(attrs, key):
    for a in attrs or ():
        if a.get("key") == key:
            return (a.get("value") or {}).get("stringValue")
    return None


def body_text(body):
    if not body:
        return ""
    if "stringValue" in body:
        return body["stringValue"]
    return json.dumps(body, separators=(",", ":"))


def to_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


def iter_docs(path):
    """Yields every JSON document in an object: one per line, or concatenated."""
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as f:
        text = f.read()
    dec = json.JSONDecoder()
    i, n = 0, len(text)
    while True:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            return
        doc, i = dec.raw_decode(text, i)
        yield doc


def normalize(path, src, out_prefix):
    """Converts one object into sorted per-stream run files.

    Returns ({stream: run_path}, warning or None).
    """
    records, prev, warning = [], 0, None
    try:
        for doc in iter_docs(path):
            for rl in doc.get("resourceLogs") or ():
                r_stream = first_attr((rl.get("resource") or {}).get("attributes"), IOSTREAM_ATTR)
                for sl in rl.get("scopeLogs") or ():
                    s_stream = first_attr((sl.get("scope") or {}).get("attributes"), IOSTREAM_ATTR)
                    for rec in sl.get("logRecords") or ():
                        # A record without a time keeps its predecessor's, so it
                        # stays where it was written.
                        ts = (
                            to_int(rec.get("timeUnixNano"))
                            or to_int(rec.get("observedTimeUnixNano"))
                            or prev
                        )
                        prev = ts
                        attrs = rec.get("attributes")
                        stream = first_attr(attrs, IOSTREAM_ATTR) or s_stream or r_stream
                        records.append(
                            (
                                ts,
                                len(records),
                                stream,
                                first_attr(attrs, LOGTAG_ATTR) or "",
                                body_text(rec.get("body")),
                            )
                        )
    except (ValueError, OSError, AttributeError) as e:
        warning = f"{path}: unreadable after {len(records)} record(s), keeping those: {e}"

    records.sort(key=lambda r: (r[0], r[1]))
    files, outs = {}, {}
    with contextlib.ExitStack() as stack:
        for ts, seq, stream, tag, body in records:
            # Untagged records go to both streams, as in the CDE UI, rather than
            # being dropped.
            targets = (stream,) if stream in STREAMS else STREAMS
            line = f"{ts}\t{src}\t{seq}\t{tag}\t{json.dumps(body, ensure_ascii=False)}\n"
            for s in targets:
                if s not in outs:
                    files[s] = f"{out_prefix}.{s}"
                    outs[s] = stack.enter_context(open(files[s], "w", encoding="utf-8"))
                outs[s].write(line)
    return files, warning


# ---------------------------------------------------------------- merge


def read_run(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            ts, src, seq, _ = line.split("\t", 3)
            # (src, seq) is unique within a stream, so the line is never compared.
            yield int(ts), int(src), int(seq), line


def merged_runs(paths, fan_in, work_prefix):
    """K-way merges run files, in several passes when there are more than fan_in."""
    level = 0
    while len(paths) > fan_in:
        next_paths = []
        for i in range(0, len(paths), fan_in):
            batch = paths[i : i + fan_in]
            if len(batch) == 1:
                next_paths.append(batch[0])
                continue
            out = f"{work_prefix}.pass{level}.{i}"
            with open(out, "w", encoding="utf-8") as w:
                w.writelines(line for *_, line in heapq.merge(*(read_run(p) for p in batch)))
            for p in batch:
                os.remove(p)
            next_paths.append(out)
        paths = next_paths
        level += 1
    return heapq.merge(*(read_run(p) for p in paths))


def fmt_ts(ts):
    if not ts:
        return "-"
    sec, nanos = divmod(ts, 10**9)
    t = datetime.datetime.fromtimestamp(sec, datetime.timezone.utc)  # noqa: UP017 - runs on 3.9
    return f"{t:%Y-%m-%dT%H:%M:%S}.{nanos:09d}Z"


def merge_stream(paths, out_path, work_prefix, fan_in, join_partial, timestamps, compress):
    """Merges one container's stream into out_path. Returns the lines written."""
    opener = gzip.open if compress else open
    written = 0
    pending_ts, pending = None, []
    with opener(out_path, "wt", encoding="utf-8") as w:

        def emit(ts, text):
            nonlocal written
            w.write(f"{fmt_ts(ts)} {text}\n" if timestamps else f"{text}\n")
            written += 1

        for ts, _, _, line in merged_runs(paths, fan_in, work_prefix):
            _, _, _, tag, body = line.rstrip("\n").split("\t", 4)
            text = json.loads(body)
            # The container runtime splits a long line into P (partial) chunks
            # ending in an F chunk; joining restores the original line.
            if join_partial and tag == "P":
                if pending_ts is None:
                    pending_ts = ts
                pending.append(text)
                continue
            if pending:
                pending.append(text)
                text, ts = "".join(pending), pending_ts
                pending_ts, pending = None, []
            emit(ts, text)
        if pending:
            emit(pending_ts, "".join(pending))
    for p in paths:
        if os.path.exists(p):
            os.remove(p)
    return written


def default_fan_in():
    try:
        import resource

        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        want = 4096 if hard == resource.RLIM_INFINITY else min(hard, 4096)
        if soft < want:
            resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
            soft = want
        return max(16, min(512, soft - 64))
    except (ImportError, ValueError, OSError):
        return 200


def init_worker():
    default_fan_in()


def merge(args, base):
    raw = os.path.join(base, "raw")
    if not os.path.isdir(raw):
        die(f"nothing to merge: {raw} does not exist")
    manifest = load_manifest(base)

    rels = []
    for root, _, names in os.walk(raw):
        for name in names:
            rel = os.path.relpath(os.path.join(root, name), raw).replace(os.sep, "/")
            if selected(rel, args):
                rels.append(rel)
    if not rels:
        die(f"no log objects under {raw}")
    missing = [r for r in rels if r not in manifest]
    if missing:
        log(
            f"warning: {len(missing)} object(s) are not in {MANIFEST}; their timestamp ties fall back to key order"
        )

    groups = group_entities(rels)
    logs_dir = os.path.join(base, "logs")
    work = os.path.join(base, ".work")
    shutil.rmtree(work, ignore_errors=True)
    shutil.rmtree(logs_dir, ignore_errors=True)
    fan_in = args.fan_in or default_fan_in()
    ext = ".log.gz" if args.gzip else ".log"

    log(
        f"merging {len(rels)} object(s) into {len(groups)} container log(s) with {args.workers} worker(s)"
    )
    runs = {}  # (entity, stream) -> [run paths in src order]
    with cf.ProcessPoolExecutor(args.workers, initializer=init_worker) as pool:
        futures = {}
        for e_idx, (entity, keys) in enumerate(sorted(groups.items())):
            edir = os.path.join(work, str(e_idx))
            os.makedirs(edir)
            # The object order is only the timestamp tiebreak: LastModified, then key.
            keys.sort(key=lambda k: (manifest.get(k, {}).get("last_modified", ""), k))
            for src, key in enumerate(keys):
                fut = pool.submit(
                    normalize, os.path.join(raw, key), src, os.path.join(edir, str(src))
                )
                futures[fut] = (entity, src)
        collected = {}
        for done, fut in enumerate(cf.as_completed(futures), 1):
            entity, src = futures[fut]
            files, warning = fut.result()
            if warning:
                log(f"warning: {warning}")
            for stream, path in files.items():
                collected.setdefault((entity, stream), []).append((src, path))
            if done % 1000 == 0 or done == len(futures):
                log(f"  parsed {done}/{len(futures)}")
        for k, v in collected.items():
            runs[k] = [p for _, p in sorted(v)]

        merges = {}
        for e_idx, entity in enumerate(sorted(groups)):
            out_dir = os.path.join(logs_dir, entity)
            os.makedirs(out_dir, exist_ok=True)
            for stream in STREAMS:
                paths = runs.get((entity, stream), [])
                out = os.path.join(out_dir, stream + ext)
                fut = pool.submit(
                    merge_stream,
                    paths,
                    out,
                    os.path.join(work, str(e_idx), stream),
                    fan_in,
                    args.join_partial,
                    args.timestamps,
                    args.gzip,
                )
                merges[fut] = (entity, stream, out)
        results = []
        for fut in cf.as_completed(merges):
            results.append((*merges[fut], fut.result()))

    shutil.rmtree(work, ignore_errors=True)
    for entity, stream, out, n in sorted(results):
        log(f"  {n:>10} lines  {os.path.relpath(out)}")
    if args.clean_raw:
        shutil.rmtree(raw)
        log(f"removed {raw}")


# ---------------------------------------------------------------- main


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Download a CDE run's or session's archived Spark logs from S3 and merge them "
        "into time-ordered stdout/stderr files per container.",
        epilog="S3 access comes from AWS_ENDPOINT_URL_S3, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY "
        "(and optionally AWS_SESSION_TOKEN, AWS_REGION, AWS_CA_BUNDLE, CDE_LOGS_BUCKET).",
    )
    p.add_argument("id", help="job run ID (or session ID with --session)")
    p.add_argument("--session", action="store_true", help="the ID is a session, not a job run")
    p.add_argument(
        "--bucket",
        default=os.environ.get("CDE_LOGS_BUCKET"),
        help="logs bucket (default: $CDE_LOGS_BUCKET)",
    )
    p.add_argument(
        "--log-location",
        help="the run's s3://bucket/prefix log location; overrides --bucket and the default prefix",
    )
    p.add_argument("--out", default="cde-logs", help="output root directory (default: ./cde-logs)")

    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--download-only", action="store_true", help="download, do not merge")
    mode.add_argument(
        "--merge-only", action="store_true", help="merge what is already in <out>/<id>/raw"
    )

    p.add_argument("--driver-only", action="store_true", help="only the driver's logs")
    p.add_argument(
        "--from-hour",
        metavar="YYYYMMDDHH",
        help="skip hour folders before this one (flush hour, so approximate at the edge)",
    )
    p.add_argument("--to-hour", metavar="YYYYMMDDHH", help="skip hour folders after this one")

    p.add_argument(
        "--join-partial",
        action="store_true",
        help="rejoin lines the container runtime split into partial (logtag P) chunks",
    )
    p.add_argument(
        "--timestamps", action="store_true", help="prefix each line with its UTC record time"
    )
    p.add_argument("--gzip", action="store_true", help="write .log.gz files")
    p.add_argument(
        "--clean-raw", action="store_true", help="delete the downloaded objects after merging"
    )

    p.add_argument("--parallel", type=int, default=32, help="concurrent downloads (default: 32)")
    p.add_argument(
        "--workers",
        type=int,
        default=os.cpu_count() or 4,
        help="parse/merge processes (default: CPU count)",
    )
    p.add_argument(
        "--fan-in", type=int, help="max files merged at once (default: from the open-file limit)"
    )
    p.add_argument(
        "--addressing-style",
        choices=("path", "virtual", "auto"),
        default="path",
        help="S3 addressing style (default: path)",
    )
    p.add_argument(
        "--no-verify-ssl", action="store_true", help="do not verify the endpoint's TLS certificate"
    )
    args = p.parse_args(argv)

    if "/" in args.id or not args.id.strip():
        p.error("id must be a bare run or session ID")
    for flag in ("from_hour", "to_hour"):
        v = getattr(args, flag)
        if v and not re.fullmatch(r"\d{10}", v):
            p.error(f"--{flag.replace('_', '-')} must be YYYYMMDDHH")
    if args.fan_in is not None and args.fan_in < 2:
        p.error("--fan-in must be at least 2")
    return args


def resolve_location(args):
    prefix = (SESSION_PREFIX if args.session else RUN_PREFIX).format(args.id)
    bucket = args.bucket
    if args.log_location:
        m = re.fullmatch(r"s3a?://([^/]+)/(.+)", args.log_location.strip())
        if not m:
            die("--log-location must look like s3://bucket/prefix")
        bucket, prefix = m.group(1), m.group(2).strip("/") + "/"
    return bucket, prefix


def main(argv=None):
    args = parse_args(argv)
    base = os.path.join(args.out, args.id)
    if not args.merge_only:
        bucket, prefix = resolve_location(args)
        if not bucket:
            die("set --bucket, --log-location or CDE_LOGS_BUCKET")
        download(args, bucket, prefix, base)
    if not args.download_only:
        merge(args, base)
        log(f"done: {os.path.join(base, 'logs')}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)