"""spaCy + Presidio wrapper.  Loaded lazily, entirely offline.

The spaCy model is installed as a pip package (see pyproject) so no download
happens at runtime.  Presidio adds its rule-based recognisers (SSN, phone,
email, ...) on top of spaCy NER; we take PERSON / LOCATION / ORGANIZATION
from NER and let ``phi.py`` regexes cover the rest, using Presidio mainly for
its context-aware scoring and checksum validators.
"""

from __future__ import annotations

import logging
import re
from functools import lru_cache

from .hits import Hit

log = logging.getLogger(__name__)

DEFAULT_MODEL = "en_core_web_lg"

# spaCy label -> our flag type
NER_MAP = {
    "PERSON": "NAME",
    "GPE": "LOCATION",
    "LOC": "LOCATION",
    "FAC": "LOCATION",
    "ORG": "ORGANIZATION",
    "DATE": "DATE",
}

PRESIDIO_MAP = {
    "PERSON": "NAME",
    "PHONE_NUMBER": "PHONE",
    "EMAIL_ADDRESS": "EMAIL",
    "US_SSN": "SSN",
    "URL": "URL",
    "IP_ADDRESS": "URL",
    "CREDIT_CARD": "ID_NUMBER",
    "US_DRIVER_LICENSE": "ID_NUMBER",
    "US_PASSPORT": "ID_NUMBER",
    "US_BANK_NUMBER": "ID_NUMBER",
    "MEDICAL_LICENSE": "ID_NUMBER",
    "LOCATION": "LOCATION",
    "DATE_TIME": "DATE",
}

# DATE entities with none of these are durations ("two weeks"), not PHI.
_DATE_SIGNAL = re.compile(
    r"\d|\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|monday|tuesday|wednesday|thursday|friday|saturday|sunday|"
    r"christmas|thanksgiving|easter|halloween|birthday)",
    re.I,
)
_YEAR_ONLY = re.compile(r"^\s*(?:19|20)\d{2}\s*$")
_BARE_NUMBER = re.compile(r"^\s*\d+\s*$")
# Capitalised sentence-starters spaCy likes to call PERSON.
_NOT_NAMES = {"email", "text", "call", "okay", "ok", "yeah", "yes", "no", "um", "uh", "like", "well", "right", "sure",
              "honestly", "mom", "dad", "mum", "grandma", "grandpa", "nana", "papa", "interviewer", "participant",
              "speaker", "thanks", "thank", "hi", "hello", "hey", "so", "and", "but", "also", "anyway", "cool", "wow",
              "god", "jesus", "christ", "lord", "google", "siri", "alexa", "netflix", "covid", "zoom"}
_LOC_GENERIC = {"home", "school", "work", "church", "hospital", "the hospital", "the er", "er", "the emergency room", "college", "the store", "downtown", "the city", "the country", "town", "the park"}
_ORG_GENERIC = {"cps", "dcf", "dcfs", "fbi", "irs", "nih", "cdc", "who", "covid", "covid-19", "instagram", "facebook", "tiktok", "snapchat", "twitter", "youtube", "google", "amazon", "netflix", "discord", "reddit", "zoom", "ai", "gpt", "chatgpt", "ssri", "adhd", "ptsd", "ocd", "dbt", "cbt", "ema", "redcap"}


def _force_tldextract_offline() -> None:
    """Presidio's email recogniser calls tldextract, which by default tries to
    refresh the public-suffix list from the internet.  Pin it to the bundled
    snapshot so nothing ever leaves the machine."""
    try:
        import tldextract

        tldextract.extract = tldextract.TLDExtract(suffix_list_urls=(), fallback_to_snapshot=True)
    except Exception:  # pragma: no cover
        pass


