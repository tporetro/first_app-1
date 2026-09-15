from django import forms

from .models import Contact, ContactImport


class ContactImportForm(forms.Form):
    source_type = forms.ChoiceField(choices=ContactImport.SourceType.choices, label="Source")
    degree = forms.ChoiceField(
        choices=Contact.Degree.choices,
        initial=Contact.Degree.FIRST,
        label="Degree",
        help_text="1st-degree = your direct contacts. 2nd-degree = a mutual-connections export.",
    )
    file = forms.FileField(label="CSV file")


class TargetImportForm(forms.Form):
    file = forms.FileField(label="CSV file")


class SingleContactForm(forms.Form):
    full_name = forms.CharField(label="Name")
    phone = forms.CharField(label="Phone", required=False)
    email = forms.EmailField(label="Email", required=False)
    company = forms.CharField(label="Company", required=False)
    degree = forms.ChoiceField(
        choices=Contact.Degree.choices,
        initial=Contact.Degree.FIRST,
        label="Degree",
        help_text="1st-degree = someone you know directly. 2nd-degree = someone you know through a mutual connection.",
    )

    def clean(self):
        cleaned = super().clean()
        if not cleaned.get("phone") and not cleaned.get("email"):
            raise forms.ValidationError("Enter at least a phone number or an email address.")
        return cleaned
