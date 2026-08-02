import { chromium } from "playwright";
import { writeFile } from "node:fs/promises";

const outputJson = new URL("../docs/accessibility-audit.json", import.meta.url);
const outputMarkdown = new URL(
  "../docs/ACCESSIBILITY_AUDIT.md",
  import.meta.url
);
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const context = browser.contexts()[0];
if (!context) throw new Error("Authenticated browser context is unavailable.");
const page = await context.newPage();
await page.setViewportSize({ width: 768, height: 1024 });
await page.goto("http://127.0.0.1:3000/", {
  waitUntil: "networkidle",
  timeout: 60_000,
});
await page
  .getByRole("heading", { name: "Remote iOS automation command center" })
  .waitFor({ timeout: 60_000 });

const semantics = await page.evaluate(() => {
  const visible = element => {
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return (
      style.visibility !== "hidden" &&
      style.display !== "none" &&
      rect.width > 0 &&
      rect.height > 0
    );
  };
  const accessibleName = element => {
    const aria = element.getAttribute("aria-label")?.trim();
    if (aria) return aria;
    const labelledBy = element.getAttribute("aria-labelledby");
    if (labelledBy) {
      const text = labelledBy
        .split(/\s+/)
        .map(id => document.getElementById(id)?.textContent ?? "")
        .join(" ")
        .trim();
      if (text) return text;
    }
    if (element.id) {
      const label = document
        .querySelector(`label[for="${CSS.escape(element.id)}"]`)
        ?.textContent?.trim();
      if (label) return label;
    }
    return (
      element.textContent ??
      element.getAttribute("title") ??
      element.getAttribute("alt") ??
      ""
    ).trim();
  };
  const candidates = [
    ...document.querySelectorAll(
      'button,input,textarea,select,a[href],[role="button"],[role="combobox"]'
    ),
  ].filter(visible);
  return {
    interactiveCount: candidates.length,
    missingNames: candidates
      .filter(element => !accessibleName(element))
      .map(element => ({
        tag: element.tagName.toLowerCase(),
        id: element.id || null,
        role: element.getAttribute("role"),
      })),
  };
});

await page.evaluate(() => document.body.focus());
const focusSamples = [];
for (
  let index = 0;
  index < Math.min(80, semantics.interactiveCount + 8);
  index += 1
) {
  await page.keyboard.press("Tab");
  const sample = await page.evaluate(() => {
    const element = document.activeElement;
    if (!(element instanceof HTMLElement) || element === document.body)
      return null;
    const style = getComputedStyle(element);
    const name =
      element.getAttribute("aria-label") ||
      element.textContent?.trim() ||
      element.getAttribute("placeholder") ||
      element.id ||
      element.tagName;
    return {
      tag: element.tagName.toLowerCase(),
      name: name.slice(0, 120),
      focusVisible:
        (style.outlineStyle !== "none" && parseFloat(style.outlineWidth) > 0) ||
        style.boxShadow !== "none" ||
        parseFloat(style.borderWidth) > 0,
    };
  });
  if (sample) focusSamples.push(sample);
}
const uniqueFocus = [
  ...new Map(
    focusSamples.map(item => [`${item.tag}:${item.name}`, item])
  ).values(),
];

