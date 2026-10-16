// fetch-subsites.mjs: copy the sub-sites listed in web/subsites.json into
// web/dist/<path>/ after `astro build`, so one deploy publishes them under
// www.ziglang.in/<path>/.
//
// A sub-site is a separate project with its own repo and its own build (for
// example raylib-zig-web, the Zig port of raylib). Each one builds itself for
// BASE_PATH=/<path>/ and publishes its finished site to a branch of its own
// repo, usually gh-pages. GitHub Pages cannot serve another repo's Pages under
// a path of this site's custom domain, so this script fetches that branch and
// the guide's deploy carries it.
//
// It fails, rather than skipping, when a sub-site cannot be fetched or would
// overwrite a page the guide built: the deploy is an orphan commit, so a
// skipped sub-site would vanish from the live site with nothing turning red.
//
//   node tools/fetch-subsites.mjs          # after astro build, before e2e
//
// A sub-site's updates go live on the guide's next deploy (a push to main or
// the nightly).
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const web = new URL("..", import.meta.url).pathname;
const dist = join(web, "dist");
const subsites = JSON.parse(readFileSync(join(web, "subsites.json"), "utf8"));

if (!existsSync(dist)) {
  console.error("fetch-subsites: web/dist does not exist; run astro build first");
  process.exit(1);
}

for (const { path, repo, branch } of subsites) {
  if (!/^[a-z0-9][a-z0-9-]*$/.test(path)) throw new Error(`subsites.json: bad path "${path}"`);
  const target = join(dist, path);
  if (existsSync(target)) throw new Error(`subsites.json: /${path}/ would overwrite pages the guide built`);

  const work = mkdtempSync(join(tmpdir(), `subsite-${path}-`));
  try {
    execFileSync("git", ["clone", "--quiet", "--depth", "1", "--branch", branch, `https://github.com/${repo}.git`, work], {
      stdio: ["ignore", "inherit", "inherit"],
    });
    const commit = execFileSync("git", ["-C", work, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim();
    // Repo plumbing and Pages files that belong to the guide's root, not here.
    for (const name of [".git", "CNAME", ".nojekyll"]) rmSync(join(work, name), { recursive: true, force: true });
    if (!existsSync(join(work, "index.html"))) throw new Error(`${repo}@${branch} has no index.html`);
    cpSync(work, target, { recursive: true });
    console.log(`fetch-subsites: /${path}/ <- ${repo}@${branch} (${commit})`);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}
