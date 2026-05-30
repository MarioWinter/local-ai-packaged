# SPDX-License-Identifier: AGPL-3.0-or-later
"""Brave Search routed through the ScraperOps wrapper API.

We do NOT delegate to searx.engines.brave.request() because that
function reads brave.py module-locals (traits, Goggles, brave_category,
etc.) that SearXNG only populates for ENABLED engines. Since we want
brave disabled here (we only want our wrapped variant firing), brave.pys
traits never get initialized and delegation crashes with NameError.

Instead we build the search.brave.com URL inline ourselves, then wrap
that URL through the ScraperOps proxy. The Brave HTML parser (response)
is still delegated to brave.py because that function is pure-input.

One outbound HTTP per chat query = 1 ScraperOps credit. Anti-bot and
residential IP rotation handled by ScraperOps.

Required env: SCRAPEOPS_API_KEY (passed into Vane container by the
local-ai-packaged compose override).
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

# Map SearXNG time_range tokens to Braves tf param.
TIME_RANGE_MAP = {
    "day": "pd",
    "week": "pw",
    "month": "pm",
    "year": "py",
}


def request(query, params):
    api_key = os.environ.get("SCRAPEOPS_API_KEY", "").strip()
    if not api_key:
        _searx_logger.error(
            "brave_scrapeops: SCRAPEOPS_API_KEY not set in Vane env; "
            "skipping query."
        )
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
        + "&render_js=false"
    )
    params["headers"]["Accept-Encoding"] = "gzip, deflate"
    # ScraperOps does not forward cookies; clear any default SearXNG set.
    params["cookies"] = {}


def response(resp):
    return _brave.response(resp)
