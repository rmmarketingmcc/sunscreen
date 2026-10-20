# Sunscreen

A small Mac menu bar app that makes your screens follow the sun. Normal colours by day; from sunset, no blue light on every screen and a dimmer external monitor. Automatic, every day.

**Install and guide:** https://rmmarketingmcc.github.io/sunscreen/

Or in Terminal:

```
curl -fsSL https://rmmarketingmcc.github.io/sunscreen/install.sh | bash
```

## Build

Needs only Apple's Command Line Tools:

```
./build.sh            # build/Sunscreen.dmg + build/Sunscreen.zip
./build.sh --install  # also install to /Applications and relaunch
```

The whole app is `Sources/main.swift`. The guide page is `docs/` (GitHub Pages).
