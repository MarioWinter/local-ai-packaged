# SPDX-License-Identifier: AGPL-3.0-or-later
"""Brave Search routed through the ScraperOps wrapper API.

Brave's SERP migrated to a JavaScript-rendered Svelte SPA. The native
SearXNG `brave` engine assumes the older server-rendered HTML and
returns 0 results against the current Brave. Combined with our Strato
datacenter IP getting 429-rate-limited by Brave directly, the stock
engine is unusable for the chat.

This wrapper:
1. Builds the search.brave.com URL itself (avoids brave.py's `traits`
   module-locals which only get populated for enabled engines and crash
   the request when delegated).
2. Wraps that URL through ScraperOps's wrapper API endpoint
   (https://proxy.scrapeops.io/v1/?api_key=$KEY&url=$ENC&render_js=true)
   so ScraperOps handles anti-bot, residential IP rotation, AND
   JS-rendering of Brave's SPA to a parseable HTML.
3. Delegates `response()` to the upstream brave engine's HTML parser
   — once the page is rendered, the structure brave.py reads (the
   `<script>data: [{...}]</script>` block) is back in the served HTML.

One outbound HTTP per chat search = 1 ScraperOps credit (verified via
`sops_api_credits: 1` response header). Anti-bot + residential IP +
JS-rendering all handled by ScraperOps.

Required env: ``SCRAPEOPS_API_KEY`` — forwarded into the Vane
container by the local-ai-packaged compose override. SCRAPEOPS_API_KEY
must also be exported in the sudo subshell that runs the embedded
SearXNG; the override mounts a custom entrypoint.sh that does this.
"""
import os
from urllib.parse import quote_plus, urlencode

from searx.engines import brave as _brave
from searx.engines import logger as _searx_logger

about = {
    "website": "https://search.brave.com/",
    "wikidata_id": "Q22906900",
    "use_official_api": False,
    "requires_api_key": True,
    "results": "HTML",
}
categories = ["general", "web"]
paging = True
time_range_support = True

SCRAPEOPS_PROXY_URL = "https://proxy.scrapeops.io/v1/"
BRAVE_BASE_URL = "https://search.brave.com/search"

# Map SearXNG time_range tokens to Brave's `tf` query param.
TIME_RANGE_MAP = {"day": "pd", "week": "pw", "month": "pm", "year": "py"}


def request(query, params):
    api_key = os.environ.get("SCRAPEOPS_API_KEY", "").strip()
    if not api_key:
        _searx_logger.error(
            "brave_scrapeops: SCRAPEOPS_API_KEY not set in Vane env; "
            "skipping query."
        )
        # Empty url is SearXNG's idiom for "this engine has no work to do".
        params["url"] = ""
        return

    args = {"q": query, "source": "web"}
    pageno = params.get("pageno", 1)
    if pageno > 1:
        args["offset"] = pageno - 1
    tr = params.get("time_range")
    if tr and TIME_RANGE_MAP.get(tr):
        args["tf"] = TIME_RANGE_MAP[tr]

    brave_url = BRAVE_BASE_URL + "?" + urlencode(args)
    params["url"] = (
        SCRAPEOPS_PROXY_URL
        + "?api_key=" + quote_plus(api_key)
        + "&url=" + quote_plus(brave_url)
        + "&render_js=true"
    )
    # ScraperOps does not forward cookies through to the target.
    params["cookies"] = {}


def response(resp):
    return _brave.response(resp)
