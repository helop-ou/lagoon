# Lagoon website brief

Planning record from September 7, 2026, under HEL-143. The site is built in the
separate `lagoon-website` repository (SvelteKit, fully prerendered, Cloudflare
Workers static assets like `helop-website`) as of September 10, 2026, but is not
yet published: it has no remote, no DNS and no rights-cleared screenshots. The
privacy and support documents in this directory were the editorial drafts for it;
the pages in the website repository now carry the current copy, so edit there and
treat these files as history.

## Purpose and address

Give Lagoon a public home where prospective users can understand the app,
existing users can find help, and everyone can read its privacy and licensing
information without a Jellyfin account.

The proposed starting address is **`lagoon.helop.ee`**, subject to confirming
control of `helop.ee` and choosing hosting. This avoids registering another
domain and gives the app its own section of the Helop identity. A dedicated
Lagoon domain can be considered later if independent branding becomes useful.
Neither DNS nor hosting has been configured as part of this work.

Apple requires the relevant privacy and support information to be reachable;
it does not prescribe a separately purchased domain for each app. An existing
domain, subdomain or suitable hosted address can provide those pages. For
Lagoon's platforms, App Store Connect requires a privacy-policy URL for iOS and
privacy-policy text for tvOS. The Support URL must lead to actual contact
information. A marketing URL is optional. See Apple's [privacy requirements](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
and [platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information).

## Initial pages

Paths below are proposed routes, not live links. They can share one small static
site and a common navigation/footer.

| Route | Purpose and content | Starting material |
| --- | --- | --- |
| `/` | Explain that Lagoon is a Jellyfin client for iPhone, iPad and Apple TV; describe the server/account requirement; show representative screenshots and supported features; add the App Store link when available. | App assets and verified release behavior; landing-page copy still needs writing. |
| `/privacy` | Approved policy covering the publisher, data flows, permissions, service relationships, retention/deletion and privacy contact. | [Privacy draft](privacy.md) and the [data-flow assessment](../hel-143-release-preparation.md). |
| `/support` | Setup, connection/permission recovery, sign-in and playback/subtitle troubleshooting, reporting instructions and a monitored contact route. | [Support draft](support.md). |
| `/licenses` | Third-party acknowledgements and license texts, with links to the exact source/build/relink materials required for the distributed version. | [Native inventory](../native-dependency-inventory.json) and the licensing assessment in HEL-143; recipient materials remain unfinished. |

Privacy and support are release requirements. The landing page helps users
understand the product. The licenses page is the proposed home for the materials
chosen by the dependency compliance decision; creating an acknowledgements page
alone does not resolve the static-library licensing work.

## Design and implementation direction

Start with a responsive static site. Hosting and implementation tools are still
open choices; use a setup that is easy to maintain alongside the app.

- Reuse Lagoon's existing logo, colours and visual identity. Keep text readable,
  navigation accessible by keyboard, and pages usable on small phone screens.
- Explain the Jellyfin server requirement prominently so visitors know what
  they need before installing. Describe Seerr and subtitles according to the
  final release scope.
- Use screenshots from the released build with media/artwork cleared for public
  use. Show only device, server and format support that has been validated.
- Serve the pages over HTTPS, with stable direct URLs and no sign-in required.
  Keep privacy, support and licenses easy to find from every page.
- The initial scope is informational pages. Accounts, payments, a support
  backend, analytics and a newsletter are not planned for this first version.
  Revisit data disclosures if the chosen hosting or later features collect data.

## Decisions to make when work resumes

- [ ] Confirm `lagoon.helop.ee` as the public address and verify DNS control.
- [x] Choose hosting, deployment method and who maintains the site: Cloudflare
  Workers static assets via `wrangler.jsonc`, maintained alongside `helop-website`.
- [ ] Choose a monitored support/privacy contact and confirm publisher identity.
- [ ] Decide the initial site languages and keep policy/support content aligned
  with the App Store languages being offered.
- [ ] Finalize the app's data collection/retention answers, including support
  messages, Apple-provided reports, services and any website hosting logs.
- [x] Direct OpenSubtitles inclusion: removed under HEL-146.
- [ ] Resolve the dependency licensing materials before finalizing related copy.
- [ ] Select rights-cleared screenshots; the site draws each app layout as a
  placeholder until a file lands in its `static/screens/` folder.
- [x] Write concise landing-page copy.

## Suggested work order

1. Review this brief and the existing drafts; settle address, hosting and contact.
2. Build the shared layout and the four routes with the app's existing identity.
   Done in `lagoon-website`: landing, privacy, support, licences and a 404 page.
3. Finalize the policy, support and licensing materials against the actual release.
   Remove editorial instructions and unresolved placeholders from public copy.
4. Review a preview on phone and desktop, including keyboard navigation, contrast,
   text scaling, links, downloads and the contact route.
5. Publish the approved site, verify HTTPS/direct page access, and record the
   final addresses in the app and App Store Connect.
6. Add reachable privacy/support/acknowledgements destinations before sign-in and
   in About. Verify readable content or a practical handoff on Apple TV, and put
   the approved privacy text in App Store Connect's Apple TV field.

## Ready for public release when

- [ ] Privacy/support pages contain final information and work without an account.
- [ ] Contact details work and someone is responsible for responding.
- [ ] Privacy copy matches app behavior, collection declarations and actual
  handling of website/support data.
- [ ] Licensing links deliver the required materials for the exact shipped build.
- [ ] App links, App Store Connect entries and tvOS policy text agree with the site.
- [ ] Screenshots and claims accurately describe the available release; download
  links point to the real listing when it becomes available.

These items are part of the wider [public release checklist](../public-release-checklist.md).
Building the site is separate from submitting or releasing the app.
