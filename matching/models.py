from django.conf import settings
from django.db import models


class ContactImport(models.Model):
    """One CSV upload of a partner's own contacts/connections."""

    class SourceType(models.TextChoices):
        LINKEDIN = "linkedin", "LinkedIn export"
        PHONE = "phone", "Phone contacts export"
        EMAIL = "email", "Email address book export"
        OTHER = "other", "Other"

    partner = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="contact_imports"
    )
    source_type = models.CharField(max_length=20, choices=SourceType.choices)
    file_name = models.CharField(max_length=255, blank=True)
    row_count = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.partner} / {self.get_source_type_display()} ({self.created_at:%Y-%m-%d})"


class Contact(models.Model):
    """A person from a partner's own, self-exported contact/connection data.

    Every row here is data the importing partner already had legitimate
    access to (their own LinkedIn export, phone contacts, or email address
    book) -- never scraped from a third party's account.
    """

    class Degree(models.TextChoices):
        FIRST = "1st", "1st-degree (direct contact)"
        SECOND = "2nd", "2nd-degree (mutual connection)"

    partner = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="contacts"
    )
    import_batch = models.ForeignKey(
        ContactImport, on_delete=models.CASCADE, related_name="contacts", null=True, blank=True
    )
    full_name = models.CharField(max_length=255)
    email = models.EmailField(blank=True)
    phone = models.CharField(max_length=50, blank=True)
    company = models.CharField(max_length=255, blank=True)
    degree = models.CharField(max_length=3, choices=Degree.choices, default=Degree.FIRST)
    raw_data = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [
            models.Index(fields=["full_name"]),
            models.Index(fields=["email"]),
            models.Index(fields=["company"]),
        ]

    def __str__(self):
        return f"{self.full_name} ({self.partner})"


class TargetImport(models.Model):
    """One CSV upload of the building-owner / hail-damage lead list."""

    file_name = models.CharField(max_length=255, blank=True)
    row_count = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Target import ({self.created_at:%Y-%m-%d}) - {self.row_count} rows"


class Target(models.Model):
    """A commercial building owner with known hail damage."""

    owner_name = models.CharField(max_length=255)
    entity_name = models.CharField(max_length=255, blank=True, help_text="LLC / holding entity, if different from owner_name")
    address = models.CharField(max_length=255, blank=True)
    city = models.CharField(max_length=100, blank=True)
    state = models.CharField(max_length=50, blank=True)
    zip_code = models.CharField(max_length=20, blank=True)
    damage_type = models.CharField(max_length=100, default="hail")
    damage_date = models.DateField(null=True, blank=True)
    source_notes = models.TextField(blank=True)
    import_batch = models.ForeignKey(
        TargetImport, on_delete=models.CASCADE, related_name="targets", null=True, blank=True
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [
            models.Index(fields=["owner_name"]),
            models.Index(fields=["entity_name"]),
        ]

    def __str__(self):
        return self.owner_name

    @property
    def best_match(self):
        status_priority = {"confirmed": 0, "pending": 1, "rejected": 2}
        matches = list(self.matches.all())
        if not matches:
            return None
        return sorted(matches, key=lambda m: (status_priority[m.status], -m.match_confidence))[0]


class Match(models.Model):
    """A candidate or confirmed path from a partner's contact to a target."""

    class Status(models.TextChoices):
        PENDING = "pending", "Pending review"
        CONFIRMED = "confirmed", "Confirmed connection"
        REJECTED = "rejected", "Not a real connection"

    target = models.ForeignKey(Target, on_delete=models.CASCADE, related_name="matches")
    contact = models.ForeignKey(Contact, on_delete=models.CASCADE, related_name="matches")
    match_confidence = models.FloatField(help_text="0-100 fuzzy match score")
    matched_on = models.CharField(max_length=255, help_text="Which fields produced the match")
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.PENDING)
    reviewed_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True, blank=True, related_name="reviewed_matches"
    )
    reviewed_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["target", "contact"], name="unique_target_contact_match")
        ]
        ordering = ["-match_confidence"]

    @property
    def partner(self):
        return self.contact.partner

    def __str__(self):
        return f"{self.target} <-> {self.contact} ({self.match_confidence:.0f}%)"
