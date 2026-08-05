# KOReader Custom Patches 📚
Custom Lua patches for **KOReader** optimized for E-ink devices.

# 📖 Page Browser 
This patch allows you to quickly flip back and forth through the book, with the option to easily return to your original page using the 'x' button or stay on the new page.You can also use the interactive progress bar and bookmark browser. Streamlined, E-ink optimized, based on KOReader's browser architecture and inspired by the native Kindle page picker experience. Get patch: [**2-page-browser.lua**](./2-page-browser.lua)

> **Features**
* **3-Page Thumbnail Grid:** Displays a live preview of the previous, current, and next pages side by side, keeping the active page perfectly centered.
* **E-Ink Safe Navigation:** Features a slow, controlled hold-to-repeat page turning speed to prevent ghosting loops and screen lag.
* **Quick Access Toolbar:** Top navigation bar with direct buttons for Home, Settings, Bookmarks, Table of Contents, and Font Options.
* **Progress & Info Bar:** Includes an interactive slider, chapter title, and a precise percentage/page counter.

@ *Credits & Acknowledgments* 
* **Zen UI Plugin:** Inspired by the clean, minimal aesthetic of the **Zen UI** plugin (`anthonygress/zen_ui.koplugin`).
* Built upon KOReader's core architecture and community browser components.

# 📄 Page Scrubbers 
 * [**2-page-scrubber-alt.lua**](./2-page-scrubber-alt.lua): Bottom bar with progress, chapter info, and E-ink-safe continuous hold.
 * [**2-page-scrubber.lua**](./2-page-scrubber.lua): Centered floating window variant with rounded corners, and quick-access buttons.
   
## > 📱 Screenshots: **Page Browser and Page Scrubber**
<p align="center">
  <img src="Screenshot_2026-08-05-01-00-43-539_org.koreader.launcher.jpg" width="45%" alt="Page Browser Preview" />
  <img src="Screenshot_2026-07-31-00-12-58-523_org.koreader.launcher.jpg" width="45%" alt="Page Scrubber Preview" />
</p>
 
## ⚙️ Installation
 1. Download the .lua file.
 2. Place it in your KOReader user plugins/patches folder.
 3. Restart KOReader.
    
  **Setup & Activation**
 1. Open a book in KOReader.
 2. Go to **Settings** (⚙️) > **Gestures** > **Reader**.
 3. Choose your preferred gesture and assign it to **Page Scrubber**
