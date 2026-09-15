import re

from django.conf import settings
from django.core.management.base import BaseCommand
from rapidfuzz import fuzz

from matching.models import Contact, Match, Target

ENTITY_SUFFIXES = re.compile(
    r"\b(llc|l\.l\.c\.|inc|inc\.|incorporated|corp|corp\.|corporation|co|co\.|"
    r"llp|lp|ltd|ltd\.|holdings|realty|properties|management|group)\b",
    re.IGNORECASE,
)


def normalize(value):
    if not value:
        return ""
    value = value.lower()
    value = ENTITY_SUFFIXES.sub("", value)
    value = re.sub(r"[^a-z0-9\s]", "", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value


class Command(BaseCommand):
    help = (
        "Compute candidate connections between imported contacts and the "
        "target (building owner) list. Creates pending Match rows for a "
        "human to confirm or reject; never auto-confirms anything."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            "--threshold",
            type=int,
            default=None,
            help="Override the minimum match score (0-100, default from MATCH_SCORE_THRESHOLD setting)",
        )

    def handle(self, *args, **options):
        threshold = options["threshold"] or settings.MATCH_SCORE_THRESHOLD

        contacts = list(Contact.objects.all())
        targets = list(Target.objects.all())

        if not contacts or not targets:
            self.stdout.write(self.style.WARNING("Need at least one Contact and one Target to match."))
            return

        norm_contacts = [
            (c, normalize(c.full_name), normalize(c.company), (c.email.split("@")[-1].lower() if c.email and "@" in c.email else ""))
            for c in contacts
        ]

        created = 0
        checked = 0
        for target in targets:
            target_owner_norm = normalize(target.owner_name)
            target_entity_norm = normalize(target.entity_name)

            for contact, contact_name_norm, contact_company_norm, contact_email_domain in norm_contacts:
                checked += 1
                best_score = 0.0
                matched_on = []

                if target_owner_norm and contact_name_norm:
                    score = fuzz.token_sort_ratio(target_owner_norm, contact_name_norm)
                    if score > best_score:
                        best_score = score
                    if score >= threshold:
                        matched_on.append(f"owner name ~ contact name ({score:.0f}%)")

                if target_entity_norm and contact_company_norm:
                    score = fuzz.token_sort_ratio(target_entity_norm, contact_company_norm)
                    if score > best_score:
                        best_score = score
                    if score >= threshold:
                        matched_on.append(f"entity name ~ contact company ({score:.0f}%)")

                if target_owner_norm and contact_company_norm:
                    score = fuzz.token_set_ratio(target_owner_norm, contact_company_norm)
                    if score > best_score:
                        best_score = score
                    if score >= threshold:
                        matched_on.append(f"owner name ~ contact company ({score:.0f}%)")

                if best_score < threshold or not matched_on:
                    continue

                _, created_flag = Match.objects.get_or_create(
                    target=target,
                    contact=contact,
                    defaults={
                        "match_confidence": best_score,
                        "matched_on": "; ".join(matched_on),
                    },
                )
                if created_flag:
                    created += 1

        self.stdout.write(self.style.SUCCESS(
            f"Checked {checked} target/contact pair(s), created {created} new candidate match(es) "
            f"at threshold {threshold}. Existing matches were left untouched."
        ))
