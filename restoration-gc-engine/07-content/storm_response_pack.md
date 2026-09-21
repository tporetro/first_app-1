# Storm Response Pack

## 1. Regional Briefing Post Template

> A hailstorm producing hail up to {max_hail_size_in}" and winds near {max_wind_mph} mph moved through {state} on {event_date}. If your property is in the affected area, here's what to check first: [dated photos, roof access, date of loss]. {state deadline sentence — see `08-testing/fixtures/hail_event.json` and the verified deadline lexicon}. We help document damage and scope — we're a licensed general contractor, not a public adjuster, and we don't adjust claims or give legal advice. Free Hail-Impact Report: [link]. — Michael Johnson, 512-621-4201

## 2. Owner-Specific Property Briefing Email

> Subject: Storm activity near {property_address}
>
> Hi {first_name}, our records show a hail event ({max_hail_size_in}" hail) passed near {property_address} on {event_date}. We're not able to tell you whether there's damage without an inspection, but here's what's worth knowing: {state deadline sentence}. If you'd like, we can coordinate a free assessment — no obligation, and we don't adjust claims or provide legal advice. — Michael Johnson, 512-621-4201, michael@restorationgc.net

## 3. Assessment CTA Page Copy

> **Request a free roof assessment.** We'll walk your roof, document what we find with photos, and give you a plain-English scope summary. We are a licensed general contractor — we do not adjust insurance claims, negotiate with your insurer, or provide legal advice. If you'd like a formal claim evaluation, a licensed public adjuster or attorney can help with that side.

## 4. Voice-Agent Talk Track (AI Disclosure)

Used **only** where a matching `consent_records` row exists with `channel = voice`, `consent_given = true`, AND `ai_voice_disclosed = true` (TCPA / FCC 24-17).

> "Hi, this is an AI-generated voice calling on behalf of Restoration GC. I'm reaching out because of recent storm activity near your property. If you'd like to stop receiving these calls, just say 'stop' or reply STOP to any text, and we'll honor that right away. Would you like to hear more, or should I let you go?"

Immediate opt-out is honored per FCC 24-24 (within a reasonable time, not to exceed 10 business days; a one-time confirmation text is permitted).
