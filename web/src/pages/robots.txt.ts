import type { APIRoute } from "astro";

/**
 * Generated rather than kept in `public/` for the same reason `ads.txt` is:
 * the sitemap line has to be an absolute URL, and the origin differs between
 * the custom domain and a github.io project site. A static file would name one
 * of them and be quietly wrong on the other.
 *
 * `public/wasm/` is not disallowed on purpose. The snippets are the content;
 * letting a crawler read them is the point.
 */
export const GET: APIRoute = ({ site }) => {
  const base = import.meta.env.BASE_URL;
  return new Response(
    ["User-agent: *", "Allow: /", "", `Sitemap: ${new URL(`${base}sitemap.xml`, site).href}`, ""].join(
      "\n",
    ),
    { headers: { "content-type": "text/plain; charset=utf-8" } },
  );
};
