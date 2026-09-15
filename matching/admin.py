from django.contrib import admin
from django.utils import timezone

from .models import Contact, ContactImport, Match, PropertyFinding, PropertyResearchRun, Target, TargetImport


@admin.register(ContactImport)
class ContactImportAdmin(admin.ModelAdmin):
    list_display = ("partner", "source_type", "file_name", "row_count", "created_at")
    list_filter = ("source_type", "partner")
    readonly_fields = ("row_count", "created_at")

    def get_queryset(self, request):
        qs = super().get_queryset(request)
        if request.user.is_superuser:
            return qs
        return qs.filter(partner=request.user)

    def save_model(self, request, obj, form, change):
        if not change:
            obj.partner = request.user
        super().save_model(request, obj, form, change)


@admin.register(Contact)
class ContactAdmin(admin.ModelAdmin):
    list_display = ("full_name", "partner", "company", "degree", "email", "created_at")
    list_filter = ("partner", "degree", "import_batch__source_type")
    search_fields = ("full_name", "email", "company")

    def get_queryset(self, request):
        qs = super().get_queryset(request)
        if request.user.is_superuser:
            return qs
        return qs.filter(partner=request.user)

    def has_change_permission(self, request, obj=None):
        if obj is not None and not request.user.is_superuser and obj.partner != request.user:
            return False
        return super().has_change_permission(request, obj)


@admin.register(TargetImport)
class TargetImportAdmin(admin.ModelAdmin):
    list_display = ("file_name", "row_count", "created_at")
    readonly_fields = ("row_count", "created_at")


class MatchInline(admin.TabularInline):
    model = Match
    extra = 0
    fields = ("contact", "match_confidence", "matched_on", "status", "reviewed_by", "reviewed_at")
    readonly_fields = ("contact", "match_confidence", "matched_on", "reviewed_by", "reviewed_at")
    can_delete = False

    def has_add_permission(self, request, obj=None):
        return False


class PropertyFindingInline(admin.TabularInline):
    model = PropertyFinding
    extra = 0
    fields = ("finding_type", "summary", "relevance_score", "source_name", "source_url")
    readonly_fields = ("finding_type", "summary", "relevance_score", "source_name", "source_url")
    can_delete = False

    def has_add_permission(self, request, obj=None):
        return False


@admin.register(Target)
class TargetAdmin(admin.ModelAdmin):
    list_display = ("owner_name", "entity_name", "ticker", "city", "state", "damage_date", "match_status", "finding_count")
    list_filter = ("state", "damage_type")
    search_fields = ("owner_name", "entity_name", "ticker", "address", "city")
    inlines = [MatchInline, PropertyFindingInline]

    @admin.display(description="Findings")
    def finding_count(self, obj):
        return obj.findings.count()

    @admin.display(description="Best match")
    def match_status(self, obj):
        best = obj.best_match
        if not best:
            return "No known path"
        label = {
            "confirmed": "Confirmed",
            "pending": "Candidate (needs review)",
            "rejected": "Rejected",
        }[best.status]
        return f"{label} via {best.contact.partner} -> {best.contact.full_name} ({best.match_confidence:.0f}%)"


@admin.register(Match)
class MatchAdmin(admin.ModelAdmin):
    list_display = ("target", "contact", "partner_display", "match_confidence", "matched_on", "status", "reviewed_by")
    list_filter = ("status", "contact__partner")
    search_fields = ("target__owner_name", "contact__full_name")
    actions = ["confirm_matches", "reject_matches"]
    readonly_fields = ("target", "contact", "match_confidence", "matched_on", "created_at")

    @admin.display(description="Partner")
    def partner_display(self, obj):
        return obj.contact.partner

    @admin.action(description="Confirm selected matches as real connections")
    def confirm_matches(self, request, queryset):
        updated = queryset.update(status=Match.Status.CONFIRMED, reviewed_by=request.user, reviewed_at=timezone.now())
        self.message_user(request, f"Confirmed {updated} match(es).")

    @admin.action(description="Reject selected matches (not a real connection)")
    def reject_matches(self, request, queryset):
        updated = queryset.update(status=Match.Status.REJECTED, reviewed_by=request.user, reviewed_at=timezone.now())
        self.message_user(request, f"Rejected {updated} match(es).")


@admin.register(PropertyResearchRun)
class PropertyResearchRunAdmin(admin.ModelAdmin):
    list_display = ("target", "status", "requested_by", "created_at", "finished_at")
    list_filter = ("status",)
    readonly_fields = ("target", "requested_by", "status", "error_message", "created_at", "finished_at")


@admin.register(PropertyFinding)
class PropertyFindingAdmin(admin.ModelAdmin):
    list_display = ("target", "finding_type", "summary", "relevance_score", "source_name", "created_at")
    list_filter = ("finding_type",)
    search_fields = ("target__owner_name", "summary")
    readonly_fields = ("target", "research_run", "finding_type", "summary", "source_url", "source_name", "relevance_score", "created_at")
