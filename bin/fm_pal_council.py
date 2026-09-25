#!/usr/bin/env python3
"""Mechanics of the pal-council skill.

bin/fm-pal-council.sh is the entry point and the single owner of the command
reference, exit codes, and environment knobs; this module implements them with
the Python standard library only. The moderator's procedure lives in
.agents/skills/pal-council/SKILL.md, and the texts a voice or the researcher
reads live in that skill's references/, which this module inlines rather than
restating.
"""

import argparse
import calendar
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CODE_ROOT = SCRIPT_DIR.parent
REFS = CODE_ROOT / ".agents" / "skills" / "pal-council" / "references"
DEFAULT_CONFIG = CODE_ROOT / "docs" / "examples" / "pal-council.json"
ENTRY = SCRIPT_DIR / "fm-pal-council.sh"


def _home():
    root = os.environ.get("FM_ROOT_OVERRIDE") or str(CODE_ROOT)
    return Path(os.environ.get("FM_HOME") or root).resolve()


FM_HOME = _home()
DATA = Path(os.environ.get("FM_DATA_OVERRIDE") or FM_HOME / "data").resolve()
STATE = Path(os.environ.get("FM_STATE_OVERRIDE") or FM_HOME / "state").resolve()
CONFIG = Path(os.environ.get("FM_CONFIG_OVERRIDE") or FM_HOME / "config").resolve()

VERIFIED_HARNESSES = ("claude", "codex", "opencode", "pi", "pi-signed", "grok", "kimi", "cursor", "muse", "agy")
EFFORTS = ("low", "medium", "high", "xhigh", "max")
RESEARCHER = "researcher"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,35}$")
SEAT_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,15}$")
STATUS_RE = re.compile(r"^\[STATUS\]\s+(CONTINUE|DONE)\s+new=(\d+)\s+changed=(\d+)\s*$", re.I)
DOSSIER_RE = re.compile(r"^\[DOSSIER\]\s+complete\b", re.I)
RESEARCH_RE = re.compile(r"^\s*(?:[-*]\s*)?\[RESEARCH\]\s*(.+?)\s*$", re.M)
DOD_MARK = "<!-- definition of done -->"
NONE_WORDS = ("none", "nessuna", "nessuno", "-", "n/a", "no")
EXIT_USAGE, EXIT_REFUSED, EXIT_RUNTIME, EXIT_CAPTAIN = 2, 3, 4, 5

LANGUAGE_NAMES = {"it": "Italian (italiano)", "en": "English", "sl": "Slovenian (slovenščina)",
                  "de": "German (Deutsch)", "fr": "French (français)", "es": "Spanish (español)"}

LABELS = {
    "it": {"verbale": "Verbale del consiglio", "topic": "Tema", "created": "Convocato", "tier": "Livello",
           "language": "Lingua", "budget": "Budget", "seat": "Seggio", "model": "Modello", "provider": "Fornitore",
           "tool": "Strumento", "effort": "Effort", "round": "Turno", "summary": "Riassunto del moderatore",
           "dossier": "Dossier del ricercatore", "missing": "INTERVENTO MANCANTE", "timeout": "tempo scaduto",
           "closed_early": "turno chiuso dal moderatore prima della consegna", "incomplete": "file incompleto conservato in",
           "captain_msg": "Messaggio del capitano", "to_all": "a tutte le voci", "to": "a", "closing": "Chiusura",
           "reason": "Motivo", "spent": "Costo stimato", "rounds": "Turni svolti", "dropped": "Voce ritirata",
           "lost": "Voce persa: invio del turno fallito", "research_failed": "Ricerca non consegnata",
           "research_unavailable": "Ricercatore non disponibile: richieste di ricerca non evase",
           "cancelled": "Consiglio annullato", "researcher": "Ricercatore", "excluded": "escluso",
           "packet_title": "Pacchetto del turno", "others": "Nuovi interventi delle altre voci",
           "no_dossier": "Nessuna ricerca in questo turno", "task": "Compito di questo turno"},
    "en": {"verbale": "Council record", "topic": "Topic", "created": "Convened", "tier": "Tier",
           "language": "Language", "budget": "Budget", "seat": "Seat", "model": "Model", "provider": "Provider",
           "tool": "Tool", "effort": "Effort", "round": "Round", "summary": "Moderator summary",
           "dossier": "Researcher dossier", "missing": "MISSING TURN", "timeout": "time limit reached",
           "closed_early": "round closed by the moderator before delivery", "incomplete": "incomplete file kept at",
           "captain_msg": "Message from the captain", "to_all": "to every voice", "to": "to", "closing": "Close",
           "reason": "Reason", "spent": "Estimated cost", "rounds": "Rounds run", "dropped": "Voice withdrawn",
           "lost": "Voice lost: the round could not be delivered", "research_failed": "Research not delivered",
           "research_unavailable": "Researcher unavailable: research requests not served",
           "cancelled": "Council cancelled", "researcher": "Researcher", "excluded": "excluded",
           "packet_title": "Round packet", "others": "New turns from the other voices",
           "no_dossier": "No research this round", "task": "Your task this round"},
}

PLACEHOLDER_LABELS = {
    "it": {"PERSON": "PERSONA", "ORG": "ENTE", "ADDRESS": "INDIRIZZO", "PLACE": "LUOGO", "ID": "NUMERO",
           "AMOUNT": "IMPORTO", "CASE": "PRATICA", "DATE": "DATA", "CONTACT": "CONTATTO", "OTHER": "SEGNO"},
    "en": {"PERSON": "PERSON", "ORG": "ORG", "ADDRESS": "ADDRESS", "PLACE": "PLACE", "ID": "NUMBER",
           "AMOUNT": "AMOUNT", "CASE": "CASE", "DATE": "DATE", "CONTACT": "CONTACT", "OTHER": "MARK"},
}
ENTITY_TYPES = tuple(PLACEHOLDER_LABELS["en"])

# A hit in anything bound for ANY worker refuses the send: credentials never leave.
SECRET_PATTERNS = {
    "private key": r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    "AWS access key": r"\bAKIA[0-9A-Z]{16}\b",
    "GitHub token": r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})\b",
    "API key": r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{24,}",
    "Slack token": r"\bxox[abprs]-[A-Za-z0-9-]{10,}",
    "Google API key": r"\bAIza[0-9A-Za-z_-]{35}\b",
    "credential assignment": r"(?i)\b(?:password|passwd|secret|api[_-]?key|access[_-]?token)\s*[:=]\s*[\"'][^\"'\s]{8,}[\"']",
}
# Extra net beside the literal recheck for workers outside Anthropic.
STRUCTURAL_PATTERNS = {
    "e-mail address": r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
    "IBAN": r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}\b",
    "Italian tax code": r"\b[A-Z]{6}\d{2}[A-EHLMPR-T]\d{2}[A-Z]\d{3}[A-Z]\b",
}

HAIKU_PROMPT = """You are a pseudonymisation tool. Read the TEXT below and list every piece of identifying information about private people and private organisations in it.

Identify:
- PERSON: names of natural persons, including every inflected form, initials, nicknames, and a surname used alone.
- ORG: names of private companies, customers, suppliers, associations, clubs, foundations, and named private premises.
- ADDRESS: street and postal addresses.
- PLACE: villages, towns or localities that locate a private person, customer, or premises.
- ID: tax, VAT, registry, customer, contract, account, IBAN, card, and passport numbers, vehicle plates, land-registry parcels.
- CONTACT: telephone numbers, e-mail addresses, and personal or customer websites.
- AMOUNT: sums of money with their figures that belong to a private party (e.g. "1.500,00 EUR").
- CASE: case, file, order, or reference numbers of a proceeding or a private file.
- DATE: dates that identify a person or a private event (birth dates, signing dates).
- OTHER: anything else that would let a reader identify a private person or organisation.

Do NOT list: laws and their articles; courts, ministries, and other public authorities; programming languages, public software, libraries, products, services, standards, and the companies that publish them when named as technology (for example cloud and AI vendors); generic role words; placeholders already in square brackets such as [PERSON_1]; anything inside a file-system path or a URL; code identifiers; empty fill-in fields; durations and deadlines.

Copy each form EXACTLY as it appears in the TEXT, character for character, and copy only the identifying value, not the label in front of it. List every distinct form.
One group is ONE real-world entity or ONE value: its forms are different spellings or inflections of the same thing.
{known}
Reply with JSON only, no prose and no code fence, in this shape:
{{"entities": [{{"type": "PERSON", "forms": ["Jane Roe", "Roe"]}}]}}
If there is nothing to list, reply {{"entities": []}}.

TEXT:
<<<
{text}
>>>
"""


class Stop(Exception):
    """A plain-language failure that ends the command with a non-zero exit."""

    def __init__(self, message, code=EXIT_USAGE):
        super().__init__(message)
        self.code = code


# --- small helpers -------------------------------------------------------------