class NlpEngine:
    def __init__(self, model: str = DEFAULT_MODEL, use_presidio: bool = True):
        import spacy

        self.model_name = model
        self.nlp = spacy.load(model, disable=["lemmatizer", "textcat"])
        self.analyzer = None
        if use_presidio:
            try:
                _force_tldextract_offline()
                from presidio_analyzer import AnalyzerEngine
                from presidio_analyzer.nlp_engine import NlpEngineProvider

                logging.getLogger("presidio-analyzer").setLevel(logging.ERROR)
                provider = NlpEngineProvider(
                    nlp_configuration={
                        "nlp_engine_name": "spacy",
                        "models": [{"lang_code": "en", "model_name": model}],
                        "ner_model_configuration": {
                            "labels_to_ignore": ["CARDINAL", "ORDINAL", "QUANTITY", "MONEY", "PERCENT", "PRODUCT",
                                                 "EVENT", "WORK_OF_ART", "LAW", "LANGUAGE", "TIME", "FAC", "NORP"],
                        },
                    }
                )
                self.analyzer = AnalyzerEngine(nlp_engine=provider.create_engine(), supported_languages=["en"])
            except Exception as e:  # pragma: no cover - depends on install
                log.warning("Presidio unavailable, using spaCy NER only: %s", e)
                self.analyzer = None

    # ------------------------------------------------------------------ vocab
    def is_oov(self, word: str) -> bool:
        lex = self.nlp.vocab[word.lower()]
        # With vector models ``is_oov`` means "no word vector".  Without
        # vectors (sm model) every word is OOV, so fall back to lexeme prob.
        if self.nlp.vocab.vectors.n_keys > 0:
            return lex.is_oov
        return lex.prob <= -20.0

    # -------------------------------------------------------------------- NER
    def analyze(self, text: str) -> list[Hit]:
        if not text.strip():
            return []
        hits: list[Hit] = []
        doc = self.nlp(text)
        for ent in doc.ents:
            typ = NER_MAP.get(ent.label_)
            if not typ:
                continue
            conf = 0.85
            note = ""
            low = ent.text.lower().strip()
            if typ == "DATE":
                if _YEAR_ONLY.match(ent.text) or _BARE_NUMBER.match(ent.text):
                    continue  # year alone is not PHI under Safe Harbor; bare numbers are not dates
                if not _DATE_SIGNAL.search(ent.text):
                    continue  # durations / relative phrases
                conf = 0.6 if not re.search(r"\d", ent.text) else 0.8
                note = "spaCy DATE"
            elif typ == "LOCATION":
                if low in _LOC_GENERIC or len(low) < 3:
                    continue
                conf = 0.75
                note = f"spaCy {ent.label_}"
            elif typ == "ORGANIZATION":
                if low in _ORG_GENERIC or len(low) < 3:
                    continue
                conf = 0.6
                note = "spaCy ORG"
            elif typ == "NAME":
                if low in _NOT_NAMES:
                    continue
                conf = 0.85
                if not any(t.text[:1].isupper() for t in ent):
                    conf = 0.55
                    note = "lowercase PERSON"
                if len(low) < 2:
                    continue
            hits.append(Hit(ent.start_char, ent.end_char, ent.text, typ, conf, "ner", note, ent.label_))

        if self.analyzer is not None:
            try:
                results = self.analyzer.analyze(text=text, language="en", score_threshold=0.35)
            except Exception as e:  # pragma: no cover
                log.warning("Presidio analyze failed: %s", e)
                results = []
            for r in results:
                typ = PRESIDIO_MAP.get(r.entity_type)
                if not typ:
                    continue
                span = text[r.start : r.end]
                if typ == "DATE":
                    if _YEAR_ONLY.match(span) or _BARE_NUMBER.match(span) or not _DATE_SIGNAL.search(span):
                        continue
                if typ == "NAME" and span.lower().strip() in _NOT_NAMES:
                    continue
                if typ == "LOCATION" and span.lower().strip() in _LOC_GENERIC:
                    continue
                hits.append(Hit(r.start, r.end, span, typ, round(float(r.score), 2), "presidio", "", r.entity_type))
        return hits


@lru_cache(maxsize=2)
def load_engine(model: str = DEFAULT_MODEL, use_presidio: bool = True) -> NlpEngine:
    return NlpEngine(model, use_presidio)
