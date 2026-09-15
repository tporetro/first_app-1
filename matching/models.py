from django.conf import settings
from django.db import models


class ContactImport(models.Model):
    """One CSV upload of a partner's own contacts/connections."""

    class SourceType(models.TextChoices):
        LINKEDIN = "linkedin", "LinkedIn export"
        FACEBOOK = "facebook", "Facebook friends export"
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
    ticker = models.CharField(
        max_length=10, blank=True,
        help_text="Stock ticker, only if the owning entity is a public company (e.g. a REIT). Leave blank for private LLCs -- enables SEC filings research when set.",
    )
    address = models.CharField(max_length=255, blank=True)
    city = models.CharField(max_length=100, blank=True)
    state = models.CharField(max_length=50, blank=True)
    zip_code = models.CharField(max_length=20, blank=True)
    phone = models.CharField(max_length=50, blank=True, help_text="Owner's direct phone, if known -- for reaching them without a warm path")
    email = models.EmailField(blank=True, help_text="Owner's direct email, if known -- for reaching them without a warm path")
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


class PropertyResearchRun(models.Model):
    """One research pass over public sources for a target's property/entity."""

    class Status(models.TextChoices):
        PENDING = "pending", "Pending"
        RUNNING = "running", "Running"
        DONE = "done", "Done"
        FAILED = "failed", "Failed"

    target = models.ForeignKey(Target, on_delete=models.CASCADE, related_name="research_runs")
    requested_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True)
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.PENDING)
    error_message = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    finished_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"Research run for {self.target} ({self.status})"


class PropertyFinding(models.Model):
    """A single fact surfaced about a target's building or business entity.

    Scope is deliberately limited to the property and the business entity
    that owns it -- roof/building condition, tenant complaints, permits,
    code violations, litigation, and entity-level business news. This is
    never used to store personal/biographical facts about the owner as an
    individual (life events, health, personal philanthropy, family
    matters): those are out of scope by design, not just by omission.
    """

    class FindingType(models.TextChoices):
        COMPLAINT = "complaint", "Tenant/public complaint"
        PERMIT = "permit", "Building permit or code violation"
        DAMAGE = "damage", "Reported damage or storm event"
        NEWS = "news", "Business/entity news"
        LITIGATION = "litigation", "Litigation or regulatory action"
        OTHER = "other", "Other property/entity fact"

    target = models.ForeignKey(Target, on_delete=models.CASCADE, related_name="findings")
    research_run = models.ForeignKey(
        PropertyResearchRun, on_delete=models.CASCADE, related_name="findings", null=True, blank=True
    )
    finding_type = models.CharField(max_length=20, choices=FindingType.choices, default=FindingType.OTHER)
    summary = models.TextField(help_text="Factual, property/entity-level summary of what was found")
    source_url = models.URLField(blank=True)
    source_name = models.CharField(max_length=255, blank=True)
    published_at = models.DateField(null=True, blank=True)
    relevance_score = models.FloatField(default=0.0, help_text="0-100, how relevant this is to a hail-damage claim")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-relevance_score", "-created_at"]

    def __str__(self):
        return f"{self.get_finding_type_display()}: {self.summary[:60]}"
