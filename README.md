# Flare Tracker

![Flare Tracker](https://substackcdn.com/image/fetch/$s_!Tx7T!,w_1456,c_limit,f_webp,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F10eb13ed-f795-4c6a-9f3b-ad5ef64a5562_1508x692.png)

**Full documentation writeup here: [https://darkmarc.substack.com/p/flare-tracker-an-open-source-link](https://darkmarc.substack.com/p/flare-tracker-an-open-source-link))**

A single self-contained Bash script that deploys and manages Flare Tracker, a link tracker that runs on Cloudflare Workers. It provisions the storage and Worker for you, gives you a hosted admin dashboard, and needs nothing on your machine beyond `curl` and `python3`.

Flare Tracker creates short links of the form `https://<your-host>/s/<token>`. When someone opens one, they first see a plain page that names exactly what will be recorded, and nothing is recorded unless they choose to continue. It is meant for analytics where the people being tracked have a basis to be tracked and can see what is collected. Please read the "Responsible use" section before deploying it.

## What it records

When a visitor a tracked link, Flare Tracker records the destination, a timestamp, the visitor IP, approximate location (country and city), the ISP and ASN, and the browser user agent. If a link is set to "enhanced," it also records screen resolution, platform, and time zone, all of which are listed on the consent page. The consent page discloses every one of these fields before anything is stored.

## Requirements

* `bash`, `curl`, and `python3`. All three are preinstalled on macOS and virtually every Linux distribution.
* A Cloudflare account.
* A Cloudflare API token.

## Getting a Cloudflare API token

Flare Tracker uses account-owned API tokens. Create one in the Cloudflare dashboard under Manage Account > Account API Tokens > Create Token.

The account id is detected automatically from the token, so there is nothing to paste by hand.

## Install and first run

```sh
# Make it executable
chmod +x start.sh

# Start the interactive shell
./start.sh
```

Inside the `cf>` prompt:

```sh
# Paste your account-owned token (hidden input); the account is auto-detected
login

# Remember the credentials in a private file next to the script
save

# Provision storage, set an admin password, and deploy the Worker
setup

# Open the hosted dashboard in your browser
dashboard
```

`setup` offers a quick option (Worker `ft-worker`, KV namespace `FT_CACHE`) or a custom option where you choose both names. It also prompts for an admin password; leave it blank to have a strong one generated and shown once. Setup is safe to run again and keeps an existing password and settings.

When it finishes it prints your endpoint, for example `https://ft-worker.<yoursub>.workers.dev`. The dashboard is that endpoint plus `/admin`.

Every command also works as a direct argument, so `./start.sh results` and `./start.sh setup` behave the same as typing them at the prompt.

## Creating tracking links

You can create links two ways, and both produce the same result.

From the dashboard, open **Create tracking link**, fill in the destination and options, and click Generate. From the terminal:

```sh
link create https://example.com/landing "Summer_Promo"
```

The terminal flow prompts for anything you omit, including the analytics level, the consent-page setting, an optional custom domain, and optional link-preview fields. Both paths let you choose whether the consent page is shown (the default) or skipped for that link. See "Responsible use" for when skipping is appropriate.

## Command reference

Credentials:

```sh
login                 # enter an account-owned token; account auto-detected
set token <token>     # use an account-owned API token (cfat_...)
set account <id>      # set the account id manually (rarely needed)
set account auto      # auto-detect the account id from the token
save                  # remember credentials on this machine
logout                # clear credentials
status                # show current auth type and account
```

Setup and dashboard:

```sh
setup                          # interactive: quick (defaults) or custom names
setup [WORKER_NAME] [KV_TITLE]  # non-interactive; KV defaults to FT_CACHE
dashboard                      # open the /admin dashboard in your browser
reset
