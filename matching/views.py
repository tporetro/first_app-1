from django.contrib.auth.mixins import LoginRequiredMixin
from django.db.models import Prefetch
from django.views.generic import ListView

from .models import Match, Target


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
        rows = []
        status_priority = {"confirmed": 0, "pending": 1, "rejected": 2, None: 3}
        for target in targets:
            matches = list(target.matches.all())
            best = None
            if matches:
                best = sorted(
                    matches,
                    key=lambda m: (status_priority[m.status], -m.match_confidence),
                )[0]
            rows.append({"target": target, "best_match": best, "match_count": len(matches)})

        rank = {"confirmed": 0, "pending": 1, "rejected": 2, None: 3}
        rows.sort(key=lambda r: rank[r["best_match"].status if r["best_match"] else None])
        context["rows"] = rows
        return context
