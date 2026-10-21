# Storyteller Sync (storytellersync.koplugin)

![GitHub release (latest by date)](https://img.shields.io/github/v/release/Sirozha1337/storytellersync.koplugin?style=for-the-badge&color=orange) ![GitHub all releases](https://img.shields.io/github/downloads/Sirozha1337/storytellersync.koplugin/total?style=for-the-badge&color=yellow) ![Platform](https://img.shields.io/badge/Platform-KOReader-success?style=for-the-badge&logo=koreader)

A [KOReader](https://github.com/koreader/koreader) plugin for synchronizing reading progress with a [Storyteller](https://gitlab.com/storyteller-platform/storyteller) server.

- Keep your reading progress in sync across all your devices.
- Seamlessly transition between reading an ebook on KOReader and listening to the readaloud epub on Storyteller app.
- Easy authentication using a QR code.

## 📋 Compatibility & Book File Requirements

### Plugin v2.0.0-beta+ (Storyteller v3.0.0-beta.55+)
- **Server Compatibility**: Supports **Storyteller v3.0.0-beta.55+**.
- **Original EPUB Support**: Allows you to sync progress between the **original (text-only) EPUB** file on KOReader and the **Readaloud** on Storyteller.
- **Requirement**: Both files (the original EPUB and the Readaloud) must be uploaded/present on your Storyteller server.

### Plugin v1.x (Prior to v2)
- **Server Compatibility**: Compatible with **Storyteller v2.11.4+**.
- **Same File Requirement**: Requires you to have the **same Readaloud EPUB file** on both devices.
- **💡 Workaround to reduce file size**: Since Readaloud files include audio and can be very large, you can open the Readaloud `.epub` as a `.zip` archive and delete the `Audio` folder inside it before transferring it to KOReader.


## 💾 Installation

1. Copy the plugin folder (`storytellersync.koplugin`) to your KOReader plugins directory:
   - `koreader/plugins/storytellersync.koplugin`
2. Make sure the folder contains:
   - `main.lua`
   - `_meta.lua`
   - `StorytellerApi.lua`
   - `StorytellerAuth.lua`
   - `StorytellerBookLink.lua`
   - `StorytellerQueue.lua`
   - `StorytellerSyncEngine.lua`
   - `LocatorHelper.lua`

## ▶️ Enabling the plugin

1. Start **KOReader**.
2. Open the **Top Settings menu**.
3. Go to **Tools** (icon with tools) -> **Plugin management**.
4. Find **Storyteller Sync** in the list and enable it.
5. Restart **KOReader**.

## ⚙️ Configuration

Before syncing, you need to set your Storyteller server URL:

1. Open the book (make sure it's an EPUB, other formats are not supported)
2. Open the **Top Settings menu**.
3. Go to **Tools** (icon with tools) -> **Storyteller Sync**.
4. Select **Server URL** and enter your server address (e.g., `https://storyteller.example.com`).

## 🔑 Authentication

1. In the **Storyteller Sync** menu, select **Login**.
2. A QR code will appear on your screen.
3. Scan it with your phone or visit the displayed URL and enter the provided code.
4. Once authorized, KOReader will automatically link with your account.

## 🔄 Syncing Progress

Once set up, the plugin provides two main actions:

- **Push progress**: Send your current position to the Storyteller server.
- **Pull progress**: Check the server for a newer position from another device and jump to it.

The first time you trigger sync (push or pull) for a book, the plugin will try to find a matching book on the server. If found, it will link the book and store the link for future syncs. If not found, you can link the book manually selecting it from the list of books available on your Storyteller instance.

You can trigger these manually from the **Storyteller Sync** menu or configure automatic sync behavior in the settings.
