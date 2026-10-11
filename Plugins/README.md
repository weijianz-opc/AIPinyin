# Plugins

Plugins kept with the app's source. They are **not installed with the app**: the plugin library
(Settings → Plugins, coming in 0.5.0) publishes them, signed, from its own repository.

| Plugin | Type | What it does |
| --- | --- | --- |
| `@x` | link | Opens X's composer with the text: `https://x.com/intent/post?text=…` |
| `@threads` | link | Opens Threads' composer: `https://www.threads.net/intent/post?text=…` |
| `@bsky` | link | Opens Bluesky's composer: `https://bsky.app/intent/compose?text=…` |
| `@weibo` | link | Opens Weibo's share page: `https://service.weibo.com/share/share.php?title=…` |
| `@xe` | script | Converts currencies: `@xe 100 USD CNY` → `100 USD = 670.69 CNY (1 USD = 6.7069 CNY · 2026-10-11)` |

A `link` plugin runs no code: the text after the command is put into the address and the page opens in
your default browser, where you post it yourself (signed in as usual). Nothing is inserted or sent by the
input method. See [docs/plugins.md](../docs/plugins.md).

## @xe

Currency conversion, one line with the date of the rate. Rates by
[ExchangeRate-API](https://www.exchangerate-api.com) (`open.er-api.com`, no key, updated daily); when it can't be
reached, the European Central Bank's rates through [Frankfurter](https://frankfurter.dev) (`api.frankfurter.dev`,
about 30 currencies). One request a run (two when the first fails).

| You type | You get |
| --- | --- |
| `@xe 100 USD CNY` | `100 USD = 670.69 CNY (1 USD = 6.7069 CNY · 2026-10-11)` |
| `@xe USD JPY` | no amount is 1: `1 USD = 158.29 JPY (1 JPY = 0.006318 USD · 2026-10-11)` |
| `@xe 1000 日元 人民币` | `1,000 JPY = 42.35 CNY (1 JPY = 0.04235 CNY · 2026-10-11)` |
| `@xe 100 USD` | one currency: to CNY (from CNY: to USD) |
| `@xe 100 USD CNY JPY EUR` | `100 USD = 670.69 CNY · 15,829 JPY · 89.24 EUR (2026-10-11)` |

- The first currency is the one converted from; the amount can be anywhere (`usd cny 100`), stuck to a code
  (`100usd`), with separators (`1,200.5`) or `万` / `亿` / `k` (`1.5万 港币`).
- Codes in any case; `to`, `in`, `→`, `=`, `换成`, `兑`, `等于多少` and the like between them are skipped
  (`100 USD to CNY`, `100美元换成多少人民币`).
- Names and symbols: 美元 / 美金 / `$` / `US$` USD, 人民币 / 元 / 块 / `RMB` CNY, 日元 / 日币 / 円 JPY, 欧元 / `€` EUR,
  英镑 / `£` GBP, 港币 / 港元 / `HK$` HKD, 台币 / 新台币 / `NT$` TWD, 韩元 / `₩` KRW, 澳元 AUD, 加元 CAD, 新加坡元 SGD,
  瑞士法郎 CHF, 泰铢 THB, 卢比 INR, 卢布 RUB, 澳门元 MOP, 新西兰元 NZD and a few more (see `NAMES` in `main.js`).
- `¥` is the yuan (CNY), unless the other currency is the yuan: `@xe ¥1000 人民币` converts yen. Write `円`, `JPY` or
  日元 to be sure.
- Errors: `Unknown currency: XYZ`, `Couldn't get exchange rates`.
- Inside a sentence (`@reply 报价 @xe 1200 USD CNY 可以吗`) the argument is a word plus the following words without
  lowercase letters, so amounts with uppercase codes work as they are; lowercase codes, `to` / `in` or Chinese names
  end it early: quote them, `@xe「1000 日元 人民币」`.
- What's typed after `@xe` starts in Latin (like every script plugin); Chinese names work when typed in Chinese or
  inside 「…」.

## Installing one by hand

Copy its folder into the plugins folder; the command list has it the next time you click into a text field,
and Settings → Plugins lists it (Refresh):

```sh
mkdir -p ~/.config/allinoneime/plugins
cp -R Plugins/x ~/.config/allinoneime/plugins/
```

The folder name must match the plugin's `name`. A plugin copied by hand shows as **local (not reviewed)**.
To remove it, use Remove in Settings → Plugins or delete the folder.
