// Oczy orkiestratora: zrzuty ekranu (komputer + telefon) i automatyczne kontrole jakości.
// Użycie: node oczy.mjs <katalog_wyjściowy> <plik_listy_stron> [--wzor]
//         node oczy.mjs --sprawdz        (czy przeglądarka się uruchamia)
// Plik listy: jedna strona na linię, "nazwa adres", np. "start http://localhost:3000".
// Zapisuje <nazwa>-komputer.png, <nazwa>-telefon.png i wynik.json. Kod 2 = brak Playwright.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";

const narz = process.env.ORK_NARZ || path.join(os.homedir(), ".orkiestrator", "narzedzia");
let chromium;
try {
  ({ chromium } = createRequire(path.join(narz, "package.json"))("playwright"));
} catch {
  try {
    ({ chromium } = await import("playwright"));
  } catch {
    console.error("BRAK_PLAYWRIGHT: uruchom silnik.sh przygotuj");
    process.exit(2);
  }
}

// Najpierw przeglądarka Playwrighta; jeśli jej brak, gotowe przeglądarki w systemie.
async function uruchomPrzegladarke() {
  try {
    return await chromium.launch();
  } catch (pierwszyBlad) {
    const kandydaci = [
      process.env.ORK_CHROMIUM,
      "/opt/pw-browsers/chromium",
      "/usr/bin/chromium",
      "/usr/bin/chromium-browser",
      "/usr/bin/google-chrome",
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    ].filter(Boolean);
    for (const k of kandydaci) {
      if (!fs.existsSync(k)) continue;
      try {
        return await chromium.launch({ executablePath: k });
      } catch {
        /* następny */
      }
    }
    throw pierwszyBlad;
  }
}

if (process.argv[2] === "--sprawdz") {
  try {
    const b = await uruchomPrzegladarke();
    await b.close();
    console.log("OK");
    process.exit(0);
  } catch (e) {
    console.error(String(e.message || e).split("\n")[0]);
    process.exit(1);
  }
}

const [, , outDir, listFile, ...flags] = process.argv;
const wzor = flags.includes("--wzor");
const MAX_WYSOKOSC = 3200;

const WIDOKI = [
  { id: "komputer", width: 1440, height: 900, isMobile: false },
  { id: "telefon", width: 390, height: 844, isMobile: true },
];

const strony = fs
  .readFileSync(listFile, "utf8")
  .split("\n")
  .map((l) => l.trim())
  .filter((l) => l && !l.startsWith("#"))
  .map((l) => {
    const [nazwa, ...reszta] = l.split(/\s+/);
    return { nazwa: nazwa.replace(/[^a-zA-Z0-9_-]/g, "-"), url: reszta.join(" ") || nazwa };
  });

fs.mkdirSync(outDir, { recursive: true });

// Kontrole uruchamiane w przeglądarce
function kontroleWStronie(szerUstawiona) {
  // Na telefonie przeglądarka potrafi oddalić widok, żeby zmieścić za szeroką stronę,
  // więc porównujemy z ustawioną szerokością ekranu, a nie z window.innerWidth.
  const szer = szerUstawiona;
  const wynik = { poziomyScroll: false, wystajace: [], niskiKontrast: [], liczbaTekstow: 0 };

  const opis = (el) => {
    let s = el.tagName.toLowerCase();
    if (el.id) s += "#" + el.id;
    else if (typeof el.className === "string" && el.className.trim())
      s += "." + el.className.trim().split(/\s+/).slice(0, 2).join(".");
    const t = (el.innerText || "").trim().replace(/\s+/g, " ").slice(0, 40);
    return t ? `${s} „${t}”` : s;
  };

  if (document.documentElement.scrollWidth > szer + 1) {
    wynik.poziomyScroll = true;
    const kandydaci = [];
    for (const el of document.body.querySelectorAll("*")) {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.right > szer + 1) kandydaci.push({ el, nadmiar: Math.round(r.right - szer) });
    }
    // najgłębsze elementy, które wystają (rodzice zwykle wystają przez dzieci)
    const liscie = kandydaci.filter((k) => !kandydaci.some((o) => o !== k && k.el.contains(o.el)));
    wynik.wystajace = liscie.slice(0, 5).map((k) => `${opis(k.el)} (+${k.nadmiar}px)`);
  }

  const rgb = (s) => {
    const m = s.match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(/[ ,/]+/).filter(Boolean).map(Number);
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  };
  const lum = ({ r, g, b }) => {
    const f = (c) => {
      c /= 255;
      return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
  };
  const tlo = (el) => {
    for (let e = el; e; e = e.parentElement) {
      const st = getComputedStyle(e);
      if (st.backgroundImage && st.backgroundImage !== "none") return null; // gradient/obraz: nie oceniamy
      const c = rgb(st.backgroundColor);
      if (c && c.a > 0.9) return c;
    }
    return { r: 255, g: 255, b: 255, a: 1 };
  };

  const teksty = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  while (walker.nextNode() && teksty.length < 400) {
    const n = walker.currentNode;
    if (!n.textContent.trim()) continue;
    const el = n.parentElement;
    if (!el || teksty.includes(el)) continue;
    const r = el.getBoundingClientRect();
    const st = getComputedStyle(el);
    if (r.width === 0 || r.height === 0 || st.visibility === "hidden" || Number(st.opacity) < 0.1) continue;
    if (el.closest("[disabled],[aria-disabled=true],input,textarea,select")) continue;
    teksty.push(el);
  }
  wynik.liczbaTekstow = teksty.length;
  for (const el of teksty) {
    const st = getComputedStyle(el);
    const kolor = rgb(st.color);
    const t = tlo(el);
    if (!kolor || !t || kolor.a < 0.9) continue;
    const l1 = lum(kolor), l2 = lum(t);
    const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
    const px = parseFloat(st.fontSize);
    const duzy = px >= 24 || (px >= 18.66 && Number(st.fontWeight) >= 700);
    const prog = duzy ? 3 : 4.5;
    if (ratio < prog) wynik.niskiKontrast.push(`${opis(el)} (${ratio.toFixed(2)}:1, wymagane ${prog}:1)`);
  }
  wynik.niskiKontrastLiczba = wynik.niskiKontrast.length;
  wynik.niskiKontrast = wynik.niskiKontrast.slice(0, 5);
  return wynik;
}

