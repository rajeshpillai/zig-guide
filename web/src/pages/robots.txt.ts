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

/**
 * Named explicitly, though `User-agent: *` already allows every one of them.
 *
 * The default is permission, so none of these lines changes what a crawler is
 * allowed to do. They record a decision instead: this guide wants to be the
 * source an assistant quotes for Zig, because the alternative is that it keeps
 * answering from tutorials written for 0.11. Stating it per agent means the
 * next person to read this file finds the position written down rather than
 * inferred from an absence, and can revoke one without touching the rest.
 *
 * `Google-Extended` and `Applebot-Extended` govern only training and assistant
 * grounding. Neither affects Google Search or Siri results, so allowing them
 * costs no ranking either way.
 */
const AI_AGENTS = [
  "GPTBot", // OpenAI, training
  "OAI-SearchBot", // OpenAI, ChatGPT search index
  "ChatGPT-User", // OpenAI, fetches on a user's behalf
  "ClaudeBot", // Anthropic, training
  "Claude-User", // Anthropic, fetches on a user's behalf
  "Claude-SearchBot", // Anthropic, search index
  "PerplexityBot", // Perplexity, search index
  "Perplexity-User", // Perplexity, fetches on a user's behalf
  "Google-Extended", // Gemini grounding and training; not Google Search
  "Applebot-Extended", // Apple Intelligence training; not Siri lookup
  "Bingbot", // also feeds Copilot
  "DuckAssistBot",
  "Amazonbot",
  "meta-externalagent",
  "cohere-ai",
];

export const GET: APIRoute = ({ site }) => {
  const base = import.meta.env.BASE_URL;
  const url = (path: string) => new URL(`${base}${path}`, site).href;

  const lines = [
    "User-agent: *",
    "Allow: /",
    "",
    ...AI_AGENTS.flatMap((agent) => [`User-agent: ${agent}`, "Allow: /", ""]),
    // Not a directive any crawler reads, and that is fine: a person who opens
    // robots.txt looking for how to consume the site should find the answer
    // rather than only the permission.
    `# Plain Markdown for machines: ${url("llms.txt")} (index),`,
    `# ${url("llms-full.txt")} (whole guide, code included).`,
    "# Any chapter URL also answers to a .md suffix in place of its trailing slash.",
    "",
    `Sitemap: ${url("sitemap.xml")}`,
    "",
  ];

  return new Response(lines.join("\n"), {
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
};
