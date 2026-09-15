from django.contrib import messages
from django.contrib.auth.mixins import LoginRequiredMixin
from django.db.models import Prefetch
from django.shortcuts import redirect
from django.urls import reverse_lazy
from django.views import View
from django.views.generic import FormView, ListView

from .forms import ContactImportForm, TargetImportForm
from .models import Match, Target
from .services import ImportError_, import_contacts_from_file, import_targets_from_file, run_matching


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


class RunMatchingView(LoginRequiredMixin, View):
    """POST-only trigger to (re)compute candidate matches."""

    def post(self, request, *args, **kwargs):
        checked, created = run_matching()
        if checked == 0:
            messages.warning(request, "Need at least one contact and one target before matching can run.")
        else:
            messages.success(request, f"Checked {checked} pair(s); found {created} new candidate match(es).")
        return redirect("dashboard")
