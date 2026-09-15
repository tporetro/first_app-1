"""Shared logic for importing contacts/targets and computing matches.

Used by both the management commands (CLI) and the web upload views, so
there is exactly one code path for each operation.
"""
import re

from django.conf import settings
from django.db import transaction
from rapidfuzz import fuzz

from .importers import parse_facebook_export, parse_generic_contacts, parse_linkedin_export, parse_targets
from .models import Contact, ContactImport, Match, Target, TargetImport

CONTACT_PARSERS = {
    ContactImport.SourceType.LINKEDIN: parse_linkedin_export,
    ContactImport.SourceType.FACEBOOK: parse_facebook_export,
    ContactImport.SourceType.PHONE: parse_generic_contacts,
    ContactImport.SourceType.EMAIL: parse_generic_contacts,
    ContactImport.SourceType.OTHER: parse_generic_contacts,
}

ENTITY_SUFFIXES = re.compile(
    r"\b(llc|l\.l\.c\.|inc|inc\.|incorporated|corp|corp\.|corporation|co|co\.|"
    r"llp|lp|ltd|ltd\.|holdings|realty|properties|management|group)\b",
    re.IGNORECASE,
)


class ImportError_(Exception):
    """Raised when a CSV can't be parsed; carries a user-facing message."""


def normalize(value):
    if not value:
        return ""
    value = value.lower()
    value = ENTITY_SUFFIXES.sub("", value)
    value = re.sub(r"[^a-z0-9\s]", "", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value


def import_contacts_from_file(partner, source_type, file_obj, degree, file_name=""):
    parser_fn = CONTACT_PARSERS[source_type]
    try:
        records = parser_fn(file_obj)
    except ValueError as e:
        raise ImportError_(str(e))

    if not records:
        return None, 0

    with transaction.atomic():
        batch = ContactImport.objects.create(
            partner=partner,
            source_type=source_type,
            file_name=file_name,
            row_count=len(records),
        )
        Contact.objects.bulk_create([
            Contact(
                partner=partner,
                import_batch=batch,
                full_name=r["full_name"],
                email=r.get("email", ""),
                phone=r.get("phone", ""),
                company=r.get("company", ""),
                degree=degree,
                raw_data=r.get("raw_data", {}),
            )
            for r in records
        ])
    return batch, len(records)


def create_manual_contacts(partner, contacts_data, degree, source_type=ContactImport.SourceType.PHONE, file_name="Manual entry"):
    """Creates one or more contacts a partner entered/picked directly,
    rather than importing from a file. Used by the manual add-a-contact
    form and the browser Contact Picker flow -- both are still the
    partner adding their own contacts, so they share the same batch-based
    provenance as file imports.

    contacts_data: iterable of dicts with at least "full_name", plus any
    of "email", "phone", "company".
    """
    records = [r for r in contacts_data if r.get("full_name", "").strip()]
    if not records:
        return None, 0

    with transaction.atomic():
        batch = ContactImport.objects.create(
            partner=partner,
            source_type=source_type,
            file_name=file_name,
            row_count=len(records),
        )
        Contact.objects.bulk_create([
            Contact(
                partner=partner,
                import_batch=batch,
                full_name=r["full_name"].strip(),
                email=r.get("email", "") or "",
                phone=r.get("phone", "") or "",
                company=r.get("company", "") or "",
                degree=degree,
                raw_data=r.get("raw_data", {}),
            )
            for r in records
        ])
    return batch, len(records)


def import_targets_from_file(file_obj, file_name=""):
    from datetime import datetime

    date_formats = ["%Y-%m-%d", "%m/%d/%Y", "%m-%d-%Y"]

    def parse_date(value):
        if not value:
            return None
        for fmt in date_formats:
            try:
                return datetime.strptime(value, fmt).date()
            except ValueError:
                continue
        return None

    try:
        records = parse_targets(file_obj)
    except ValueError as e:
        raise ImportError_(str(e))

    if not records:
        return None, 0

    with transaction.atomic():
        batch = TargetImport.objects.create(file_name=file_name, row_count=len(records))
        Target.objects.bulk_create([
            Target(
                import_batch=batch,
                owner_name=r["owner_name"],
                entity_name=r.get("entity_name", ""),
                address=r.get("address", ""),
                city=r.get("city", ""),
                state=r.get("state", ""),
                zip_code=r.get("zip_code", ""),
                damage_type=r.get("damage_type") or "hail",
                damage_date=parse_date(r.get("damage_date", "")),
                source_notes=r.get("source_notes", ""),
            )
            for r in records
        ])
    return batch, len(records)


def run_matching(threshold=None):
    threshold = threshold or settings.MATCH_SCORE_THRESHOLD

    contacts = list(Contact.objects.all())
    targets = list(Target.objects.all())

    if not contacts or not targets:
        return 0, 0

    norm_contacts = [
        (c, normalize(c.full_name), normalize(c.company))
        for c in contacts
    ]

    created = 0
    checked = 0
    for target in targets:
        target_owner_norm = normalize(target.owner_name)
        target_entity_norm = normalize(target.entity_name)

        for contact, contact_name_norm, contact_company_norm in norm_contacts:
            checked += 1
            best_score = 0.0
            matched_on = []

            if target_owner_norm and contact_name_norm:
                score = fuzz.token_sort_ratio(target_owner_norm, contact_name_norm)
                best_score = max(best_score, score)
                if score >= threshold:
                    matched_on.append(f"owner name ~ contact name ({score:.0f}%)")

            if target_entity_norm and contact_company_norm:
                score = fuzz.token_sort_ratio(target_entity_norm, contact_company_norm)
                best_score = max(best_score, score)
                if score >= threshold:
                    matched_on.append(f"entity name ~ contact company ({score:.0f}%)")

            if target_owner_norm and contact_company_norm:
                score = fuzz.token_set_ratio(target_owner_norm, contact_company_norm)
                best_score = max(best_score, score)
                if score >= threshold:
                    matched_on.append(f"owner name ~ contact company ({score:.0f}%)")

            if best_score < threshold or not matched_on:
                continue

            _, created_flag = Match.objects.get_or_create(
                target=target,
                contact=contact,
                defaults={"match_confidence": best_score, "matched_on": "; ".join(matched_on)},
            )
            if created_flag:
                created += 1

    return checked, created
