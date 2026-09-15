import json

from django.contrib import messages
from django.contrib.auth.mixins import LoginRequiredMixin
from django.db.models import Prefetch
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect
from django.urls import reverse_lazy
from django.utils import timezone
from django.views import View
from django.views.generic import DetailView, FormView, ListView

from .forms import ContactImportForm, SingleContactForm, TargetImportForm
from .models import Contact, Match, PropertyResearchRun, Target
from .research import ResearchUnavailable, run_research
from .services import (
    ImportError_,
    create_manual_contacts,
    import_contacts_from_file,
    import_targets_from_file,
    run_matching,
)


class DashboardView(LoginRequiredMixin, ListView):
    model = Target
    template_name = "matching/dashboard.html"
    context_object_name = "targets"
    paginate_by = 50

    def get_queryset(self):
        qs = Target.objects.prefetch_related(
            Prefetch("matches", queryset=Match.objects.select_related("contact", "contact__partner"))
        )
        query = self.request.GET.get("q", "").strip()
        if query:
            qs = qs.filter(owner_name__icontains=query)
        return qs.order_by("owner_name")

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context["query"] = self.request.GET.get("q", "")
        targets = context["targets"]
        status_priority = {"confirmed": 0, "pending": 1, "rejected": 2, None: 3}
        rows = []
        for target in targets:
            matches = list(target.matches.all())
            best = None
            if matches:
                best = sorted(matches, key=lambda m: (status_priority[m.status], -m.match_confidence))[0]
            rows.append({"target": target, "best_match": best, "match_count": len(matches)})
        rows.sort(key=lambda r: status_priority[r["best_match"].status if r["best_match"] else None])
        context["rows"] = rows
        return context


class ContactImportView(LoginRequiredMixin, FormView):
    template_name = "matching/import_contacts.html"
    form_class = ContactImportForm
    success_url = reverse_lazy("import_contacts")

    def form_valid(self, form):
        upload = self.request.FILES["file"]
        try:
            batch, count = import_contacts_from_file(
                partner=self.request.user,
                source_type=form.cleaned_data["source_type"],
                file_obj=upload,
                degree=form.cleaned_data["degree"],
                file_name=upload.name,
            )
        except ImportError_ as e:
            messages.error(self.request, f"Could not import '{upload.name}': {e}")
            return redirect("import_contacts")

        if count == 0:
            messages.warning(self.request, f"No rows could be parsed from '{upload.name}'.")
        else:
            messages.success(self.request, f"Imported {count} contact(s) from '{upload.name}'.")
        return super().form_valid(form)


class TargetImportView(LoginRequiredMixin, FormView):
    template_name = "matching/import_targets.html"
    form_class = TargetImportForm
    success_url = reverse_lazy("import_targets")

    def form_valid(self, form):
        upload = self.request.FILES["file"]
        try:
            batch, count = import_targets_from_file(upload, file_name=upload.name)
        except ImportError_ as e:
            messages.error(self.request, f"Could not import '{upload.name}': {e}")
            return redirect("import_targets")

        if count == 0:
            messages.warning(self.request, f"No rows could be parsed from '{upload.name}'.")
        else:
            messages.success(self.request, f"Imported {count} target(s) from '{upload.name}'.")
        return super().form_valid(form)


class AddContactView(LoginRequiredMixin, FormView):
    """Manual quick-add for a single contact, plus (where the browser
    supports it) a "pick from phone contacts" button using the Contact
    Picker API -- see the bulk endpoint below for that path."""

    template_name = "matching/add_contact.html"
    form_class = SingleContactForm
    success_url = reverse_lazy("add_contact")

    def form_valid(self, form):
        data = form.cleaned_data
        batch, count = create_manual_contacts(
            partner=self.request.user,
            contacts_data=[{
                "full_name": data["full_name"],
                "phone": data["phone"],
                "email": data["email"],
                "company": data["company"],
            }],
            degree=data["degree"],
            file_name="Manual entry",
        )
        if count:
            messages.success(self.request, f"Added {data['full_name']} to your contacts.")
        return super().form_valid(form)


class BulkAddContactsView(LoginRequiredMixin, View):
    """POST-only JSON endpoint for the browser Contact Picker flow: the
    page's JS asks the OS for permission, the user picks contacts on
    their own device, and the picked list is posted here as JSON."""

    def post(self, request, *args, **kwargs):
        try:
            payload = json.loads(request.body)
            contacts = payload.get("contacts", [])
        except (json.JSONDecodeError, AttributeError):
            return JsonResponse({"error": "Invalid request body."}, status=400)

        if not isinstance(contacts, list):
            return JsonResponse({"error": "'contacts' must be a list."}, status=400)

        records = []
        for c in contacts:
            if not isinstance(c, dict):
                continue
            records.append({
                "full_name": (c.get("full_name") or "").strip(),
                "phone": (c.get("phone") or "").strip(),
                "email": (c.get("email") or "").strip(),
            })

        batch, count = create_manual_contacts(
            partner=request.user,
            contacts_data=records,
            degree=Contact.Degree.FIRST,
            file_name="Phone contact picker",
        )
        return JsonResponse({"added": count})


class RunMatchingView(LoginRequiredMixin, View):
    """POST-only trigger to (re)compute candidate matches."""

    def post(self, request, *args, **kwargs):
        checked, created = run_matching()
        if checked == 0:
            messages.warning(request, "Need at least one contact and one target before matching can run.")
        else:
            messages.success(request, f"Checked {checked} pair(s); found {created} new candidate match(es).")
        return redirect("dashboard")


class TargetDetailView(LoginRequiredMixin, DetailView):
    model = Target
    template_name = "matching/target_detail.html"
    context_object_name = "target"

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context["findings"] = self.object.findings.all()
        context["matches"] = self.object.matches.select_related("contact", "contact__partner").all()
        context["research_runs"] = self.object.research_runs.all()[:5]
        return context


class RunResearchView(LoginRequiredMixin, View):
    """POST-only trigger to run public-source property/entity research
    for one target. Scoped to the building and its owning business
    entity -- see matching/research.py for what is and isn't collected."""

    def post(self, request, *args, **kwargs):
        target = get_object_or_404(Target, pk=kwargs["pk"])
        run = PropertyResearchRun.objects.create(
            target=target, requested_by=request.user, status=PropertyResearchRun.Status.RUNNING
        )
        try:
            findings = run_research(target)
        except ResearchUnavailable as e:
            run.status = PropertyResearchRun.Status.FAILED
            run.error_message = str(e)
            run.finished_at = timezone.now()
            run.save()
            messages.error(request, f"Research isn't configured yet: {e}")
            return redirect("target_detail", pk=target.pk)
        except Exception as e:
            run.status = PropertyResearchRun.Status.FAILED
            run.error_message = str(e)
            run.finished_at = timezone.now()
            run.save()
            messages.error(request, f"Research failed: {e}")
            return redirect("target_detail", pk=target.pk)

        for f in findings:
            run.findings.create(
                target=target,
                finding_type=f["finding_type"],
                summary=f["summary"],
                relevance_score=f["relevance_score"],
                source_url=f.get("source_url", ""),
                source_name=f.get("source_name", ""),
            )
        run.status = PropertyResearchRun.Status.DONE
        run.finished_at = timezone.now()
        run.save()

        if findings:
            messages.success(request, f"Found {len(findings)} finding(s) about the property/entity.")
        else:
            messages.info(request, "No relevant property/entity findings surfaced in this pass.")
        return redirect("target_detail", pk=target.pk)
