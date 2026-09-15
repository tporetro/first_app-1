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
