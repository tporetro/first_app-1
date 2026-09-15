"""Public-source research on a target's property and business entity.

Scope, by design: the building's physical condition, tenant/public
complaints, permits and code violations, storm/damage reports, and
business-entity-level news or litigation. This module never queries for
or stores personal/biographical information about the owner as an
individual (life events, health, family matters, personal philanthropy).
That line is enforced in the query construction below and again in the
prompt sent to the analysis model, not left to the model's discretion.

Requires an ANTHROPIC_API_KEY to actually produce findings (used to turn
raw search snippets into structured, cited findings); everything else is
optional at import time so the app still runs without it -- each search
source simply reports itself unavailable and is skipped:

- BING_SEARCH_API_KEY: general web search.
- COMPOSIO_API_KEY: adds Composio's keyless web + news search
  (COMPOSIO_SEARCH_WEB / COMPOSIO_SEARCH_NEWS) as extra sources.
- REDDIT_CLIENT_ID / REDDIT_CLIENT_SECRET: reliable Reddit search via
  Reddit's own OAuth API. Without these, Reddit search falls back to the
  public, unauthenticated endpoint, which needs no key but is best-effort.
"""
import json
import os

import requests

REDDIT_PUBLIC_SEARCH_URL = "https://www.reddit.com/search.json"
REDDIT_OAUTH_TOKEN_URL = "https://www.reddit.com/api/v1/access_token"
REDDIT_OAUTH_SEARCH_URL = "https://oauth.reddit.com/search"
BING_SEARCH_URL = "https://api.bing.microsoft.com/v7.0/search"
COMPOSIO_API_BASE_URL = "https://backend.composio.dev/api/v3.1"
USER_AGENT = os.environ.get("REDDIT_USER_AGENT", "leadpath-property-research/1.0")
REQUEST_TIMEOUT = 10

ANALYSIS_SYSTEM_PROMPT = """\
You extract factual findings about a COMMERCIAL BUILDING and the BUSINESS \
ENTITY that owns it from search result snippets, for a hail-damage \
insurance outreach team.

In scope: the building's physical condition (leaks, roof damage, storm \
damage), tenant or public complaints about the building, permits or code \
violations tied to the property, litigation or regulatory action \
involving the owning entity, and business-level news about the owning \
entity (as a company, not as a person).

STRICTLY OUT OF SCOPE, even if present in the snippets: any personal or \
biographical information about the owner as an individual -- life events, \
health, family matters, personal relationships, or personal (as opposed \
to corporate) philanthropy. If a snippet contains this kind of \
information, ignore it entirely; do not summarize, paraphrase, or \
reference it in any way.

Each snippet is prefixed with an index in brackets, like [3]. Return a
JSON array of finding objects, each with exactly these fields:
- source_index: the integer index of the ONE snippet this finding is drawn from
- finding_type: one of "complaint", "permit", "damage", "news", "litigation", "other"
- summary: a one- or two-sentence factual summary, in-scope only
- relevance_score: 0-100, how relevant this is to a hail-damage insurance claim

If nothing in-scope is present, return an empty JSON array: []
Return ONLY the JSON array, no other text.
"""


class ResearchUnavailable(Exception):
    """Raised when a required API key/service isn't configured."""


def build_queries(target):
    """Property/entity-scoped search queries. Deliberately excludes any
    query about the owner's personal life."""
    subject = target.entity_name or target.owner_name
    location = ", ".join(p for p in [target.city, target.state] if p)
    base = f'"{subject}" {location}'.strip()
    return [
        f"{base} roof leak OR water damage",
        f"{base} hail OR storm damage",
        f"{base} tenant complaint OR maintenance",
        f"{base} building permit OR code violation",
        f"{base} lawsuit OR litigation",
    ]


