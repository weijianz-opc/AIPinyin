// @xe: currency conversion, on one line.
//   @xe 100 USD CNY          100 USD = 670.69 CNY (1 USD = 6.7069 CNY · 2026-10-11)
//   @xe USD JPY              no amount: 1
//   @xe 100usd to cny        lowercase, no space, "to" / "in" / "→" between
//   @xe 1000 日元 人民币       Chinese names and symbols ($ € £ ¥ ₩ HK$ …)
//   @xe 100 USD              one currency: to CNY (from CNY: to USD)
//   @xe 100 USD CNY JPY EUR  several targets, separated by " · "
// The first currency is the one converted from; the amount can be anywhere. ¥ is CNY, unless the
// other currency is CNY (`@xe ¥1000 人民币`): then it's JPY. Write 円 / JPY / 日元 to be sure.
// Rates by ExchangeRate-API (https://www.exchangerate-api.com, daily); if it can't be reached,
// the ECB's rates through Frankfurter (https://frankfurter.dev, fewer currencies).

/** What people write for a currency, besides its ISO code. Longer names are matched first. */
const NAMES = {
  USD: ["美元", "美金", "美刀", "$", "US$", "dollar", "dollars"],
  CNY: ["人民币", "人民幣", "元", "块钱", "块", "塊", "CN¥", "RMB", "yuan"],
  JPY: ["日元", "日圆", "日圓", "日币", "日幣", "円", "JP¥", "yen"],
  EUR: ["欧元", "歐元", "€", "euro", "euros"],
  GBP: ["英镑", "英鎊", "£", "pound", "pounds"],
  HKD: ["港币", "港幣", "港元", "港纸", "HK$"],
  TWD: ["新台币", "新台幣", "台币", "台幣", "NT$"],
  KRW: ["韩元", "韓元", "韩币", "韓幣", "₩", "won"],
  AUD: ["澳元", "澳币", "澳幣", "澳大利亚元", "A$", "AU$"],
  CAD: ["加元", "加币", "加幣", "加拿大元", "C$", "CA$"],
  SGD: ["新加坡元", "新加坡币", "新币", "新幣", "S$"],
  NZD: ["新西兰元", "纽元", "纽币", "NZ$"],
  MOP: ["澳门元", "澳门币", "澳門幣", "葡币"],
  CHF: ["瑞士法郎", "瑞郎"],
  THB: ["泰铢", "泰銖", "฿", "baht"],
  INR: ["卢比", "盧比", "印度卢比", "₹", "rupee", "rupees"],
  RUB: ["卢布", "盧布", "₽"],
  MYR: ["林吉特", "令吉", "马币", "馬幣"],
  PHP: ["菲律宾比索", "₱"],
  IDR: ["印尼盾"],
  VND: ["越南盾", "₫"],
  MXN: ["墨西哥比索"],
  BRL: ["雷亚尔", "巴西雷亚尔", "R$"],
  TRY: ["土耳其里拉", "里拉", "₺"],
  AED: ["迪拉姆"],
  SAR: ["沙特里亚尔"],
  SEK: ["瑞典克朗"],
  NOK: ["挪威克朗"],
  DKK: ["丹麦克朗"],
  ZAR: ["兰特", "南非兰特"],
  ILS: ["谢克尔", "₪"],
};

/** Words between the currencies that mean nothing here. */
const FILLERS = ["to", "in", "into", "as", "换成", "换算", "兑换", "兑", "换", "转成", "转", "到", "等于", "是", "折合", "合", "多少", "能换", "约"];

/** Currencies without minor units in practice. */
const WHOLE = ["JPY", "KRW", "VND", "IDR", "CLP", "ISK", "PYG", "UGX", "XAF", "XOF", "IRR", "TWD", "HUF", "COP"];

const AMBIGUOUS_YEN = "¥";

