# Plugins

Plugins kept with the app's source. They are **not installed with the app**: the plugin library
(Settings → Plugins, coming in 0.5.0) publishes them, signed, from its own repository.

| Plugin | Type | What it does |
| --- | --- | --- |
| `@x` | link | Opens X's composer with the text: `https://x.com/intent/post?text=…` |
| `@threads` | link | Opens Threads' composer: `https://www.threads.net/intent/post?text=…` |
| `@bsky` | link | Opens Bluesky's composer: `https://bsky.app/intent/compose?text=…` |
| `@weibo` | link | Opens Weibo's share page: `https://service.weibo.com/share/share.php?title=…` |

A `link` plugin runs no code: the text after the command is put into the address and the page opens in
your default browser, where you post it yourself (signed in as usual). Nothing is inserted or sent by the
input method. See [docs/plugins.md](../docs/plugins.md).

## Installing one by hand

Copy its folder into the plugins folder; the command list has it the next time you click into a text field,
and Settings → Plugins lists it (Refresh):

```sh
mkdir -p ~/.config/allinoneime/plugins
cp -R Plugins/x ~/.config/allinoneime/plugins/
```

The folder name must match the plugin's `name`. A plugin copied by hand shows as **local (not reviewed)**.
To remove it, use Remove in Settings → Plugins or delete the folder.