def now():
    fixed = os.environ.get("FM_PAL_NOW")
    return float(fixed) if fixed else time.time()


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def parse_iso(text):
    return float(calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%SZ")))


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def eur(value):
    return f"{value:.2f}"


def read(path):
    return Path(path).read_text(encoding="utf-8")


def write_atomic(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def append(path, text):
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(text)


def last_line(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def labels(lang):
    return LABELS.get(lang, LABELS["en"])


# --- configuration -------------------------------------------------------------

CONFIG_KEYS = ("rounds", "round_timeout_minutes", "purge_after_hours", "brief_max_chars", "budget", "estimate",
               "usd_to_eur", "prices", "providers", "catalog", "tiers", "researcher", "pseudonymiser")


def load_config():
    local = CONFIG / "pal-council.json"
    path = local if local.is_file() else DEFAULT_CONFIG
    try:
        cfg = json.loads(read(path))
    except (OSError, json.JSONDecodeError) as exc:
        raise Stop(f"{path} is not readable JSON: {exc}")
    missing = [k for k in CONFIG_KEYS if k not in cfg]
    if missing:
        raise Stop(f"{path} lacks {', '.join(missing)}; start from docs/examples/pal-council.json")
    patterns = [e.get("match", "") for e in cfg["prices"]]
    for rules in cfg["catalog"].values():
        patterns += [p for key in ("top", "economy", "exclude") for p in rules.get(key, [])]
    for pattern in patterns:
        try:
            re.compile(pattern)
        except re.error as exc:
            raise Stop(f"{path}: {pattern!r} is not a valid regular expression: {exc}")
    cfg["_source"] = str(path)
    return cfg


def price_for(cfg, harness, model):
    for entry in cfg["prices"]:
        if entry.get("harness") and entry["harness"] != harness:
            continue
        if re.search(entry.get("match", ""), model or ""):
            return entry
    raise Stop(f"no price in {cfg['_source']} matches {harness}/{model}; add one (a fallback entry with an empty match covers every model)")


# --- council records -------------------------------------------------------------

def council_dir(cid):
    if not ID_RE.match(cid or ""):
        raise Stop(f"invalid council id {cid!r}")
    return DATA / f"pal-{cid}"


def load_council(cid):
    path = council_dir(cid) / "consiglio.json"
    if not path.is_file():
        raise Stop(f"no council {cid}: {path} does not exist")
    return json.loads(read(path))


def save_council(council):
    write_atomic(council_dir(council["id"]) / "consiglio.json", json.dumps(council, indent=2, ensure_ascii=False) + "\n")


def load_costs(cdir):
    path = cdir / "costi.json"
    if path.is_file():
        return json.loads(read(path))
    return {"budget_eur": 0.0, "moderator_eur": 0.0, "pseudonymiser_eur": 0.0, "seats": {}, "spent_eur": 0.0}


def save_costs(cdir, costs):
    costs["spent_eur"] = round(costs.get("moderator_eur", 0.0) + costs.get("pseudonymiser_eur", 0.0)
                               + sum(sum(s.get("rounds", {}).values()) for s in costs.get("seats", {}).values()), 4)
    write_atomic(cdir / "costi.json", json.dumps(costs, indent=2, ensure_ascii=False) + "\n")
    return costs["spent_eur"]


def voices(council, statuses=("active",)):
    return [s for s in council["seats"] if s["status"] in statuses]


def seat_by_name(council, name):
    if name == RESEARCHER and council.get("researcher"):
        return council["researcher"]
    for seat in council["seats"]:
        if seat["seat"] == name:
            return seat
    raise Stop(f"council {council['id']} has no seat {name!r}")


def current_round(council):
    return council["rounds"][-1] if council["rounds"] else None


def require_state(council, *states):
    if council["state"] not in states:
        raise Stop(f"council {council['id']} is {council['state']}; this step needs {' or '.join(states)}")


# --- model catalogs and tiers -------------------------------------------------------

CATALOG_COMMANDS = {
    "claude": ["claude", "--help"],
    "codex": ["codex", "debug", "models"],
    "agy": ["agy", "models"],
    "grok": ["grok", "models"],
    "cursor": ["cursor-agent", "--list-models"],
}


def catalog_raw(harness):
    fixture_dir = os.environ.get("FM_PAL_CATALOG_DIR")
    if fixture_dir:
        path = Path(fixture_dir) / harness
        return read(path) if path.is_file() else None
    cmd = CATALOG_COMMANDS.get(harness)
    if not cmd or not shutil.which(cmd[0]):
        return None
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout if out.returncode == 0 else None


def parse_catalog(harness, raw):
    """Return [(model_id, searchable_text)] in the catalog's own order."""
    entries = []
    if harness == "claude":
        # claude --help documents aliases for the latest model of each family in its --model paragraph.
        block, inside = [], False
        for line in raw.splitlines():
            if re.match(r"^\s*--model\b", line):
                inside = True
            elif inside and re.match(r"^\s*-", line):
                break
            if inside:
                block.append(line)
        for alias in re.findall(r"'([a-z][a-z-]*)'", " ".join(block)):
            if alias not in [e[0] for e in entries]:
                entries.append((alias, alias))
    elif harness == "codex":
        try:
            models = json.loads(raw).get("models") or []
        except json.JSONDecodeError:
            return []
        listed = [m for m in models if m.get("visibility") == "list" and m.get("slug")]
        listed.sort(key=lambda m: m.get("priority", 1 << 30))
        entries = [(m["slug"], " ".join(str(m.get(k, "")) for k in ("slug", "display_name", "description"))) for m in listed]
    else:
        for line in raw.splitlines():
            parts = re.split(r"\t|\s{2,}", line.strip())
            if parts and re.match(r"^[A-Za-z0-9][A-Za-z0-9._:/-]*$", parts[0]) and not line.lower().startswith(("fetching", "available")):
                entries.append((parts[0], line.strip()))
    return entries


def pick_model(cfg, harness, pick, entries):
    rules = (cfg["catalog"].get(harness) or {})
    exclude = [re.compile(p) for p in rules.get("exclude", [])]
    usable = [e for e in entries if not any(p.search(e[0]) or p.search(e[1]) for p in exclude)]
    for pattern in rules.get(pick, []):
        rx = re.compile(pattern)
        for model_id, text in usable:
            if rx.search(model_id) or rx.search(text):
                return model_id
    return None


def resolve_rule(cfg, rule):
    harness = rule["harness"]
    raw = catalog_raw(harness)
    entries = parse_catalog(harness, raw) if raw else []
    if not entries:
        return None, f"{harness}: model catalog unavailable"
    model = pick_model(cfg, harness, rule.get("pick", "top"), entries)
    if not model:
        return None, f"{harness}: no catalog model matches the {rule.get('pick', 'top')} rule"
    return model, None


def provider_of(cfg, harness, given=None):
    provider = given or cfg["providers"].get(harness)
    if not provider:
        raise Stop(f"no provider known for harness {harness}; give the participant a 'provider'")
    return provider


def make_seat(cfg, council_id, name, harness, model, effort, provider, economy=False, persona=None, instructions=""):
    if harness not in VERIFIED_HARNESSES:
        raise Stop(f"harness {harness!r} is not a verified adapter ({', '.join(VERIFIED_HARNESSES)})")
    if effort and effort not in EFFORTS:
        raise Stop(f"effort {effort!r} is not one of {', '.join(EFFORTS)}")
    price = price_for(cfg, harness, model)
    return {"seat": name, "harness": harness, "model": model, "effort": effort or "", "provider": provider,
            "trusted": harness == "claude", "economy": economy, "opus_class": bool(price.get("opus_class")),
            "persona": f"persone/{name}.md", "instructions": instructions, "task_id": f"pal-{council_id}-{name}",
            "status": "planned", "spawned": False, "note": "", "_persona_text": persona}


def unique_name(existing, base):
    name, n = base, 2
    while name in existing:
        name = f"{base}-{n}"
        n += 1
    return name


def seats_from_tier(cfg, cid, tier):
    if tier not in cfg["tiers"]:
        raise Stop(f"unknown tier {tier!r}; configured tiers: {', '.join(cfg['tiers'])}")
    seats, notes = [], []
    for rule in cfg["tiers"][tier]["seats"]:
        model, problem = resolve_rule(cfg, rule)
        if problem:
            if rule.get("optional"):
                notes.append(f"{problem}; optional seat skipped")
                continue
            raise Stop(f"{problem}; fix the tool or pass --participants", EXIT_RUNTIME)
        economy = rule.get("pick") == "economy"
        name = unique_name({s["seat"] for s in seats}, f"{rule['harness']}-eco" if economy else rule["harness"])
        seats.append(make_seat(cfg, cid, name, rule["harness"], model, rule.get("effort"),
                               provider_of(cfg, rule["harness"]), economy=economy))
    return seats, notes


def seats_from_participants(cfg, cid, path):
    try:
        data = json.loads(read(path))
    except (OSError, json.JSONDecodeError) as exc:
        raise Stop(f"--participants {path}: not readable JSON: {exc}")
    if isinstance(data, dict):
        data = data.get("participants")
    if not isinstance(data, list) or not data:
        raise Stop("--participants must be a JSON array of {harness, model, persona, instructions}")
    seats = []
    for item in data:
        if not isinstance(item, dict) or not item.get("harness") or not item.get("model"):
            raise Stop(f"participant {item!r} needs at least harness and model")
        name = item.get("seat") or item["harness"]
        if not SEAT_RE.match(name):
            raise Stop(f"seat name {name!r} must be lowercase letters, digits, and dashes")
        name = unique_name({s["seat"] for s in seats} | {RESEARCHER}, name)
        seats.append(make_seat(cfg, cid, name, item["harness"], item["model"], item.get("effort", "high"),
                               provider_of(cfg, item["harness"], item.get("provider")),
                               persona=item.get("persona"), instructions=item.get("instructions", "")))
    return seats


# --- quota ------------------------------------------------------------------------

def quota_remaining(harnesses):
    """Return ({quota-provider: percent remaining}, note). Missing evidence is uncertainty, never exclusion."""
    fixture = os.environ.get("FM_PAL_QUOTA_JSON")
    if fixture:
        text = read(fixture)
    else:
        if not shutil.which("quota-axi"):
            return {}, "quota-axi is not installed; quota unchecked"
        try:
            out = subprocess.run(["quota-axi", "--provider", ",".join(sorted(set(harnesses))), "--json",
                                  "--no-credential-refresh"], capture_output=True, text=True, timeout=180)
        except (OSError, subprocess.TimeoutExpired):
            return {}, "quota-axi did not answer; quota unchecked"
        if out.returncode != 0:
            return {}, f"quota-axi failed ({out.returncode}); quota unchecked"
        text = out.stdout
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return {}, "quota-axi output is not JSON; quota unchecked"
    result = {}
    for provider in data.get("providers") or []:
        for scope in ((provider.get("quotaSemantics") or {}).get("effectiveAvailability") or []):
            if scope.get("scope") == "all_models" and scope.get("status") == "known":
                value = scope.get("effectivePercentRemaining")
                if isinstance(value, (int, float)):
                    result[provider.get("provider")] = value
    return result, None


def apply_quota(council):
    members = voices(council, ("planned",)) + ([council["researcher"]] if council.get("researcher") else [])
    remaining, note = quota_remaining([s["harness"] for s in members])
    notes = [note] if note else []
    for seat in members:
        value = remaining.get(seat["harness"])
        if value is None:
            notes.append(f"{seat['seat']}: no quota evidence for {seat['harness']}; kept, quota uncertain")
        elif value <= 0:
            seat["status"] = "excluded"
            seat["note"] = f"no quota left on {seat['harness']} ({value}% remaining)"
            notes.append(f"{seat['seat']}: EXCLUDED - {seat['note']}")
    return notes


def check_diversity(council):
    active = voices(council, ("planned", "active"))
    if not active:
        raise Stop("no voice is left to sit on the council", EXIT_CAPTAIN)
    providers = {s["provider"] for s in active}
    quota_narrowed = len({s["provider"] for s in voices(council, ("planned", "active", "excluded"))}) > 1
    if (len(active) >= 2 or quota_narrowed) and len(providers) == 1 and not council.get("single_provider_ok"):
        raise Stop(f"every remaining voice is from one provider ({providers.pop()}); a single-provider council "
                   "gives weaker reviews - ask the captain, and pass --single-provider-ok only on their word", EXIT_CAPTAIN)


# --- pseudonymisation -----------------------------------------------------------------

ENTITY_ROW = re.compile(r"^\|\s*\[([^\]]+)\]\s*\|\s*([A-Z]+)\s*\|\s*(.*?)\s*\|\s*$")


def load_entities(cdir):
    path = cdir / "entita.md"
    if not path.is_file():
        return []
    rows = []
    for line in read(path).splitlines():
        m = ENTITY_ROW.match(line)
        if m:
            rows.append({"placeholder": f"[{m.group(1)}]", "type": m.group(2), "form": m.group(3).replace("\\|", "|")})
    return rows


def write_entities(cdir, rows):
    lines = ["# Entity map", "",
             "Placeholder table for this council, one row per form found in its texts.",
             "It stays inside the Anthropic trust boundary: never send it to any worker.",
             "", "| Placeholder | Type | Form |", "|---|---|---|"]
    lines += [f"| {r['placeholder']} | {r['type']} | {r['form'].replace('|', chr(92) + '|')} |" for r in rows]
    write_atomic(cdir / "entita.md", "\n".join(lines) + "\n")


def form_pattern(form):
    parts = [re.escape(p) for p in form.split()]
    return re.compile(r"(?<!\w)" + r"\s+".join(parts) + r"(?!\w)", re.IGNORECASE)


def path_prefixes():
    prefixes = {str(Path.home()), str(FM_HOME), str(DATA), str(STATE), str(CODE_ROOT)}
    return sorted((p for p in prefixes if p and p != "/"), key=len, reverse=True)


def mask_paths(text):
    """Hide operational path prefixes so a username inside a path is neither replaced nor reported."""
    restore = {}
    for i, prefix in enumerate(path_prefixes()):
        token = f"\u27e6PATH{i}\u27e7"
        if prefix in text:
            text = text.replace(prefix, token)
            restore[token] = prefix
    return text, restore


def unmask(text, restore):
    for token, prefix in restore.items():
        text = text.replace(token, prefix)
    return text


def apply_map(text, rows):
    masked, restore = mask_paths(text)
    for r in sorted(rows, key=lambda r: len(r["form"]), reverse=True):
        if len(r["form"].strip()) >= 2:
            masked = form_pattern(r["form"]).sub(r["placeholder"], masked)
    return unmask(masked, restore)


def leak_hits(text, rows):
    masked, _ = mask_paths(text)
    hits = []
    for r in rows:
        if len(r["form"].strip()) >= 2:
            n = len(form_pattern(r["form"]).findall(masked))
            if n:
                hits.append(f"{r['placeholder']} ({r['type']}) x{n}")
    return hits


def gate(cdir, text, trusted, what):
    """Refuse (exit 3) before anything leaves: secrets for every worker, identifying data for the rest."""
    problems = [f"{name} pattern" for name, rx in SECRET_PATTERNS.items() if re.search(rx, text)]
    if not trusted:
        problems += leak_hits(text, load_entities(cdir))
        masked, _ = mask_paths(text)
        problems += [f"{name} pattern" for name, rx in STRUCTURAL_PATTERNS.items() if re.search(rx, masked)]
    if problems:
        raise Stop(f"REFUSED: {what} still contains data that must not be sent: {', '.join(problems)}. "
                   "Pseudonymise it (pseudo --add TYPE=FORM for a missed form) or remove the secret, then retry.",
                   EXIT_REFUSED)


def pseudonymiser_argv(cfg):
    override = os.environ.get("FM_PAL_PSEUDONYMISER_CMD")
    if override:
        return shlex.split(override)
    return ["claude", "-p", "--model", cfg["pseudonymiser"].get("model", "haiku"), "--setting-sources", "",
            "--strict-mcp-config", "--tools", "", "--no-session-persistence", "--output-format", "json"]


def call_pseudonymiser(cfg, text, rows):
    known = ""
    if rows:
        groups = {}
        for r in rows:
            groups.setdefault(r["placeholder"], []).append(r["form"])
        known = ("\nThese entities were already found in earlier texts of the same council; if they occur, group "
                 "their forms the same way:\n" + json.dumps(list(groups.values()), ensure_ascii=False) + "\n")
    masked, _ = mask_paths(text)
    prompt = HAIKU_PROMPT.format(known=known, text=masked)
    timeout = int(cfg["pseudonymiser"].get("timeout_seconds", 600))
    try:
        out = subprocess.run(pseudonymiser_argv(cfg), input=prompt, capture_output=True, text=True, timeout=timeout,
                             cwd=tempfile.gettempdir())
    except FileNotFoundError:
        raise Stop("the pseudonymiser command is not installed; nothing was sent", EXIT_RUNTIME)
    except subprocess.TimeoutExpired:
        raise Stop(f"the pseudonymiser did not answer within {timeout}s; nothing was sent", EXIT_RUNTIME)
    if out.returncode != 0:
        raise Stop(f"the pseudonymiser failed (exit {out.returncode}): {(out.stderr or out.stdout).strip()[:400]}", EXIT_RUNTIME)
    try:
        envelope = json.loads(out.stdout)
    except json.JSONDecodeError:
        raise Stop(f"the pseudonymiser returned non-JSON output: {out.stdout.strip()[:300]}", EXIT_RUNTIME)
    if envelope.get("is_error"):
        raise Stop(f"the pseudonymiser reported an error: {str(envelope.get('result'))[:400]}", EXIT_RUNTIME)
    answer = envelope.get("result") or ""
    m = re.search(r"\{.*\}", answer, re.S)
    try:
        data = json.loads(m.group(0)) if m else None
    except json.JSONDecodeError:
        data = None
    if not isinstance(data, dict):
        raise Stop(f"the pseudonymiser's answer holds no entity JSON: {answer[:300]}", EXIT_RUNTIME)
    return data.get("entities") or [], float(envelope.get("total_cost_usd") or 0.0)


def merge_entities(rows, groups, text, lang):
    names = PLACEHOLDER_LABELS.get(lang, PLACEHOLDER_LABELS["en"])
    by_form = {r["form"].casefold(): r["placeholder"] for r in rows}
    counters = {}
    for r in rows:
        m = re.match(r"\[([A-Z]+)_(\d+)\]", r["placeholder"])
        if m:
            counters[m.group(1)] = max(counters.get(m.group(1), 0), int(m.group(2)))
    masked, _ = mask_paths(text)
    added = 0
    for group in groups:
        etype = str(group.get("type", "OTHER")).upper()
        etype = etype if etype in ENTITY_TYPES else "OTHER"
        forms = [str(f).strip() for f in group.get("forms") or []]
        # A form the model invented or altered is not in the text and is ignored.
        forms = [f for f in forms if len(f) >= 2 and not f.startswith("[") and form_pattern(f).search(masked)]
        if not forms:
            continue
        placeholder = next((by_form[f.casefold()] for f in forms if f.casefold() in by_form), None)
        if placeholder is None:
            label = names[etype]
            counters[label] = counters.get(label, 0) + 1
            placeholder = f"[{label}_{counters[label]}]"
        for f in forms:
            if f.casefold() not in by_form:
                rows.append({"placeholder": placeholder, "type": etype, "form": f})
                by_form[f.casefold()] = placeholder
                added += 1
    return added


def charge_pseudonymiser(cdir, usd, cfg):
    if usd:
        costs = load_costs(cdir)
        costs["pseudonymiser_eur"] = round(costs.get("pseudonymiser_eur", 0.0) + usd * cfg["usd_to_eur"], 4)
        save_costs(cdir, costs)


def pseudonymise_pass(council, cfg, texts, skip_model=False, extra=()):
    """Grow the entity map from texts (one model call over all of them) and mark the council sensitive if it is non-empty."""
    cdir = council_dir(council["id"])
    rows = load_entities(cdir)
    before = len(rows)
    joined = "\n\n".join(t for t in texts if t.strip())
    groups = list(extra)
    if joined and not skip_model:
        found, usd = call_pseudonymiser(cfg, joined, rows)
        groups += found
        charge_pseudonymiser(cdir, usd, cfg)
    forced = " ".join(str(f) for g in extra for f in g.get("forms", []))
    merge_entities(rows, groups, f"{joined}\n{forced}", council["language"])
    if len(rows) != before:
        write_entities(cdir, rows)
    if rows and not council.get("sensitive"):
        council["sensitive"] = True
    return rows, len(rows) - before


def free_texts(council):
    """Council fields firstmate writes into the record: the topic and the seat notes (drop reasons, failures)."""
    members = council["seats"] + ([council["researcher"]] if council.get("researcher") else [])
    return [council["topic"]] + [s["note"] for s in members if s.get("note")]


def write_pseudo_verbale(council, rows):
    cdir = council_dir(council["id"])
    text = apply_map(read(cdir / "verbale.md"), rows)
    gate(cdir, text, False, "psevdo/verbale.md")
    write_atomic(cdir / "psevdo" / "verbale.md", text)


def outgoing_sources(cdir):
    sources = [Path("brief.md")]
    for sub in ("allegati", "precedenti", "persone"):
        folder = cdir / sub
        if folder.is_dir():
            sources += sorted(p.relative_to(cdir) for p in folder.rglob("*") if p.is_file())
    return [s for s in sources if (cdir / s).is_file()]


def pseudo_current(cdir, rel):
    record = json.loads(read(cdir / "pseudo.json")) if (cdir / "pseudo.json").is_file() else {}
    src = cdir / rel
    return rel.as_posix() in record and record[rel.as_posix()] == sha(read(src)) and (cdir / "psevdo" / rel).is_file()


# --- cost model ---------------------------------------------------------------------

def turn_cost(cfg, price, ctx_tokens, new_tokens, out_tokens):
    e = cfg["estimate"]
    full = new_tokens + e["tool_tokens_per_turn"]
    cached = ctx_tokens * e["requests_per_turn"]
    usd = (full * price["input_usd_per_mtok"]
           + cached * price["input_usd_per_mtok"] * e["cached_input_factor"]
           + out_tokens * price["output_usd_per_mtok"]) / 1e6
    return usd * cfg["usd_to_eur"]


def reasoning(cfg, effort):
    table = cfg["estimate"]["reasoning_tokens"]
    return table.get(effort or "medium", table.get("medium", 0))


def project_seat(cfg, seat, brief_chars, n_voices, rounds, researcher=False):
    """Per-round euro projection for one worker; the researcher works in every round but the last."""
    e = cfg["estimate"]
    cpt = e["chars_per_token"]
    price = price_for(cfg, seat["harness"], seat["model"])
    ctx = e["harness_context_tokens"] + brief_chars / cpt
    per = []
    active_rounds = max(rounds - 1, 0) if researcher else rounds
    for r in range(1, active_rounds + 1):
        if researcher:
            new = n_voices * e["research_request_chars"] / cpt
            out = e["dossier_chars"] / cpt + reasoning(cfg, seat["effort"])
        else:
            new = (brief_chars if r == 1 else (n_voices - 1) * e["turn_chars"] + e["summary_chars"] + e["dossier_chars"]) / cpt
            out = e["turn_chars"] / cpt + reasoning(cfg, seat["effort"])
        per.append(turn_cost(cfg, price, ctx, new, out))
        ctx += new + out - reasoning(cfg, seat["effort"]) + e["tool_tokens_per_turn"]
    return per


def charge_turn(cfg, costs, seat, round_no, new_chars, out_chars):
    e = cfg["estimate"]
    cpt = e["chars_per_token"]
    price = price_for(cfg, seat["harness"], seat["model"])
    record = costs.setdefault("seats", {}).setdefault(seat["seat"], {"ctx_tokens": e["harness_context_tokens"], "rounds": {}})
    new, out = new_chars / cpt, out_chars / cpt + reasoning(cfg, seat["effort"])
    record["rounds"][str(round_no)] = round(turn_cost(cfg, price, record["ctx_tokens"], new, out), 4)
    record["ctx_tokens"] = int(record["ctx_tokens"] + new + out_chars / cpt + e["tool_tokens_per_turn"])


# --- external commands ------------------------------------------------------------

def tool(name, default):
    return os.environ.get(f"FM_PAL_{name}_BIN") or str(SCRIPT_DIR / default)


def run_tool(argv, timeout=900):
    env = dict(os.environ, FM_HOME=str(FM_HOME))
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)
    return out.returncode, out.stdout, out.stderr


def send_line(council, seat, line):
    cdir = council_dir(council["id"])
    gate(cdir, line, seat["trusted"], f"the message to {seat['seat']}")
    code, out, err = run_tool([tool("SEND", "fm-send.sh"), seat["task_id"], line], timeout=300)
    return code, (err or out).strip()


# --- templates ----------------------------------------------------------------------

def render(template, values):
    text = template
    for key, value in values.items():
        text = text.replace("{{" + key + "}}", value)
    left = re.findall(r"\{\{([a-z_]+)\}\}", text)
    if left:
        raise Stop(f"template placeholders left unfilled: {', '.join(sorted(set(left)))}", EXIT_RUNTIME)
    return text


def synthesis_headings(lang):
    block = re.search(r"```headings\n(.*?)```", read(REFS / "synthesis-template.md"), re.S)
    for line in (block.group(1) if block else "").splitlines():
        code, _, rest = line.partition(":")
        if code.strip() == lang:
            return [h.strip() for h in rest.split("|") if h.strip()]
    raise Stop(f"references/synthesis-template.md lists no synthesis headings for language {lang!r}; add its line")


# --- commands -------------------------------------------------------------------------

def cmd_new(args):
    cfg = load_config()
    like = load_council(args.like) if args.like else None
    topic = args.topic.strip()
    if not topic or len(topic) > 500:
        raise Stop("the topic must be 1-500 characters; put the detail in brief.md")
    slug = args.slug or time.strftime("%y%m%d", time.gmtime(now()))
    cid = f"{slug}-{secrets.token_hex(2)}"
    if not ID_RE.match(cid):
        raise Stop(f"--slug {slug!r} must be lowercase letters, digits, and dashes, at most 31 characters")
    cdir = council_dir(cid)
    if cdir.exists():
        raise Stop(f"{cdir} already exists; retry")
    language = args.language or (like or {}).get("language") or cfg.get("language", "en")
    rounds = args.rounds or (like or {}).get("max_rounds") or cfg["rounds"]["default"]
    if not 1 <= rounds <= cfg["rounds"]["max"]:
        raise Stop(f"--rounds must be between 1 and {cfg['rounds']['max']}")
    b = cfg["budget"]
    if args.budget is not None and not b["min_eur"] <= args.budget <= b["max_eur"]:
        raise Stop(f"--budget must be between {b['min_eur']} and {b['max_eur']} EUR", EXIT_REFUSED)
    project = Path(args.project or (like or {}).get("project") or CODE_ROOT).expanduser().resolve()
    if not (project / ".git").exists():
        raise Stop(f"--project {project} is not a git checkout the voices can read")
    attachments = [Path(a).expanduser().resolve() for a in args.attach]
    for att in attachments:
        if not att.is_file():
            raise Stop(f"attachment {att} is not a file")
        try:
            att.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            raise Stop(f"attachment {att} is not UTF-8 text; convert it to text or Markdown first")
    if len({a.name for a in attachments}) != len(attachments):
        raise Stop("two attachments share a file name; rename one")

    notes = []
    tier = None
    if args.participants and args.tier:
        raise Stop("pass --tier or --participants, not both")
    if args.participants:
        seats = seats_from_participants(cfg, cid, args.participants)
    elif like and not args.tier:
        tier = like.get("tier")
        seats = []
        for old in like["seats"]:
            if old["status"] == "excluded":
                continue
            seat = make_seat(cfg, cid, old["seat"], old["harness"], old["model"], old["effort"], old["provider"],
                             economy=old.get("economy", False), instructions=old.get("instructions", ""))
            persona = council_dir(like["id"]) / old["persona"]
            seat["_persona_text"] = read(persona) if persona.is_file() else None
            seats.append(seat)
    else:
        tier = args.tier or cfg.get("default_tier", "best")
        seats, notes = seats_from_tier(cfg, cid, tier)
    if not 1 <= len(seats) <= 5:
        raise Stop(f"a council seats 1-5 voices; this one would seat {len(seats)}")

    rrule = cfg["researcher"]
    rmodel, problem = resolve_rule(cfg, rrule)
    researcher = None
    if problem:
        notes.append(f"researcher: {problem}; the council runs without research")
    else:
        researcher = make_seat(cfg, cid, RESEARCHER, rrule["harness"], rmodel, rrule.get("effort"),
                               provider_of(cfg, rrule["harness"]))
        researcher["_persona_text"] = read(REFS / "researcher-persona.md")

    council = {
        "schema": 1, "id": cid, "topic": topic, "created": iso(now()), "language": language, "tier": tier,
        "project": str(project), "sensitive": bool(args.sensitive), "state": "draft", "max_rounds": rounds,
        "round_timeout_minutes": args.round_timeout or cfg["round_timeout_minutes"],
        "budget_eur": 0.0, "budget_source": "captain" if args.budget is not None else "default",
        "single_provider_ok": bool(args.single_provider_ok), "seats": seats, "researcher": researcher,
        "rounds": [], "messages": [], "prior": [], "prior_searched": False, "closed_reason": "",
        "closed_at": None, "purged_at": None, "purge_watch": False, "rag": [],
    }
    notes += apply_quota(council)
    check_diversity(council)

    active = voices(council, ("planned",))
    if args.budget is not None:
        budget = args.budget
    else:
        budget = sum(b["opus_class_voice_eur"] if s["opus_class"] else b["other_voice_eur"] for s in active)
        if researcher and researcher["status"] == "planned":
            budget += b["researcher_eur"]
        budget = min(max(budget + b["moderator_eur"], b["min_eur"]), b["max_eur"])
    council["budget_eur"] = round(budget, 2)

    for sub in ("allegati", "persone", "precedenti", "turni", "pacchetti", "riassunti", "ricerca", "messaggi", "rag"):
        (cdir / sub).mkdir(parents=True, exist_ok=True)
    for att in attachments:
        shutil.copy2(att, cdir / "allegati" / att.name)
    for seat in council["seats"] + ([researcher] if researcher else []):
        text = seat.pop("_persona_text", None)
        if text:
            write_atomic(cdir / seat["persona"], text.rstrip() + "\n")
    inherit = list(args.inherit) + ([like["id"]] if like else [])
    for prior in inherit:
        notes.append(record_prior(council, prior, None))
    save_council(council)
    costs = load_costs(cdir)
    costs["budget_eur"] = council["budget_eur"]
    save_costs(cdir, costs)

    print(f"council: {cid}")
    print(f"folder: {cdir}")
    print(f"state: draft; tier {tier or 'explicit'}; language {language}; rounds up to {rounds}; project {project}")
    for seat in council["seats"] + ([researcher] if researcher else []):
        print(f"seat {seat['seat']}: {seat['harness']} {seat['model']} effort={seat['effort'] or 'default'} "
              f"provider={seat['provider']} trusted={'yes' if seat['trusted'] else 'no'} status={seat['status']}")
    print(f"budget: {eur(council['budget_eur'])} EUR ({council['budget_source']})")
    for note in notes:
        if note:
            print(f"note: {note}")
    missing = [s["persona"] for s in council["seats"] if s["status"] == "planned" and not (cdir / s["persona"]).is_file()]
    print("next: search the RAG for earlier councils and record them with `prior`, write brief.md"
          + (f" and {', '.join(missing)}" if missing else "") + ", then run pseudo, estimate, launch")
    return 0


def record_prior(council, prior_id, source):
    cdir = council_dir(council["id"])
    if not ID_RE.match(prior_id or ""):
        raise Stop(f"invalid prior council id {prior_id!r}")
    src = Path(source).expanduser() if source else council_dir(prior_id) / "sintesi.md"
    if not src.is_file():
        return f"prior council {prior_id}: no synthesis at {src}; record it with `prior {council['id']} {prior_id} --file <synthesis>`"
    write_atomic(cdir / "precedenti" / f"{prior_id}.md", read(src))
    if prior_id not in council["prior"]:
        council["prior"].append(prior_id)
    council["prior_searched"] = True
    return f"prior council {prior_id}: synthesis recorded"


def cmd_prior(args):
    council = load_council(args.id)
    require_state(council, "draft")
    if args.none:
        council["prior_searched"] = True
        save_council(council)
        print("prior search recorded: no relevant earlier council")
        return 0
    if not args.prior:
        raise Stop("pass a prior council id, or --none when the RAG search found nothing relevant")
    message = record_prior(council, args.prior, args.file)
    save_council(council)
    print(message)
    return 0 if "recorded" in message else EXIT_USAGE


def cmd_pseudo(args):
    cfg = load_config()
    council = load_council(args.id)
    require_state(council, "draft", "running")
    cdir = council_dir(council["id"])
    sources = [Path(s) for s in args.source] if args.source else outgoing_sources(cdir)
    for rel in sources:
        if rel.is_absolute() or ".." in rel.parts or not (cdir / rel).is_file():
            raise Stop(f"--source {rel} is not a file inside the council folder")
    extra = []
    for item in args.add:
        etype, sep, form = item.partition("=")
        if not sep or not form.strip():
            raise Stop(f"--add expects TYPE=FORM, got {item!r}")
        extra.append({"type": etype.strip().upper(), "forms": [form.strip()]})
    texts = [read(cdir / rel) for rel in sources]
    rows, added = pseudonymise_pass(council, cfg, texts + free_texts(council), skip_model=args.skip_model, extra=extra)
    record = json.loads(read(cdir / "pseudo.json")) if (cdir / "pseudo.json").is_file() else {}
    for rel, text in zip(sources, texts):
        out = apply_map(text, rows)
        hits = leak_hits(out, rows)
        if hits:
            raise Stop(f"literal recheck FAILED for {rel}: {', '.join(hits)}; nothing more was written", EXIT_REFUSED)
        write_atomic(cdir / "psevdo" / rel, out)
        record[rel.as_posix()] = sha(text)
    write_atomic(cdir / "pseudo.json", json.dumps(record, indent=2) + "\n")
    save_council(council)
    placeholders = sorted({r["placeholder"] for r in rows})
    print(f"pseudonymised {len(sources)} file(s) into psevdo/; entity map: {len(rows)} forms, {added} new")
    if placeholders:
        print("placeholders: " + " ".join(placeholders))
    print("literal recheck: PASSED")
    for rel in sources:
        masked, _ = mask_paths(read(cdir / "psevdo" / rel))
        for name, rx in STRUCTURAL_PATTERNS.items():
            if re.search(rx, masked):
                print(f"warning: psevdo/{rel} still matches the {name} pattern; add it with --add or the send will be refused")
    print(f"sensitive: {'yes' if council['sensitive'] else 'no'}")
    return 0


def cmd_check(args):
    council = load_council(args.id)
    cdir = council_dir(council["id"])
    for name in args.files:
        gate(cdir, read(name), args.trusted, name)
        print(f"OK: {name} passes the {'trusted' if args.trusted else 'outside-Anthropic'} send gate")
    return 0


def estimate_rows(council, cfg):
    cdir = council_dir(council["id"])
    e = cfg["estimate"]
    brief = cdir / "brief.md"
    base = len(read(brief)) if brief.is_file() else cfg["brief_max_chars"]
    for sub in ("precedenti",):
        base += sum(len(read(p)) for p in (cdir / sub).glob("*.md"))
    expected = min(e["expected_rounds"], council["max_rounds"])
    active = voices(council, ("planned", "active"))
    rows = []
    for seat in active:
        persona = cdir / seat["persona"]
        chars = base + (len(read(persona)) if persona.is_file() else 1500) + 4000
        per = project_seat(cfg, seat, chars, len(active), council["max_rounds"])
        rows.append((seat, per[0] if per else 0.0, sum(per[:expected]), sum(per)))
    researcher = council.get("researcher")
    if researcher and researcher["status"] in ("planned", "active"):
        per = project_seat(cfg, researcher, base + 3000, len(active), council["max_rounds"], researcher=True)
        rows.append((researcher, per[0] if per else 0.0, sum(per[:max(expected - 1, 0)]), sum(per)))
    return rows, expected


def cmd_estimate(args):
    cfg = load_config()
    council = load_council(args.id)
    cdir = council_dir(council["id"])
    rows, expected = estimate_rows(council, cfg)
    costs = load_costs(cdir)
    moderator = cfg["budget"]["moderator_eur"]
    pseudo = costs.get("pseudonymiser_eur", 0.0)
    total = sum(r[2] for r in rows) + moderator + pseudo
    at_limit = sum(r[3] for r in rows) + moderator + pseudo
    print(f"estimate for council {council['id']}: {expected} expected round(s), limit {council['max_rounds']}; "
          f"prices from {cfg['_source']} (checked {cfg.get('prices_checked', 'unknown')})")
    print("| seat | model | price class | per round EUR | expected EUR | at the limit EUR |")
    print("|---|---|---|---|---|---|")
    for seat, first, exp, lim in rows:
        price = price_for(cfg, seat["harness"], seat["model"])
        klass = "opus" if price.get("opus_class") else ("fallback" if price.get("fallback") else "standard")
        print(f"| {seat['seat']} | {seat['harness']}/{seat['model']} | {klass} | {eur(first)} | {eur(exp)} | {eur(lim)} |")
    print(f"| moderator | firstmate | fixed | - | {eur(moderator)} | {eur(moderator)} |")
    print(f"| pseudonymiser | spent so far | - | - | {eur(pseudo)} | {eur(pseudo)} |")
    print(f"total expected: {eur(total)} EUR; at the round limit: {eur(at_limit)} EUR; budget: {eur(council['budget_eur'])} EUR")
    costs["estimate"] = {"expected_rounds": expected, "expected_eur": round(total, 4), "at_limit_eur": round(at_limit, 4),
                         "at": iso(now())}
    costs["budget_eur"] = council["budget_eur"]
    save_costs(cdir, costs)
    if total > council["budget_eur"]:
        raise Stop(f"REFUSED: the estimate ({eur(total)} EUR) exceeds the budget ({eur(council['budget_eur'])} EUR); "
                   "lower the tier or the rounds, drop a seat, or ask the captain for a higher --budget "
                   f"(at most {cfg['budget']['max_eur']} EUR)", EXIT_REFUSED)
    print("verdict: within budget")
    return 0


def attachments_block(cdir, seat, lang):
    names = sorted(p.name for p in (cdir / "allegati").glob("*") if p.is_file())
    if not names:
        return ""
    base = (cdir / "psevdo" / "allegati") if not seat["trusted"] else (cdir / "allegati")
    lines = ["## Attachments, to read when you need them", ""]
    lines += [f"- `{base / n}`" for n in names]
    return "\n".join(lines)


def prior_block(cdir, seat, council):
    if not council["prior"]:
        return ""
    base = cdir if seat["trusted"] else cdir / "psevdo"
    parts = ["## Syntheses of earlier councils on this subject", ""]
    for prior in council["prior"]:
        path = base / "precedenti" / f"{prior}.md"
        parts += [f"### Council {prior}", "", read(path).strip() if path.is_file() else "(missing)", ""]
    return "\n".join(parts)


def worker_text(council, seat, cfg):
    cdir = council_dir(council["id"])
    base = cdir if seat["trusted"] else cdir / "psevdo"
    lang = council["language"]
    example = f"[{PLACEHOLDER_LABELS.get(lang, PLACEHOLDER_LABELS['en'])['PERSON']}_1]"
    common = {"council_id": council["id"], "placeholder_example": example, "seat": seat["seat"], "model": seat["model"], "harness": seat["harness"],
              "provider": seat["provider"], "language": lang, "language_name": LANGUAGE_NAMES.get(lang, lang),
              "persona": read(base / seat["persona"]).strip(), "brief": read(base / "brief.md").strip()}
    if seat["seat"] == RESEARCHER:
        template = read(REFS / "researcher-brief.md")
        values = dict(common, research_dir=str(cdir / "ricerca"))
    else:
        template = read(REFS / "voice-brief.md")
        others = [f"`{s['seat']}` ({s['model']}, {s['provider']})" for s in voices(council, ("planned", "active")) if s is not seat]
        if seat["trusted"]:
            rule = (f"Some turns and dossiers contain placeholders such as `{example}`: they stand for identifying data "
                    "that workers outside Anthropic are not shown. Keep identifying data out of your `[RESEARCH]` lines, "
                    "because the researcher is outside Anthropic too.")
            verbale = cdir / "verbale.md"
        else:
            rule = ("Names, places, codes, contacts and other identifying data in what firstmate sends you are replaced by "
                    f"placeholders such as `{example}`. Treat each as a real but unknown value, never try to find out what "
                    "it hides, and never put identifying data in a `[RESEARCH]` line.")
            verbale = cdir / "psevdo" / "verbale.md"
        instructions = seat.get("instructions") or ""
        values = dict(common, other_seats=", ".join(others) or "none", verbale=str(verbale), placeholder_rule=rule,
                      instructions=(f"## Your instructions from the captain\n\n{instructions}" if instructions else ""),
                      attachments=attachments_block(cdir, seat, lang), prior=prior_block(cdir, seat, council),
                      turn_contract=re.sub(r"\A# [^\n]*\n+", "", read(REFS / "turn-contract.md")).strip(), turn_dir=str(cdir / "turni"))
    task, sep, done = render(template, values).partition(DOD_MARK)
    if not sep:
        raise Stop(f"the {seat['seat']} brief template lacks its {DOD_MARK} separator", EXIT_RUNTIME)
    return task.strip(), done.strip()


SCAFFOLD_EDITS = (
    (r"This is a SCOUT task: the deliverable is a written report, not a [^\n]*",
     "This is a council task: the deliverable is a sequence of written turns, never a report or a code change."),
    (r"The worktree is your laboratory - [^\n]*",
     "In this council you are read-only: read freely, but change nothing here or anywhere else except your own council files."),
    (r"The report is the only thing that survives, [^\n]*",
     "Your files in the council folder are the only thing that survives."),
    (r"2\. Stay inside this worktree; the only files you may write outside it are the report and the status file below\.",
     "2. Change nothing inside this worktree; the only files you may write are your own council files named below and the status file below."),
)


def build_worker_brief(council, seat, cfg):
    cdir = council_dir(council["id"])
    task, done = worker_text(council, seat, cfg)
    brief_path = DATA / seat["task_id"] / "brief.md"
    if brief_path.exists() and not seat.get("spawned"):
        brief_path.unlink()
    code, out, err = run_tool([tool("BRIEF", "fm-brief.sh"), seat["task_id"], council["project"], "--scout"], timeout=120)
    if code != 0 or not brief_path.is_file():
        raise Stop(f"fm-brief.sh failed for {seat['task_id']}: {(err or out).strip()[:400]}", EXIT_RUNTIME)
    text = read(brief_path)
    if text.count("# Task\n{TASK}\n") != 1:
        raise Stop("the scout scaffold no longer carries its '# Task' {TASK} slot; update fm_pal_council.py", EXIT_RUNTIME)
    text = text.replace("# Task\n{TASK}\n", "# Task\n" + task + "\n", 1)
    if council["prior"]:
        found = f"Earlier councils found in the RAG and included below: {', '.join(council['prior'])}."
        changed = "Their syntheses are part of the council's question, so the council starts from them rather than from zero."
    else:
        found = "Nothing relevant: firstmate searched the RAG for earlier councils on this question and found none."
        changed = "Nothing"
    text, n1 = re.subn(r"\{RECALL_FOUND:[^}]*\}", lambda _m: found, text)
    text, n2 = re.subn(r"\{RECALL_CHANGED:[^}]*\}", lambda _m: changed, text)
    if n1 != 1 or n2 != 1:
        raise Stop("the scout scaffold's recall placeholders changed; update fm_pal_council.py", EXIT_RUNTIME)
    for pattern, replacement in SCAFFOLD_EDITS:
        text, n = re.subn(pattern, lambda _m, r=replacement: r, text, count=1)
        if n != 1:
            raise Stop(f"the scout scaffold no longer contains {pattern!r}; update fm_pal_council.py", EXIT_RUNTIME)
    head, sep, _old = text.partition("\n# Definition of done\n")
    if not sep:
        raise Stop("the scout scaffold lost its Definition of done section; update fm_pal_council.py", EXIT_RUNTIME)
    text = head.rstrip() + "\n\n" + done + "\n"
    gate(cdir, text, seat["trusted"], f"the {seat['seat']} brief")
    write_atomic(brief_path, text)
    return brief_path


def verbale_header(council):
    lab = labels(council["language"])
    lines = [f"# {lab['verbale']} {council['id']}", "",
             f"- {lab['topic']}: {council['topic']}", f"- {lab['created']}: {council['created']}",
             f"- {lab['tier']}: {council['tier'] or 'explicit'}", f"- {lab['language']}: {council['language']}",
             f"- {lab['budget']}: {eur(council['budget_eur'])} EUR", "",
             f"| {lab['seat']} | {lab['model']} | {lab['provider']} | {lab['tool']} | {lab['effort']} |",
             "|---|---|---|---|---|"]
    members = council["seats"] + ([council["researcher"]] if council.get("researcher") else [])
    for s in members:
        name = lab["researcher"] if s["seat"] == RESEARCHER else s["seat"]
        status = f" ({lab['excluded']}: {s['note']})" if s["status"] == "excluded" else ""
        lines.append(f"| {name}{status} | {s['model']} | {s['provider']} | {s['harness']} | {s['effort'] or '-'} |")
    return "\n".join(lines) + "\n"


def open_round(council, number):
    deadline = now() + council["round_timeout_minutes"] * 60
    council["rounds"].append({"n": number, "opened": iso(now()), "deadline": iso(deadline), "closed": None,
                              "results": {}, "summary": False, "research": "none", "research_requests": 0})


def spawn(council, seat):
    argv = [tool("SPAWN", "fm-spawn.sh"), seat["task_id"], council["project"], "--scout", "--harness", seat["harness"]]
    if seat["model"]:
        argv += ["--model", seat["model"]]
    if seat["effort"]:
        argv += ["--effort", seat["effort"]]
    code, out, err = run_tool(argv)
    seat["spawned"] = code == 0
    seat["status"] = "active" if code == 0 else "failed"
    if code != 0:
        seat["note"] = f"spawn failed: {(err or out).strip()[:300]}"
    return code == 0


def cmd_launch(args):
    cfg = load_config()
    council = load_council(args.id)
    require_state(council, "draft")
    cdir = council_dir(council["id"])
    brief = cdir / "brief.md"
    if not brief.is_file() or not read(brief).strip():
        raise Stop("write brief.md first: the question, its context, and the decision needed")
    if len(read(brief)) > cfg["brief_max_chars"]:
        raise Stop(f"brief.md is {len(read(brief))} characters; the limit is {cfg['brief_max_chars']} - move detail into attachments")
    if not council["prior_searched"]:
        raise Stop("search the RAG for earlier councils first, then record them with `prior` (or `prior --none`)")
    members = voices(council, ("planned",)) + ([council["researcher"]] if council.get("researcher") and council["researcher"]["status"] == "planned" else [])
    for seat in members:
        if not (cdir / seat["persona"]).is_file():
            raise Stop(f"write {seat['persona']} (references/persona-template.md) before launch")
    if any(not s["trusted"] for s in members):
        stale = [rel.as_posix() for rel in outgoing_sources(cdir) if not pseudo_current(cdir, rel)]
        if stale:
            raise Stop(f"run `pseudo {council['id']}`: no current pseudonymised copy of {', '.join(stale)}", EXIT_REFUSED)
    check_diversity(council)
    rows, _expected = estimate_rows(council, cfg)
    costs = load_costs(cdir)
    total = sum(r[2] for r in rows) + cfg["budget"]["moderator_eur"] + costs.get("pseudonymiser_eur", 0.0)
    if total > council["budget_eur"]:
        raise Stop(f"REFUSED: the estimate ({eur(total)} EUR) exceeds the budget ({eur(council['budget_eur'])} EUR); run estimate", EXIT_REFUSED)
    for seat in members:  # every brief is built and gated before the first worker starts
        build_worker_brief(council, seat, cfg)
    if not (cdir / "verbale.md").is_file():
        write_atomic(cdir / "verbale.md", verbale_header(council))
    if any(not s["trusted"] for s in members):
        write_pseudo_verbale(council, load_entities(cdir))
    costs["moderator_eur"] = cfg["budget"]["moderator_eur"]
    costs["budget_eur"] = council["budget_eur"]
    open_round(council, 1)
    council["state"] = "running"
    save_council(council)
    for seat in members:
        ok = spawn(council, seat)
        print(f"{seat['seat']}: {'spawned ' + seat['task_id'] if ok else 'FAILED - ' + seat['note']}")
        save_council(council)
    save_costs(cdir, costs)
    if not voices(council):
        council["state"] = "cancelled"
        council["closed_reason"] = "no voice could be started"
        council["closed_at"] = iso(now())
        save_council(council)
        raise Stop("no voice could be started; the council is cancelled - run cleanup for any worker that did start", EXIT_RUNTIME)
    print(f"round 1 is open until {current_round(council)['deadline']} (blind)")
    print("next: check each new worker for a trust dialog, then wait for turn wakes and run `barrier`")
    return 0


def delivered(cdir, round_no, seat):
    path = cdir / "turni" / f"{round_no}-{seat['seat']}.md"
    if not path.is_file():
        return None, path
    text = read(path)
    m = STATUS_RE.match(last_line(text))
    return (m, path) if m else (False, path)


def cmd_barrier(args):
    council = load_council(args.id)
    require_state(council, "running")
    cdir = council_dir(council["id"])
    rnd = current_round(council)
    answered, pending = [], []
    for seat in voices(council):
        m, _path = delivered(cdir, rnd["n"], seat)
        (answered if m else pending).append(seat["seat"])
    expired = now() >= parse_iso(rnd["deadline"])
    print(f"round: {rnd['n']} ({'closed' if rnd['closed'] else 'open'}; deadline {rnd['deadline']}; expired {'yes' if expired else 'no'})")
    print(f"answered: {' '.join(answered) or '-'}")
    print(f"pending: {' '.join(pending) or '-'}")
    print(f"complete: {'yes' if not pending else 'no'}")
    for r in council["rounds"]:
        if r["research"] == "requested":
            ready = (cdir / "ricerca" / f"{r['n']}.md").is_file() and DOSSIER_RE.match(last_line(read(cdir / "ricerca" / f"{r['n']}.md")))
            print(f"research: round {r['n']} {'delivered - run dossier' if ready else 'pending'}")
    return 0


def seat_heading(seat, lab):
    name = lab["researcher"] if seat["seat"] == RESEARCHER else seat["seat"]
    return f"### {name} - {seat['model']} ({seat['provider']}, {seat['harness']})"


def close_round(council, cfg, force):
    """Append the open round to the record: delivered turns verbatim, every other voice recorded as missing."""
    cdir = council_dir(council["id"])
    lab = labels(council["language"])
    rnd = current_round(council)
    expired = now() >= parse_iso(rnd["deadline"])
    active = voices(council)
    states = {s["seat"]: delivered(cdir, rnd["n"], s) for s in active}
    pending = [name for name, (m, _p) in states.items() if not m]
    if pending and not expired and not force:
        raise Stop(f"round {rnd['n']} is still waiting for {', '.join(pending)}; wait, or pass --force to close it now")
    entries = [f"\n## {lab['round']} {rnd['n']}\n"]
    costs = load_costs(cdir)
    requests, delivered_statuses = [], []
    for seat in active:
        m, path = states[seat["seat"]]
        if m:
            text = read(path)
            entries.append(f"\n{seat_heading(seat, lab)}\n\n{text.strip()}\n")
            rnd["results"][seat["seat"]] = {"result": "ok", "status": m.group(1).upper(), "new": int(m.group(2)),
                                            "changed": int(m.group(3)), "sha256": sha(text)}
            delivered_statuses.append(rnd["results"][seat["seat"]])
            requests += [(seat["seat"], q) for q in RESEARCH_RE.findall(text) if q.strip().strip(".").lower() not in NONE_WORDS]
            packet = (cdir / "pacchetti" / f"{rnd['n']}-{seat['seat']}.md") if rnd["n"] > 1 else (DATA / seat["task_id"] / "brief.md")
            new_chars = len(read(packet)) if packet.is_file() else 0
            charge_turn(cfg, costs, seat, rnd["n"], new_chars, len(text))
        else:
            why = lab["timeout"] if expired else lab["closed_early"]
            extra = f"; {lab['incomplete']} {path}" if m is False else ""
            entries.append(f"\n{seat_heading(seat, lab)}\n\n**{lab['missing']}** ({why}{extra})\n")
            rnd["results"][seat["seat"]] = {"result": "timeout" if expired else "missing"}
            est = project_seat(cfg, seat, cfg["brief_max_chars"], len(active), rnd["n"])
            costs.setdefault("seats", {}).setdefault(seat["seat"], {"ctx_tokens": 0, "rounds": {}})["rounds"][str(rnd["n"])] = round(est[-1], 4)
    append(cdir / "verbale.md", "".join(entries))
    rnd["closed"] = iso(now())
    if requests:
        body = [f"# Research requests - round {rnd['n']}", ""]
        body += [f"- R{rnd['n']}.{i} ({who}): {q}" for i, (who, q) in enumerate(requests, 1)]
        write_atomic(cdir / "ricerca" / f"richieste-{rnd['n']}.md", "\n".join(body) + "\n")
    rnd["research_requests"] = len(requests)
    spent = save_costs(cdir, costs)
    save_council(council)
    return rnd, active, pending, delivered_statuses, requests, spent


def cmd_close_round(args):
    cfg = load_config()
    council = load_council(args.id)
    require_state(council, "running")
    cdir = council_dir(council["id"])
    rnd = current_round(council)
    if rnd["closed"]:
        raise Stop(f"round {rnd['n']} is already closed; run summary, research, and next")
    rnd, active, pending, delivered_statuses, requests, spent = close_round(council, cfg, args.force)
    all_done = bool(delivered_statuses) and not pending and all(r["status"] == "DONE" for r in delivered_statuses)
    no_news = rnd["n"] >= 2 and bool(delivered_statuses) and all(r["new"] == 0 and r["changed"] == 0 for r in delivered_statuses)
    print(f"round {rnd['n']} closed: {len(delivered_statuses)} delivered, {len(pending)} missing")
    for seat in active:
        res = rnd["results"][seat["seat"]]
        detail = f"{res['status']} new={res['new']} changed={res['changed']}" if res["result"] == "ok" else res["result"].upper()
        print(f"  {seat['seat']}: {detail} - {cdir / 'turni' / (str(rnd['n']) + '-' + seat['seat'] + '.md')}")
    print(f"research requests: {len(requests)}")
    print(f"closing conditions: all-done {'yes' if all_done else 'no'}; no-news {'yes (confirm by reading)' if no_news else 'no'}; "
          f"round-limit {'reached' if rnd['n'] >= council['max_rounds'] else 'not reached'}; "
          f"budget {'EXCEEDED' if spent > council['budget_eur'] else 'within'} ({eur(spent)} of {eur(council['budget_eur'])} EUR)")
    print("next: read every turn in full, write riassunti/<n>.md, run summary")
    return 0


def last_closed(council):
    closed = [r for r in council["rounds"] if r["closed"]]
    if not closed:
        raise Stop("no round has been closed yet")
    return closed[-1]


def cmd_summary(args):
    council = load_council(args.id)
    require_state(council, "running", "closing")
    cdir = council_dir(council["id"])
    rnd = last_closed(council)
    if rnd["summary"]:
        raise Stop(f"the summary of round {rnd['n']} is already in the record; the record is append-only")
    text = read(args.file).strip()
    if not text:
        raise Stop(f"{args.file} is empty")
    dest = cdir / "riassunti" / f"{rnd['n']}.md"
    if Path(args.file).resolve() != dest.resolve():
        write_atomic(dest, text + "\n")
    lab = labels(council["language"])
    append(cdir / "verbale.md", f"\n### {lab['summary']} - {lab['round'].lower()} {rnd['n']}\n\n{text}\n")
    rnd["summary"] = True
    save_council(council)
    print(f"summary of round {rnd['n']} appended to the record")
    return 0


def outgoing_text(council, cfg, seat, clear, rows):
    """What a worker actually receives: clear for Anthropic, the map applied for everyone else; both gated."""
    cdir = council_dir(council["id"])
    text = clear if seat["trusted"] else apply_map(clear, rows)
    gate(cdir, text, seat["trusted"], f"the packet for {seat['seat']}")
    return text


def cmd_research(args):
    cfg = load_config()
    council = load_council(args.id)
    require_state(council, "running")
    cdir = council_dir(council["id"])
    lab = labels(council["language"])
    rnd = last_closed(council)
    requests = cdir / "ricerca" / f"richieste-{rnd['n']}.md"
    if not requests.is_file():
        rnd["research"] = "none"
        save_council(council)
        print(f"no research requests in round {rnd['n']}")
        return 0
    researcher = council.get("researcher")
    if not researcher or researcher["status"] != "active":
        rnd["research"] = "unavailable"
        append(cdir / "verbale.md", f"\n### {lab['dossier']} - {lab['round'].lower()} {rnd['n']}\n\n**{lab['research_unavailable']}**\n")
        save_council(council)
        print("the researcher is not available; recorded in the record")
        return 0
    clear = read(requests)
    rows, _added = pseudonymise_pass(council, cfg, [clear])
    target = cdir / "ricerca" / f"{rnd['n']}.md"
    packet = (f"# Council {council['id']} - research requests, round {rnd['n']}\n\n{clear.split(chr(10), 2)[-1].strip()}\n\n"
              f"Write the dossier to `{target}` following your dossier contract, then append `done: research {rnd['n']}`.\n")
    text = outgoing_text(council, cfg, researcher, packet, rows)
    path = cdir / "ricerca" / f"pacchetto-{rnd['n']}.md"
    write_atomic(path, text)
    code, detail = send_line(council, researcher, f"Council {council['id']} research round {rnd['n']}: read {path} and write {target}, then append done: research {rnd['n']} to your status file.")
    if code not in (0, 3):
        raise Stop(f"could not reach the researcher ({detail}); retry `research`, or record the failure with `dossier --failed`", EXIT_RUNTIME)
    rnd["research"] = "requested"
    save_council(council)
    print(f"research requests of round {rnd['n']} sent to the researcher" + (" (submit unconfirmed: check the pane)" if code == 3 else ""))
    return 0


def cmd_dossier(args):
    cfg = load_config()
    council = load_council(args.id)
    require_state(council, "running", "closing")
    cdir = council_dir(council["id"])
    lab = labels(council["language"])
    pending = [r for r in council["rounds"] if r["research"] == "requested"]
    if not pending:
        raise Stop("no research is waiting for a dossier")
    rnd = pending[0]
    heading = f"\n### {lab['dossier']} - {lab['round'].lower()} {rnd['n']}\n\n"
    path = cdir / "ricerca" / f"{rnd['n']}.md"
    if args.failed:
        append(cdir / "verbale.md", heading + f"**{lab['research_failed']}**\n")
        rnd["research"] = "failed"
        save_council(council)
        print(f"research of round {rnd['n']} recorded as not delivered")
        return 0
    if not path.is_file() or not DOSSIER_RE.match(last_line(read(path))):
        raise Stop(f"the dossier for round {rnd['n']} is not delivered yet ({path}); wait, or pass --failed")
    text = read(path).strip()
    append(cdir / "verbale.md", heading + text + "\n")
    append(cdir / "dossier-ricerca.md", f"\n## {lab['round']} {rnd['n']}\n\n{text}\n")
    costs = load_costs(cdir)
    packet = cdir / "ricerca" / f"pacchetto-{rnd['n']}.md"
    charge_turn(cfg, costs, council["researcher"], rnd["n"], len(read(packet)) if packet.is_file() else 0, len(text))
    save_costs(cdir, costs)
    rnd["research"] = "done"
    save_council(council)
    print(f"dossier of round {rnd['n']} appended to the record and to dossier-ricerca.md")
    return 0


def packet_for(council, seat, rnd, lab):
    cdir = council_dir(council["id"])
    parts = [f"# {lab['packet_title']} {rnd['n'] + 1} - {council['id']} - {seat['seat']}", ""]
    for msg in council["messages"]:
        if msg["delivered"] is None and msg["to"] in ("all", seat["seat"]):
            parts += [f"## {lab['captain_msg']}", "", read(cdir / msg["file"]).strip(), ""]
    parts += [f"## {lab['summary']} - {lab['round'].lower()} {rnd['n']}", "", read(cdir / "riassunti" / f"{rnd['n']}.md").strip(), ""]
    dossier = cdir / "ricerca" / f"{rnd['n']}.md"
    parts += [f"## {lab['dossier']} - {lab['round'].lower()} {rnd['n']}", "",
              read(dossier).strip() if rnd["research"] == "done" and dossier.is_file() else lab["no_dossier"], ""]
    parts += [f"## {lab['others']} - {lab['round'].lower()} {rnd['n']}", ""]
    for other in council["seats"]:
        if other is seat or other["seat"] not in rnd["results"]:
            continue
        parts.append(seat_heading(other, lab))
        parts.append("")
        if rnd["results"][other["seat"]]["result"] == "ok":
            parts.append(read(cdir / "turni" / f"{rnd['n']}-{other['seat']}.md").strip())
        else:
            parts.append(f"**{lab['missing']}**")
        parts.append("")
    turn = cdir / "turni" / f"{rnd['n'] + 1}-{seat['seat']}.md"
    parts += [f"## {lab['task']}", "",
              f"Round {rnd['n'] + 1}: take a position on the other voices' findings by number, keep, modify, or withdraw your own, "
              f"and add only findings that are genuinely new. Write `{turn}` with the closing block of the turn contract, then "
              f"append `done: turn {rnd['n'] + 1} <CONTINUE or DONE>` to your status file.", ""]
    return "\n".join(parts)


def cmd_next(args):
    cfg = load_config()
    council = load_council(args.id)
    require_state(council, "running")
    cdir = council_dir(council["id"])
    lab = labels(council["language"])
    rnd = current_round(council)
    if not rnd["closed"]:
        raise Stop(f"round {rnd['n']} is still open; run barrier and close-round")
    if not rnd["summary"]:
        raise Stop(f"append the moderator summary of round {rnd['n']} first (summary)")
    if rnd["research_requests"] and rnd["research"] in ("none", "requested"):
        raise Stop(f"round {rnd['n']} has research {'waiting' if rnd['research'] == 'requested' else 'not yet sent'}; run research and dossier (or dossier --failed)")
    if rnd["n"] >= council["max_rounds"]:
        raise Stop(f"the round limit ({council['max_rounds']}) is reached; close the council")
    costs = load_costs(cdir)
    if costs.get("spent_eur", 0.0) > council["budget_eur"]:
        raise Stop(f"the budget is exceeded ({eur(costs['spent_eur'])} of {eur(council['budget_eur'])} EUR); close the council", EXIT_REFUSED)
    active = voices(council)
    if not active:
        raise Stop("no voice is left; close the council")
    packets = {s["seat"]: packet_for(council, s, rnd, lab) for s in active}
    rows = load_entities(cdir)
    if any(not s["trusted"] for s in active):
        fresh = [read(cdir / "turni" / f"{rnd['n']}-{name}.md") for name, res in rnd["results"].items() if res["result"] == "ok"]
        fresh.append(read(cdir / "riassunti" / f"{rnd['n']}.md"))
        if rnd["research"] == "done":
            fresh.append(read(cdir / "ricerca" / f"{rnd['n']}.md"))
        fresh += [read(cdir / m["file"]) for m in council["messages"] if m["delivered"] is None]
        rows, _added = pseudonymise_pass(council, cfg, fresh + free_texts(council))
        write_pseudo_verbale(council, rows)
    ready = {}
    for seat in active:  # every packet is built and gated before the first one leaves
        ready[seat["seat"]] = outgoing_text(council, cfg, seat, packets[seat["seat"]], rows)
    open_round(council, rnd["n"] + 1)
    new = current_round(council)
    save_council(council)
    for seat in active:
        path = cdir / "pacchetti" / f"{new['n']}-{seat['seat']}.md"
        write_atomic(path, ready[seat["seat"]])
        turn = cdir / "turni" / f"{new['n']}-{seat['seat']}.md"
        code, detail = send_line(council, seat, f"Council {council['id']} round {new['n']}: read {path} in full and write {turn}, then append done: turn {new['n']} to your status file.")
        if code == 0:
            print(f"{seat['seat']}: round {new['n']} packet sent")
        elif code == 3:
            print(f"{seat['seat']}: packet typed but the submit is unconfirmed - check the pane before any resend")
        else:
            seat["status"] = "lost"
            seat["note"] = f"round {new['n']} send failed: {detail[:200]}"
            append(cdir / "verbale.md", f"\n**{lab['lost']}** - {seat['seat']} ({lab['round'].lower()} {new['n']})\n")
            print(f"{seat['seat']}: LOST - {detail[:200]}")
    for msg in council["messages"]:
        if msg["delivered"] is None:
            msg["delivered"] = f"round {new['n']}"
    save_council(council)
    projected = sum(project_seat(cfg, s, cfg["brief_max_chars"], len(active), new["n"])[-1] for s in voices(council))
    if costs.get("spent_eur", 0.0) + projected > council["budget_eur"]:
        print(f"warning: this round is projected to take the spend past the budget ({eur(costs.get('spent_eur', 0.0) + projected)} of {eur(council['budget_eur'])} EUR)")
    print(f"round {new['n']} is open until {new['deadline']}")
    return 0


def cmd_message(args):
    cfg = load_config()
    council = load_council(args.id)
    require_state(council, "running")
    cdir = council_dir(council["id"])
    lab = labels(council["language"])
    to = "all" if args.all else args.seat
    targets = voices(council) if args.all else [seat_by_name(council, args.seat)]
    if not args.all and targets[0]["status"] != "active":
        raise Stop(f"seat {args.seat} is not active")
    text = read(args.file).strip()
    if not text:
        raise Stop(f"{args.file} is empty")
    k = len(council["messages"]) + 1
    rel = f"messaggi/{k}.md"
    write_atomic(cdir / rel, text + "\n")
    who = lab["to_all"] if args.all else f"{lab['to']} {args.seat}"
    append(cdir / "verbale.md", f"\n### {lab['captain_msg']} ({who})\n\n{text}\n")
    msg = {"k": k, "to": to, "file": rel, "delivered": None}
    council["messages"].append(msg)
    if args.now:
        rows = load_entities(cdir)
        if any(not s["trusted"] for s in targets):
            rows, _added = pseudonymise_pass(council, cfg, [text])
        ready = {s["seat"]: outgoing_text(council, cfg, s, f"# {lab['captain_msg']}\n\n{text}\n", rows) for s in targets}
        for seat in targets:
            path = cdir / "pacchetti" / f"msg-{k}-{seat['seat']}.md"
            write_atomic(path, ready[seat["seat"]])
            code, detail = send_line(council, seat, f"Council {council['id']}: a message from the captain is at {path}; read it and take it into account in your current or next turn.")
            print(f"{seat['seat']}: {'sent' if code in (0, 3) else 'FAILED - ' + detail[:200]}")
        msg["delivered"] = "now"
    save_council(council)
    print(f"message {k} recorded" + ("" if args.now else "; it travels with the next round's packets"))
    return 0


def cmd_drop(args):
    council = load_council(args.id)
    require_state(council, "running", "draft")
    seat = seat_by_name(council, args.seat)
    seat["status"] = "dropped"
    seat["note"] = args.reason
    lab = labels(council["language"])
    if (council_dir(council["id"]) / "verbale.md").is_file():
        append(council_dir(council["id"]) / "verbale.md", f"\n**{lab['dropped']}** - {args.seat}: {args.reason}\n")
    save_council(council)
    print(f"{args.seat} withdrawn: {args.reason}")
    return 0


def cmd_close(args):
    council = load_council(args.id)
    require_state(council, "running")
    rnd = current_round(council)
    if rnd and not rnd["closed"]:
        raise Stop(f"round {rnd['n']} is still open; close it first (close-round --force closes it now)")
    council["state"] = "closing"
    council["closed_reason"] = args.reason
    save_council(council)
    print(f"council {council['id']} is closing ({args.reason}); write sintesi.md and run finalize")
    return 0


def cmd_cancel(args):
    council = load_council(args.id)
    require_state(council, "draft", "running", "closing")
    lab = labels(council["language"])
    rnd = current_round(council)
    if council["state"] == "running" and rnd and not rnd["closed"]:
        _rnd, _active, pending, delivered_statuses, _requests, _spent = close_round(council, load_config(), True)
        print(f"round {rnd['n']} closed into the record: {len(delivered_statuses)} delivered, {len(pending)} missing")
    council["state"] = "cancelled"
    council["closed_reason"] = args.reason or lab["cancelled"]
    council["closed_at"] = iso(now())
    path = council_dir(council["id"]) / "verbale.md"
    if path.is_file():
        append(path, f"\n## {lab['closing']}\n\n{lab['cancelled']}: {council['closed_reason']}\n")
    save_council(council)
    print(f"council {council['id']} cancelled; run complete and cleanup to stop its workers")
    return 0


def cmd_finalize(args):
    cfg = load_config()
    council = load_council(args.id)
    require_state(council, "closing")
    cdir = council_dir(council["id"])
    lab = labels(council["language"])
    synth = cdir / "sintesi.md"
    if not synth.is_file() or not read(synth).strip():
        raise Stop("write sintesi.md first (references/synthesis-template.md)")
    text = read(synth)
    missing = [h for h in synthesis_headings(council["language"]) if not re.search(r"^##\s+" + re.escape(h), text, re.M | re.I)]
    if missing:
        raise Stop(f"sintesi.md lacks the heading(s): {', '.join(missing)}")
    costs = load_costs(cdir)
    lines = [f"\n## {lab['closing']}\n", f"- {lab['reason']}: {council['closed_reason']}",
             f"- {lab['rounds']}: {len([r for r in council['rounds'] if r['closed']])}",
             f"- {lab['spent']}: {eur(costs.get('spent_eur', 0.0))} / {eur(council['budget_eur'])} EUR"]
    append(cdir / "verbale.md", "\n".join(lines) + "\n")
    council["state"] = "closed"
    council["closed_at"] = iso(now())
    save_council(council)
    files = build_rag(council, cfg)
    print(f"council {council['id']} closed; {len(files)} knowledge payload(s) in {cdir / 'rag'}")
    print("next: ingest each payload with ingest_document and record it with rag-done, turn the captain's questions "
          "into held tasks, then complete and cleanup" + ("; this council is sensitive: arm the purge (arm-purge)" if council["sensitive"] else ""))
    return 0


def chunks(text, limit):
    pieces, current = [], ""
    for block in re.split(r"(?=\n#{2,3} )", text):
        while len(block) > limit:
            cut = block.rfind("\n", 0, limit)
            cut = cut if cut > limit // 2 else limit
            if current:
                pieces.append(current)
                current = ""
            pieces.append(block[:cut])
            block = block[cut:]
        if len(current) + len(block) > limit and current:
            pieces.append(current)
            current = ""
        current += block
    if current.strip():
        pieces.append(current)
    return [p.strip() for p in pieces if p.strip()]


def build_rag(council, cfg):
    cdir = council_dir(council["id"])
    rows = load_entities(cdir) if council["sensitive"] else []
    date = council["created"][:10]
    participants = [f"{s['seat']}:{s['harness']}/{s['model']}" for s in council["seats"] if s["status"] != "excluded"]
    topic = apply_map(council["topic"], rows) if rows else council["topic"]
    outcome = apply_map(council["closed_reason"], rows) if rows else council["closed_reason"]
    topic_tag = re.sub(r"[^a-z0-9]+", "-", topic.lower()).strip("-")[:60]
    tags = ["pal-council", f"council:{council['id']}", f"topic:{topic_tag}", f"date:{date}",
            f"tier:{council['tier'] or 'explicit'}", f"sensitivity:{'sensitive' if council['sensitive'] else 'normal'}",
            f"outcome:{council['state']}"] + [f"participant:{p}" for p in participants]
    out_dir = cdir / "rag"
    for old in out_dir.glob("*.json"):
        old.unlink()
    files = []
    for kind, name in (("synthesis", "sintesi.md"), ("record", "verbale.md")):
        path = cdir / name
        if not path.is_file():
            continue
        text = apply_map(read(path), rows) if rows else read(path)
        if rows and leak_hits(text, rows):
            raise Stop(f"the pseudonymised {name} still holds mapped data; nothing was written", EXIT_REFUSED)
        parts = chunks(text, 7000)
        for i, part in enumerate(parts, 1):
            header = (f"# pal-council {council['id']} - {kind} ({i}/{len(parts)})\n"
                      f"Tags: {'; '.join(tags)}\nTopic: {topic}\nOutcome: {outcome}\n\n")
            meta = {"file_path": f"firstmate/pal-council/{council['id']}/{name}", "slug": f"pal-council-{council['id']}-{kind}-{i}",
                    "author": "firstmate-pal-council", "document_type": f"pal_council_{kind}", "document_date": date,
                    "rbac_roles": ["admin", "dev"], "confidence_score": 1.0, "tags": tags,
                    "scope_chain": ["pal-council", council["id"], kind],
                    "pal_council": {"id": council["id"], "topic": topic, "tier": council["tier"], "sensitive": council["sensitive"],
                                    "outcome": outcome, "participants": participants, "part": i, "parts": len(parts)}}
            payload = {"chunk_text": header + part, "metadata_json": json.dumps(meta, ensure_ascii=False), "user_roles": "admin,dev"}
            dest = out_dir / f"{kind}-{i}.json"
            write_atomic(dest, json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
            files.append(dest)
    return files


def cmd_rag(args):
    cfg = load_config()
    council = load_council(args.id)
    require_state(council, "closed")
    for path in build_rag(council, cfg):
        print(path)
    return 0


def cmd_rag_done(args):
    council = load_council(args.id)
    name = Path(args.payload).name
    if not (council_dir(council["id"]) / "rag" / name).is_file():
        raise Stop(f"{name} is not a payload of council {council['id']}")
    council["rag"] = [r for r in council["rag"] if r["payload"] != name] + [{"payload": name, "point_id": args.point_id, "at": iso(now())}]
    save_council(council)
    print(f"recorded {name} as ingested ({args.point_id})")
    return 0


def cmd_rag_query(args):
    council = load_council(args.id)
    print(f"query_text: pal-council {council['topic']}")
    print("user_roles: admin,dev")
    return 0


def spawned_workers(council):
    members = council["seats"] + ([council["researcher"]] if council.get("researcher") else [])
    return [s for s in members if s.get("spawned")]


def cmd_complete(args):
    council = load_council(args.id)
    require_state(council, "closed", "cancelled")
    if not args.none and not args.holds:
        raise Stop("pass --none, or the ids of the captain-held tasks that carry the council's open questions")
    failed = 0
    for seat in spawned_workers(council):
        argv = [tool("HOLD", "fm-captain-hold.sh"), "complete", seat["task_id"]] + (["--none"] if args.none else list(args.holds))
        code, out, err = run_tool(argv, timeout=120)
        print(f"{seat['seat']}: {'completed' if code == 0 else 'FAILED - ' + (err or out).strip()[:300]}")
        failed += code != 0
    return EXIT_RUNTIME if failed else 0


def cmd_cleanup(args):
    council = load_council(args.id)
    require_state(council, "closed", "cancelled")
    cdir = council_dir(council["id"])
    verbale = read(cdir / "verbale.md") if (cdir / "verbale.md").is_file() else ""
    for rnd in council["rounds"]:
        for name, res in rnd["results"].items():
            if res["result"] != "ok":
                continue
            path = cdir / "turni" / f"{rnd['n']}-{name}.md"
            intact = council.get("purged_at") or (path.is_file() and sha(read(path)) == res["sha256"])
            if not intact or not path.is_file() or read(path).strip() not in verbale:
                raise Stop(f"turn {path.name} is not in the record as delivered; nothing was cleaned up", EXIT_REFUSED)
    workers = [s for s in spawned_workers(council) if s["status"] != "closed"]
    for seat in workers:
        report = DATA / seat["task_id"] / "report.md"
        if not report.is_file():
            write_atomic(report, f"# Council worker {seat['task_id']}\n\nThis worker sat as `{seat['seat']}` in pal-council "
                                 f"{council['id']}. Its turns are in {cdir / 'verbale.md'}; the synthesis is {cdir / 'sintesi.md'}.\n")
    unverified = []
    for seat in workers:
        code, out, err = run_tool([tool("HOLD", "fm-captain-hold.sh"), "verify", seat["task_id"]], timeout=120)
        if code != 0:
            unverified.append(seat["seat"])
    if unverified:
        raise Stop(f"the completion gate has not passed for {', '.join(unverified)}; run complete first", EXIT_REFUSED)
    failed = []
    for seat in workers:
        code, out, err = run_tool([tool("TEARDOWN", "fm-teardown.sh"), seat["task_id"]])
        if code == 0:
            seat["status"] = "closed"
            print(f"{seat['seat']}: cleaned up")
        else:
            failed.append(seat["seat"])
            print(f"{seat['seat']}: REFUSED - {(err or out).strip()[:300]}")
        save_council(council)
    if failed:
        raise Stop(f"cleanup refused for {', '.join(failed)}; investigate before any retry, never force", EXIT_RUNTIME)
    print(f"every worker of council {council['id']} is cleaned up")
    return 0


def purge_due(council, cfg):
    if not council.get("sensitive") or council.get("purged_at") or council["state"] not in ("closed", "cancelled"):
        return False
    return now() >= parse_iso(council["closed_at"]) + cfg["purge_after_hours"] * 3600


def cmd_purge_due(args):
    cfg = load_config()
    if args.all:
        for path in sorted(DATA.glob("pal-*/consiglio.json")):
            council = json.loads(read(path))
            if purge_due(council, cfg):
                print(council["id"])
        return 0
    if not args.id:
        raise Stop("pass a council id or --all")
    return 0 if purge_due(load_council(args.id), cfg) else 1


def map_strings(value, rows):
    if isinstance(value, str):
        return apply_map(value, rows)
    if isinstance(value, list):
        return [map_strings(v, rows) for v in value]
    if isinstance(value, dict):
        return {k: map_strings(v, rows) for k, v in value.items()}
    return value


def cmd_purge(args):
    council = load_council(args.id)
    cdir = council_dir(council["id"])
    if council.get("purged_at"):
        print(f"council {council['id']} was already purged at {council['purged_at']}")
        return 0
    if not council.get("sensitive"):
        print(f"council {council['id']} is not sensitive; there is nothing to purge")
        return 0
    if council["state"] not in ("closed", "cancelled") and not args.force:
        raise Stop("the council is still open and needs its map; close or cancel it first (or --force on the captain's word)")
    rows = load_entities(cdir)
    targets = [p for p in cdir.rglob("*") if p.is_file() and p.suffix in (".md", ".json")
               and not {"allegati"} & set(p.relative_to(cdir).parts) and p.name not in ("entita.md", "pseudo.json")]
    for seat in council["seats"] + ([council["researcher"]] if council.get("researcher") else []):
        for name in ("brief.md", "report.md"):
            path = DATA / seat["task_id"] / name
            if path.is_file():
                targets.append(path)
    for path in targets:
        text = read(path)
        if path.name == "consiglio.json":
            new = json.dumps(map_strings(json.loads(text), rows), indent=2, ensure_ascii=False) + "\n"
        else:
            new = apply_map(text, rows)
        if new != text:
            write_atomic(path, new)
    leftover = [str(p) for p in targets if leak_hits(read(p), rows)]
    if leftover:
        raise Stop(f"clear data survived in {', '.join(leftover)}; the map was kept", EXIT_RUNTIME)
    shutil.rmtree(cdir / "allegati", ignore_errors=True)
    (cdir / "entita.md").unlink(missing_ok=True)
    council = load_council(args.id)
    council["purged_at"] = iso(now())
    council["topic"] = apply_map(council["topic"], rows)
    save_council(council)
    if council.get("purge_watch"):
        run_tool([tool("WHEN", "fm-procevent-when.sh"), "retire", f"pal-purge-{council['id']}"], timeout=60)
    print(f"council {council['id']} purged: placeholder table and original attachments deleted, {len(targets)} file(s) left pseudonymised")
    return 0


def cmd_arm_purge(args):
    cfg = load_config()
    council = load_council(args.id)
    require_state(council, "closed", "cancelled")
    if not council.get("sensitive") or council.get("purged_at"):
        raise Stop("only a sensitive council that is not purged yet needs a purge watch")
    due = parse_iso(council["closed_at"]) + cfg["purge_after_hours"] * 3600
    deadline = int(max(due - now(), 0) + 7 * 86400)
    argv = [tool("WHEN", "fm-procevent-when.sh"), "arm", f"pal-purge-{council['id']}", "--interval", "600", "--stable", "1",
            "--deadline", str(deadline), "--condition", str(ENTRY), "purge-due", council["id"],
            "--action", str(ENTRY), "status", council["id"]]
    code, out, err = run_tool(argv, timeout=120)
    if code != 0:
        raise Stop(f"could not arm the purge watch: {(err or out).strip()[:400]}", EXIT_RUNTIME)
    council["purge_watch"] = True
    save_council(council)
    print(f"purge watch armed: it wakes firstmate from {iso(due)} to run purge {council['id']}")
    return 0


def cmd_catalog(args):
    cfg = load_config()
    raw = catalog_raw(args.harness)
    entries = parse_catalog(args.harness, raw) if raw else []
    if not entries:
        raise Stop(f"{args.harness}: model catalog unavailable", EXIT_RUNTIME)
    for model_id, _text in entries:
        print(f"model: {model_id}")
    for pick in ("top", "economy"):
        print(f"{pick}: {pick_model(cfg, args.harness, pick, entries) or '-'}")
    return 0


def cmd_status(args):
    council = load_council(args.id)
    cdir = council_dir(council["id"])
    costs = load_costs(cdir)
    rnd = current_round(council)
    print(f"council: {council['id']} ({council['state']}); topic: {council['topic']}")
    print(f"round: {rnd['n'] if rnd else 0} of {council['max_rounds']}" + (f" ({'closed' if rnd['closed'] else 'open until ' + rnd['deadline']})" if rnd else ""))
    for seat in council["seats"] + ([council["researcher"]] if council.get("researcher") else []):
        print(f"seat {seat['seat']}: {seat['harness']}/{seat['model']} {seat['status']}" + (f" - {seat['note']}" if seat["note"] else ""))
    print(f"spent: {eur(costs.get('spent_eur', 0.0))} of {eur(council['budget_eur'])} EUR")
    print(f"sensitive: {'yes' if council['sensitive'] else 'no'}; purged: {council.get('purged_at') or 'no'}")
    if council["closed_reason"]:
        print(f"closed: {council['closed_reason']}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fm-pal-council.sh", add_help=True,
                                 description="pal-council mechanics; bin/fm-pal-council.sh --help is the command reference")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("new")
    p.add_argument("topic")
    p.add_argument("--tier", choices=None)
    p.add_argument("--participants")
    p.add_argument("--rounds", type=int)
    p.add_argument("--budget", type=float)
    p.add_argument("--attach", action="append", default=[])
    p.add_argument("--inherit", action="append", default=[])
    p.add_argument("--project")
    p.add_argument("--sensitive", action="store_true")
    p.add_argument("--language")
    p.add_argument("--slug")
    p.add_argument("--round-timeout", type=int)
    p.add_argument("--single-provider-ok", action="store_true")
    p.add_argument("--like")
    p.set_defaults(fn=cmd_new)

    p = sub.add_parser("prior")
    p.add_argument("id")
    p.add_argument("prior", nargs="?")
    p.add_argument("--file")
    p.add_argument("--none", action="store_true")
    p.set_defaults(fn=cmd_prior)

    p = sub.add_parser("pseudo")
    p.add_argument("id")
    p.add_argument("--source", action="append", default=[])
    p.add_argument("--add", action="append", default=[])
    p.add_argument("--skip-model", action="store_true")
    p.set_defaults(fn=cmd_pseudo)

    p = sub.add_parser("check")
    p.add_argument("id")
    p.add_argument("files", nargs="+")
    p.add_argument("--trusted", action="store_true")
    p.set_defaults(fn=cmd_check)

    for name, fn in (("estimate", cmd_estimate), ("launch", cmd_launch), ("barrier", cmd_barrier), ("research", cmd_research),
                     ("next", cmd_next), ("finalize", cmd_finalize), ("rag", cmd_rag), ("rag-query", cmd_rag_query),
                     ("cleanup", cmd_cleanup), ("arm-purge", cmd_arm_purge), ("status", cmd_status)):
        p = sub.add_parser(name)
        p.add_argument("id")
        p.set_defaults(fn=fn)

    p = sub.add_parser("catalog")
    p.add_argument("harness", choices=sorted(CATALOG_COMMANDS))
    p.set_defaults(fn=cmd_catalog)

    p = sub.add_parser("close-round")
    p.add_argument("id")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_close_round)

    p = sub.add_parser("summary")
    p.add_argument("id")
    p.add_argument("file")
    p.set_defaults(fn=cmd_summary)

    p = sub.add_parser("dossier")
    p.add_argument("id")
    p.add_argument("--failed", action="store_true")
    p.set_defaults(fn=cmd_dossier)

    p = sub.add_parser("message")
    p.add_argument("id")
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--all", action="store_true")
    group.add_argument("--seat")
    p.add_argument("--file", required=True)
    p.add_argument("--now", action="store_true")
    p.set_defaults(fn=cmd_message)

    p = sub.add_parser("drop")
    p.add_argument("id")
    p.add_argument("seat")
    p.add_argument("--reason", required=True)
    p.set_defaults(fn=cmd_drop)

    p = sub.add_parser("close")
    p.add_argument("id")
    p.add_argument("--reason", required=True)
    p.set_defaults(fn=cmd_close)

    p = sub.add_parser("cancel")
    p.add_argument("id")
    p.add_argument("--reason", default="")
    p.set_defaults(fn=cmd_cancel)

    p = sub.add_parser("rag-done")
    p.add_argument("id")
    p.add_argument("payload")
    p.add_argument("point_id")
    p.set_defaults(fn=cmd_rag_done)

    p = sub.add_parser("complete")
    p.add_argument("id")
    p.add_argument("holds", nargs="*")
    p.add_argument("--none", action="store_true")
    p.set_defaults(fn=cmd_complete)

    p = sub.add_parser("purge")
    p.add_argument("id")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_purge)

    p = sub.add_parser("purge-due")
    p.add_argument("id", nargs="?")
    p.add_argument("--all", action="store_true")
    p.set_defaults(fn=cmd_purge_due)

    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except Stop as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return exc.code


if __name__ == "__main__":
    sys.exit(main())