function literal(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

const LOOKUP = {};
for (const code in NAMES) for (const name of NAMES[code]) LOOKUP[name.toLowerCase()] = code;
const SYMBOLS = Object.keys(LOOKUP).concat([AMBIGUOUS_YEN], FILLERS)
  .filter(s => !/^[a-z]+$/.test(s))  // words are matched whole, below
  .sort((a, b) => b.length - a.length);
// A number (1,200.50, 1.5万, 2k), a name or symbol, an ASCII word, or anything else (one character).
const TOKEN = new RegExp("(\\d+(?:\\.\\d+)?)(万|亿|k\\b)?|(" + SYMBOLS.map(literal).join("|") + ")|([A-Za-z]+)|(\\S)", "gi");

/** "100 USD to CNY" → {amount: 100, amountText: "100", from: "USD", to: ["CNY"]}. */
function parse(input) {
  const text = input.normalize("NFKC").replace(/(\d)[,，](?=\d{3}(?!\d))/g, "$1");
  let amount = null, amountText = null;
  const currencies = [];
  let yen = false, match;
  TOKEN.lastIndex = 0;
  while ((match = TOKEN.exec(text)) !== null) {
    const [, number, scale, symbol, word, other] = match;
    if (number !== undefined) {
      if (amount !== null) throw new Error("One amount at a time, e.g. @xe 100 USD CNY");
      const factor = { "万": 1e4, "亿": 1e8, "k": 1e3, "K": 1e3 }[scale] || 1;
      amount = parseFloat(number) * factor;
      amountText = factor === 1 ? number : null;
    } else if (symbol !== undefined) {
      if (symbol === AMBIGUOUS_YEN) { currencies.push(AMBIGUOUS_YEN); yen = true; }
      else if (LOOKUP[symbol.toLowerCase()]) currencies.push(LOOKUP[symbol.toLowerCase()]);
      // else a filler
    } else if (word !== undefined) {
      const lower = word.toLowerCase();
      if (FILLERS.includes(lower)) continue;
      if (LOOKUP[lower]) currencies.push(LOOKUP[lower]);
      else if (word.length === 3) currencies.push(word.toUpperCase());
      else throw new Error("Unknown currency: " + word);
    } else if (!/[\s,，、.。;；:：=→>\-–—()（）]/.test(other)) {
      throw new Error("Unknown currency: " + other);
    }
  }
  if (currencies.length === 0) throw new Error("Type currencies after @xe, e.g. 100 USD CNY");
  // ¥ is the yuan, unless the yuan is the other currency.
  const yenIs = yen && currencies.includes("CNY") ? "JPY" : "CNY";
  const codes = currencies.map(c => c === AMBIGUOUS_YEN ? yenIs : c);
  const from = codes[0];
  const to = codes.slice(1).filter((c, i, all) => c !== from && all.indexOf(c) === i);
  if (to.length === 0) to.push(from === "CNY" ? "USD" : "CNY");
  return { amount: amount === null ? 1 : amount, amountText, from, to };
}

/** 1234567.891 → "1,234,567.89". */
function group(fixed) {
  const [whole, part] = fixed.split(".");
  return whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",") + (part ? "." + part : "");
}

/** An amount of `code`: cents (none for yen and the like); small amounts keep two significant digits. */
function money(value, code) {
  if (value === 0) return "0";
  if (Math.abs(value) >= 1) return group(value.toFixed(WHOLE.includes(code) ? 0 : 2));
  return group(value.toFixed(Math.min(10, Math.max(2, Math.floor(-Math.log10(Math.abs(value))) + 2))));
}

/** A rate: 6.7069, 158.25, 0.006319. */
function rate(value) {
  if (value >= 100) return group(value.toFixed(2));
  if (value >= 1) return value.toFixed(4);
  return value.toFixed(Math.min(12, Math.floor(-Math.log10(value)) + 4));
}

/** The amount as typed (1200 → "1,200", 1.5 → "1.5"). */
function typed(amount, text) {
  if (text !== null) return group(text.replace(/^0+(?=\d)/, ""));
  return group(String(Number(amount.toFixed(4))));
}

/** Rates from `from`: {rates, date}; throws when there are none. One request (a second if the first fails). */
function ratesFrom(from) {
  let primary = null;
  try {
    primary = fetch("https://open.er-api.com/v6/latest/" + encodeURIComponent(from));
  } catch (e) {}
  if (primary && primary.ok) {
    let data = null;
    try { data = primary.json(); } catch (e) {}
    if (data && data.result === "success" && data.rates) {
      const updated = new Date(data.time_last_update_unix * 1000);
      return { rates: data.rates, date: isNaN(updated) ? "" : updated.toISOString().slice(0, 10) };
    }
    if (data && data["error-type"] === "unsupported-code") throw new Error("Unknown currency: " + from);
  }
  // ExchangeRate-API is down or limiting: the ECB's rates.
  try {
    const backup = fetch("https://api.frankfurter.dev/v1/latest?base=" + encodeURIComponent(from));
    if (backup.ok) {
      const data = backup.json();
      if (data && data.rates) {
        data.rates[from] = 1;
        return { rates: data.rates, date: data.date || "" };
      }
    }
  } catch (e) {}
  throw new Error("Couldn't get exchange rates");
}

function run(input) {
  const { amount, amountText, from, to } = parse(input);
  if (!/^[A-Z]{3}$/.test(from)) throw new Error("Unknown currency: " + from);
  const unknown = to.find(c => !/^[A-Z]{3}$/.test(c));
  if (unknown) throw new Error("Unknown currency: " + unknown);
  const { rates, date } = ratesFrom(from);
  const missing = to.filter(c => typeof rates[c] !== "number");
  if (missing.length > 0) throw new Error("Unknown currency: " + missing.join(", "));
  const note = parts => " (" + parts.filter(Boolean).join(" · ") + ")";
  const head = typed(amount, amountText) + " " + from + " = ";
  if (to.length === 1) {
    const r = rates[to[0]];
    if (amount === 1) {
      // The amount is the rate: show it precisely, and the other way round.
      return head + rate(r) + " " + to[0] + note(["1 " + to[0] + " = " + rate(1 / r) + " " + from, date]);
    }
    return head + money(amount * r, to[0]) + " " + to[0] + note(["1 " + from + " = " + rate(r) + " " + to[0], date]);
  }
  return head + to.map(c => money(amount * rates[c], c) + " " + c).join(" · ") + (date ? note([date]) : "");
}
