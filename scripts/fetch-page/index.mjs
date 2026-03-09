#!/usr/bin/env node

/**
 * fetch-page
 *
 * Fetches a webpage, cleans it with @mozilla/readability, converts to markdown,
 * downloads images locally, and takes a screenshot.
 */

import { writeFile, mkdir } from "node:fs/promises";
import { join, extname } from "node:path";
import { createHash } from "node:crypto";
import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import { fromHtml } from "hast-util-from-html";
import { toMdast } from "hast-util-to-mdast";
import { toMarkdown } from "mdast-util-to-markdown";
import { gfmTableToMarkdown } from "mdast-util-gfm-table";
import puppeteer from "puppeteer";

const TIMEOUT_MS = 60_000;
const MAX_IMAGE_SIZE = 10 * 1024 * 1024;
const MAX_IMAGES = 50;


function imageFilename(url) {
  const hash = createHash("sha256").update(url).digest("hex").slice(0, 16);
  let ext = extname(new URL(url).pathname).split("?")[0];
  if (!ext || ext.length > 6) ext = ".png";
  return `${hash}${ext}`;
}

async function downloadImage(url, imagesDir) {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15_000);
    const resp = await fetch(url, {
      signal: controller.signal,
      headers: { "User-Agent": "Mozilla/5.0 (compatible; SiaBot/1.0)" },
    });
    clearTimeout(timeout);

    if (!resp.ok) return null;

    const contentLength = resp.headers.get("content-length");
    if (contentLength && parseInt(contentLength) > MAX_IMAGE_SIZE) return null;

    const buf = Buffer.from(await resp.arrayBuffer());
    if (buf.length > MAX_IMAGE_SIZE) return null;

    const filename = imageFilename(url);
    await writeFile(join(imagesDir, filename), buf);
    return filename;
  } catch {
    return null;
  }
}

function resolveUrl(src, baseUrl) {
  try {
    return new URL(src, baseUrl).href;
  } catch {
    return null;
  }
}

async function main() {
  const [, , url, outputDir] = process.argv;

  if (!url || !outputDir) {
    console.error("Usage: index.mjs <url> <output-dir>");
    process.exit(1);
  }

  let parsedUrl;
  try {
    parsedUrl = new URL(url);
    if (!["http:", "https:"].includes(parsedUrl.protocol)) {
      throw new Error("URL must use http or https");
    }
  } catch (e) {
    console.error(`Invalid URL: ${e.message}`);
    process.exit(1);
  }

  const imagesDir = join(outputDir, "images");
  await mkdir(imagesDir, { recursive: true });

  let browser;
  try {
    browser = await puppeteer.launch({
      headless: true,
      args: [
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
      ],
    });

    const page = await browser.newPage();
    await page.setViewport({ width: 1280, height: 900 });
    await page.setUserAgent(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    );

    await page.goto(url, { waitUntil: "networkidle2", timeout: TIMEOUT_MS });

    await page.screenshot({
      path: join(outputDir, "screenshot.png"),
      fullPage: true,
    });

    const html = await page.content();

    await browser.close();
    browser = null;

    const { document } = parseHTML(html);

    const baseEl = document.createElement("base");
    baseEl.setAttribute("href", url);
    document.head.prepend(baseEl);

    const reader = new Readability(document, { charThreshold: 0 });
    const article = reader.parse();

    if (!article || !article.content) {
      console.error("Readability could not extract content from the page.");
      await writeFile(
        join(outputDir, "index.md"),
        `# ${url}\n\nCould not extract readable content.\n`,
      );
      process.exit(0);
    }

    const { document: cleanDoc } = parseHTML(article.content);
    const imgElements = [...cleanDoc.querySelectorAll("img")];

    const imageMap = new Map();
    const downloadQueue = [];

    for (const img of imgElements.slice(0, MAX_IMAGES)) {
      const src = img.getAttribute("src");
      if (!src) continue;
      const resolved = resolveUrl(src, url);
      if (!resolved) continue;
      if (imageMap.has(resolved)) continue;

      imageMap.set(resolved, null);
      downloadQueue.push(
        downloadImage(resolved, imagesDir).then((filename) => {
          if (filename) {
            imageMap.set(resolved, `images/${filename}`);
          } else {
            imageMap.delete(resolved);
          }
        }),
      );
    }

    await Promise.all(downloadQueue);

    for (const img of imgElements) {
      const src = img.getAttribute("src");
      if (!src) continue;
      const resolved = resolveUrl(src, url);
      if (resolved && imageMap.has(resolved)) {
        img.setAttribute("src", imageMap.get(resolved));
      }
    }

    const finalHtml = cleanDoc.toString();

    const hast = fromHtml(finalHtml, { fragment: true });
    const mdast = toMdast(hast);
    const markdown = toMarkdown(mdast, {
      extensions: [gfmTableToMarkdown()],
      bullet: "-",
      emphasis: "*",
      rule: "-",
    });

    const title = article.title || parsedUrl.hostname;
    const siteName = article.siteName ? ` — ${article.siteName}` : "";
    const header = `# ${title}${siteName}\n\n`;

    await writeFile(join(outputDir, "index.md"), header + markdown);

    console.log(
      JSON.stringify({
        success: true,
        title: article.title,
        byline: article.byline,
        excerpt: article.excerpt,
        images: imageMap.size,
        outputDir,
      }),
    );
  } catch (e) {
    console.error(`Error: ${e.message}`);
    process.exit(1);
  } finally {
    if (browser) {
      await browser.close().catch(() => {});
    }
  }
}

main();

