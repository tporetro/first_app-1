from django.contrib import admin
from django.contrib.auth import views as auth_views
from django.urls import path

from matching.views import (
    AddContactView,
    BulkAddContactsView,
    BulkRunResearchView,
    ContactImportView,
    DashboardView,
    RunMatchingView,
    RunResearchView,
    TargetDetailView,
    TargetImportView,
)

urlpatterns = [
    path("admin/", admin.site.urls),
    path("accounts/login/", auth_views.LoginView.as_view(), name="login"),
    path("accounts/logout/", auth_views.LogoutView.as_view(next_page="login"), name="logout"),
    path("", DashboardView.as_view(), name="dashboard"),
    path("import/contacts/", ContactImportView.as_view(), name="import_contacts"),
    path("import/targets/", TargetImportView.as_view(), name="import_targets"),
    path("contacts/add/", AddContactView.as_view(), name="add_contact"),
    path("contacts/add/bulk/", BulkAddContactsView.as_view(), name="bulk_add_contacts"),
    path("run-matching/", RunMatchingView.as_view(), name="run_matching"),
    path("run-research-bulk/", BulkRunResearchView.as_view(), name="run_research_bulk"),
    path("targets/<int:pk>/", TargetDetailView.as_view(), name="target_detail"),
    path("targets/<int:pk>/run-research/", RunResearchView.as_view(), name="run_research"),
]