const browser = await uruchomPrzegladarke();
const raport = { czas: new Date().toISOString(), strony: [] };

for (const s of strony) {
  for (const w of WIDOKI) {
    const ctx = await browser.newContext({
      viewport: { width: w.width, height: w.height },
      isMobile: w.isMobile,
      hasTouch: w.isMobile,
      deviceScaleFactor: 1,
      reducedMotion: "reduce",
      locale: "pl-PL",
    });
    const page = await ctx.newPage();
    const bledyStrony = [];
    const bledyKonsoli = [];
    page.on("pageerror", (e) => bledyStrony.push(String(e.message || e).slice(0, 200)));
    page.on("console", (m) => {
      if (m.type() === "error") bledyKonsoli.push(m.text().slice(0, 200));
    });

    const wpis = { nazwa: s.nazwa, url: s.url, widok: w.id, plik: `${s.nazwa}-${w.id}.png` };
    try {
      let odp;
      try {
        odp = await page.goto(s.url, { waitUntil: "networkidle", timeout: 30000 });
      } catch {
        odp = await page.goto(s.url, { waitUntil: "load", timeout: 30000 });
      }
      wpis.status = odp ? odp.status() : null;
      if (wzor) {
        await page.addStyleTag({
          content:
            '[id*="cookie" i],[class*="cookie" i],[id*="consent" i],[class*="consent" i]{display:none!important}',
        });
      }
      await page.waitForTimeout(800);
      const k = await page.evaluate(kontroleWStronie, w.width);
      Object.assign(wpis, k);
      const wys = await page.evaluate(() => document.documentElement.scrollHeight);
      await page.screenshot({
        path: path.join(outDir, wpis.plik),
        fullPage: true,
        clip: { x: 0, y: 0, width: w.width, height: Math.min(wys, MAX_WYSOKOSC) },
      });
    } catch (e) {
      wpis.blad = String(e.message || e).split("\n")[0].slice(0, 200);
    }
    wpis.bledyStrony = bledyStrony.slice(0, 5);
    wpis.bledyKonsoli = bledyKonsoli.slice(0, 5);
    raport.strony.push(wpis);
    await ctx.close();
  }
}
await browser.close();

fs.writeFileSync(path.join(outDir, "wynik.json"), JSON.stringify(raport, null, 2));

// Podsumowanie dla człowieka i dla Claude
for (const p of raport.strony) {
  const uwagi = [];
  if (p.blad) uwagi.push(`NIE ZAŁADOWAŁA SIĘ: ${p.blad}`);
  if (p.status && p.status >= 400) uwagi.push(`kod HTTP ${p.status}`);
  if (p.bledyStrony.length) uwagi.push(`błędy JavaScript: ${p.bledyStrony.length}`);
  if (p.poziomyScroll) uwagi.push(`POZIOMY SCROLL (${p.wystajace.join("; ")})`);
  if (p.niskiKontrastLiczba) uwagi.push(`niski kontrast tekstu: ${p.niskiKontrastLiczba} miejsc`);
  if (p.bledyKonsoli.length) uwagi.push(`błędy w konsoli: ${p.bledyKonsoli.length}`);
  console.log(`${p.nazwa} [${p.widok}] ${uwagi.length ? uwagi.join(" | ") : "OK"} → ${p.plik}`);
}
