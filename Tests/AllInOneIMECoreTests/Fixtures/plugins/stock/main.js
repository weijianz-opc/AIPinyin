// @stock: quotes for the symbols after the command, on one line.
//   @stock AAPL            Apple Inc. AAPL 336.64 USD −1.11%
//   @stock aapl tsla       several, separated by spaces or commas
//   @stock 600519 700      A shares (6 digits) and Hong Kong (1–5 digits) without the suffix
//   @stock ^GSPC BTC-USD   indices and crypto, as Yahoo Finance writes them
// Prices from Yahoo Finance (no key); some markets are delayed by about 15 minutes.

/** Yahoo's symbol for what was typed: 600519 → 600519.SS, 000001 → 000001.SZ, 700 → 0700.HK. */
function symbolFor(text) {
  const s = text.trim().toUpperCase();
  if (/^\d{6}$/.test(s)) return s + ("569".includes(s[0]) ? ".SS" : ".SZ");
  if (/^\d{1,5}$/.test(s)) return (s.replace(/^0+/, "") || "0").padStart(4, "0") + ".HK";
  return s;
}

/** 1234.5 → "1,234.50". */
function money(n) {
  const [whole, cents] = Math.abs(n).toFixed(2).split(".");
  return (n < 0 ? "-" : "") + whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",") + "." + cents;
}

function line(symbol, response) {
  if (!response.ok) {
    const why = response.status === 404 ? "not found" : (response.error || "HTTP " + response.status);
    return { failed: true, text: symbol + ": " + why };
  }
  let meta;
  try {
    meta = response.json().chart.result[0].meta;
  } catch (e) {
    return { failed: true, text: symbol + ": not found" };
  }
  const price = meta.regularMarketPrice, before = meta.chartPreviousClose;
  if (typeof price !== "number") return { failed: true, text: symbol + ": no price" };
  let text = [meta.shortName || meta.longName, symbol, money(price), meta.currency].filter(Boolean).join(" ");
  if (typeof before === "number" && before > 0) {
    const change = (price - before) / before * 100;
    text += " " + (change >= 0 ? "+" : "−") + Math.abs(change).toFixed(2) + "%";
  }
  return { failed: false, text };
}

function run(input) {
  const symbols = input.split(/[\s,，、]+/).filter(Boolean).slice(0, 8).map(symbolFor);
  if (symbols.length === 0) throw new Error("Type a stock symbol after @stock, e.g. AAPL");
  const urls = symbols.map(s => "https://query1.finance.yahoo.com/v8/finance/chart/" + encodeURIComponent(s) + "?range=1d&interval=1d");
  const responses = fetch(urls, { headers: { "User-Agent": "Mozilla/5.0" } });
  const lines = responses.map((r, i) => line(symbols[i], r));
  const text = lines.map(l => l.text).join(" · ");
  if (lines.every(l => l.failed)) throw new Error(text);
  return text;
}
