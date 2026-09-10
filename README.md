# Goodreads for KOReader

Browse your Goodreads shelves on your e-reader, offline.

Goodreads retired its API, so this plugin reads the public RSS export of your shelf instead. One sync stores every book and its cover on the device; everything after that — browsing, searching, opening a book — reads only what is stored, and needs no connection.

## ✨ Features

- 📚 **Your whole library**: Syncs every book of your Goodreads shelves, 100 at a time
- 📴 **Offline first**: Books and covers are stored locally, browse with the Wi-Fi off
- 🖼️ **Covers**: Downloads a cover per book, with a stand-in for the ones without
- 🔍 **Search**: Find a book by title or author, without leaving the device
- 🗂️ **Shelves**: Browse shelf by shelf, fullest first
- ↕️ **Sorting**: Recently added, title, author, average rating or most rated
- ⚡ **Incremental sync**: A re-sync only reads what you added since last time
- 🔑 **No API key**: A public shelf needs nothing; a private one takes your feed address

## 📋 Requirements

- [KOReader](https://koreader.rocks) (2023 or later)
- A Goodreads account with a public shelf, or your private RSS feed address

## 🚀 Installation

1. Clone this repository into your KOReader plugins directory:

```bash
git clone https://github.com/johackim/goodreads.koplugin ~/.config/koreader/plugins/
```

The plugins directory depends on your device.

2. Restart KOReader

The plugin appears under **Tools → Goodreads**.

## 📦 Usage

1. Open **Tools → Goodreads → Goodreads account**
2. Enter your username, user number or RSS address, and the shelf you want, or `All` for everything
3. Tap **Sync from Goodreads** and wait for the sync to finish

Then browse your books from **My books**, **Browse by shelf** or **Search your books**, with or without a connection.

Tap a book to see its cover, rating, number of ratings, page count, release year and description.

## 🔧 Customization

**Private shelf**: paste your whole RSS address in the first field instead of your username. Goodreads gives it on your shelf page, under *RSS* at the bottom, and it carries the key a private shelf needs — it is the only way to sync a library that is not public:

```
https://www.goodreads.com/review/list_rss/12345678?key=xxxxx&shelf=read
```

**Full re-sync**: a tap on *Sync from Goodreads* only reads what you added since last time. **Hold** it to read the whole shelf again, which also picks up books you removed or moved between shelves.

**Sorting**: *Sort by* changes the order of every list — recently added, title, author, average rating or most rated.

Both sync passes can be stopped by tapping the screen; whatever was fetched is kept.

Your books are stored in `koreader/settings/goodreads_library.lua`, the covers in `koreader/cache/goodreads_covers`.

## 🙏 Credits

All the code takes inspiration from the [original KOReader Goodreads plugin](https://github.com/koreader/koreader/tree/4d9d599a6aab36875a37d75d98bfaaedb54fd059/plugins/goodreads.koplugin), which KOReader dropped in 2021 when the Goodreads API was retired.

## 🤖 Vibe coding

All the source code is vibe coded.

## 🎁 Support me

I'd love to work on this project, but my time on this earth is limited, support my work to give me more time!

Please support me with a one-time or a monthly donation and help me continue my activities.

[![Github sponsor](https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors)](https://github.com/sponsors/johackim/)

## 📜 License

This project is licensed under the GNU AGPL v3.0, like KOReader itself — see the [LICENSE.txt](https://raw.githubusercontent.com/johackim/goodreads.koplugin/master/LICENSE.txt) file for details.

**Free Software, Hell Yeah!**