const contrast = await page.evaluate(() => {
  const clamp = value => Math.max(0, Math.min(1, value));
  const unit = value =>
    value.endsWith("%") ? Number(value.slice(0, -1)) / 100 : Number(value);
  const gamma = value =>
    255 *
    (value <= 0.0031308 ? 12.92 * value : 1.055 * value ** (1 / 2.4) - 0.055);
  const oklabToRgb = (lightness, a, b) => {
    const lr = lightness + 0.3963377774 * a + 0.2158037573 * b;
    const mr = lightness - 0.1055613458 * a - 0.0638541728 * b;
    const sr = lightness - 0.0894841775 * a - 1.291485548 * b;
    const l = lr ** 3;
    const m = mr ** 3;
    const s = sr ** 3;
    return [
      gamma(clamp(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)),
      gamma(clamp(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)),
      gamma(clamp(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s)),
    ];
  };
  const canvas = new OffscreenCanvas(1, 1);
  const colorContext = canvas.getContext("2d", { willReadFrequently: true });
  const parseColor = value => {
    const rgb = value.match(
      /rgba?\(([\d.]+)[, ]+([\d.]+)[, ]+([\d.]+)(?:\s*\/\s*([\d.%]+)|[, ]+([\d.]+))?/i
    );
    if (rgb)
      return {
        rgb: [Number(rgb[1]), Number(rgb[2]), Number(rgb[3])],
        alpha: unit(rgb[4] ?? rgb[5] ?? "1"),
      };
    const lab = value.match(
      /oklab\(([\d.%]+)\s+(-?[\d.]+)\s+(-?[\d.]+)(?:\s*\/\s*([\d.%]+))?\)/i
    );
    if (lab)
      return {
        rgb: oklabToRgb(unit(lab[1]), Number(lab[2]), Number(lab[3])),
        alpha: unit(lab[4] ?? "1"),
      };
    const lch = value.match(
      /oklch\(([\d.%]+)\s+([\d.]+)\s+(-?[\d.]+)(?:deg)?(?:\s*\/\s*([\d.%]+))?\)/i
    );
    if (lch) {
      const hue = (Number(lch[3]) * Math.PI) / 180;
      const chroma = Number(lch[2]);
      return {
        rgb: oklabToRgb(
          unit(lch[1]),
          chroma * Math.cos(hue),
          chroma * Math.sin(hue)
        ),
        alpha: unit(lch[4] ?? "1"),
      };
    }
    if (!colorContext) return null;
    colorContext.clearRect(0, 0, 1, 1);
    colorContext.fillStyle = "rgba(0,0,0,0)";
    colorContext.fillStyle = value;
    colorContext.fillRect(0, 0, 1, 1);
    const [red, green, blue, alpha] = colorContext.getImageData(
      0,
      0,
      1,
      1
    ).data;
    return { rgb: [red, green, blue], alpha: alpha / 255 };
  };
  const composite = (top, bottom) => {
    const alpha = top.alpha + bottom.alpha * (1 - top.alpha);
    return alpha <= 0
      ? { rgb: [0, 0, 0], alpha: 0 }
      : {
          rgb: top.rgb.map(
            (channel, index) =>
              (channel * top.alpha +
                bottom.rgb[index] * bottom.alpha * (1 - top.alpha)) /
              alpha
          ),
          alpha,
        };
  };
  const luminance = rgb => {
    const channels = rgb.map(value => {
      const channel = value / 255;
      return channel <= 0.03928
        ? channel / 12.92
        : ((channel + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
  };
  const background = element => {
    const layers = [];
    let current = element;
    while (current instanceof HTMLElement) {
      const color = parseColor(getComputedStyle(current).backgroundColor);
      if (color && color.alpha > 0) layers.push(color);
      current = current.parentElement;
    }
    let result = { rgb: [0, 0, 0], alpha: 1 };
    for (const layer of layers.reverse()) result = composite(layer, result);
    return result;
  };
  const leaves = [...document.querySelectorAll("body *")].filter(element => {
    if (!(element instanceof HTMLElement)) return false;
    if (
      ![...element.childNodes].some(
        node => node.nodeType === Node.TEXT_NODE && node.textContent?.trim()
      )
    )
      return false;
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return (
      style.visibility !== "hidden" &&
      style.display !== "none" &&
      rect.width > 0 &&
      rect.height > 0
    );
  });
  const failures = [];
  let audited = 0;
  for (const element of leaves) {
    const style = getComputedStyle(element);
    const foreground = parseColor(style.color);
    const backdrop = background(element);
    if (!foreground) continue;
    const rendered = composite(foreground, backdrop).rgb;
    const lighter = Math.max(luminance(rendered), luminance(backdrop.rgb));
    const darker = Math.min(luminance(rendered), luminance(backdrop.rgb));
    const ratio = (lighter + 0.05) / (darker + 0.05);
    const fontSize = parseFloat(style.fontSize);
    const threshold =
      fontSize >= 24 || (fontSize >= 18.66 && Number(style.fontWeight) >= 700)
        ? 3
        : 4.5;
    audited += 1;
    if (ratio + 0.05 < threshold)
      failures.push({
        text: (element.textContent ?? "").trim().slice(0, 100),
        ratio: Number(ratio.toFixed(2)),
        threshold,
      });
  }
  return { audited, failures: failures.slice(0, 50) };
});

const layout = await page.evaluate(() => ({
  viewportWidth: document.documentElement.clientWidth,
  scrollWidth: document.documentElement.scrollWidth,
  horizontalOverflow:
    document.documentElement.scrollWidth >
    document.documentElement.clientWidth + 1,
}));
const result = {
  capturedAt: new Date().toISOString(),
  viewport: { width: 768, height: 1024 },
  semantics,
  keyboard: {
    uniqueTabStops: uniqueFocus.length,
    focusVisibilityFailures: uniqueFocus.filter(item => !item.focusVisible),
  },
  contrast,
  layout,
  passed:
    semantics.missingNames.length === 0 &&
    uniqueFocus.length > 0 &&
    uniqueFocus.every(item => item.focusVisible) &&
    contrast.audited > 0 &&
    contrast.failures.length === 0 &&
    !layout.horizontalOverflow,
};
await writeFile(outputJson, `${JSON.stringify(result, null, 2)}\n`, "utf8");
await writeFile(
  outputMarkdown,
  `# Accessibility Audit\n\nThe authenticated operator dashboard was evaluated in Chromium at a **768 × 1024** tablet viewport.\n\n| Check | Result |\n|---|---|\n| Interactive controls inspected | ${semantics.interactiveCount} |\n| Controls missing an accessible name | ${semantics.missingNames.length} |\n| Unique keyboard tab stops observed | ${uniqueFocus.length} |\n| Focus visibility failures | ${result.keyboard.focusVisibilityFailures.length} |\n| Text elements contrast-checked | ${contrast.audited} |\n| Contrast failures | ${contrast.failures.length} |\n| Horizontal overflow | ${layout.horizontalOverflow ? "Yes" : "No"} |\n| Overall | **${result.passed ? "PASS" : "FAIL"}** |\n\nThe machine-readable result is stored in \`docs/accessibility-audit.json\`.\n`,
  "utf8"
);
await page.close();
await browser.close();
console.log(JSON.stringify(result, null, 2));
if (!result.passed) process.exitCode = 1;
