"""Participant roster: the only key linking names to study IDs.

CSV columns (header required, case-insensitive):

    study_id, first_name, last_name, aliases

``aliases`` is a pipe- or semicolon-separated list of nicknames, initials,
maiden names, or however the transcriber spelt the name.  Extra columns are
ignored so a REDCap export can be used directly.
"""

from __future__ import annotations

import csv
import re
from dataclasses import dataclass, field
from pathlib import Path

from rapidfuzz import fuzz

# Common English words that are also first names; single-token matches on
# these require a capital letter to count.
AMBIGUOUS_NAMES = {
    "hope", "will", "grace", "joy", "faith", "may", "june", "april", "rose",
    "bill", "mark", "art", "guy", "chase", "lane", "pat", "sue", "dawn",
    "summer", "autumn", "sunny", "chris", "jack", "jay", "ray", "ken", "don",
    "gene", "frank", "rich", "victor", "carol", "holly", "ivy", "lily",
    "penny", "ruby", "amber", "crystal", "destiny", "jasmine", "olive",
    "wade", "grant", "hunter", "miles", "reed", "ward", "wells", "young",
    "brown", "white", "green", "black", "gray", "grey", "stone", "wood",
    "hill", "rivers", "bishop", "king", "knight", "page", "price", "long",
    "short", "little", "best", "moody", "bright", "bond", "north", "west",
}


@dataclass
class Participant:
    study_id: str
    first_name: str
    last_name: str
    aliases: list[str] = field(default_factory=list)

    @property
    def full_name(self) -> str:
        return " ".join(p for p in (self.first_name, self.last_name) if p)

    def name_forms(self) -> list[tuple[str, str]]:
        """(form, kind) pairs to search for, longest first."""
        forms: list[tuple[str, str]] = []
        if self.first_name and self.last_name:
            forms.append((self.full_name, "full"))
            forms.append((f"{self.last_name}, {self.first_name}", "full"))
            forms.append((f"{self.first_name[0]}. {self.last_name}", "full"))
            forms.append((f"{self.first_name[0]}{self.last_name[0]}", "initials"))
        for a in self.aliases:
            forms.append((a, "alias"))
        if self.first_name:
            forms.append((self.first_name, "first"))
        if self.last_name:
            forms.append((self.last_name, "last"))
        seen: set[str] = set()
        out: list[tuple[str, str]] = []
        for f, k in sorted(forms, key=lambda x: -len(x[0])):
            key = f.lower()
            if key and key not in seen:
                seen.add(key)
                out.append((f, k))
        return out


@dataclass
class RosterMatch:
    start: int
    end: int
    text: str
    participant: Participant
    kind: str
    confidence: float


class Roster:
    def __init__(self, participants: list[Participant]):
        self.participants = participants
        self._compiled: list[tuple[re.Pattern[str], Participant, str, str]] = []
        for p in participants:
            for form, kind in p.name_forms():
                # Case-sensitive for single tokens that double as words,
                # case-insensitive otherwise.
                flags = 0 if (kind in {"first", "last", "alias"} and form.lower() in AMBIGUOUS_NAMES) else re.IGNORECASE
                if kind == "initials":
                    pattern = rf"(?<![A-Za-z]){re.escape(form)}(?![A-Za-z])"
                    flags = 0
                else:
                    pattern = rf"(?<![A-Za-z]){re.escape(form)}(?:'s)?(?![A-Za-z])"
                self._compiled.append((re.compile(pattern, flags), p, form, kind))
        self._fuzzy_tokens: list[tuple[str, Participant, str]] = [
            (form.lower(), p, kind)
            for p in participants
            for form, kind in p.name_forms()
            if " " not in form and len(form) >= 4 and kind != "initials"
        ]
        self.by_id = {p.study_id: p for p in participants}

    def __len__(self) -> int:
        return len(self.participants)

    @classmethod
    def from_csv(cls, path: str | Path) -> "Roster":
        path = Path(path)
        participants: list[Participant] = []
        with path.open(newline="", encoding="utf-8-sig") as fh:
            reader = csv.DictReader(fh)
            if reader.fieldnames is None:
                raise ValueError(f"{path}: empty roster")
            cols = {c.lower().strip(): c for c in reader.fieldnames}
            if "study_id" not in cols:
                raise ValueError(f"{path}: roster needs a 'study_id' column")
            for row in reader:
                sid = (row.get(cols["study_id"]) or "").strip()
                if not sid:
                    continue
                aliases_raw = row.get(cols.get("aliases", ""), "") or ""
                aliases = [a.strip() for a in re.split(r"[|;]", aliases_raw) if a.strip()]
                participants.append(
                    Participant(
                        study_id=sid,
                        first_name=(row.get(cols.get("first_name", ""), "") or "").strip(),
                        last_name=(row.get(cols.get("last_name", ""), "") or "").strip(),
                        aliases=aliases,
                    )
                )
        return cls(participants)

    def to_csv(self, path: str | Path) -> None:
        with Path(path).open("w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["study_id", "first_name", "last_name", "aliases"])
            for p in self.participants:
                w.writerow([p.study_id, p.first_name, p.last_name, "|".join(p.aliases)])

    def add_alias(self, study_id: str, alias: str) -> None:
        p = self.by_id[study_id]
        if alias not in p.aliases:
            p.aliases.append(alias)
        self.__init__(self.participants)  # recompile

    def add_participant(self, p: Participant) -> None:
        self.participants.append(p)
        self.__init__(self.participants)

    def find(self, text: str, fuzzy: bool = True, fuzzy_threshold: float = 85.0) -> list[RosterMatch]:
        matches: list[RosterMatch] = []
        for rx, p, form, kind in self._compiled:
            for m in rx.finditer(text):
                conf = {"full": 0.99, "alias": 0.95, "first": 0.9, "last": 0.85, "initials": 0.6}[kind]
                matches.append(RosterMatch(m.start(), m.end(), m.group(0), p, kind, conf))
        if fuzzy and self._fuzzy_tokens:
            for m in re.finditer(r"[A-Za-z][A-Za-z'\-]{3,}", text):
                tok = m.group(0)
                tok_l = tok.lower().rstrip("'s") if tok.lower().endswith("'s") else tok.lower()
                if len(tok_l) < 4:
                    continue
                best: tuple[float, Participant, str] | None = None
                for form, p, kind in self._fuzzy_tokens:
                    if form == tok_l:
                        continue  # exact matches already handled
                    score = fuzz.ratio(form, tok_l)
                    if score >= fuzzy_threshold and (best is None or score > best[0]):
                        best = (score, p, kind)
                if best and tok[0].isupper():
                    matches.append(
                        RosterMatch(m.start(), m.end(), tok, best[1], f"fuzzy-{best[2]}", round(best[0] / 100 * 0.8, 2))
                    )
        return _dedupe(matches)


def _dedupe(matches: list[RosterMatch]) -> list[RosterMatch]:
    """Drop matches fully contained in a longer/higher-confidence match."""
    matches.sort(key=lambda m: (m.start, -(m.end - m.start), -m.confidence))
    kept: list[RosterMatch] = []
    for m in matches:
        if kept and m.start < kept[-1].end:
            continue
        kept.append(m)
    return kept
