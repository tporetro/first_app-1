from django.contrib import admin
from django.contrib.auth import views as auth_views
from django.urls import path

from matching.views import DashboardView

urlpatterns = [
    path("admin/", admin.site.urls),
    path("accounts/login/", auth_views.LoginView.as_view(), name="login"),
    path("accounts/logout/", auth_views.LogoutView.as_view(next_page="login"), name="logout"),
    path("", DashboardView.as_view(), name="dashboard"),
]
