## What this changes

<!-- One or two sentences, and the reason. Link the Jira ticket if there is one. -->

## Checklist

- [ ] tvOS and iOS simulator builds are green
- [ ] Unit suite passes (`xcodebuild test -scheme Lagoon -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'`)
- [ ] UI changes verified in the simulator, with screenshots attached and focus paths exercised on tvOS
- [ ] The docs guide that owns the changed behaviour is updated
- [ ] Commits carry the Jira key as a suffix where one applies, for example `(HEL-31)`
- [ ] Any new dependency has an `Acknowledgements.swift` entry and bundled licence text
