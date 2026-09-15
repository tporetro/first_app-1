from django.contrib import admin
from django.contrib.auth import views as auth_views
from django.urls import path

from matching.views import ContactImportView, DashboardView, RunMatchingView, TargetImportView

urlpatterns = [
    path("admin/", admin.site.urls),
    path("accounts/login/", auth_views.LoginView.as_view(), name="login"),
    path("accounts/logout/", auth_views.LogoutView.as_view(next_page="login"), name="logout"),
    path("", DashboardView.as_view(), name="dashboard"),
    path("import/contacts/", ContactImportView.as_view(), name="import_contacts"),
    path("import/targets/", TargetImportView.as_view(), name="import_targets"),
    path("run-matching/", RunMatchingView.as_view(), name="run_matching"),
]