def _get_reddit_oauth_token():
    client_id = os.environ.get("REDDIT_CLIENT_ID")
    client_secret = os.environ.get("REDDIT_CLIENT_SECRET")
    if not client_id or not client_secret:
        return None
    resp = requests.post(
        REDDIT_OAUTH_TOKEN_URL,
        auth=(client_id, client_secret),
        data={"grant_type": "client_credentials"},
        headers={"User-Agent": USER_AGENT},
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json().get("access_token")


def _parse_reddit_listing(data):
    results = []
    for child in data.get("data", {}).get("children", []):
        post = child.get("data", {})
        results.append({
            "title": post.get("title", ""),
            "snippet": (post.get("selftext") or "")[:500],
            "url": f"https://www.reddit.com{post.get('permalink', '')}",
            "source_name": f"r/{post.get('subreddit', '')}",
        })
    return results


def search_reddit(query):
    """Searches Reddit for public posts matching query.

    Prefers Reddit's official OAuth API (set REDDIT_CLIENT_ID /
    REDDIT_CLIENT_SECRET from a free reddit.com/prefs/apps "script" app)
    since the unauthenticated endpoint is frequently blocked from
    data-center/cloud IPs. Falls back to the public endpoint, which is
    best-effort only.
    """
    token = _get_reddit_oauth_token()
    if token:
        resp = requests.get(
            REDDIT_OAUTH_SEARCH_URL,
            params={"q": query, "sort": "relevance", "limit": 10},
            headers={"User-Agent": USER_AGENT, "Authorization": f"Bearer {token}"},
            timeout=REQUEST_TIMEOUT,
        )
    else:
        resp = requests.get(
            REDDIT_PUBLIC_SEARCH_URL,
            params={"q": query, "sort": "relevance", "limit": 10},
            headers={"User-Agent": USER_AGENT},
            timeout=REQUEST_TIMEOUT,
        )
    resp.raise_for_status()
    return _parse_reddit_listing(resp.json())


def search_web(query):
    api_key = os.environ.get("BING_SEARCH_API_KEY")
    if not api_key:
        return []
    resp = requests.get(
        BING_SEARCH_URL,
        params={"q": query, "count": 10},
        headers={"Ocp-Apim-Subscription-Key": api_key},
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    data = resp.json()
    results = []
    for item in data.get("webPages", {}).get("value", []):
        results.append({
            "title": item.get("name", ""),
            "snippet": item.get("snippet", ""),
            "url": item.get("url", ""),
            "source_name": item.get("displayUrl", ""),
        })
    return results


def _composio_execute(tool_slug, arguments):
    api_key = os.environ.get("COMPOSIO_API_KEY")
    if not api_key:
        return None
    resp = requests.post(
        f"{COMPOSIO_API_BASE_URL}/tools/execute/{tool_slug}",
        json={"arguments": arguments, "user_id": "leadpath-property-research", "version": "latest"},
        headers={"x-api-key": api_key},
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json().get("data", {})


def _domain_from_url(url):
    try:
        from urllib.parse import urlparse
        return urlparse(url).netloc or "web"
    except ValueError:
        return "web"


def search_composio_web(query):
    """General web search via Composio's keyless COMPOSIO_SEARCH_WEB tool.

    The live response nests citations/organic_results directly under
    `data` (not `data.results` as Composio's docs page describes at the
    time this was written) -- confirmed against a real API call.
    """
    data = _composio_execute("COMPOSIO_SEARCH_WEB", {"query": query})
    if not data:
        return []
    results = []
    for item in data.get("citations", []) or []:
        title = item.get("title", "")
        url = item.get("url", "") or item.get("id", "")
        results.append({
            "title": title,
            "snippet": item.get("snippet", "") or item.get("text", "") or title,
            "url": url,
            "source_name": item.get("source", "") or _domain_from_url(url),
        })
    for item in data.get("organic_results", []) or []:
        title = item.get("title", "")
        url = item.get("url", "") or item.get("link", "")
        results.append({
            "title": title,
            "snippet": item.get("snippet", "") or title,
            "url": url,
            "source_name": item.get("source", "") or _domain_from_url(url),
        })
    return results


def search_composio_news(query):
    """News search via Composio's keyless COMPOSIO_SEARCH_NEWS tool.

    Like search_composio_web, news_results is nested directly under
    `data`, confirmed against a real API call.
    """
    data = _composio_execute("COMPOSIO_SEARCH_NEWS", {"query": query})
    if not data:
        return []
    news_results = data.get("news_results", []) or []
    return [
        {
            "title": item.get("title", ""),
            "snippet": item.get("snippet", ""),
            "url": item.get("link", ""),
            "source_name": item.get("source", "") or "news",
        }
        for item in news_results
    ]


def analyze_with_claude(target, raw_results):
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise ResearchUnavailable("ANTHROPIC_API_KEY is not configured.")
    if not raw_results:
        return []

    import anthropic

    client = anthropic.Anthropic(api_key=api_key)
    subject = target.entity_name or target.owner_name
    snippets_text = "\n\n".join(
        f"[{i}] {r['title']}\nSource: {r['source_name']} ({r['url']})\n{r['snippet']}"
        for i, r in enumerate(raw_results)
    )
    message = client.messages.create(
        model="claude-sonnet-5",
        max_tokens=4096,
        thinking={"type": "disabled"},
        system=ANALYSIS_SYSTEM_PROMPT,
        messages=[{
            "role": "user",
            "content": f"Building/entity: {subject}\n\nSearch result snippets:\n\n{snippets_text}",
        }],
    )
    text = "".join(block.text for block in message.content if hasattr(block, "text"))
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else ""
        text = text.rsplit("```", 1)[0]
    try:
        findings = json.loads(text)
    except json.JSONDecodeError:
        return []

    enriched = []
    for f in findings:
        source_index = f.get("source_index")
        source = raw_results[source_index] if isinstance(source_index, int) and 0 <= source_index < len(raw_results) else {}
        enriched.append({
            "finding_type": f.get("finding_type", "other"),
            "summary": f.get("summary", ""),
            "relevance_score": f.get("relevance_score", 0),
            "source_url": source.get("url", ""),
            "source_name": source.get("source_name", ""),
        })
    return enriched


def run_research(target):
    """Runs the property/entity research pipeline for a target.

    Returns a list of finding dicts (finding_type, summary, source_url,
    source_name, relevance_score). Raises ResearchUnavailable if the
    analysis model isn't configured -- callers should surface that as a
    clear setup message, not a silent no-op.
    """
    queries = build_queries(target)
    raw_results = []
    seen_urls = set()
    fetchers = (search_reddit, search_web, search_composio_web, search_composio_news)
    for query in queries:
        for fetch in fetchers:
            try:
                results = fetch(query)
            except requests.RequestException:
                continue
            for r in results:
                if r["url"] and r["url"] in seen_urls:
                    continue
                seen_urls.add(r["url"])
                raw_results.append(r)

    return analyze_with_claude(target, raw_results)
