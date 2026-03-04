Build NerfJournal and report the results.

Run this command:

```bash
xcodebuild \
  -project NerfJournal.xcodeproj \
  -scheme NerfJournal \
  -configuration Debug \
  build \
  2>&1 | grep -E '^(.*error:|.*warning:|Build succeeded|BUILD SUCCEEDED|BUILD FAILED|.*FAILED)' | grep -v '^$'
```

If the build succeeds, say so briefly.

If the build fails, list each error with its file path and line number, group
warnings separately, and give a short plain-English summary of what went wrong
and where to look.

Do not dump the raw xcodebuild output.
