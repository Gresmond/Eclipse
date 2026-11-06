https://github.com/user-attachments/assets/8218585e-3180-44fe-88be-402fba9c622c

# Eclipse

A desktop habit tracker and to-do planner, built with Flutter.

## Installing on Arch Linux

Download `Eclipse.tar.zst` from the
[latest release](https://github.com/Gresmond/Eclipse/releases/latest), then extract
and install it.

```sh
tar --zstd -xf Eclipse.tar.zst
bash Eclipse/install.sh
```

**Updating:** Eclipse checks GitHub on startup and while running.
The bottom-right **Update and reopen** card downloads and installs the latest version.

## Installing on Windows

Download `Eclipse.exe` from the
[latest release](https://github.com/Gresmond/Eclipse/releases/latest) and run it.

**Updating:** Eclipse checks GitHub on startup and every few hours.
When a new version is out, the bottom-right card's **Download** button opens
the new `Eclipse.exe`; run it to update.

## Installing on a Mac

1. Open the [latest release](https://github.com/Gresmond/Eclipse/releases/latest)
   and download `Eclipse.dmg`.
2. Open the downloaded file and drag **Eclipse** onto the **Applications** folder.
3. Open Eclipse from Applications. The first time, macOS says it can't
   verify the app: click **Done**, then go to **System Settings → Privacy &
   Security**, scroll down and click **Open Anyway**. After that it opens normally.

**Updating:** Eclipse checks GitHub on startup and every few hours.
When a new version is out, the bottom-right card's **Download** button opens
the new `Eclipse.dmg`; drag Eclipse onto Applications again to update.

## Installing on an Android phone

Open the [latest release](https://github.com/Gresmond/Eclipse/releases/latest) on your phone,
download `Eclipse.apk`, open it and allow the install. Then sign in with the same Google account
as your computers. The phone shows today's rituals, sleep schedule and tasks, adds tasks and
sends their reminders.

**Updating:** a card at the top of the app downloads and installs a new version.

## Web version

The same app runs in Firefox and Chrome. `web/` holds its page, landing page, privacy page and offline worker, and `functions/` its sign-in, which runs on Cloudflare Pages.

To look at it locally with no sign-in, its data kept in the browser:

```bash
bash tool/build_web.sh --local
```

```bash
python3 tool/serve_web.py
```

Then open http://localhost:8765. `node --test test/web/functions.test.mjs` tests the sign-in functions.

It publishes with each release once these are set on GitHub: the repository variable `CLOUDFLARE_PROJECT`, and the secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. The Pages project needs the secrets `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`, from a Web application client in Eclipse's Google Cloud project, and `COOKIE_KEY`, any long random text. Changing `COOKIE_KEY` signs everyone out.
